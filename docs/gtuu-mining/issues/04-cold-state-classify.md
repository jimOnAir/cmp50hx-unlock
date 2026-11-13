# 04 — Cold-state classification: ALREADY_MODIFIED / PARTIALLY_MODIFIED verdicts

Type: build (EFI + claim-90hx + collect)
Status: in-progress (EFI+script+collect code landed; boot proofs pending)
Blocked by: — (can start immediately)
Source row: U3 (GTUU row IDs resolve in ../source-eval.md)

## What to build

When a 50HX boots with a non-stock speed-select state — yesterday's crash
left it half-unlocked, or an experiment is still latched — the boot-time
verdict and the collect output can now *name* the state instead of failing
opaquely: a cold-state classification matrix (CLEAN / ALREADY_MODIFIED /
PARTIALLY_MODIFIED, where PARTIALLY_MODIFIED = SS0 xor SS1 written)
computed from the SS0/SS1 snapshot the EFI app and the claim module already
take, printed into the existing log/verdict channels.

## Scope

- EFI unlock path: classify on entry; PARTIALLY_MODIFIED refuses the
  transaction (unknown partial state is not a premise) and chainloads
  untouched, logging the verdict; ALREADY_MODIFIED short-circuits with the
  existing success verdict path.
- claim-90hx: same verdict at claim entry (it already reads these registers
  for its trust control), emitted through the `stage=` dmesg protocol.
- Collect/boot-verdict tooling recognizes the new verdict lines.

## Acceptance criteria

- [x] Verdict logic is a pure xor-of-unlocked-match classifier; script-side
      truth table tested offline (guard 7/7 PASS doubles for the script
      verdict branches); EFI unit-level cases land with ticket 12's harness.
- [ ] EFI boot proof on the guinea-pig card (bench toolchain build gate PASSED: BUILD_OK, zero new warnings vs HEAD baseline 9/9 CopyMem_1 pre-existing): normal (CLEAN) boot unchanged,
      verdict line present in the ESP log; rollback = existing purge path.
- [ ] Claim-module proof: boot log shows the stage= line with the verdict on
      a normal boot; a simulated half-written state (desk test on the shim
      once ticket 11 exists, or ctypes replay of the register reads before
      then) yields the PARTIALLY_MODIFIED refusal, not a mislock.
- [ ] Collect output displays the verdict name; findings.md line records the
      proof boots.

## Notes

Keep it ~25 lines of decision logic per site, sharing the verdict-string
vocabulary across EFI and ko so parsers match. Do not change any existing
happy-path behavior — pure diagnostic addition.

## B2 fold-in (row P36-C2)

Extend the matrix with the entry-SS LATCH: capture the SS pair at claim
entry so a later failure can distinguish "our write failed" from "someone
re-wrote after us" (pairs with ticket 16's reset-scratch canary).
