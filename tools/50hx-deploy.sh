#!/usr/bin/env bash
# 50hx-deploy.sh — place the built EFI on the bench ESP as its OWN file
# (50HXMTX.EFI) and (re)create its OWN boot entry Boot0003 with the
# "multi" load option. Stock file + Boot0001 are never touched (md5
# checked before AND after). BootOrder is restored to its pre-deploy
# value: efibootmgr -c inserts the new entry FIRST (observed again
# 2026-10-26), and no test boot may happen except through one-shot
# BootNext (efibootmgr -n).
#
# Bench facts discovered this session:
#  - `-l` alone fails ("Could not prepare Boot variable: No such file
#    or directory") on this firmware — disk/partition must be explicit.
#  - `-u 'L"multi"'` stores the quotes literally; the working format is
#    plain `-u multi` (matches Boot0002's proven LoadOptions bytes).
set -euo pipefail

BENCH="${BENCH:-dmitry@192.168.3.58}"
BDIR="${BDIR:-cmp50hx-mtx}"
STOCK_MD5="${STOCK_MD5:-7a42187b0a9abd2f3f17fb864a43d6d0}"
# LOADOPT=multi (default) -> loop+preflight active.
# LOADOPT=none            -> same binary behaves as stock single-card
#                            (T1 toolchain-sanity boot, ticket 06).
# LOADOPT=tel             -> stock path + read-only forensic telemetry
#                            (E1 diagnostic; combine tokens as "multi tel"
#                            only if efibootmgr stores space-joined).
LOADOPT="${LOADOPT:-multi}"

ssh "$BENCH" bash -s <<EOF
set -euo pipefail
cd ${BDIR}/efi-unlock
test -f 50HXUNLK.EFI || { echo "FATAL: no build found — run tools/50hx-build.sh first"; exit 1; }

BEFORE=\$(md5sum /boot/efi/EFI/50HX/50HXUNLK.EFI | cut -d' ' -f1)
test "\$BEFORE" = "${STOCK_MD5}" || { echo "FATAL: stock md5 \$BEFORE != ${STOCK_MD5}"; exit 1; }

ORDER=\$(efibootmgr | awk '/^BootOrder/{print \$2}')
SRC=\$(findmnt -no SOURCE /boot/efi)
DISK=/dev/\$(lsblk -no PKNAME \$SRC | head -1)
PART=\$(lsblk -no PARTN \$SRC | head -1)

if efibootmgr | grep -q '^Boot0003'; then
    efibootmgr -v | grep '^Boot0003' | grep -q '50HX Multi' \
        || { echo "FATAL: Boot0003 exists but is not ours — refusing"; exit 1; }
    sudo efibootmgr -b 0003 -B >/dev/null
fi

sudo cp -f 50HXUNLK.EFI /boot/efi/EFI/50HX/50HXMTX.EFI
sync
if [ "${LOADOPT}" = "none" ]; then
    sudo efibootmgr -c -d \$DISK -p \$PART -L "50HX Multi DBG" \\
         -l '\\EFI\\50HX\\50HXMTX.EFI' >/dev/null
else
    sudo efibootmgr -c -d \$DISK -p \$PART -L "50HX Multi DBG" \\
         -l '\\EFI\\50HX\\50HXMTX.EFI' -u "${LOADOPT}" >/dev/null
fi

sudo efibootmgr -o "\$ORDER" >/dev/null

AFTER=\$(md5sum /boot/efi/EFI/50HX/50HXUNLK.EFI | cut -d' ' -f1)
test "\$AFTER" = "${STOCK_MD5}" || { echo "FATAL: stock md5 changed during deploy!"; exit 1; }
NOW_ORDER=\$(efibootmgr | awk '/^BootOrder/{print \$2}')
test "\$NOW_ORDER" = "\$ORDER" || { echo "FATAL: BootOrder not restored: \$NOW_ORDER"; exit 1; }

echo "--- stock 50HXUNLK.EFI md5 unchanged: \$AFTER"
echo "--- mtx md5:  \$(md5sum /boot/efi/EFI/50HX/50HXMTX.EFI | cut -d' ' -f1)"
echo "--- BootOrder: \$NOW_ORDER (restored)"
efibootmgr -v | grep -E 'Boot0001\*|Boot0003'
echo DEPLOY_OK
EOF
