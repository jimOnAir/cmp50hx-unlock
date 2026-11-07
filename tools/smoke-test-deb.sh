#!/usr/bin/env bash
# smoke-test-deb.sh — assert the cmp50hx-unlock .deb package contract.
#
# Single home for the checks .github/workflows/release.yml and .gitlab-ci.yml
# used to duplicate: both pipelines build the package, this file defines what
# "well-formed" means. Runnable locally against any built .deb. The expected
# payload paths are derived from driver-pin.env — the contract follows the
# pin; only genuinely structural changes belong in this file.
#
#   tools/smoke-test-deb.sh cmp50hx-unlock_<driver>-<rev>_amd64.deb
set -Eeuo pipefail

deb="${1:?usage: smoke-test-deb.sh <cmp50hx-unlock_*_amd64.deb>}"
[[ -f "${deb}" ]] || { printf 'not a file: %s\n' "${deb}" >&2; exit 1; }

_smoke_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../driver-pin.env
. "${_smoke_root}/driver-pin.env"
readonly driver_version="${DRIVER_VERSION}"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

for command in dpkg dpkg-deb sha256sum tar; do
    command -v "${command}" >/dev/null || { printf 'missing command: %s\n' "${command}" >&2; exit 3; }
done

# --- metadata -----------------------------------------------------------------
dpkg-deb --info "${deb}"
version="$(dpkg-deb -f "${deb}" Version)"
dpkg-deb -f "${deb}" Package Version Architecture Depends Conflicts >/dev/null
# Debian Policy 5.6.12: a hyphen may only separate upstream from revision;
# --compare-versions rejects a malformed Version with exit code 2.
dpkg --compare-versions "${version}" eq "${version}" \
    || { printf 'invalid dpkg Version string: %s\n' "${version}" >&2; exit 1; }

ctrl="$(dpkg-deb --ctrl-tarfile "${deb}" | tar -t)"
for script in control preinst prerm postinst postrm conffiles; do
    # NB: here-string, not `printf | grep -q`: with pipefail, grep -q's
    # early exit kills the writer with SIGPIPE (141) and reads as failure
    grep -qx "./${script}" <<<"${ctrl}" \
        || { printf 'missing control member: %s\n' "${script}" >&2; exit 1; }
done

# --- embedded payloads ----------------------------------------------------------
fsys="$(dpkg-deb --fsys-tarfile "${deb}" | tar -t)"
for path in \
        ./opt/cmp50hx-unlock/cache/NVIDIA-Linux-x86_64-${driver_version}.run \
        ./opt/cmp50hx-unlock/VERSION \
        ./usr/src/cmp50hx-${driver_version}/dkms.conf \
        ./opt/cmp50hx-unlock/efi/50HXUNLK.EFI \
        ./lib/systemd/system/cmp50hx-boot.service \
        ./lib/systemd/system/cmp-idle-governor.service \
        ./usr/lib/cmp50hx-unlock/cmp50hx \
        ./usr/lib/cmp50hx-unlock/cmp50hx-boot.sh \
        ./usr/bin/cmp50hx-autotune \
        ./usr/lib/cmp50hx-unlock/cmp50hx-collect.sh \
        ./opt/cmp50hx-unlock/deb/enable-services.sh \
        ./opt/cmp50hx-unlock/deb/apt-pins.sh \
        ./lib/systemd/system/cmp90hx-claim.service \
        ./usr/lib/cmp50hx-unlock/cmp90hx-claim.sh \
        ./etc/modprobe.d/gpu-unlock-claim.conf \
        ./etc/modprobe.d/cmp-unlock.conf \
        ./opt/cmp50hx-unlock/firmware-90hx/gsp_ga10x.bin \
        ./opt/cmp50hx-unlock/firmware-90hx/booter_load_ga102.bin \
        ./opt/cmp50hx-unlock/firmware-90hx/gsp_boot_ga102.bin \
        ./opt/cmp50hx-unlock/firmware-90hx/gsp_boot_desc_ga102.bin \
        ./etc/cmp50hx/boot.conf; do
    grep -qx "${path}" <<<"${fsys}" \
        || { printf 'missing package path: %s\n' "${path}" >&2; exit 1; }
done

