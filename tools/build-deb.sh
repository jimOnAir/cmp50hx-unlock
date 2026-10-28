#!/usr/bin/env bash
# build-deb.sh — assemble the self-contained cmp50hx-unlock .deb.
#
# The .deb replaces the old cmp50hx-unlock-linux.run and mirrors the
# install.sh feature set:
#   - embedded official NVIDIA 610.43.03 .run (userland, no kernel modules)
#   - patched open kernel module source as a DKMS tree (auto-rebuild on
#     every kernel update)
#   - UEFI ESP unlock (50HXUNLK.EFI + install-linux.sh), the cmp50hx-gen2
#     service, the idle governor (enabled by default) and cmp-tune
#
# Build requirements: Ubuntu/Debian host (or ubuntu:24.04 container) with
# dpkg-deb, build-essential, curl, patch, kmod, binutils. Needs network on
# first run to fetch the NVIDIA source archive and the official .run
# (both cached under cache/, verified by SHA-256). efi-unlock/50HXUNLK.EFI
# must exist: run "make efi" first (the Makefile deb target depends on it).
#
# Output: cmp50hx-unlock_<driver>-<rev>_amd64.deb
#
#   CMP_DEB_REV=0.1.30 bash tools/build-deb.sh [--out DIR]
#   CMP_DEB_CARD=cmp50hx  — single-model profile (default: both)
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly driver_version="610.43.03"
# Patch profile fed to build.sh --prepare-source. Default "both" = the
# combined 90HX+50HX fleet stack — REQUIRED on multi-CMP hosts: the
# cmp50hx-only profile is slot-blind, and its second/third identical
# 1e09 card answers RmAlloc with 0x1b NV_ERR_INSUFFICIENT_PERMISSIONS
# (proven on llm2 2026-10-28; the combined .kos pass all 17 issue-rate
# controls on every card). both/01 was regenerated 2026-10-28 to drop
# the conflict-residue signature pair; verified compile + multi-card.
readonly card_profile="${CMP_DEB_CARD:-both}"
readonly nvidia_run_url="https://us.download.nvidia.com/XFree86/Linux-x86_64/${driver_version}/NVIDIA-Linux-x86_64-${driver_version}.run"
readonly nvidia_run_sha256="45e2d4c134a23c35e50f253a4aa63e7e5e8d17e3d185d4a07c8a58e9612ed392"
readonly cache_dir="${CMP_UNLOCK_CACHE_DIR:-${root}/cache}"
readonly work_dir="${CMP_UNLOCK_WORK_DIR:-${root}/work}"

out_dir="${root}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) out_dir="${2:?--out needs a directory}"; shift 2 ;;
        -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

if [[ -n "${CMP_DEB_REV:-}" ]]; then
    rev="${CMP_DEB_REV}"
elif command -v git >/dev/null 2>&1; then
    rev="$(git -C "${root}" describe --tags --always --dirty 2>/dev/null || echo 0)"
else
    printf 'CMP_DEB_REV is unset and git is unavailable; set CMP_DEB_REV=<rev> or install git\n' >&2
    exit 3
fi
rev="${rev#v}"
[[ -n "${rev}" ]] || rev=0
# Debian Policy 5.6.12 forbids hyphens in the upstream version part; the
# git-describe fallback (1.1.22-17-g<sha>-dirty) carries them, so collapse
# them to "+", which sorts above the clean tag build.
rev="${rev//-/+}"
readonly version="${driver_version}-${rev}"
readonly pkg="cmp50hx-unlock"
readonly deb_name="${pkg}_${version}_amd64.deb"
readonly stage="${root}/.deb-stage"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

for command in dpkg-deb awk cc curl make patch sha256sum tar; do
    command -v "${command}" >/dev/null || { printf 'missing command: %s\n' "${command}" >&2; exit 3; }
done
[[ -f "${root}/efi-unlock/50HXUNLK.EFI" ]] \
    || { printf 'efi-unlock/50HXUNLK.EFI missing; run make efi first\n' >&2; exit 4; }

readonly run_file="${cache_dir}/NVIDIA-Linux-x86_64-${driver_version}.run"

rm -rf "${stage}"
mkdir -p "${stage}/DEBIAN" "${cache_dir}"

# --- 1. NVIDIA official .run (embedded verbatim) ----------------------------
if [[ ! -f "${run_file}" ]]; then
    log "downloading the NVIDIA ${driver_version} .run (several hundred MB)"
    curl -fL --retry 3 --show-error -o "${run_file}.part" "${nvidia_run_url}"
    mv "${run_file}.part" "${run_file}"
fi
printf '%s  %s\n' "${nvidia_run_sha256}" "${run_file}" | sha256sum -c - \
    || { printf 'NVIDIA .run SHA-256 mismatch\n' >&2; exit 5; }

# --- 2. patched source tree -> /usr/src/<module>-<version> ------------------
log "preparing the patched module source (build.sh --prepare-source)"
readonly dkms_module="cmp50hx"
readonly src_tree="${stage}/usr/src/${dkms_module}-${driver_version}"
CMP_UNLOCK_CACHE_DIR="${cache_dir}" CMP_UNLOCK_WORK_DIR="${work_dir}" \
    bash "${root}/build.sh" --card "${card_profile}" --prepare-source "${src_tree}" >/dev/null

