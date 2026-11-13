# 14 — FWSEC completion gate: WPR2-exact AND GSP HALT AND scratch0e AND mailbox

Type: build (EFI)
Status: resolved (code+LIVE llm2 2026-11-13) (code landed)
Blocked by: — (can start immediately)
Source row: B2-P1 (nv-uefi-unlocker @ bbcb92f loader/tx_fwsec.rs:997-1060; docs/tu10x-c-parity-diff.md:5-31)

## What to build

The EFI's FWSEC-wait currently declares success on the WPR2 lo/hi match
alone; the kernel's actual completion contract additionally waits for the
GSP falcon CPUCTL halt (~10 s), checks scratch0e[31:16]==0, and reads back
the mailbox — B2 machine-demonstrated that "WPR2-up" before the tail
completes is the root of the instruction-level-deterministic 0x91 booter
halt ("same machine always fails" class). Port the full completion gate
into the EFI's FWSEC step; the claim module already has the correct form
(its GFW/GSP-completed triage predates this — mirror its shape, keep the
EFI/ko verdict strings identical so collect parses one vocabulary).

## Acceptance criteria

- [ ] EFI boot path refuses ignition unless ALL four conditions hold, each
      with a distinct named log line (which condition, observed values,
      elapsed ms). (code side landed + harness-proven offline; the live
      boot-path demonstration awaits hardware — see boot box)
- [x] Self-test harness (same extraction pattern as preflight-selftest.sh)
      covers: all-hold accept; HALT-missing reject; scratch0e nonzero
      reject; mailbox mismatch reject; WPR2-not-exact reject.
      → efi-unlock/tools/fwsec-gate-selftest.sh, 12/12 green (adds
      never-up, low-nibble-tolerated, GSP-re-lock, mailbox-all-ones,
      mailbox-BADF, mailbox-zeros-accept, slow-HALT-waits fixtures).
- [x] Bench build zero new warnings (measured in-container: ubuntu:24.04 +
      gcc 13.3, NEW == BASELINE == 1 identical ld .note.GNU-stack line,
      BUILD_OK both; the bench's 9-warning figure is a different gcc —
      same-container comparison is the bar).
- [ ] Guinea-pig warm boot shows the four gate lines then a normal unlock
      (batched with the t04-10 boot set) — awaiting llm2, host down
      2026-11-12.
- [ ] If a real board ever shows the tail-latency class, this gate turns
      0x91 into a named wait — note the observation row in findings.md.

## Implementation record (code side, 2026-11-12)

fwsec_boot_gsp_50hx() section 7 (unlock50x_v1.c, ~2004+): the old code
`return TRUE` on the WPR2 lo/hi match alone (that race is the bug; the
5 s timeout branch already returned FALSE — no optimistic-timeout here).
New: four-condition gate, ordered per the kernel contract —
1. `[WPR2]`   exact lo+hi window (existing masked predicate kept)
2. `[HALT]`   GSP falcon CPUCTL bit4 observed, bounded 10 s @1 ms
              (NV_PFALCON_FALCON_CPUCTL_HALTED_TRUE); `[GSP-RELOCK]`
              early-abort keeps the 0xBADF sentinel idiom
3. `[SCRATCH0E]` FRTS_ERR_CODE (0x001438 >> 16) == 0
4. `[MAILBOX]`  read-back not all-ones nor 0xBADF-gated (conservative:
              benign values accepted, matching the reference)
Conditions 3+4 read AFTER halt. Every reject names condition + observed
values + elapsed ms; pass line logs all four compactly. Caller policy
unchanged ([9] still proceeds as control when FWSEC verdict is false).