# gpu-unlock-claim (ticket 06): DKMS tree present and Kbuild pins the T09
# gate-first table — a silently wrong table selection happened in development
# (kbuild ignores EXTRA_CFLAGS), so the product build asserts it here.
grep -Eq '^\./usr/src/gpu-unlock-claim-[0-9.]+/dkms\.conf$' <<<"${fsys}" \
    || { printf 'missing gpu-unlock-claim DKMS tree\n' >&2; exit 1; }
dpkg-deb --fsys-tarfile "${deb}" \
    | tar -xO --wildcards './usr/src/gpu-unlock-claim-*/Kbuild' 2>/dev/null \
    | grep -q -- '-DGU_CMP90HX_T09' \
    || { printf 'claim Kbuild does not pin -DGU_CMP90HX_T09\n' >&2; exit 1; }

# claim window is package-owned (modules-late-610 ticket 02): every
# alias-reachable module that could bind a card before the once-per-boot
# claim unit must be blacklisted by the shipped conffile — a hand-written
# kernel-cmdline blacklist stops being a deployment requirement
cf="$(dpkg-deb --fsys-tarfile "${deb}" | tar -xO ./etc/modprobe.d/cmp-unlock.conf)"
for want_line in "blacklist nouveau" "blacklist nvidia" "blacklist nvidia_uvm" \
                 "blacklist nvidia_drm" "blacklist nvidia_modeset"; do
    grep -qx "${want_line}" <<<"${cf}" \
        || { printf 'cmp-unlock.conf missing line: %s\n' "${want_line}" >&2; exit 1; }
done

# stock-equivalent late module load (ticket 01): the phase exists, names
# exactly the alias/autoload-reachable default set (peermem has no alias by
# design), is wired to the documented kill-switch, and boots with it on
bootsh="$(dpkg-deb --fsys-tarfile "${deb}" | tar -xO ./usr/lib/cmp50hx-unlock/cmp50hx-boot.sh)"
grep -qF 'NVIDIA_MODULES_LATE' <<<"${bootsh}" \
    || { printf 'cmp50hx-boot.sh lacks the NVIDIA_MODULES_LATE late-load phase\n' >&2; exit 1; }
grep -qE 'for late_mod in nvidia nvidia_uvm nvidia-drm' <<<"${bootsh}" \
    || { printf 'late-load module set drifted from the alias/autoload default set\n' >&2; exit 1; }
# autotune (map autotune-610): the shipped script must be the real tool
autotune="$(dpkg-deb --fsys-tarfile "${deb}" | tar -xO ./usr/bin/cmp50hx-autotune)"
grep -qF 'cmp50hx-autotune' <<<"${autotune}" \
    && grep -qF -- '--apply' <<<"${autotune}" \
    || { printf 'cmp50hx-autotune payload is not the expected tool\n' >&2; exit 1; }
bootconf="$(dpkg-deb --fsys-tarfile "${deb}" | tar -xO ./etc/cmp50hx/boot.conf)"
grep -qxF 'NVIDIA_MODULES_LATE=enabled' <<<"${bootconf}" \
    || { printf 'boot.conf does not ship NVIDIA_MODULES_LATE=enabled as the default\n' >&2; exit 1; }

# the argv[0] symlinks must point at TARGET-system paths, never staging
# leftovers (a build that moves libdir/ must update this contract too)
for link in cmp50hx cmp-tune rm-issue-rate; do
    target="$(dpkg-deb -c "${deb}" |
        awk -v name="./usr/bin/${link}" 'index($0, name" -> ") {sub(/.* -> /,""); print; exit}')"
    [[ "${target}" == "/usr/lib/cmp50hx-unlock/cmp50hx" ]] \
        || { printf 'bad /usr/bin/%s symlink target: %s\n' "${link}" "${target:-none}" >&2; exit 1; }
done