# NOTE: DKMS rewrites a MAKE[0]/CLEAN that begins with "make" to inject
# KERNELRELEASE=$kernelver (dkms: ${make_command/#make/make ... KERNELRELEASE=}).
# NVIDIA's kernel-open/Makefile interprets a pre-set KERNELRELEASE as "read
# by Kbuild" and fails. The "env" prefix keeps the command off the "make"
# literal so DKMS passes no KERNELRELEASE; kbuild defines it at the right
# phase on its own (verified on noble 6.8.0-147-generic in CI test).
cat > "${src_tree}/dkms.conf" <<EOF
PACKAGE_NAME="${dkms_module}"
PACKAGE_VERSION="${driver_version}"
AUTOINSTALL="yes"
MAKE[0]="env make -j\$(nproc) modules KERNEL_UNAME=\${kernelver}"
CLEAN="env make clean"
BUILT_MODULE_NAME[0]="nvidia"
BUILT_MODULE_LOCATION[0]="kernel-open/"
DEST_MODULE_LOCATION[0]="/updates/dkms"
BUILT_MODULE_NAME[1]="nvidia-uvm"
BUILT_MODULE_LOCATION[1]="kernel-open/"
DEST_MODULE_LOCATION[1]="/updates/dkms"
BUILT_MODULE_NAME[2]="nvidia-modeset"
BUILT_MODULE_LOCATION[2]="kernel-open/"
DEST_MODULE_LOCATION[2]="/updates/dkms"
BUILT_MODULE_NAME[3]="nvidia-drm"
BUILT_MODULE_LOCATION[3]="kernel-open/"
DEST_MODULE_LOCATION[3]="/updates/dkms"
BUILT_MODULE_NAME[4]="nvidia-peermem"
BUILT_MODULE_LOCATION[4]="kernel-open/"
DEST_MODULE_LOCATION[4]="/updates/dkms"
EOF

# --- 3. runtime tree under /opt/cmp50hx-unlock ------------------------------
opt="${stage}/opt/cmp50hx-unlock"
mkdir -p "${opt}/cache" "${opt}/deb" "${opt}/efi" "${opt}/bin"
cp "${root}/build.sh" "${root}/install-initramfs.sh" "${opt}/"
cp -a "${root}/patches" "${root}/verify" "${root}/cmp50hx" \
      "${root}/idle-governor" "${root}/tuning" "${opt}/"
install -m 0644 "${run_file}" "${opt}/cache/"
(cd "${opt}/cache" && sha256sum "NVIDIA-Linux-x86_64-${driver_version}.run") \
    > "${opt}/deb/nvidia-run.sha256"
printf '%s\n' "${version}" > "${opt}/VERSION"
cp "${root}/efi-unlock/50HXUNLK.EFI" \
   "${root}/efi-unlock/install-linux.sh" \
   "${root}/efi-unlock/sign-efi.sh" "${opt}/efi/"
(cd "${opt}/efi" && sha256sum 50HXUNLK.EFI > 50HXUNLK.EFI.sha256)

# --- 4. compiled runtime binaries -------------------------------------------
libdir="${stage}/usr/lib/cmp50hx-unlock"
mkdir -p "${libdir}" "${stage}/usr/bin" "${stage}/lib/systemd/system"
mkdir -p "${stage}/etc/modprobe.d"

cc -O2 -Wall -Wextra -Werror -std=c11 "${root}/idle-governor/cmp-governor.c" \
    -ldl -o "${libdir}/cmp-governor"
cc -O2 -Wall -Wextra -Werror -std=c11 "${root}/verify/rm_issue_rate.c" \
    -o "${opt}/bin/rm-issue-rate"
install -m 0755 "${root}/cmp50hx/cmp50hx-gen2.sh" "${libdir}/cmp50hx-gen2.sh"
install -m 0755 "${root}/tuning/cmp-tune" "${stage}/usr/bin/cmp-tune"

# systemd units with the package's own paths (the repo originals target the
# install.sh layout under /usr/local and /opt).
sed 's#^ExecStart=.*#ExecStart=/usr/lib/cmp50hx-unlock/cmp50hx-gen2.sh#' \
    "${root}/cmp50hx/cmp50hx-gen2.service" \
    > "${stage}/lib/systemd/system/cmp50hx-gen2.service"
sed 's#^ExecStart=.*#ExecStart=/usr/lib/cmp50hx-unlock/cmp-governor#' \
    "${root}/idle-governor/cmp-idle-governor.service" \
    > "${stage}/lib/systemd/system/cmp-idle-governor.service"
install -m 0644 "${root}/idle-governor/cmp-governor-check.service" \
    "${root}/idle-governor/cmp-governor-check.timer" \
    "${stage}/lib/systemd/system/"

# dpkg conffiles: nouveau blacklist, BAR1 selector (8 = 16 GiB, 9 = 32 GiB;
# edit to switch, mirrors install.sh --rebar-32g), tuning profiles seed.
printf 'blacklist nouveau\n' > "${stage}/etc/modprobe.d/cmp-unlock.conf"
printf 'options nvidia cmp50_rebar_size=8\n' > "${stage}/etc/modprobe.d/cmp50hx-unlock.conf"
install -m 0644 "${root}/tuning/profiles.conf" "${stage}/etc/cmp-tune.conf"

# --- 5. DEBIAN metadata and maintainer scripts -------------------------------
sed "s/@VERSION@/${version}/" "${root}/deb/control.in" > "${stage}/DEBIAN/control"
install -m 0644 "${root}/deb/conffiles" "${stage}/DEBIAN/conffiles"
for script in preinst prerm postinst postrm; do
    install -m 0755 "${root}/deb/${script}" "${stage}/DEBIAN/${script}"
done

# --- 6. build -----------------------------------------------------------------
mkdir -p "${out_dir}"
dpkg-deb --root-owner-group -Zgzip --build "${stage}" "${out_dir}/${deb_name}"
rm -rf "${stage}"

(cd "${out_dir}" && sha256sum "${deb_name}" > "${deb_name}.sha256")
log "wrote ${out_dir}/${deb_name} ($(wc -c < "${out_dir}/${deb_name}") bytes)"
