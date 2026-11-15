#!/usr/bin/env bash
# tools/docker-lifecycle.sh — run the deb lifecycle contract in the prepared
# cmp50hx-lifecycle image (bakes the SAME package set the GitHub
# linux-lifecycle job installs). No per-run apt-get, no dist/ staleness:
# exactly one deb, newest-first, explicit override available.
#
#   usage: bash tools/docker-lifecycle.sh [path/to.deb]
#
# Exit code and the leg verdict lines come straight from
# tools/lifecycle-test-deb.sh; the postinst log is copied OUT before the
# purge legs wipe it (CI lost the diagnosis exactly that way).
set -Eeuo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

docker image inspect cmp50hx-lifecycle:latest >/dev/null 2>&1 || {
    printf '==> building image cmp50hx-lifecycle:latest (one-time)\n'
    docker build -q -t cmp50hx-lifecycle:latest -f docker/Dockerfile.lifecycle "${root}/docker" | tail -1
}

if [[ $# -ge 1 ]]; then
    deb="$1"; [[ -f "$deb" ]] || { printf 'no such deb: %s\n' "$deb" >&2; exit 2; }
else
    mapfile -t cands <(ls -t "${root}"/dist/cmp50hx-unlock_*_amd64.deb 2>/dev/null || true)
    [[ ${#cands[@]} -gt 0 ]] || { printf 'no deb in dist/ (build one: CMP_DEB_REV=... tools/docker-deb.sh --out dist)\n' >&2; exit 2; }
    deb="${cands[0]}"
    printf '==> newest deb: %s%s\n' "$deb" "$( ((${#cands[@]}>1)) && printf ' (%d stale siblings ignored — pass an explicit path to pick one)' "${#cands[@]}")"
fi

out="$(mktemp -d)"
trap 'rm -rf "${out}"' EXIT
# Mount the deb's directory as /deb when it lives outside the repo (e.g.
# /tmp/opencode staging); repo-internal debs ride the /src mount.
deb_mount=()
deb_in="/src/$(realpath --relative-to="${root}" "${deb}" 2>/dev/null || true)"
if [[ "${deb}" != "${root}"/* ]]; then
    deb_mount=(-v "$(dirname "${deb}"):/deb:ro")
    deb_in="/deb/$(basename "${deb}")"
fi
docker run --rm \
    -v "${root}:/src" -v "${out}:/out" "${deb_mount[@]}" -w /src -e HOME=/tmp \
    -e DEB_IN="${deb_in}" \
    cmp50hx-lifecycle:latest bash -c '
        set -e
        DEB="${DEB_IN}"
        [[ -f "$DEB" ]] || { echo "deb missing in container: $DEB"; exit 2; }
        rc=0
        bash tools/lifecycle-test-deb.sh self --deb "$DEB" || rc=$?
        [[ -f /var/log/cmp50hx-unlock-install.log ]] &&
            cp /var/log/cmp50hx-unlock-install.log /out/postinst.log || true
        exit $rc'
rc=$?
if [[ -s "${out}/postinst.log" ]]; then
    printf '== last postinst log ==\n'
    tail -30 "${out}/postinst.log"
fi
exit $rc
