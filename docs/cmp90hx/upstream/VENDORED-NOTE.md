# Vendored upstream recon (2026-10-30)

Four public 90HX projects vendored for the Gen2 campaign (ticket 03 recon;
mechanism model in `../../../findings.md`). Text/code only — research images
and benchmark photos excluded. See `docs/cmp90hx/alt-paths-scope.md` for how
these feed paths #3 (EFI) and #4 (booter RE).

| Dir | Upstream | Commit (2026-…) | Why here |
|---|---|---|---|
| `wh1stle05/` | Wh1stle05/cmp90hx | 477c712e (09-15) | Gen2 proven on OUR VBIOS 94.02.74.00.01: minimal 2-mask set (`masks/minimal-2.txt`), `docs/PCIE-GEN2-FINDINGS.md`, retrain-retry patch 0017, cycle/handoff/minimal scripts — window #10 substrate |
| `wildflash-efi/` | WildFlash1st/cmp90hx-unlock-for-windows | 7a2397c5 (10-14) | GA102-native EFI unlocker source (`src/unlock_v2.c`, gnu-efi) — path #3 is a build+port of this, not greenfield; `BUILDING.md` blob table, `src/tools/extract_fwsec*.py`, `docs/REGISTERS.md` |
| `wildflash-linux/` | WildFlash1st/cmp90hx-unlock @ 76940ae (same commit already recorded in `../VENDORED.md`) | 76940ae5 (08-22) | STATUS.md = single-write ground truth + interpreter anchors + their failed Linux re-run evidence; `docs/GEN3ADV_XP3G_RESEARCH.md`, `XVE_CONFIG_MIRROR.md`; `research/rm_reg.c` tool |
| `iatethelogs/` | iatethelogs/cmp90hx_pwner | 73bc5ea4 (09-27) | server-class known-good apply flow (stock-first handoff, 13-try stages, PCI reset/rescan) — `cmp90hxpwner.sh` ~lines 1229-1420 |

Licenses: check per-repo LICENSE files before copying code into our tree
(wh1stle05 ships a full LICENSE text; wildflash-efi is the same lineage as our
GPL-2.0 patches).
