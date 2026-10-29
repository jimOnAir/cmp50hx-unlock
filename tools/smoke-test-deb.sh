#!/usr/bin/env bash
# smoke-test-deb.sh — assert the cmp50hx-unlock .deb package contract.
#
# Single home for the checks .github/workflows/release.yml and .gitlab-ci.yml
# used to duplicate: both pipelines build the package, this file defines what
# "well-formed" means. Runnable locally against any built .deb. The expected
# payload paths carry the literal driver version on purpose: a build that
# changes the version must update the contract here too.
#
#   tools/smoke-test-deb.sh cmp50hx-unlock_<driver>-<rev>_amd64.deb
set -Eeuo pipefail

deb="${1:?usage: smoke-test-deb.sh <cmp50hx-unlock_*_amd64.deb>}"
[[ -f "${deb}" ]] || { printf 'not a file: %s\n' "${deb}" >&2; exit 1; }

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
        ./opt/cmp50hx-unlock/cache/NVIDIA-Linux-x86_64-610.43.03.run \
        ./opt/cmp50hx-unlock/VERSION \
        ./usr/src/cmp50hx-610.43.03/dkms.conf \
        ./opt/cmp50hx-unlock/efi/50HXUNLK.EFI \
        ./lib/systemd/system/cmp50hx-boot.service \
        ./lib/systemd/system/cmp-idle-governor.service \
        ./usr/lib/cmp50hx-unlock/cmp50hx \
        ./usr/lib/cmp50hx-unlock/cmp50hx-boot.sh \
        ./usr/lib/cmp50hx-unlock/cmp50hx-collect.sh \
        ./opt/cmp50hx-unlock/deb/enable-services.sh \
        ./opt/cmp50hx-unlock/deb/apt-pins.sh \
        ./etc/cmp50hx/boot.conf; do
    grep -qx "${path}" <<<"${fsys}" \
        || { printf 'missing package path: %s\n' "${path}" >&2; exit 1; }
done

# the argv[0] symlinks must point at TARGET-system paths, never staging
# leftovers (a build that moves libdir/ must update this contract too)
for link in cmp50hx cmp-tune rm-issue-rate; do
    target="$(dpkg-deb -c "${deb}" |
        awk -v name="./usr/bin/${link}" 'index($0, name" -> ") {sub(/.* -> /,""); print; exit}')"
    [[ "${target}" == "/usr/lib/cmp50hx-unlock/cmp50hx" ]] \
        || { printf 'bad /usr/bin/%s symlink target: %s\n' "${link}" "${target:-none}" >&2; exit 1; }
done

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
[[ "$(cut -d- -f1 "${tmp}/opt/cmp50hx-unlock/VERSION")" == "610.43.03" ]] \
    || { printf 'VERSION stamp does not carry driver 610.43.03\n' >&2; exit 1; }
(cd "${tmp}/opt/cmp50hx-unlock/cache" \
    && sha256sum -c "${tmp}/opt/cmp50hx-unlock/deb/nvidia-run.sha256")
rm -rf "${tmp}"

log "package contract satisfied: ${deb} (Version: ${version})"
printf 'PASS_CMP_DEB_SMOKE\n'
