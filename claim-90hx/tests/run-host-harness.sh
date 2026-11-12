#!/usr/bin/env bash
# run-host-harness.sh — build + run the claim-module host failure-injection
# harness (gtuu-mining ticket 11). Production sources compile verbatim
# against tests/shim/; zero external dependencies beyond gcc + libc.
#   usage: bash claim-90hx/tests/run-host-harness.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
BUILD="$(mktemp -d)"
trap 'rm -rf "${BUILD}"' EXIT

CC="${CC:-gcc}"
CFLAGS=(-std=gnu11 -g -O1 -Wall -Wextra -Wno-unused-parameter
        -Wno-missing-field-initializers   # kernel-style positional init tables
        -Wno-unused-const-variable        # GA100() table macro: kernel builds
                                          # don't lint it; pre-existing recipe
                                          # surface, not harness code
        -I "${HERE}/shim"
        -I "${ROOT}/../common")           # booter_mailbox.h (Kbuild -I parity)

SRC=(falcon.c recipes.c firmware_610.c layout_610.c vbios_610.c
     prep_610.c payload.c gfw_eval.c booter_diag.c
     tests/shim/shim_impl.c tests/test_claim.c)

echo "== compiling ${#SRC[@]} TUs (production files verbatim) =="
OBJS=()
for s in "${SRC[@]}"; do
    o="${BUILD}/${s//\//_}.o"
    "${CC}" "${CFLAGS[@]}" -c "${ROOT}/${s}" -o "${o}"
    OBJS+=("${o}")
done
"${CC}" "${CFLAGS[@]}" -o "${BUILD}/test_claim" "${OBJS[@]}"

echo "== running =="
"${BUILD}/test_claim"
echo "run-host-harness: claim failure-injection harness green"
