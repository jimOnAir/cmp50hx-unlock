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

count_installed() {
    local n=0 d
    for d in /sys/bus/pci/devices/*/; do
        [ "$(cat "$d/vendor" 2>/dev/null)" = "0x10de" ] || continue
        [ "$(cat "$d/device" 2>/dev/null)" = "0x1e09" ] || continue
        n=$((n+1))
    done
    echo "$n"
}

installed=$(count_installed)
won=0
for u in u1 u3 u4; do
    grep -q "UNLOCKED (SS0" "/boot/efi/50hx_log_$u.txt" 2>/dev/null && won=$((won+1))
done
echo "installed=$installed unlocked_by_efi=$won"

if [ "$installed" = 0 ]; then exit 0; fi

if [ "$won" -ge "$installed" ]; then
    rm -f "$STATE/rolls"
    echo "ALL-UNLOCKED"
    touch /run/50hx-unlocked
    exit 0
fi

# degraded boot — is this a new power cycle? (roll state older than 6 h = reset)
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
logger -t 50hx-boothealth -- "accepting degraded boot ($won/$installed unlocked, no PDU: manual PSU cut cures)"
exit 0
