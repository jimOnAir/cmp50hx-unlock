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
        ./lib/systemd/system/cmp50hx-gen2.service; do
    grep -qx "${path}" <<<"${fsys}" \
        || { printf 'missing package path: %s\n' "${path}" >&2; exit 1; }
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
