#!/bin/bash
# cmp50hx-boot — the single CMP 50HX boot-flow unit (merged 2026-10-28 from
# cmp50hx-gen2 + 50hx-collect + 50hx-boothealth + the cmp-tune boot units):
#   phase 1: bench evidence archival (opt-in: CMP_BOOT_COLLECT=1)
#   phase 2: unlock verdict from the EFI chain logs (+ degraded advice)
#   phase 3: PCIe Gen2 policy + retrain, as a READINESS GATE for the
#            ESP-promised cards (bounded 180 s; fails the unit if a card
#            the pre-OS unlocker promised never reaches Gen2 PASS)
#   phase 4: optional cmp-tune boot profile (CMP_BOOT_PROFILE)
#
# No warm re-roll ladder (retired 2026-10-28, docs/adr/0001-ladder-retired.md):
# a boot that reboots the host to gamble on the booter-window lottery breaks
# boot determinism. A degraded boot now ACCEPTS loudly and tells the operator
# the two real cures: another manual reboot (one new ticket per boot; the
# reject is a ~15-20% lottery, 2026-10-27 archives) or a ~10 s power cycle
# (always). Locked cards are terminal this power cycle: never waited on.
# Why verdict-before-gate: the readiness gate may wait minutes; the verdict
# must be in the journal even if the gate later times out.
# Driver-load note: with CMP_BOOT_COLLECT=1 the collect phase's nvidia-smi
# loads the module ~0.3 s into the unit (setuid nvidia-modprobe bypasses the
# kernel blacklist) — benign and load-bearing: gen2/PASS are sysfs/BAR0 MMIO
# only, so the gate never depends on the driver being up, and it cannot
# deadlock when nobody else has triggered modprobe yet.
# Policy file: /etc/cmp50hx/boot.conf (sourced here; never fails the boot).
set -u

dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
CONF=${CMP_TEST_CONF:-/etc/cmp50hx/boot.conf}
CMP_BOOT_COLLECT=0
CMP_BOOT_PROFILE=""
# shellcheck disable=SC1090,SC1091
[ -f "$CONF" ] && . "$CONF"

# Test seams (tools/smoke-test-boot-verdict.sh): every variable defaults to
# the production path; unset the CMP_TEST_* env and behaviour is identical.
ESP=${CMP_TEST_ESP_DIR:-/boot/efi}
PCI=${CMP_TEST_PCI_DIR:-/sys/bus/pci}
RUNFLAG=${CMP_TEST_RUN_FLAG:-/run/50hx-unlocked}

# the merged userland binary: libdir sibling (.deb) or PATH (/usr/local/bin
# from install.sh, /usr/bin symlink from the .deb)
CMP50HX=${CMP_TEST_BIN:-$dir/cmp50hx}
[ -x "$CMP50HX" ] || CMP50HX=$(command -v cmp50hx || true)
[ -n "$CMP50HX" ] || { echo "cmp50hx binary not found next to $0 nor on PATH"; exit 1; }

# manual/bench entry: run only the Gen2 phase
if [ "${1:-}" = "--gen2-only" ]; then
    exec "$CMP50HX" gen2
fi

# --- phase 1: bench evidence archival (best-effort, never vetoes the boot) --
if [ "${CMP_BOOT_COLLECT}" = "1" ] && [ -f "$dir/cmp50hx-collect.sh" ]; then
    timeout 30 bash "$dir/cmp50hx-collect.sh" >/run/cmp50hx-boot-collect.log 2>&1 \
        || logger -t cmp50hx-boot -- "collect phase rc=$? (continuing)"
fi

# --- phase 2: unlock verdict -------------------------------------------------
count_50hx() {   # ONLY 1e09 cards get an ESP verdict line and the readiness
    local n=0 d   # gate: the 90HX unlock is driver-side stockflow
    for d in "$PCI"/devices/*/; do
        [ "$(cat "$d/vendor" 2>/dev/null)" = "0x10de" ] || continue
        [ "$(cat "$d/device" 2>/dev/null)" = "0x1e09" ] || continue
        n=$((n+1))
    done
    echo "$n"
}
has_90hx() {
    local d
    for d in "$PCI"/devices/*/; do
        [ "$(cat "$d/vendor" 2>/dev/null)" = "0x10de" ] || continue
        [ "$(cat "$d/device" 2>/dev/null)" = "0x220d" ] || continue
        [ -e "$d/driver" ] && echo "bound" || echo "unbound"
        return 0
    done
    echo "absent"
}

installed=$(count_50hx)
c90=$(has_90hx)
[ "$c90" = absent ] || echo "cmp90hx present: $c90 (driver-side unlock, not readiness-gated)"

