# 11 — Host failure-injection harness for the claim module (fake-Linux shim)

Type: build (test infrastructure)
Status: in-progress (phase-1 landed 2026-11-12: shim + 38-assert suite +
CI gate + README; phase-2 = fwsec/booter image fixtures + X2 orchestration
shim; cross-validation row awaits llm2) (code landed)
Blocked by: 04, 06, 07 (the ko-side ports it must cover exist first, so the
harness lands testing the current code, not a stale snapshot)
Source rows: X1 + X2

## What to build

The claim module's transaction logic compiled and run **on the host**,
against a fake Linux: a shim providing the kernel surfaces the module uses
(preregistered fake PCI devices, a large MMIO register array with the
real TU102/GA102 register geometry, synthetic PROM/PCI-config/ELF-GSP
fixtures, fake time), plus failure-injection knobs (allocation failures
at each stage, stuck bus-master, alien WPR content, corrupt selector,
reset locked until FLR, BAR late-ready, lost device identity, and the
rest of the ~45-knob catalog ported from the upstream harness). A test
binary drives the full claim transaction through success and injected-fault
paths, asserting the containment invariants the repo holds sacred:
buffers retained-never-freed once firmware has started, at most one
SEC2/GSP/FLR fire per attempt, unwind refusal on unquiesced handoff,
and the cold-state verdicts from ticket 04.

Plus the orchestration layer (X2): mocked module-init with the
multi-card targets parsing — which cards get unlocked, concurrently
(tracked peak in-flight), bound-driver cards skipped, the once-per-boot
claim semantics, and the suspend/resume re-unlock path this fork
invented and upstream never had.

This is the keystone: after it, every future retry/timeout/blacklist/
containment tweak in the claim module is regression-testable without
rebooting a single card.

## Acceptance criteria

- [x] Harness compiles the real module sources by inclusion (no forked
      copy) under a host gcc container gate; no `#ifdef TEST` intrusions
      into production logic beyond what the fork already tolerates at
      seams. (Landed 2026-11-12: test_claim.c includes unlock_610.c
      verbatim + sibling production TUs; zero production edits.)
- [ ] Green suite covers: happy claim path; every injected failure
      lands in a correct, logged outcome with invariants asserted;
      multi-card concurrency + bound-driver skip + resume re-claim.
      (LANDED SO FAR: happy claim; D3-force-D0 recovery + still-refuses;
      NO_FLR; config wedge ±PM cap; GFW WPR2-EBUSY/EALREADY/cold-accept
      with reverse assert; unwind containment BOTH directions (retained
      DMA proof via dma_live counter); entry guards incl. alloc-failure
      axis — 38 asserts ALL-PASS. OPEN: fwsec/booter phases need the
      image-feeding fixture; X2 orchestration (main.c shim) phase-2.)
- [ ] Cross-validation row: one simulated claim sequence's dmesg output
      diffed against a real guinea-pig boot log — protocol parity proven,
      not assumed. (awaiting owner-gated llm2 session — boot-runbook.md
      stage 1 captures the comparison log.)
- [x] Existing container gates (deb smoke, lifecycle) still green; harness
      wired into CI as its own gate job. (test:host-harness job added,
      validate-gitlab-ci.py green; production untouched so prior
      gtuu3 PASS_CMP_DEB_SMOKE stands; ko kernel builds re-verified.)
- [x] README for the harness directory (how to run, how to add a knob);
      provenance headers on shim files (rows X1/X2, GPL-2.0-only).

## Notes

The fork's parser-separated, `__KERNEL__`-guarded file layout was verified
in the sweep as shim-compatible — if inclusion reveals a new tangle, that
prefactoring belongs inside this ticket (make the change easy, then make
the easy change), keeping each production file's behavior unchanged.

## B2 fold-in (row P23)

Adopt as shim design input: the Faults catalog style with NAMED axes
(incl. platform-fault-vs-own-buffer-fault discriminator `meta_magic_corrupt`
and the `fbif_write_dead_after_run` model — after a full booter run, engine
reset does NOT restore FBIF writes, only FLR does); reverse ("must-NOT-
happen") assertions as a first-class matrix; same-source-two-builds test
trick (host gate compiles the production file verbatim — mirrors the
preflight-selftest.sh extraction pattern).
