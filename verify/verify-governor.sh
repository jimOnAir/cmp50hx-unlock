#!/usr/bin/env bash
# verify-governor.sh — fleet gate for the idle P-state governor.
# PASS_CMP_GOVERNOR: unit enabled, active, running the cmp-governor ELF.
# Opportunistic evidence (never disruptive): this-boot journal shows a forced
# P8, or a supported card currently reads P8. Absent/disabled unit is
# WARN-only (hosts may opt out); enabled-but-dead is FAIL.
set -u
u=cmp-idle-governor.service
if ! systemctl cat "$u" >/dev/null 2>&1; then
    echo "WARN_CMP_GOVERNOR_ABSENT unit not installed"
    exit 0
fi
state=$(systemctl is-enabled "$u" 2>/dev/null || true)
active=$(systemctl is-active "$u" 2>/dev/null || true)
case "$state/$active" in
    enabled/active) ;;
    enabled/*)
        echo "FAIL_CMP_GOVERNOR enabled but active=$active"
        exit 1
        ;;
    *)
        echo "WARN_CMP_GOVERNOR_DISABLED state=$state active=$active (opt-out host?)"
        exit 0
        ;;
esac
pid=$(systemctl show -p MainPID --value "$u" 2>/dev/null)
if [ "${pid:-0}" = "0" ]; then
    echo "FAIL_CMP_GOVERNOR no main pid"
    exit 1
fi
comm=$(tr -d '\0' <"/proc/$pid/comm" 2>/dev/null || echo none)
if [ "$comm" != "cmp-governor" ]; then
    echo "FAIL_CMP_GOVERNOR main process is $comm, not cmp-governor"
    exit 1
fi
proof=""
if journalctl -u "$u" -b --no-pager 2>/dev/null | grep -q "forced P8"; then
    proof="journal:P8-forced-this-boot"
elif nvidia-smi --query-gpu=pci.device_id,pstate --format=csv,noheader 2>/dev/null |
     grep -iE "0x1E0910DE|0x220D10DE" | grep -q ", *P8"; then
    proof="live:P8-now"
fi
echo "PASS_CMP_GOVERNOR enabled active pid=$pid proof=${proof:-none-yet(presence-only)}"
