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

## Tracker recon (2026-10-31, all 55 issues + PRs searched via API)

No CMP/90HX/Gen2 reports exist (searches return only license/grep noise).
The valuable signal is in adjacent reports:

- **#280 (2026-10-31, 3070 Ti FE)** — **unlock SUCCESS on kernel 7.2.6.35**
  (driver 595.104.02, Pop!_OS systemd-boot, `kernelstub` cmdline, no custom
  hook): full rates, +73%, survived 4 unlocked boots with A/B locked boots
  interleaved. Log shows their parser following the ROM export through
  NVIDIA extension images (`type=0xe0 last=128`, `ROM expansion:
  base=0xfe00 ext=0x26800`) to `FWSEC descriptor: offset=0x43408
  ROM_bytes=1048576` — **consumer GA102 ROM BAR export DOES carry the
  FWSEC** (Kohak's caveat answered for GA102; 90HX still to probe). Also:
  unsigned module loaded with only a taint ("module verification failed…
  tainting kernel") — Secure Boot off. **Breaks our kernel-era corpus
  correlation further**: pre-driver executors succeed on 7.x where in-driver
  run-#2s failed.
- **#236 (2026-10-27, 2×3090, Ubuntu 26.04, kernel 7.0.0-38 — IDENTICAL to
  llm2)** — fails, but platform-side: XCP-ng/Xen passthrough hides the
  **FLReset+ bit (DevCap bit 28)** in the VM; their
  `unlock_transaction_claim:611` hard-requires FLR capability and refuses
  before touching the card. Maintainer diagnosis confirmed by reporter
  (host sees FLReset+, VM doesn't). Takeaways: (1) same-kernel existence
  proof that the module loads and diagnoses cleanly on 7.0.0-38; (2) **FLR
  capability is a hard precondition** — probe `lspci -vv | grep FLReset` on
  the 90HX before porting (llm2 bare-metal FLR has worked in our windows,
  expected fine); (3) commenter warning that Ubuntu 26.04 wants MOK signing
  with Secure Boot on — llm2 loads our patched .ko today, so SB is off, but
  verify `mokutil --sb-state` in the probe window.
- **#260 (2026-10-29, 5×3090 behind a PEX880xx switch, Proxmox)** — unlock
  initially succeeded (+86% observed), later two fatal **DPC/Xid-79 events
  killed the whole upstream switch port** (`0000:24:10.0`), power-cycle
  needed. Their `stage=gfw` line shows the PLM read (`plm=0xffffff8f`).
  Cautionary precedent for retrain/FLR work — llm2's 90HX sits on a root
  port (no switch), lower exposure, but DPC is the same failure family as
  our L1 wedge.
- **#251 (PR, 2026-10-28)** — D3cold→D0 **clears the volatile selectors**;
  adds re-apply on that transition. Directly relevant: llm2's rtkit-audio
  and `llm2-cooldown-detect` flip this card's D-state, and the Habr author
  had the same problem (disabled rtkit). Any landed Gen2 mask dies the same
  way → the #5a design must freeze runtime PM for `03:00.0` or re-apply on
  resume (jdowning's systemd suspend/resume hooks do the latter in-driver).
- **#21 (2026-10-23, GA106 RTX 3060 LHR)** — FWSEC succeeds after relaxing
  two checks, then SEC2 PRI reads `0xbadf5620` (unreachable) — family
  variance INSIDE GA10x: GA102 success is not automatic elsewhere. Our card
  is GA102 silicon (220d), their best-supported family — good.
- **#28 (2026-10-24, GA102-250 OEM 3080 Ti 20GB)** — unlock completes +
  selectors verify **held at runtime minutes later**; no uplift because the
  SKU's cores are fused. Negative control: selector-hold and uplift are
  independent.
- **#168 (payload rebuild method)** — booter + V67 assets **byte-identical
  between 610.43.03 and 615.71.10** → V67 payload extraction is effectively
  version-independent; only `gsp_boot` needs the newer extractor (PR #35).
- **PRs #35/#57** — DMA-mask widening (47-bit) and FWSEC DMEM rounding:
  edge/GA106 fixes, no GA102 impact.

## Net effect on port confidence

Pre-driver GA102 execution works on kernels 6.8 → 7.2 (success reports),
multi-card, at scale; our kernel era is not the blocker; FLR presence and
D3 persistence are the two host-side preconditions to probe; the 90HX ROM
export remains the one true unknown (probe #1).
