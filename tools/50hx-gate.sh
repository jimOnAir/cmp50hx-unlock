#!/bin/bash
# modprobe install-gate: /etc/modprobe.d/50hx-gate.conf routes `modprobe nvidia`
# here so ANY loader (udev, nvml callers, gputempd, persistenced) triggers the
# OS-side unlock BEFORE the driver PCI-probes a locked card.
# One-shot per card per power cycle (one-touch rule): /run/50hx-gate/<bdf>.done
set -u
LOG(){ logger -t 50hx-gate -- "$*"; echo "gate: $*" >&2; }

exec 9>/run/lock/50hx-gate.lock 2>/dev/null; flock -w 120 9 || { LOG "lock timeout"; }

TOOL=/usr/local/bin/50hx-osunlock
[ -x "$TOOL" ] || { exec /sbin/modprobe --ignore-install "$@"; }

mkdir -p /run/50hx-gate
for dev in /sys/bus/pci/devices/*/; do
    bdf=$(basename "$dev")
    [ "$(cat "$dev/vendor" 2>/dev/null)" = "0x10de" ] || continue
    [ "$(cat "$dev/device" 2>/dev/null)" = "0x1e09" ] || continue
    [ -e "/run/50hx-gate/$bdf.done" ] && continue
    # driver must not own it; it must be a locked card
    if [ -e "$dev/driver" ]; then touch "/run/50hx-gate/$bdf.done"; continue; fi
    LOG "unlocking $bdf"
    if timeout 90 "$TOOL" --bdf "$bdf" --flr --wait 20 >"/run/50hx-gate/$bdf.log" 2>&1; then
        LOG "$bdf: tool success"
    else
        LOG "$bdf: tool rc=$? (see /run/50hx-gate/$bdf.log)"
    fi
    touch "/run/50hx-gate/$bdf.done"
done

exec /sbin/modprobe --ignore-install "$@"