# --- purge lifecycle wiring (deb-purge-lifecycle fix batch, 2026-11-01) -----
# The dynamic half is tools/lifecycle-test-deb.sh (full install/purge/
# reinstall loop); the static half locks the maintainer-script wiring so a
# future edit cannot silently drop a purge guarantee. Patterns use grep -F
# on here-strings — never a pipe into grep -q (SIGPIPE + pipefail = 141).
for spec in \
        "prerm:CMP_ESP_SKIP:removal must honour the ESP skip convention" \
        "prerm:initrd-kernels:prerm must record the kernels needing an initramfs rebuild" \
        "postrm:initrd-kernels:postrm must rebuild every recorded kernel's initramfs" \
        "postrm:cmp50-bak:postrm purge must remove the initrd rollback backups" \
        "postrm:firmware-copies.txt:postrm must clean the fallback firmware copies" \
        "prerm:predates gpu-unlock-claim:prerm must sweep gpu-unlock-claim DKMS state when downgrading to a claim-less revision (postrm cannot: dpkg runs the INCOMING version's postrm)" \
        "postrm:install_dir}/logs:postrm must remove the untracked logs dir" \
        "postinst:firmware-copies.txt:postinst must record fallback firmware copies" \
        "postinst:nvidia-peermem:postinst must verify all five modules per kernel" \
        "postinst:nvidia-uvm:postinst must verify all five modules per kernel"; do
    script="${spec%%:*}"; rest="${spec#*:}"; pattern="${rest%%:*}"; why="${rest#*:}"
    body="$(dpkg-deb --ctrl-tarfile "${deb}" | tar -xO "./${script}")"
    grep -qF -- "${pattern}" <<<"${body}" \
        || { printf '%s missing wiring (%s): %s\n' "${script}" "${pattern}" "${why}" >&2; exit 1; }
done

# install-linux.sh --remove must be ownership-scoped: a wholesale rm -rf of
# the ESP EFI directory would delete other unlockers' files (gap 2)
efi_body="$(dpkg-deb --fsys-tarfile "${deb}" | tar -xO ./opt/cmp50hx-unlock/efi/install-linux.sh)"
! grep -qF 'rm -rf "$ESP_MNT/$EFI_DIR"' <<<"${efi_body}" \
    || { printf 'install-linux.sh still wipes the whole ESP EFI directory\n' >&2; exit 1; }
grep -qF 'files this deployer did not place' <<<"${efi_body}" \
    || { printf 'install-linux.sh --remove is not ownership-scoped\n' >&2; exit 1; }

# --- apt pin protection wiring --------------------------------------------------
# The deb blocks stock NVIDIA driver packages from moving over the unlock via
# /etc/apt/preferences.d/cmp50hx-unlock (deb/apt-pins.sh documents the
# contract; the live lifecycle runs in the ubuntu:26.04 CI jobs). Static
# half: maintainer-script wiring. apt-mark must NEVER appear in the scripts:
# it needs the dpkg database lock that dpkg holds across them (proven to fail
# from postinst; see findings.md).
helper_body="$(dpkg-deb --fsys-tarfile "${deb}" | tar -xO ./opt/cmp50hx-unlock/deb/apt-pins.sh)"
grep -q 'Pin-Priority: -1' <<<"${helper_body}" \
    || { printf 'apt-pins.sh does not pin the stock driver family at -1\n' >&2; exit 1; }
for script in postinst prerm postrm; do
    body="$(dpkg-deb --ctrl-tarfile "${deb}" | tar -xO "./${script}")"
    grep -q 'preferences\.d/cmp50hx-unlock\|apt_pins_apply' <<<"${body}" \
        || { printf '%s missing apt-pin wiring\n' "${script}" >&2; exit 1; }
    ! grep -qE 'apt-mark (hold|unhold|showhold)' <<<"${body}" \
        || { printf '%s calls apt-mark (needs the dpkg lock maintainer scripts hold)\n' "${script}" >&2; exit 1; }
done

# --- the embedded .run must be byte-identical to the official one ---------------
tmp="$(mktemp -d)"
dpkg-deb -x "${deb}" "${tmp}"
# maintainer scripts derive the driver version from the build stamp;
# the stamp must carry exactly the version this contract pins
[[ "$(cut -d- -f1 "${tmp}/opt/cmp50hx-unlock/VERSION")" == "${driver_version}" ]] \
    || { printf 'VERSION stamp does not carry driver %s\n' "${driver_version}" >&2; exit 1; }
(cd "${tmp}/opt/cmp50hx-unlock/cache" \
    && sha256sum -c "${tmp}/opt/cmp50hx-unlock/deb/nvidia-run.sha256")
rm -rf "${tmp}"

log "package contract satisfied: ${deb} (Version: ${version})"
printf 'PASS_CMP_DEB_SMOKE\n'
