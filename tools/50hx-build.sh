#!/usr/bin/env bash
# 50hx-build.sh — build the stamped DBG multi unlocker ON THE BENCH (llm2).
#
# Ticket 03 rule: the bench toolchain is the one that ships the tested
# binary (gnu-efi lives there, and the T1 behavioral gate only means
# something for the toolchain we actually use). Source is rsynced from
# the local working tree — uncommitted feature-branch work stays
# deployable; nothing is committed or pushed until Success is proven.
#
# Deviation from stock build.sh: exactly one — EXTRA_CFLAGS carries
# -DU40X_BUILD_STAMP. Toolchain flags / objcopy invocations untouched.
set -euo pipefail

BENCH="${BENCH:-dmitry@192.168.3.58}"
BDIR="${BDIR:-cmp50hx-mtx}"
SRC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SHA=$(git -C "$SRC_ROOT" rev-parse --short HEAD)
DIRTY=""
[ -n "$(git -C "$SRC_ROOT" status --porcelain -- efi-unlock)" ] && DIRTY="-dirty"
STAMP="git-${SHA}${DIRTY}-$(date -u +%Y%m%dT%H%M%SZ)"

echo "==> sync working tree -> ${BENCH}:${BDIR}"
rsync -a --delete --exclude .git --exclude work --exclude dist-llm2 --exclude '*.o' --exclude '*.so' \
      --exclude '*.EFI' "${SRC_ROOT}/" "${BENCH}:${BDIR}/"

echo "==> build on bench (stamp: ${STAMP})"
ssh "$BENCH" bash -s <<EOF
set -euo pipefail
cd ${BDIR}/efi-unlock
export EXTRA_CFLAGS='-DU40X_BUILD_STAMP="${STAMP}"'
bash build.sh
EOF

echo "==> artifact: ${BENCH}:${BDIR}/efi-unlock/50HXUNLK.EFI  (deploy with tools/50hx-deploy.sh)"
