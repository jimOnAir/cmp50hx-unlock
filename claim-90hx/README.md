# claim-90hx — once-per-boot Gen2 mask claim module (CMP 90HX)

GPL-2.0-only. **Provenance:** ported from **Zagitta/gpu-unlock @`7eb51bcc`**
(`kernel/gpu_unlock/`, "Stable, 100+ user reports" consumer-GA102 unlocker;
upstream clone on the dev box at `work/upstream/Zagitta-gpu-unlock/`). The
port lineage lives in this repo's campaign history: W2/W3-window changes
(`gu_window` spec parameter, diag/full build variants, asset staging under
`/lib/firmware/gpu-unlock/610.43.03/`) measured across the frozen campaign's
`success-recipe.md` (7/7 landings), plus the **T09 table variant** added on
2026-11-01 (`recipes.c`, `GU_CMP90HX_T09`): gate-first 6-entry window
`{WPR_CFG, FEAT, 0x823800, 0x88fe8, 0x88fec, 0x88ff0}` — Wh1stle05's minimal-2
with openers, the exact preconditions of `nv_cmp90hx_gen2_config` (series
0016+0019). Landing evidence: map ticket 09 attempt 2 (`LnkSta 5GT/s x4`,
`nvidia-smi gen=2`, boot `d43c2d99`).

**Product shape:**

- `Kbuild` pins `-DGU_CMP90HX_T09` (the T09 table; smoke checks the
  `ga10x_cmp90hx_plm` symbol size = 0x60 via objdump — a silently wrong
  table selection happened once during development with `EXTRA_CFLAGS`
  being ignored by kbuild ≥ 6.16, hence `ccflags-y` + the size assertion).
- `dkms.conf`: sibling DKMS package `gpu-unlock-claim/610.43.03`,
  `AUTOINSTALL=yes` + **modprobe blacklist** (shipped by the deb) — only
  `/usr/local/sbin/cmp90hx-claim.sh` insmods it, once per boot, before
  `cmp50hx-boot.service` binds nvidia (unit ordering contract in
  `deb/cmp90hx-claim.service`).
- Firmware assets resolve at `gpu-unlock/610.43.03/` under `/lib/firmware`
  (`recipes.h` GU_FW_* macros): `gsp_ga10x.bin`, `gsp_boot_desc_ga102.bin`,
  `gsp_boot_ga102.bin`, `booter_load_ga102.bin` — staged by the deb from
  `firmware/` (sha256 manifest alongside; extracted from the pinned NVIDIA
  610.43.03 driver per `tools/` asset extraction; the deb already embeds the
  full official .run).

Fail-closed by construction: no module / no claim / NO-EFFECT readback ⇒
masks stay locked ⇒ the in-module config pass skips at its own `0x823800`
gate ⇒ link stays Gen1. One claim per boot; no cross-boot retry (ADR-0001).
