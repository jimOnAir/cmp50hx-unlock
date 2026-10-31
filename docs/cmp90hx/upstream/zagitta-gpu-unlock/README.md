# Zagitta/gpu-unlock — provenance & relevance (found 2026-10-31)

- Repo: https://github.com/Zagitta/gpu-unlock (GPL-2.0-only), HEAD reviewed:
  `7eb51bcca` (2026-10-31, 37 commits, 13.6k stars, "Stable, 100+ user reports"
  Ampere). Not vendored in full — clone reviewed at `/tmp/opencode/zagitta`.
- Found via https://github.com/KohakuBlueleaf/KohakUnlock (GPL-2.0, HEAD
  `584ca0e4`), whose `docs/AMPERE.md` names it as THE Ampere implementation:
  "Four RTX 3090s worked with Ubuntu 24.04, kernel 6.8.0-147-generic, NVIDIA
  open 595.99.02."

## What it is

A standalone Linux kernel module ("gpu_unlock") that runs **from the initramfs
before the NVIDIA driver binds any card**, executes the V67 exploit
(FWSEC-FRTS → Booter on SEC2, own falcon code in `falcon.c`, no nvidia.ko),
performs the privileged writes, FLRs, and hands the card to the **unmodified**
driver. README: "combines the cmpunlocker's V67/PLM technique with the
pre-driver timing of the UEFI approach." Firmware inputs extracted at build
time from public NVIDIA archives (pinned `610.43.03` — kernel-module-source
tarball + `.run`; `firmware/fetch_artifacts.py`); FWSEC image is located at
RUNTIME in the card's ROM BAR export (`unlock_610.c:792-833`, version-checked
against the family table).

## Why it matters to this campaign (5 findings, all file-verified)

1. **CMP 90HX device ID is already in their GA102 family table**
   (`recipes.c:419`: `GA102(0x220d)`), and their register constants match our
   lineage exactly (`GU_FEAT_PLM_OFFSET 0x00823804`, `FEAT_SS0 0x0082381c`,
   `FEAT_SS1 0x00823820` = our `CMP90_PC_EXACT_SS1`).
2. **One chain execution = SIX privileged writes, not one.** The GA102 payload
   is Petri Krohn's re-entrant 6-write frame layout (`recipes.c:5-23`: enter
   `reg_write_indirect()` at `0x1110`, one write per `0x18` stack frame, the
   popped r0/r1 carry the next write's params). The "V67 = single write pair,
   terminator `0x81ee`" model in our lineage (bendy2/WildFlash) is the MINIMAL
   form, not a limit. Gen2's two masks fit in one run-#1-style execution.
3. **Multi-launch after ONE healthy FWSEC works on GA102**
   (`unlock_610.c:1211-1310`): `run_privileged_writes` batches tables of any
   length into launches of 6; FWSEC runs once; each later launch = host WPR2
   FRTS-carve restore + full SEC2 reset/reload + payload refill, gated on prior
   invocation HALT evidence (`invocation_halted`, `fresh`, mailbox completion
   echo). This contradicts a universal FWSEC-slot model — our 0/49 run-#2
   refusal on llm2 is in-driver-context- and/or card-specific, and the
   pre-driver shape is exactly what our path #3 aimed to reproduce, already
   written, maintained, and proven on four-card 3090 fleets.
4. **Our blocked blob gate (#3: "needs 94.02.74.x fwsec/sec2 blobs") may be
   moot**: their code reads FWSEC-FRTS from the live card's PCI ROM export at
   runtime (with the caveat from KohakUnlock AGENT-GUIDE §2: some PROMs hide
   NVIDIA extension images beyond the standard image chain — probe-able with
   `sudo cat /sys/bus/pci/devices/0000:03:00.0/rom`, non-mutating).
5. **Write-table architecture matches Gen2's need 1:1** — recipes are ordered
   `(addr, value)` lists (`ga10x_plm[]` = `{WPR_CFG_PLM 0xfffff0ff, FEAT_PLM
   0xffffffff}` + `selectors[]` SS0/SS1; the 12-entry `ga100_plm[]` is the
   cmpunlocker `2d10f891` plmTable, i.e., same lineage as ours). A
   `cmp90hx-gen2` recipe = PLM opens + `{0x00823800, 0xffffffff}` +
   `{0x00088fe8, 0xffffffff}` + whatever the mask map (§1 Wh1stle05) needs;
   their batching handles >6 automatically.

## Their safety properties (align with our fail-closed policy)

- Refuses cards already bound/initialized by a driver ("a card some driver
  already initialised is still refused") — initramfs timing is mandatory.
- On firmware that never halts: logs, RETAINS DMA buffers until power-off
  (same wedge-conservatism as our L1/L2 policy; mirrors KohakUnlock's "retain
  DMA + blocked driver matching + pre-udev stop" rule).
- Per-card BDF opt-in (`gpu_unlock.targets=0000:03:00.0`), concurrent
  multi-card, one-shot GRUB entry recommended for experiments.

## Port sketch (path #5, see docs/cmp90hx/alt-paths-scope.md)

Add CMP 90HX recipe (220d already mapped) + Gen2 write table; build against
610.43.03 assets (we already hold the verified source tarball, sha
`9df87d75…`); initramfs-tools hook (Ubuntu-native, theirs works unmodified);
`targets=` limited to `0000:03:00.0` during experiments; post-boot retrain
step = existing cmp50hx-gen2 / patch-0017 logic aimed at the 90HX bridge.
Open questions to answer on the host: (a) does the 90HX ROM BAR export carry
the FWSEC-FRTS image; (b) does a CMP card pass their `ColdCheck`-equivalent
preconditions (GFW/WPR2/selector reads); (c) do launches beyond the first
land on THIS card (their model says yes on GA102; llm2 has surprised us).
