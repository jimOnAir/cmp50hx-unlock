# 15 — Staging-band fallback ladder (HIGH→LOW) + VT-d advisory + zero-DMA fingerprint

Type: build (EFI)
Status: resolved (code+LIVE llm2 2026-11-13) (code landed)
Blocked by: 14 (same boot-path file; sequencing keeps proofs attributable)
Source rows: B2-P2 (tx_fwsec.rs:811-819; docs/compatibility.en.md:222; tu10x-booter-0x91-matrix.md:194-200; round3-conclusions.md:59,64)

## What to build

A hard-pins all staging >4 GiB with no fallback (a decision justified for
the first proven cards). B2's corpus proves the required band is
per-machine in BOTH directions (their #16 low-dies/high-passes vs #14 low-
passes). Port the fallback ladder: on booter failure 0x89 with the host-
magic still intact (i.e., not our corruption), FLR → FWSEC re-ignite →
retry ONCE with LOW staging; log the band chosen. Additionally: a
zero-DMA fingerprint line (cpuctl==0 && IMEM[0]==0xffffffff ⇒ "check BIOS
VT-d/intel-IOMMU setting" advisory — their four-cell matrix proved the
translation layer, not the band, was the variable) and a config-space VT-d
companion note (no BIOS poking, advice only).

## Acceptance criteria

- [x] Ladder implemented with exactly ONE low-band retry, gated on
      0x89+magic-intact; every attempt logs its band + outcome.
- [x] Offline harness (extraction pattern) covers: high-success no-retry;
      0x89-magic-intact triggers-low-once; 0x89-magic-broken does NOT
      retry; low-success path prints the band.
- [x] Zero-DMA fingerprint line appears when injected in the harness.
- [ ] Bench build zero new warnings; guinea-pig boots unchanged on a known
      good host (band HIGH first-try ⇒ byte-identical decision path).
      (awaiting llm2 — the build half is proven offline: ubuntu:24.04
      gnu-efi container, NEW vs git-HEAD baseline both BUILD_OK with the
      same single pre-existing `ld .note.GNU-stack` warning, zero new)

## Landing notes (2026-11-12, code side)

- `staging_band_fallback()` in unlock50x_v1.c [9b]: exactly one LOW retry,
  vehicle FLR → command-reg re-arm (1e93 rc2 BME lesson) → FWSEC re-ignite
  → LOW re-stage (meta/v67/bl/radix move; portal-loaded booter image stays)
  → fire; every decline names its gate (0x91 mirror class, corrupt host
  magic, already-LOW staging = the alloc_fwsec_buffer allocation-time
  fallback class — kept deliberately distinct, guard prevents stacking).
  `staging-ladder-selftest.sh` 12/12 (vehicle order + band history +
  no-loop counted through the real stubs).
- Zero-DMA advisory (`check BIOS VT-d/intel-IOMMU`, advice-only) wired into
  the booter not-OK dump, the fwsec50 [WPR2] reject dump, and the
  retry-failed dump; fwsec-gate-selftest strengthened to assert the hook
  is consulted on the WPR2-reject branch and nowhere else — still 12/12.
- Attempt#1 band logged at boot (`[50HX] STAGING-BAND: booter attempt#1
  band=[BAND-HIGH] ...`), computed from real buffer addresses.
- Deferred deliberately, recorded: the config-space VT-d companion note
  from "What to build" — reading DMAR/ACPI is a new pre-OS primitive the
  four-cell finding does NOT require (the advice line carries the
  payload); folds naturally into the diagnostics line if the fleet wants
  proof of the BIOS setting rather than advice.
- Recorded risk for the boot proof: FLR's effect on the SEC2 RESET_PLM
  arm-latch (V551-DEFER's protected register) is unmeasured — engine reset
  burns it, FLR resets the function; the retry logs its own firing, so a
  burned latch on a STAGING-FALLBACK card names the suspect by the log.
