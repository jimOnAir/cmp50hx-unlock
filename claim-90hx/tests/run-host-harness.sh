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

# ---- deep-phase fixture provisioning (S24/S25) --------------------------
# Real 610 firmware assets + the real 90HX board PROM, produced offline by
# the manifest-gated production tooling when the repo cache is warm.
# Cached across runs under ${TMPDIR}; absent cache => loud SKIP downstream.
prom="${ROOT}/../cache/90hx-prom-0x300000.bin"
if [[ -z "${CLAIM_FW_FIXTURE:-}" && -s "${ROOT}/../cache/610.43.03.tar.gz" \
      && -s "${ROOT}/../cache/NVIDIA-Linux-x86_64-610.43.03.run" && -s "${prom}" ]] \
      && command -v zstd >/dev/null; then
	key="$(sha256sum "${ROOT}/../cache/610.43.03.tar.gz" | cut -c1-12)"
	prov="${TMPDIR:-/tmp}/cmp50hx-fwfix-${key}"
	if [[ ! -s "${prov}/fw/gpu-unlock/610.43.03/gsp_ga10x.bin" ]]; then
		mkdir -p "${prov}"
		tar xzf "${ROOT}/../cache/610.43.03.tar.gz" -C "${prov}" &&
		bash "${ROOT}/firmware/extract.sh" \
			"${prov}/open-gpu-kernel-modules-610.43.03" \
			"${ROOT}/../cache/NVIDIA-Linux-x86_64-610.43.03.run" \
			"${prov}/fw" >/dev/null &&
		mkdir -p "${prov}/fw/gpu-unlock/610.43.03" &&
		for f in "${prov}"/fw/*.bin; do
			ln -sf "../../$(basename "$f")" "${prov}/fw/gpu-unlock/610.43.03/"
		done || rm -rf "${prov}"
	fi
	if [[ -s "${prov}/fw/gpu-unlock/610.43.03/gsp_ga10x.bin" ]]; then
		export CLAIM_FW_FIXTURE="${prov}/fw" CLAIM_PROM_FIXTURE="${prom}"
	fi
fi

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
