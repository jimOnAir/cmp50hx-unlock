#!/bin/bash
# 50hx-boothealth — ticket 04 policy: parse EFI chain logs each boot; if any
# installed CMP is locked, warm re-roll (up to MAX_ROLLS per power cycle),
# then accept degraded state. Power-cycle (PMU cure) = manual only — no PDU
# hardware (user decision 2026-10-27). Runs Before=docker so a re-roll
# happens before llama allocates on capped cards.
set -u
MAX_ROLLS=3
STATE=/var/lib/50hx-boothealth
LOG=/run/50hx-boothealth.log
mkdir -p "$STATE"
exec >"$LOG" 2>&1


# ---- PCIe Gen2 late retrain (ticket 11) ----
# Patch 04's in-driver retrain fires at ~8 s and loses the race with GSP link
# management settling (RETRAIN_FAIL status=1041). Policy + target writes have
# already succeeded by then; a plain Retrain Link on the upstream root port
# ~30 s later lands Gen2 and it survives driver init + full load (proven
# 2026-10-27). BIOS slot speed is NOT a factor (same ports train a 3090 at
# Gen3). Requires: card LnkCap >= 5GT (adoption done by driver) and its
# LnkCtl2 target already at >= 5GT; we only mirror target onto the root port
# and pulse Retrain Link — safe under load, idempotent.
link_speed() { # bdf -> 1..5 or 0
    sudo lspci -s "$1" -vv 2>/dev/null | grep -oE "LnkSta:[[:space:]]+Speed [0-9.]+GT/s" | head -1 |
        grep -oE "[0-9.]+" | cut -d. -f1
}
upstream_of() {
    local bus=$(echo "${1#0000:}" | awk -F: '{print $(NF-1)}') b
    for b in $(lspci -D 2>/dev/null | awk "/^[0-9a-f]+:00:/ {print \$1}" | grep -E "^[0-9a-f]+:00:[0-9a-f]+\.[0-9a-f]+$"); do
        [ "$(sudo lspci -s "$b" -vv 2>/dev/null | grep -oE 'secondary=[0-9a-f]+' | head -1)" = "secondary=$bus" ] && { echo "$b"; return 0; }
    done
    return 1
}
exp_base_of() { sudo lspci -s "$1" -vv | grep -oE "\[([0-9a-f]+)\] Express" | grep -oE "[0-9a-f]+" | head -1; }
gen2_retrain_one() { # gpu bdf
    local gpu="$1" br base v
    br=$(upstream_of "$gpu") || { echo "gen2 $gpu: no upstream found"; return 1; }
    base=$(exp_base_of "$br"); [ -n "$base" ] || { echo "gen2 $gpu: no express cap on $br"; return 1; }
    # mirror card's 5GT target onto root port, then pulse retrain
    local ct2off=$(python3 -c "print('%x'%(0x$base+0x30))")
    v=$(sudo setpci -s "$br" $ct2off.w)
    sudo setpci -s "$br" $ct2off.w=$(python3 -c "print('%04x'%((int('$v',16)&~0xf)|2))")
    local lcoff=$(python3 -c "print('%x'%(0x$base+0x10))")
    local tries=0
    while [ $tries -lt 3 ]; do
        v=$(sudo setpci -s "$br" $lcoff.w)
        sudo setpci -s "$br" $lcoff.w=$(python3 -c "print('%04x'%((int('$v',16)|0x20)))")
        sleep 2
        if [ "$(link_speed "$gpu")" = "5" ]; then echo "gen2 $gpu: RETRAIN_PASS via $br"; return 0; fi
        tries=$((tries+1)); sleep 3
    done
    echo "gen2 $gpu: still $(link_speed "$gpu")GT after $tries retrain(s) via $br"; return 1
}
gen2_phase() {
    local d b
    for d in /sys/bus/pci/devices/*/; do
        b=$(basename "$d")
        [ "$(cat "$d/vendor" 2>/dev/null)" = "0x10de" ] || continue
        [ "$(cat "$d/device" 2>/dev/null)" = "0x1e09" ] || continue
        spd=$(link_speed "$b")
        cap=$(sudo lspci -s "$b" -vv 2>/dev/null | awk '/LnkCap:/{print; exit}' | grep -oE "Speed [0-9.]+GT/s" | grep -oE "[0-9.]+" | cut -d. -f1)
        if [ "$spd" = "5" ]; then echo "gen2 $b: already 5GT"; continue; fi
        [ "$cap" = "5" ] || { echo "gen2 $b: cap=${cap:-?}GT — adoption missing, skip"; continue; }
        gen2_retrain_one "$b"
    done
}

count_50hx() {   # ONLY 1e09 cards are roll-gated: the 90HX unlock is
    local n=0 d   # driver-side stockflow with no per-boot ESP verdict line
    for d in /sys/bus/pci/devices/*/; do
        [ "$(cat "$d/vendor" 2>/dev/null)" = "0x10de" ] || continue
        [ "$(cat "$d/device" 2>/dev/null)" = "0x1e09" ] || continue
        n=$((n+1))
    done
    echo "$n"
}
has_90hx() {
    local d
    for d in /sys/bus/pci/devices/*/; do
        [ "$(cat "$d/vendor" 2>/dev/null)" = "0x10de" ] || continue
        [ "$(cat "$d/device" 2>/dev/null)" = "0x220d" ] || continue
        [ -e "$d/driver" ] && echo "bound" || echo "unbound"
        return 0
    done
    echo "absent"
}

if [ "${1:-}" = "--gen2-only" ]; then gen2_phase; exit 0; fi

installed=$(count_50hx)
c90=$(has_90hx)
[ "$c90" = absent ] || echo "cmp90hx present: $c90 (driver-side unlock, never roll-gated)"
won=0
for u in u1 u3 u4; do
    grep -q "UNLOCKED (SS0" "/boot/efi/50hx_log_$u.txt" 2>/dev/null && won=$((won+1))
done
echo "installed=$installed unlocked_by_efi=$won"

if [ "$installed" = 0 ]; then exit 0; fi   # 90HX-only box: nothing to roll for

if [ "$won" -ge "$installed" ]; then
    rm -f "$STATE/rolls" "$STATE/accepted"
    echo "ALL-UNLOCKED"
    touch /run/50hx-unlocked
    gen2_phase || true
    exit 0
fi

# episode boundary: a previous boot spent the budget and accepted degraded
# cards => THIS boot starts a fresh episode (ticket-04 policy, 2026-10-27 fix)
if [ -e "$STATE/accepted" ]; then
    echo "new episode after previous degraded-accept"; rm -f "$STATE/rolls" "$STATE/accepted"
fi
# fallback: is this a new power cycle? (roll state older than 6 h = reset)
if [ -e "$STATE/rolls" ] && \
   [ $(( $(date +%s) - $(stat -c %Y "$STATE/rolls") )) -gt 21600 ]; then
    echo "reset stale roll counter"; rm -f "$STATE/rolls"
fi
rolls=$(cat "$STATE/rolls" 2>/dev/null || echo 0)

if [ "$rolls" -lt "$MAX_ROLLS" ]; then
    echo $((rolls+1)) > "$STATE/rolls"
    echo "DEGRADED win=$won/$installed roll=$((rolls+1))/$MAX_ROLLS -> warm re-roll in 20s"
    logger -t 50hx-boothealth -- "re-roll $((rolls+1))/$MAX_ROLLS ($won/$installed unlocked)"
    sleep 20
    systemctl reboot
    exit 0
fi

echo "DEGRADED win=$won/$installed — roll budget spent; accepting capped cards"
touch "$STATE/accepted"
gen2_phase || true   # winner cards still deserve Gen2; locked cards are skipped by the phase itself
logger -t 50hx-boothealth -- "accepting degraded boot ($won/$installed unlocked, no PDU: manual PSU cut cures)"
exit 0
