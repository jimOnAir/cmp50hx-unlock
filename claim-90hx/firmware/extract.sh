#!/usr/bin/env bash
# claim-90hx/firmware/extract.sh — regenerate the four /lib/firmware assets.
# Sources (both already part of the deb build inputs):
#   $1 = prepared source root of the pinned driver (g_bindata_*.c)
#   $2 = official NVIDIA .run of the same version (GSP firmware members)
#   $3 = output directory
#   $4 = driver version both inputs must match (from driver-pin.env — the
#        single source of truth; nothing here hardcodes a version anymore)
# Deterministic tooling: tools/extract_boot_assets.py + tools/extract_gsp.py
# (Zagitta/gpu-unlock @7eb51bcc, GPL-2.0). Manifest: MANIFEST.sha256.
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="${1:?prepared source root}"; run="${2:?official .run}"; out="${3:?output dir}"
version="${4:?expected driver version}"
mkdir -p "$out"
python3 "$here/../tools/extract_boot_assets.py" "$src" "$out"
python3 "$here/../tools/extract_gsp.py" "$run" "$out" "$version"
rm -f "$out/NVIDIA-LICENSE"   # shipped separately by the deb's driver payload
(cd "$out" && sha256sum booter_load_ga102.bin gsp_boot_desc_ga102.bin gsp_boot_ga102.bin gsp_ga10x.bin | sha256sum -c "$here/MANIFEST.sha256")
echo "PASS_90HX_FW_EXTRACT"
