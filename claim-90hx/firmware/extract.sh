#!/usr/bin/env bash
# claim-90hx/firmware/extract.sh — regenerate the four /lib/firmware assets.
# Sources (both already part of the deb build inputs):
#   $1 = NVIDIA 610.43.03 prepared source root (g_bindata_*.c)
#   $2 = NVIDIA-Linux-x86_64-610.43.03.run (GSP firmware members)
#   $3 = output directory
# Deterministic tooling: tools/extract_boot_assets.py + tools/extract_gsp.py
# (Zagitta/gpu-unlock @7eb51bcc, GPL-2.0). Manifest: MANIFEST.sha256.
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="${1:?prepared source root}"; run="${2:?official .run}"; out="${3:?output dir}"
mkdir -p "$out"
python3 "$here/../tools/extract_boot_assets.py" "$src" "$out"
python3 "$here/../tools/extract_gsp.py" "$run" "$out"
rm -f "$out/NVIDIA-LICENSE"   # shipped separately by the deb's driver payload
(cd "$out" && sha256sum booter_load_ga102.bin gsp_boot_desc_ga102.bin gsp_boot_ga102.bin gsp_ga10x.bin | sha256sum -c "$here/MANIFEST.sha256")
echo "PASS_90HX_FW_EXTRACT"
