# SOURCES — canonical link ledger (user-provided + discovered)

Every external link referenced by the 90HX Gen2 campaign, with where its
substance is reflected in this repo. Links are preserved regardless of
outcome. (Bash-greppable: one URL per bullet.)

## Articles

- https://habr.com/ru/articles/1087254/ — iatethelogs **part 4**
  (2026-09-27): **first published CMP 90HX P2P + Gen2 x16 datapoint** — P2P
  at Gen1 (3.08/3.35 GB/s vs 1.60 staged), the IOMMU-`identity` fix (250 MB/s
  trap; ACS exonerated), cross-socket NODE limits, and 6.70 GB/s symmetric
  after his Gen2 ladder. His P2P + Gen2 automation is in pwner (below).
  Full analysis: `docs/cmp90hx/rm-levers-and-p2p.md` §1-2.
- https://habr.com/ru/articles/1082724/ — iatethelogs, "Часть 3. Кремний
  взломал кремний…" (2026-09-15): first-confirmed **PCIe Gen2 x16** claim for
  CMP 90HX. Method = same stock-module-first → patched-handoff → rejoin16
  shape we vendored. **llm2 step-by-step verdict (windows #9–#10 evidence,
  preserved here because the analysis lives nowhere else):** their chain
  fails on llm2 at exactly ONE step — the Gen2 mask writes ride rejoin16
  run #2, refused here 0/49 (per-load-internal, healthy stock FWSEC
  preceding doesn't help); everything else in their sequence works on llm2
  (handoff run #1 2/2 `SS0=0x88888888` `status=0x0`, compute unlock every
  boot, FLR, retrain). Their `relock()` readback check would fail on llm2
  (FEAT-page CPU writes inert, window #9). Their x16 additionally required
  **soldering lane capacitors (220 nF)** — llm2's card trains
  `Width x4 (downgraded)`, so even a landed Gen2 ≈ jdowning's x4. Author's
  own framing ("nothing I found online worked for me either") = existence
  proof on one machine, not a portable recipe; llm2 is now the best-
  documented counter-example (per-step telemetry, ticket 03).
- https://habr.com/ru/articles/1020334/ — same author, part 1 (dual-Xeon
  CMP fleet build context).
- https://habr.com/ru/articles/1076224/ — same author, **part 2** (linked
  from part 4's series index 2026-10-31; content unread — presumed the
  PCIe-lane-soldering/Gen2 hardware story referenced by parts 3-4). TODO:
  read when convenient, reflect here.

## Unlock repos (lineage)

- https://github.com/bendy2/cmp90hx — V67 stockflow origin for CMP 90HX.
- https://github.com/pearlfortune/cmpunlocker — production compute unlock;
  llm2 serving flow. Reflected: `patches/cmp90hx/0014/0015`, findings.md.
  RF-window fetch (2026-10-31): release bundle
  `…/releases/download/v0.1.28/cmpunlocker-v0.1.28-linux-x64-90hx-stockflow.tar.gz`,
  sha256 `19c67cd0cb2df5ee10ea28c97ada756ada309553f2500129f973c3adf84f99c3`
  (against published SHA256SUMS); v0.1.28 tag = commit `f60330c`.
- https://github.com/jdowning100/cmpunlocker — rejoin16 Gen2 path +
  `90HX-GEN2-RESEARCH-NOTES.md` (vendored here as
  `docs/cmp90hx/rejoin16-RESEARCH-NOTES.md`) + `bench/rejoin16-apply-all.sh`.
  Tested 1:1 → 0/49 on llm2; see ticket 03, `upstream-issue-draft.md`
  (b1, ready to post).
  RF-window clone (2026-10-31) at commit `2cdc63cf1ab8`: vendored `0016` patch
  + `build-candidate-with-rejoin16.sh` byte-identical (md5 `3a9fff52`/`625e20a8`);
  patches 0014/0015 absent from git — ship only in the release bundle above.
- https://download.nvidia.com/XFree86/NVIDIA-kernel-module-source/NVIDIA-kernel-module-source-610.43.03.tar.xz
  — RF-window build input, sha256 `7e118923c7a23edc36114d63273a46e3e04e9af98695a42203e7ac2dfe9fc1dc`
  (pinned by the author's build script; verified on llm2 before build).
- https://github.com/Wh1stle05/cmp90hx — published 2×90HX landings (6.8.0-
  139). Vendored: `docs/cmp90hx/upstream/wh1stle05/` (see VENDORED-NOTE.md).
