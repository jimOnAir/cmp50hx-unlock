#!/usr/bin/env bash
# tools/docker-deb.sh — reproducible .deb build + smoke inside the pre-baked
# images (docker/Dockerfile.build, docker/Dockerfile.smoke).
#
# The ad-hoc recipe this replaces was wasteful twice over: a fresh
# `apt-get install` every run, and — worse — an rsync that excluded
# cache/, forcing a 440 MB NVIDIA .run re-download inside the container
# every single build (observed stalling at 100 kB/s on 2026-11-13).
# Here the host's sha-verified cache/ is bind-mounted, so a warm build
# needs NO network at all.
#
#   usage: CMP_DEB_REV=<rev> bash tools/docker-deb.sh [--out DIR]
#
# Artifacts land in DIR (default: repo root): cmp50hx-unlock_*_amd64.deb +
# .sha256. The deb's embedded EFI digest is printed for the promotion log.
set -Eeuo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${root}"
[[ "${1:-}" == "--out" ]] && { out="${2:?--out needs a directory}"; shift 2; }
[[ $# -eq 0 ]] || { printf 'usage: CMP_DEB_REV=<rev> bash tools/docker-deb.sh [--out DIR]\n' >&2; exit 2; }
: "${CMP_DEB_REV:?set CMP_DEB_REV (e.g. 20261113.gtuu8)}"

for img in cmp50hx-build:latest docker/Dockerfile.build \
           cmp50hx-smoke:latest docker/Dockerfile.smoke; do
    [[ "$img" == docker/* ]] && continue
    docker image inspect "$img" >/dev/null 2>&1 || {
        printf '==> building image %s (one-time)\n' "$img"
        docker build -q -t "$img" -f "docker/Dockerfile.${img%%:*}" "${root}/docker" \
            | tail -1
    }
done

build_dir="$(mktemp -d /tmp/cmp50hx-deb.XXXXXX)"
# Cleanup must survive root-owned container residue (a failed build mid-way
# used to trap the host rm, and its noise drowned the real error).
cleanup() {
    docker run --rm -v "${build_dir}:/bd" cmp50hx-build:latest \
        sh -c 'rm -rf /bd/* /bd/.[!.]* 2>/dev/null || true' >/dev/null 2>&1 || true
    rm -rf "${build_dir}"
}
trap cleanup EXIT
printf '==> staging sources into %s\n' "${build_dir}"
rsync -a --exclude .git --exclude work --exclude 'dist*' --exclude cache \
      --exclude '.scratch' --exclude '*.deb' --exclude 'docker' \
      "${root}/" "${build_dir}/"

printf '==> build (offline if cache/ is warm)\n'
docker run --rm \
    -v "${build_dir}:/src" -w /src \
    -v "${root}/cache:/src/cache" \
    -e CMP_DEB_REV="${CMP_DEB_REV}" -e HOME=/tmp \
    -e SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "${root}" log -1 --format=%ct 2>/dev/null || date +%s)}" \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    cmp50hx-build:latest bash -c '
        set -e
        source driver-pin.env   # offline-cache probe must follow the pin, not a literal
        [[ -s "cache/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run" ]] \
            && echo "cache mount: $(du -sh cache | cut -f1) available offline"
        rm -f efi-unlock/50HXUNLK.EFI
        (cd efi-unlock && bash build.sh >/dev/null)
        sha256sum efi-unlock/50HXUNLK.EFI
        bash tools/build-deb.sh --out . > /tmp/build-deb.log 2>&1 \
            || { tail -120 /tmp/build-deb.log; exit 1; }
        grep -E "^(PASS|OK)" /tmp/build-deb.log | tail -5 || true
        ls cmp50hx-unlock_*_amd64.deb
        chown -R "${HOST_UID}:${HOST_GID}" /src'   # root residue would trap the cleanup

printf '==> smoke (26.04 toolchain)\n'
deb="$(ls "${build_dir}"/cmp50hx-unlock_*_amd64.deb)"
docker run --rm -v "${build_dir}:/src" -w /src cmp50hx-smoke:latest \
    bash -c "set -e; bash tools/smoke-test-deb.sh $(basename "${deb}"); chown -R $(id -u):$(id -g) /src"

mkdir -p "${out}"
install -m 0644 "${build_dir}"/cmp50hx-unlock_*_amd64.deb* "${out}/"
printf '==> done: '
ls -la "${out}"/cmp50hx-unlock_*_amd64.deb | tail -1
if [[ -f "${deb}.sha256" ]]; then
    (cd "${out}" && sha256sum -c "$(basename "${deb}").sha256")
else
    (cd "${out}" && sha256sum "$(basename "${deb}")")
fi
