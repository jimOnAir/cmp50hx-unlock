# 10 — gpu_peek: read-only pre-driver BAR0 sampler for remote triage

Type: build (diagnostic ko + deb packaging)
Status: ready-for-agent (code landed)
Blocked by: — (can start immediately)
Source row: T2

## What to build

A small kernel module, `gpu_peek`, that answers "what state is this card
in *before* the display driver touches it" from a headless SSH session:
loads against an unbound CMP card, performs single 32-bit reads only, and
prints the speed-select overrides, the FEAT readout cluster (9×3-bit
fields + override nibbles), selected permission PLMs, and PMC_BOOT_0 —
then exits with the card untouched. The fleet-triage win: cold /
locked / half-open (cross-reference ticket 04's vocabulary) distinguishable
remotely without booting into the unlock flow or visiting the bench.

## Distribution discipline (agreed, Q14)

- Ships inside the deb but is **modprobe-blacklisted and never
  autoloaded** — the same claim-window philosophy: only an explicit
  operator `insmod` loads it; nothing in the boot flow may ever touch it.
- Read-only by construction: the audit is a hard acceptance criterion
  (below), not a code-review hope.

## Acceptance criteria

- [x] Static audit of the module diff proves zero writes, zero resets, no
      Bus Master/MEM-space enables, no config-space writes: every MMIO
      access is an `ioread32`-class primitive; evidence (grep table) in
      the PR description. (grep table: gpu-peek/README.md + ticket report
      2026-11-12)
- [x] Container compile on the supported kernel-header generations.
      (ubuntu:24.04 6.8.0-149-generic + ubuntu:26.04 7.0.0-43-generic,
      zero source warnings; host 7.2.9-1 & 6.18.55-1-MANJARO too, incl. W=1)
- [ ] Live proof on the guinea-pig host: insmod against an unbound card
      (or before driver bind), output decodes correctly against the
      known-state reading from the existing post-driver verifier, rmmod
      clean; LnkSta/Xid unaffected (link state unchanged, zero Xid).
      — awaiting owner-gated llm2 session.
- [x] Deb contents: module + blacklist conf + `/usr/local` helper wrapper
      with `--help`; smoke gate asserts the blacklist line exists and
      that no unit orders the module into any boot phase.
      (`PASS_CMP_DEB_SMOKE` on a real 20261112.peektest1 build, 2026-11-12)
- [ ] README (EN/RU) diagnostic section gets the one-line usage;
      findings.md proof line; provenance header (row T2).
      — gpu-peek/README.md provenance header landed; the root README.md/
      README.RU.md + findings.md lines are outside this agent's file
      domain (needed diff in the ticket report).

## B2 fold-in (rows P20+P24+P34) — follow-up enrichment, not blocking close

Verdict strings can later gain: the badf named taxonomy (0xBADF5040
PRIV_VIOLATION / 1100 UNDECODED / 20xx FLOORSWEPT / 5620 domain-locked),
B2's in-OS register union (FEAT 0x409650-6c full quad + fuse dictionary at
GA100-0x7FF000, GR anchor 0x409604), and the selector nibble->rate-code
decode corroborated by their GA106 arithmetic (code 4 <-> 1.80x). Filed
against gpu-peek; do the claim-ko `stage=` decode via ticket 17 instead.