- https://github.com/iatethelogs/cmp90hx_pwner — Habr part-3 tool. Vendored:
  `docs/cmp90hx/upstream/iatethelogs/`.
- https://github.com/WildFlash1st/cmp90hx-unlock — Linux research + EFI
  pre-OS. Vendored: `docs/cmp90hx/upstream/wildflash-linux/`,
  `wildflash-efi/`.
- https://github.com/WildFlash1st/cmp90hx-unlock-for-windows — Windows port.
- https://github.com/xrip/cmp50hx-unlock — this repo's upstream (CMP 50HX
  unlock; `NO_EFI_VERDICT` boot-gate context).

## Found 2026-10-31 (user-provided pointer → material discovery)

- https://github.com/KohakuBlueleaf/KohakUnlock — HEAD `584ca0e4`,
  GPL-2.0. TU102 initramfs one-shot executor + docs; Ampere = Zagitta
  (external); AD102 Windows/UEFI source. No Gen2/90HX content. Key extracts:
  `docs/AMPERE.md` (4×3090 on kernel 6.8.0-147, driver 595.99.02; failure
  lessons incl. wedge recovery), `docs/AGENT-GUIDE.md` (fail-closed rules,
  ROM-export caveat "PCI ROM export may stop at the standard image chain;
  private NVIDIA extension images can be beyond it"). Reflected:
  `docs/cmp90hx/upstream/zagitta-gpu-unlock/README.md`, findings.md,
  alt-paths-scope.md #5.
- https://github.com/Zagitta/gpu-unlock — HEAD `7eb51bccae0a0b7e599e084d971170e9a1e82d0c`,
  GPL-2.0, 13.6k★. Pre-driver initramfs V67 executor; **new primary path #5**
  (port to 90HX Gen2 write table). 6-write GA102 frames (`recipes.c:5-53`),
  multi-launch-after-one-FWSEC (`unlock_610.c:1211-1310`), `GA102(0x220d)`
  already listed (`recipes.c:419`), runtime FWSEC from ROM BAR
  (`unlock_610.c:792-833`). Full file-referenced note:
  `docs/cmp90hx/upstream/zagitta-gpu-unlock/README.md`.
- https://github.com/Zagitta/gpu-unlock/issues/17 — dual-3090 success on
  pinned `a9b0c75` (multi-GPU pre-driver corroboration).
- https://github.com/Zagitta/gpu-unlock/issues/23 — non-cold failure report
  on revision `fc833215` (pre-launch HALTED-clear timeout at `0x110100`,
  DMA retained, recovery = full power-off — their wedge mode ≈ ours).
- https://github.com/Zagitta/gpu-unlock/issues/11 — Ubuntu pre-udev
  initramfs ordering (matters for our initramfs-tools hook plan).
- https://github.com/Zagitta/gpu-unlock/pull/24 — Ada port ("not a
  device-ID-only extension" — caution precedent for our 220d recipe work).
- Tracker recon 2026-10-31 (full analysis in
  `docs/cmp90hx/upstream/zagitta-gpu-unlock/README.md`):
  - https://github.com/Zagitta/gpu-unlock/issues/280 — 3070 Ti FE unlock
    SUCCESS on kernel **7.2.6** (breaks kernel-era corpus correlation; ROM
    export shown to carry FWSEC on consumer GA102).
  - https://github.com/Zagitta/gpu-unlock/issues/236 — 2×3090 on **kernel
    7.0.0-38 (= llm2)**; failure root-caused to Xen hiding FLReset+ →
    module's hard FLR-capability precondition documented
    (`unlock_transaction_claim:611`).
  - https://github.com/Zagitta/gpu-unlock/issues/260 — 5×3090 behind
    PEX880xx: post-unlock DPC/Xid-79 whole-switch loss (retrain/FLR caution
    precedent).
  - https://github.com/Zagitta/gpu-unlock/pull/251 — D3cold clears volatile
    selectors, re-apply on resume (llm2 rtkit/cooldown interaction).
  - https://github.com/Zagitta/gpu-unlock/issues/21 — GA106 SEC2
    `0xbadf5620` (intra-GA10x family variance; GA102 = our silicon).
  - https://github.com/Zagitta/gpu-unlock/issues/28 — OEM GA102-250:
    selectors held at runtime, fused-no-uplift negative control.
  - https://github.com/Zagitta/gpu-unlock/issues/168 — payload rebuild
    method; booter/V67 byte-identical 610.43.03 vs 615.71.10.
  - https://github.com/Zagitta/gpu-unlock/discussions/238 — XCP-ng FLR
    workaround thread (referenced from #236).
- https://github.com/impacifist/Windows-GPU-UNLOCK — Windows port of
  Zagitta (per their FAQ; adjacent to WildFlash's EFI approach).
- https://github.com/haohervchb/Turing-unlock — upstream of KohakUnlock's
  TU102 executor (attribution chain).
- https://github.com/KohakuBlueleaf/mmapeak — randomized-input benchmark fork
  (fixes all-zero-fragment overcounting; benchmark-methodology caution).
- https://huggingface.co/TOTORONG/AD103_win_unlocker — board-specific Ada
  UEFI research (adjacent; recorded for completeness).
- https://github.com/physicsdolphin/nv-uefi-unlocker — HEAD `16e9dc5`
  (2026-10-31, repo created 2026-10-26), GPL-2.0-only, 436★, Rust. UEFI
  pre-driver unlock executor (USB-stick `BOOTX64.EFI`, Windows/Linux/
  Hackintosh): SEC2 scrubber → FWSEC/WPR2 → signed Booter → V67 four-write
  payload, read-back verified — the EFI pre-OS analogue of our `efi-unlock/`
  and WildFlash's EFI work, transplanted from the Zagitta transaction chain.
  **Not applicable to 90HX/50HX: compatibility matrix explicitly excludes
  GA100** (supports GTX 16/RTX 20/30/40 only). Value to the campaign =
  mechanism precedent (WPR2-up triage anchored on GFW-completed + GSP-not-
  started, RTD3 power-loss caveat, re-apply every cold boot, no-retry-after-
  STOP discipline) + lineage anchors below. Reflected: not yet analyzed in
  depth — recorded 2026-10-31, user-provided pointer.
- https://github.com/JustAResearcher/gpu-unlock-ada — GPL-2.0; AD10x
  four-write chain source, per nv-uefi-unlocker credits (new via the entry
  above).
- https://github.com/Consensus-Protocol/cmp170hx — PLM semantics +
  validation methodology, per nv-uefi-unlocker credits (distinct from the
  cmp170hx-gen2 forks already cited in vendored upstream notes).

## Found 2026-11-01 (user-provided pointer → material discovery)

- https://github.com/skbskhud/p104-unlock-v3 — HEAD tool v1.2 (2026-10-31),
  "full open source". **GP104 P104-100 (`10DE:1B87`) PCIe Gen2 x4 LIVE unlock**
  — the first lever in our corpus that reaches Gen2 **without writing XP3G**
  (no compute exploit, no `0x8E1B0` gate). Adds `0x2241C` **NV_PTOP_FS4**
  ("live declaration switch", bits[0],[7]=1) which appears nowhere else in our
  docs; reuses the XVE/XP_PL set we already hold (`0x8841C/0x8C040/0x8C1C0/
  0x8C2C0/0x8872C`) plus `0x8C300` CYA1 + `0x88610` VSEC_HIER, then TLS=2 both
  ends + root-port retrain. Measured GP104: Gen1 0.78 → Gen2 1.55/1.69 GB/s,
  volatile (20 ms watchdog). Full register cross-map + TU102 port notes + risk
  analysis + read-only probe: **`docs/cmp90hx/upstream/p104-unlock-v3/README.md`**.
  **Candidate lever for the CMP 50HX 615-EFI-only Gen2 gap** (ticket 11 §9):
  untested on Turing; GA102 (`0x88fe8=0xffffffcf`, `VSEC_DEVICE` fuse-shadow) is
  the negative control — probe `0x88fe8`/`0x2241C` on TU102 before any write.

## NVIDIA firmware inputs (Zagitta build deps, pinned)

- https://download.nvidia.com/XFree86/NVIDIA-kernel-module-source/NVIDIA-kernel-module-source-610.43.03.tar.xz
- https://download.nvidia.com/XFree86/Linux-x86_64/610.43.03/NVIDIA-Linux-x86_64-610.43.03-no-compat32.run
  Local cache: `cache/610.43.03.tar.gz` sha256 `9df87d75…` (verified);
  extraction tooling: `firmware/fetch_artifacts.py`,
  `extract_boot_assets.py`, `extract_gsp.py` (in Zagitta repo).

## lixiangwuxian cluster (2026-10-31 — the lineage ROOT + new levers)

- https://github.com/lixiangwuxian/cmpunlocker — HEAD **`2d10f89` = the
  "cmpunlocker 2d10f891" cited by Zagitta AND jdowning's research notes**:
  the root CMP unlocker (170HX/GA100, Tom's Hardware/wccftech/LTT-featured),
  contains `driver/patches/sec2-postbl-plm-ss-cfg.patch` with the original
  `plmTable` from which our whole 90HX lineage descends.
- https://github.com/lixiangwuxian/170hx_tips — HEAD `0d30567` (2026-10-20).
  `Gen3_unlock_en.md` = complete CMP **Gen3 x16** enablement guide (GA100,
  driver 615.71.09): probe-stage software-fuse-override code
  (`EN_SW_OVERRIDE 0x820040`, Gen3-disable bits `0x820250/0x820580`,
  FEATURE_OVERRIDE `0x82380C/10/2C` CPU-writable on GA100), standalone
  **RM-client staged link trainer** (`NV2080_CTRL_CMD_BUS_SET_PCIE_SPEED`
  0x20801805, `set_pcie_speed.c`), registry combo
  `RmForceEnableGen2=1;RMPcieLinkSpeed=0x5;CmpGen3=1`, RM error map
  (0x1b=instance mixup, 0x0f=power-cycle), LnkSta-only acceptance +
  single-pass discipline. Reflected: `docs/cmp90hx/rm-levers-and-p2p.md`.
- https://github.com/lixiangwuxian/170hx-rir-tool — HEAD `03a612a`. GA100
  **RIR fuse writer** (irreversible burns; unlocked `disable_sw_override` on
  170HX). **GA100-only, NOT applicable to the 90HX, never run at llm2.**
  Recorded for the mechanism chain (why 170HX needed a burn: burned
  `0x820084` bit0; our L1b probe answers whether 90HX fuses are burned).

- https://github.com/iatethelogs/cmp90hx_pwner — **updated HEAD `73bc5ea`
  (2026-09-27 "Document manual P2P mode")** vs our older vendored snapshot:
  now ships the full P2P recipe (exact `NVreg_RegistryDwords` string +
  IOMMU-identity switching + srcversion-verified insmod of the rejoin16-
  patched stockflow module). Key-by-key audit vs our tree in
  `docs/cmp90hx/rm-levers-and-p2p.md` §2.
- https://github.com/xrip/cmp50hx-unlock/issues/14 — 50HX P2P proof +
  `iommu=pt`/GSP counter-case; basis of patches `05-rtx2080ti-rebar`,
  `06-aikitoria-p2p`, `07-turing-p2p` and `docs/P2P.md`.
- https://github.com/iatethelogs/cmp90hx_pwner/issues (2, 5, 7) — apply
  automation reports.
- https://github.com/iatethelogs/cmp90hx_pwner — resolved target of the
  opaque `google.com/goto?url=CAESZAHrOzAV…` redirect in the user's
  2026-10-31 (late) message (user clarified 2026-10-31); same repo as the
  HEAD-`73bc5ea` entry above — no new content beyond what is already
  analyzed in `docs/cmp90hx/rm-levers-and-p2p.md` §2.

## Where the campaign record lives

- Ticket journal + windows v1–v10: `.scratch/90hx-gen2-p2p/issues/03-…md`
  (git-excluded; mirrored to llm2 `/tmp/90hx-gen2-p2p-scratch/`).
- Mechanism findings: `findings.md` (committed).
- Path scoping (#1–#5): `docs/cmp90hx/alt-paths-scope.md`.
- Kernel hypothesis verdict: `docs/cmp90hx/kernel-hypothesis.md`.
- Upstream drafts for posting (jdowning b1 + WildFlash):
  `.scratch/90hx-gen2-p2p/upstream-issue-draft*.md` — user posts; never
  published from this side.
