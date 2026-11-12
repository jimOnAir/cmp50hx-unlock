#!/usr/bin/env bash
# gen-efi-assets.sh — generate / verify the EFI unlock asset blobs from the
# pinned NVIDIA source (gtuu-mining ticket 13, row X5; P27 content-derived
# manifest; P22 zero-badge documented in NOTICE-ASSETS.md).
#
#   usage: bash efi-unlock/tools/gen-efi-assets.sh [--check|--write]
#          [--src <prepared open-gpu-kernel-modules root>] [--blobs <dir>]
#
# Default input when --src is not given: the pinned source archive under
# cache/ (driver-pin.env SOURCE_SHA256; HTTPS-only fetch is the existing
# build.sh job — this script only ever VERIFIES the local copy and fails
# loudly naming the expected digest on a corrupt cache entry).
#
# Classes (full text: efi-unlock/blobs/NOTICE-ASSETS.md):
#   GENERATED   byte-identical to the pinned 610.43.03 bindata / zero-fill:
#                 bl_gsp_tu102.bin       UCODE_IMAGE (ksec2GetBinArchiveBlUcode_TU102)
#                 booter_ucode_prod.bin  IMAGE_PROD (kgspGetBinArchiveBooterLoadUcode_TU102)
#                 gsp_rm_boot_dbg.bin    131072 zero bytes (payload mode never consumes it)
#   PINNED-KEEP cannot be regenerated from driver sources — digests pinned:
#                 v67_payload.bin, booter_ucode_dbg.bin  (deleted CMP40HX-Unlock
#                   MIT upstream; byte-differ from 610 builders — see NOTICE)
#                 fwsec_50hx_{prod,dbg}.bin, fwsec_50hx_desc.json,
#                 sec2_ucode_vbios_{49,89}.bin           (card VBIOS ROM captures;
#                   generator efi-unlock/extract_fwsec.py ships with the repo)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
BLOBS="${HERE}/../blobs"
MODE=--check
SRC=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check|--write) MODE="$1"; shift ;;
        --src) SRC="${2:?--src needs the prepared source root}"; shift 2 ;;
        --blobs) BLOBS="${2:?}"; shift 2 ;;
        *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
    esac
done
source "${ROOT}/driver-pin.env"
TAR="${CMP_UNLOCK_CACHE_DIR:-${ROOT}/cache}/${DRIVER_VERSION}.tar.gz"

# --- 1. obtain a source root (verify cache copy; never fetch here) ---------
TMP=""
cleanup() { [[ -n "${TMP}" ]] && rm -rf "${TMP}" || true; }
trap cleanup EXIT
if [[ -z "${SRC}" ]]; then
    [[ -f "${TAR}" ]] || { printf 'gen-efi-assets: no source tree and no warm cache entry %s\n' "${TAR}" >&2; exit 4; }
    actual="$(sha256sum "${TAR}" | cut -d' ' -f1)"
    [[ "${actual}" == "${SOURCE_SHA256}" ]] || {
        printf 'gen-efi-assets: CACHE CORRUPT: %s sha256=%s expected=%s\n' \
               "${TAR}" "${actual}" "${SOURCE_SHA256}" >&2; exit 5; }
    TMP="$(mktemp -d)"
    tar -xzf "${TAR}" -C "${TMP}"
    SRC="$(find "${TMP}" -maxdepth 1 -type d -name "open-gpu-kernel-modules-*" | head -1)"
fi
[[ -d "${SRC}/src/nvidia/generated" ]] || { printf 'gen-efi-assets: %s is not an open-gpu-kernel-modules source root\n' "${SRC}" >&2; exit 6; }

# --- 2. generate + classify -------------------------------------------------
python3 - "$SRC" "$BLOBS" "$MODE" "${ROOT}/claim-90hx/tools/extract_boot_assets.py" <<'PYEOF'
import hashlib, importlib.util, pathlib, sys

src_root, blobs_dir, mode = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
spec = importlib.util.spec_from_file_location(
    "eb", pathlib.Path(sys.argv[4]))
eb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(eb)   # production parser — no forked copy

gen = src_root / "src/nvidia/generated"
def arr(fname, label):
    return eb._array_bytes((gen / fname).read_text(), label)[0]

boot = "g_bindata_kgspGetBinArchiveBooterLoadUcode_TU102.c"
loader = "g_bindata_ksec2GetBinArchiveBlUcode_TU102.c"
generated = {
    "bl_gsp_tu102.bin": arr(loader, "UCODE_IMAGE"),
    "booter_ucode_prod.bin": arr(boot, "IMAGE_PROD"),
    "gsp_rm_boot_dbg.bin": bytes(131072),   # zero badge, see NOTICE-ASSETS.md
}
pinned_keep = [
    "v67_payload.bin", "booter_ucode_dbg.bin",
    "fwsec_50hx_prod.bin", "fwsec_50hx_dbg.bin", "fwsec_50hx_desc.json",
    "sec2_ucode_vbios_49.bin", "sec2_ucode_vbios_89.bin",
]
def sha(b): return hashlib.sha256(b).hexdigest()

manifest = "".join("%s  %s\n" % (sha(generated[n]), n) for n in sorted(generated))
manifest += "".join("%s  %s\n" % (sha((blobs_dir / n).read_bytes()), n) for n in sorted(pinned_keep))

bad = 0
for name, data in generated.items():
    committed = blobs_dir / name
    if mode == "--write":
        committed.write_bytes(data)     # generation IS the point (ticket 13)
        continue
    if not committed.is_file():
        print("MISSING %s (generated class)" % name); bad += 1; continue
    if committed.read_bytes() != data:
        print("MISMATCH %s: committed=%s generated=%s" %
              (name, sha(committed.read_bytes())[:16], sha(data)[:16])); bad += 1

# --check also verifies the whole dir against the committed manifest (tamper)
mpath = blobs_dir / "SOURCE-MANIFEST.sha256"
if mode == "--write":
    out = mpath
    old = out.read_text() if out.exists() else None
    out.write_text(manifest)
    print("wrote %s (%d entries)" % (out, manifest.count("\n")))
    if old is not None and old != manifest:
        print("NOTE: manifest changed (content-derived inputs moved)")
else:
    if not mpath.is_file():
        print("MISSING SOURCE-MANIFEST.sha256"); bad += 1
    else:
        for line in mpath.read_text().splitlines():
            want, _, name = line.partition("  ")
            f = blobs_dir / name
            if not f.is_file():
                print("MANIFEST-FAIL missing %s" % name); bad += 1
            elif sha(f.read_bytes()) != want:
                print("MANIFEST-FAIL digest %s: file=%s manifest=%s" %
                      (name, sha(f.read_bytes())[:16], want[:16])); bad += 1

# v67 generation cross-check (documents the gap; ticket 13 honesty)
#   claim-90hx builder output (gu_payload_build, writes=NULL) is NOT
#   byte-equal to the committed v67_payload.bin — the blob predates the
#   recipe tables and traces to the deleted CMP40HX-Unlock upstream.
sys.exit(1 if bad else 0)
PYEOF
[[ "${MODE}" == "--write" ]] && { echo "WROTE_SOURCE_MANIFEST"; exit 0; }
echo "PASS_GEN_EQ: generated-class EFI assets byte-identical to pinned source; manifest verified"
