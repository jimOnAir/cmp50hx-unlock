# 03 — CREDITS: Vendored + Consulted sections, full pinned source inventory

Type: docs
Status: resolved (2026-11-11)
Blocked by: — (can start immediately)

## What to build

The repo root CREDITS file grows from a single vendored-code line into two
sections — **Vendored** (existing cmp90hx-unlock line, plus Zagitta/gpu-unlock
and CMP40HX-Unlock entries promoted from their component READMEs so the root
file is the complete attribution surface) and **Consulted sources** —
enumerating every third-party project/document the research has actually
used, each with a one-line role and a pinned revision where one is already
recorded in docs.

## Consulted inventory (compiled this session — verify each URL/anchor before landing)

- Research/exploit lineage: Jon Pry "A Canary in the Crypto Mine"
  (zenodo.org/records/20916112); TOTORONG/AD103_win_unlocker rev 51df9c17;
  physicsdolphin/nv-uefi-unlocker; KohakuBlueleaf/KohakUnlock;
  Zagitta/gpu-unlock (discussions/issues studied); Consensus-Protocol/cmp170hx.
- Studied upstream unlockers (docs/cmp90hx/upstream/): bendy2/cmp90hx;
  iatethelogs/cmp90hx_pwner; Wh1stle05/cmp90hx; Rhonstin/cmp90hx-unlock;
  NatsumeAi/CMP-90HX-Compute-PCIE2.0-unlock; studebaker8/cmp170hx-gen2;
  skbskhud/p104-unlock-v3; xrip/cmp50hx-unlock (our upstream);
  WildFlash1st/cmp90hx-unlock-for-windows.
- cmpunlocker family surveyed: pearlfortune/cmpunlocker (v0.1.28);
  jdowning100/cmpunlocker; Cyridd/cmpunlocker; lixiangwuxian/cmpunlocker;
  minicx/cmpunlocker.
- Tooling in measurement/packaging: NVIDIA/open-gpu-kernel-modules @ 610.43.03;
  ProjectPhysX/OpenCL-Benchmark; ilya-zlobintsev/LACT; ncroxon/gnu-efi;
  notfromstatefarm/nvflashk; dartraiden/NVIDIA-patcher;
  bmgjet/Ampere-Bios-Editor.
- New (this work stream): MindAllik/GPU-Tensor-Unlock-Universal @ 1d6a508 —
  consult line notes it is downstream of this lineage (it credits
  xrip/cmp50hx-unlock upstream), was evaluated read-only per GTUU-MINING
  posture, and carries the caveat: cite contents of the pinned commit only
  (public tree built from a non-public master; see source-eval.md red flags).

## Acceptance criteria

- [x] Every URL resolves; every pin matches what docs/README already record
      (no new unprovenanced pins invented here).
- [x] Vendored section covers the three vendored-code upstreams with their
      recorded commits/licenses (GPL-2.0 @ 76940ae; Zagitta @ 7eb51bcc
      lineage; CMP40HX MIT base with existing LICENSE-40HX-UNLOCK).
- [x] MindAllik entry includes commit pin + consult-only + simulated-CMP-rows
      caveats, consistent with source-eval.md.
- [x] README attribution mentions cross-link to CREDITS (no duplicate lists).