# Freshness rule (same window as cmp50hx-collect.sh): the unlocker writes
# the ESP log PRE-OS, so its FAT mtime lands within [boot-300s, boot+120s]
# iff it ran THIS boot. A stale log (e.g. a plain 50hx_log.txt left by an
# older single-module deployment) must never count toward the verdict —
# that would mask a locked boot.
BOOT_EPOCH=${CMP_TEST_BOOT_EPOCH:-$(date -u -d "$(uptime -s)" +%s 2>/dev/null || echo 0)}
won=0
seen_log=0
for lf in "$ESP/50hx_log_u1.txt" "$ESP/50hx_log_u3.txt" \
          "$ESP/50hx_log_u4.txt" "$ESP/50hx_log.txt"; do
    [ -f "$lf" ] || continue
    M=$(stat -c %Y "$lf" 2>/dev/null || echo 0)
    if [ "$BOOT_EPOCH" -gt 0 ] && \
       { [ "$M" -lt $((BOOT_EPOCH - 300)) ] || [ "$M" -gt $((BOOT_EPOCH + 120)) ]; }; then
        echo "stale ESP log (not counted): $lf"
        continue
    fi
    seen_log=1
    grep -q "UNLOCKED (SS0" "$lf" 2>/dev/null && won=$((won+1))
done

# promised = how many Gen2 PASSes the readiness gate must see to call this
# boot healthy; -1 = no ESP promise exists to gate on (best-effort gen2).
case "$installed:$seen_log:$won" in
    0:*)
        echo "no CMP 50HX installed; skipping verdict+gate"
        promised=-1 ;;
    *:0:*)
        echo "NO_EFI_VERDICT no unlocker log on the ESP; skipping verdict, gen2 best-effort"
        promised=-1 ;;
    *)
        if [ "$won" -ge "$installed" ]; then
            echo "ALL-UNLOCKED win=$won/$installed"
            touch "$RUNFLAG"
            promised=$won
        else
            echo "installed=$installed unlocked_by_efi=$won"
            echo "DEGRADED win=$won/$installed — accepting this boot; the host will NOT reboot itself"
            echo "  (=$((installed-won)) card(s) compute-locked: the pre-OS unlocker missed their booter window. Cures: reboot once per ticket (it is a ~15-20% lottery per warm boot — 2026-10-27 bench data) or a ~10 s power cycle (always works). Run 'cmp50hx explain' for the full story.)"
            logger -t cmp50hx-boot -- "DEGRADED win=$won/$installed accepted; manual reboot/power-cycle cures (ladder retired: docs/adr/0001)"
            promised=$won
        fi ;;
esac

# --- phase 3: Gen2 readiness gate --------------------------------------------
# Gate ONLY on ESP-promised cards: a card the unlocker rejected this boot has
# a gate that can NEVER open until the power is cut, and waiting on it is how
# the pre-cap unit held docker hostage for 20 min (2026-10-28). Counting
# PASS lines against `won` needs no module->BDF map: locked cards
# structurally cannot PASS, so passed < promised IS the "a promised card
# failed to initialize" signal. gen2 is sysfs/BAR0 MMIO — no NVML, no driver,
# no deadlock regardless of who loaded (or skipped) nvidia.ko.
glog=$(mktemp "${TMPDIR:-/tmp}/cmp50hx-boot-gen2.XXXXXX")
t0=$(date +%s)
if [ "$promised" -le 0 ]; then
    # promised=0 no longer means "nothing can work": since issue 15 the kernel
    # V551 stockflow unlocks armed-but-EFI-missed cards at probe — those cards
    # exist and deserve Gen2 retrain even though the ESP promised none. Proven
    # live 2026-10-28 19:45: win=0/3 ESP verdict, kernel rescued 2/3 cards
    # (HANDOFF_PASS SS0=88888888) that then sat at 2.5 GT/s because we skipped.
    # Genuinely locked cards cost only the gen2 GATE-GIVEUP grace (90 s).
    [ "$promised" = 0 ] && echo "gen2 best-effort: ESP promised none, but kernel stockflow may have rescued armed cards"
    timeout 120 "$CMP50HX" gen2 || logger -t cmp50hx-boot -- "WARN gen2 best-effort rc=$? (locked-card grace applies)"
    echo "gen2 best-effort done (no ESP-promised count to gate on)"
else
    timeout 180 "$CMP50HX" gen2 2>&1 | tee "$glog"
    rc=${PIPESTATUS[0]}
    passed=$(grep -c "PASS, link" "$glog" 2>/dev/null || true)
    if [ "$passed" -ge "$promised" ]; then
        echo "READY: $passed/$promised promised GPUs initialized (Gen2 PASS) after $(( $(date +%s) - t0 ))s"
    else
        echo "INIT-INCOMPLETE: only $passed/$promised promised GPUs reached Gen2 PASS (rc=$rc, $(( $(date +%s) - t0 ))s)"
        echo "  (a card the pre-OS unlocker PROMISED is not initializing — driver/GSP flake on an unlocked card; reboot once, else power cycle. Run 'cmp50hx explain'.)"
        logger -t cmp50hx-boot -- "INIT-INCOMPLETE passed=$passed promised=$promised rc=$rc — failing unit (deterministic-boot policy: a promised GPU must be ready before dependents start)"
        rm -f "$glog"
        exit 1
    fi
fi
rm -f "$glog"

# --- phase 4: optional boot tuning profile (driver is up by now) ------------
if [ -n "${CMP_BOOT_PROFILE}" ]; then
    if timeout 120 "$CMP50HX" tune apply "${CMP_BOOT_PROFILE}"; then
        logger -t cmp50hx-boot -- "applied boot profile ${CMP_BOOT_PROFILE}"
    else
        logger -t cmp50hx-boot -- "WARN boot profile ${CMP_BOOT_PROFILE} rc=$? (continuing)"
    fi
fi

exit 0
