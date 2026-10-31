# SOURCES — canonical link ledger (user-provided + discovered)

Every external link referenced by the 90HX Gen2 campaign, with where its
substance is reflected in this repo. Links are preserved regardless of
outcome. (Bash-greppable: one URL per bullet.)

## Articles

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

## Unlock repos (lineage)

- https://github.com/bendy2/cmp90hx — V67 stockflow origin for CMP 90HX.
- https://github.com/pearlfortune/cmpunlocker — production compute unlock;
  llm2 serving flow. Reflected: `patches/cmp90hx/0014/0015`, findings.md.
- https://github.com/jdowning100/cmpunlocker — rejoin16 Gen2 path +
  `90HX-GEN2-RESEARCH-NOTES.md` (vendored here as
  `docs/cmp90hx/rejoin16-RESEARCH-NOTES.md`) + `bench/rejoin16-apply-all.sh`.
  Tested 1:1 → 0/49 on llm2; see ticket 03, `upstream-issue-draft.md`
  (b1, ready to post).
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

## NVIDIA firmware inputs (Zagitta build deps, pinned)

- https://download.nvidia.com/XFree86/NVIDIA-kernel-module-source/NVIDIA-kernel-module-source-610.43.03.tar.xz
- https://download.nvidia.com/XFree86/Linux-x86_64/610.43.03/NVIDIA-Linux-x86_64-610.43.03-no-compat32.run
  Local cache: `cache/610.43.03.tar.gz` sha256 `9df87d75…` (verified);
  extraction tooling: `firmware/fetch_artifacts.py`,
  `extract_boot_assets.py`, `extract_gsp.py` (in Zagitta repo).

## Older campaign sources (previously scattered; consolidated here)

- https://github.com/lixiangwuxian/170hx_tips — GA100 `Gen3_unlock_en.md`
  (device 2082), reflected in `docs/cmp90hx/gen-feasibility.md`.
- https://github.com/xrip/cmp50hx-unlock/issues/14 — 50HX P2P proof +
  `iommu=pt`/GSP counter-case; basis of patches `05-rtx2080ti-rebar`,
  `06-aikitoria-p2p`, `07-turing-p2p` and `docs/P2P.md`.
- https://github.com/iatethelogs/cmp90hx_pwner/issues (2, 5, 7) — apply
  automation reports.

## Where the campaign record lives

- Ticket journal + windows v1–v10: `.scratch/90hx-gen2-p2p/issues/03-…md`
  (git-excluded; mirrored to llm2 `/tmp/90hx-gen2-p2p-scratch/`).
- Mechanism findings: `findings.md` (committed).
- Path scoping (#1–#5): `docs/cmp90hx/alt-paths-scope.md`.
- Kernel hypothesis verdict: `docs/cmp90hx/kernel-hypothesis.md`.
- Upstream drafts for posting (jdowning b1 + WildFlash):
  `.scratch/90hx-gen2-p2p/upstream-issue-draft*.md` — user posts; never
  published from this side.
