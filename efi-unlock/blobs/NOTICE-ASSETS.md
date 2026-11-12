# EFI asset blobs — provenance, generation and license (NOTICE-ASSETS.md)

gtuu-mining ticket 13 (row X5; P27 content-derived manifest; P22 zero
badge). `gen-efi-assets.sh --check` gates every package build:
GENERATED-class files are re-derived from the pinned NVIDIA source
(`driver-pin.env` SOURCE_SHA256) and must match byte-for-byte; all files
must match `SOURCE-MANIFEST.sha256` (content-derived, timestamp-free,
byte-idempotent: two runs write identical bytes).

## GENERATED (regenerated from the pinned 610.43.03 open kernel module source)

| File | Source | Proof |
|---|---|---|
| `bl_gsp_tu102.bin` | `UCODE_IMAGE` of `g_bindata_ksec2GetBinArchiveBlUcode_TU102.c` (= `ksec2GetBinArchiveBlUcode_TU102`) | byte-equal (2026-11-12) |
| `booter_ucode_prod.bin` | `IMAGE_PROD` of `g_bindata_kgspGetBinArchiveBooterLoadUcode_TU102.c` | byte-equal (2026-11-12) |
| `gsp_rm_boot_dbg.bin` | 131072 zero bytes — **the P22 zero badge**: third parties byte-pin this file's digest as a "provenance-pinned BOOT_DIRECT bootloader"; it is a placeholder. Payload mode NEVER consumes the BL slot (independently demonstrated by this repo's field boots and by nv-uefi-unlocker @ bbcb92f `make-usbroot.sh`'s manifest, which pins exactly this all-zero digest). | generator emits `sha256(0x00 * 131072) = fa43239b…` |

License: generated from NVIDIA driver source; ship under the NVIDIA
driver license — the .deb embeds the full driver package + license
verbatim (see `tools/build-deb.sh` cache step); nothing NVIDIA-derived
is relicensed by this repo.

## PINNED-KEEP — committed, NOT regenerable from driver source

| File | Origin | Why kept committed |
|---|---|---|
| `v67_payload.bin` | CMP40HX-Unlock (MIT; upstream **deleted** — author 404 since 2026-11, see CREDITS.md row) | **Preservation copy.** Not reproducible from the 610/615 builders: `claim-90hx/tools/v67_regen.c` (host build of the production `gu_payload_build` + recipe tables) produces a byte-differing image at offset 0 — the committed blob predates the recipe tables. |
| `booter_ucode_dbg.bin` | CMP40HX-Unlock (MIT; deleted upstream) | **Preservation copy.** 59136 B like the 610 `IMAGE_PROD` but digest-distinct; equals neither 610 `IMAGE_PROD` nor `IMAGE_DBG`. Debug-path asset. |
| `fwsec_50hx_prod.bin`, `fwsec_50hx_dbg.bin`, `fwsec_50hx_desc.json` | card VBIOS ROM (`CMP50HX.90.02.60.00.1A.live.rom`) walked by the repo's own `extract_fwsec.py` (driver-parser-faithful, `kernel_gsp_fwsec.c` semantics) | input is a card-owned ROM capture, not a redistributable driver artifact; regenerate with `python3 efi-unlock/extract_fwsec.py <rom> efi-unlock/blobs/` when the ROM is available |
| `sec2_ucode_vbios_49.bin`, `sec2_ucode_vbios_89.bin` | card VBIOS experiments | inert (README blobs table); pinned for tamper-detection |

License: MIT 40HX-lineage files ship under `LICENSE-40HX-UNLOCK` (MIT)
retained in this directory tree; card captures are our own extractions
from hardware we own.

## Follow-up recorded by this ticket
The 615.78.08 branch bindata files use a token format the current
`extract_boot_assets.py` byte-array parser rejects (`non-byte token` —
literal suffixes); when the 615 line moves to generation, adapt that
production parser in the claim module first (its MANIFEST gates deb
builds today) and re-pin SOURCE-MANIFEST for the new driver version.
