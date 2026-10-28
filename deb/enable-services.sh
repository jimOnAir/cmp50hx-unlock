#!/usr/bin/env bash
# enable-services.sh — the single source of truth for which cmp50hx-unlock
# services a host ends up with. Called by deb/postinst (mode "deb",
# offline-safe via deb-systemd-helper) and by install.sh (mode "install").
# The installer surface problem this kills: the enable list used to live in
# three places (postinst, install.sh, the bench SSH deploy scripts), which is
# how retired units kept resurrecting on upgraded hosts.
#
# Current service set (see README):
#   cmp50hx-boot.service        boot flow: verdict + ladder + Gen2 (+ profile)
#   cmp-idle-governor.service   resident idle P-state daemon
#
# Everything else was merged into those two or never was a service: the EFI
# app runs pre-OS, the modprobe gate is a hook, and 50hx-osunlock stays a
# bench-deployed opt-in unit (its blobs are not redistributable).
#
# Every legacy unit name is disabled and its /etc leftovers removed, so both
# channels converge on the same set no matter what the host ran before.
set -u

mode="${1:-install}"

LEGACY_UNITS=(
    cmp50hx-gen2.service
    cmp-governor-check.service
    cmp-governor-check.timer
    50hx-boot.service
    50hx-boothealth.service
    50hx-collect.service
    cmp-tune-boot.service
    cmp-tune-profile.service
)
ENABLE_UNITS=(cmp50hx-boot.service)
if [ "${CMP_ENABLE_GOVERNOR:-1}" = "1" ]; then
    ENABLE_UNITS+=(cmp-idle-governor.service)
fi

disable_unit() {
    local unit="$1"
    if command -v deb-systemd-helper >/dev/null 2>&1; then
        deb-systemd-helper disable "$unit" >/dev/null 2>&1 || true
    fi
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    # /etc copies of units that are no longer shipped (install.sh path and
    # old debs installed into /etc/systemd/system directly)
    rm -f "/etc/systemd/system/${unit}" /etc/systemd/system/*.wants/"${unit}" 2>/dev/null || true
}

for unit in "${LEGACY_UNITS[@]}"; do disable_unit "$unit"; done

for unit in "${ENABLE_UNITS[@]}"; do
    if [ "$mode" = deb ] && command -v deb-systemd-helper >/dev/null 2>&1; then
        deb-systemd-helper enable "$unit" >/dev/null 2>&1 || true
    else
        systemctl enable "$unit" >/dev/null 2>&1 || true
    fi
done

command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
printf 'enabled: %s\n' "${ENABLE_UNITS[*]}"
