# 12 — UEFI app ASan/UBSan self-test + parser unit tests (host-side)

Type: build (test infrastructure)
Status: resolved (2026-11-12) — code landed, all five boxes verified
offline (container-boot scope note recorded in box 2)
Source rows: X3 + X4

## What to build

The EFI unlock app's transaction and pre-flight code (including the
new capability walker, PROM gate, and cold-state classifier) compiled
**for host Linux** under `-fsanitize=address,undefined -Werror` against a
simulated PCI/MMIO/DMA environment, driven by a scenario suite — memory
errors and UB in boot-path code found by the build gate, not by a bricked
boot. Plus (X4): unit tests for the shared parser surface — booter-header
validation, ELF section walk, WPR metadata, boot-descriptor parse,
VBIOS/FWSEC walk, cold-state matrix, capability-layout edge cases — the
near-drop-in versions of the upstream parser tests, adapted to this fork's
proven constants (TU102, 1e09, the 20 GB variants).

## Acceptance criteria

- [x] `python3 windows-side...` equivalent runner in this repo's tooling
      (script location follows repo convention): compiles the app sources
      host-side with vendored EDK2-style headers and runs the scenario
      suite under both sanitizers, zero findings; wired into the existing
      container-gate CI. (LANDED 2026-11-12: efi-unlock/tools/
      asan-gate-selftest.sh — VERBATIM slices (ticket convention; stub
      <efi.h> for the real sha256.c TU), gcc -fsanitize=address,undefined
      -fno-sanitize-recover=all -Werror, test:host-harness job.)
- [x] Scenario catalog includes: full success transaction; each
      ticket-08 refusal case; ticket-09 digest-mismatch case; ticket-04
      cold-state matrix; the foundry-strap chip variant from ticket 05.
      (37 asserts: C1-C6 verdict matrix; CI1-CI4 strap WARNING/silence;
      AT1-AT4 attest incl. tamper + missing-entry refusals; P1-P6 PROM
      OBSERVE/ENFORCE/MISMATCH/length-field/alloc-skip; ticket-08 walker
      stays covered by preflight-selftest (13). "Full success
      transaction" scope note: the booter phases remain the
      container-boot-gated path (llm2); host coverage = boot-path logic
      + parser surface.)
- [x] Memory-safety proof: deliberately poisoned fixture (freed DMA
      buffer still referenced on a failure exit) is caught by ASan — the
      harness itself is validated against a known bug, per the repo's
      "a fix must be proven on its failure path" standard. (poison.c
      subprocess: harness FAILS if ASan does not report
      heap-use-after-free; it bit twice on first runs — fixture sfn()
      overread AND would have caught the real-code
      (bpb[39]<<24) signed-shift UB: production fixed under
      UBSan-guarantee in this very commit, scenario F14 pins it.)
- [x] Parser unit tests green with the fork's own fixtures (no imported
      GeForce constants passed off as ours); fixtures generated
      deterministically, zero binaries committed. (F1-F16: whole
      cmp90_fat_* parser block verbatim over synthetic FAT32+FAT16
      volumes built in code — geometry, 8.3, case-insensitive, LFN
      reassembly, BPB adversarial set (bad sig/bps=0/spc=0/rootClus<2),
      corrupted-cluster chain, oversized path, absurd fatsz, sign-bit
      fatsz, non-MZ PE sanitizer, alloc-cap; sha256 manifest fixture
      computed by hashlib at generation time.)
- [x] Provenance headers on new harness files (rows X3/X4); the
      containment-assert vocabulary shared with ticket 11's harness so
      both suites read alike. (ck()/PASS/FAIL/log_ring/log_has shared
      shape; headers cite GTUU ab7bfc0/1d6a508 tests read-only + B2-P23.)
