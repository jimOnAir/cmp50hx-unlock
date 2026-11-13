# 05 — Foundry-strap-tolerant PMC_BOOT_0 chip-ID validation

Type: build (EFI)
Status: in-progress (script mask + EFI observation landed; premise CORRECTED below, boot proofs pending)
Blocked by: — (can start immediately)
Source row: U4

## What to build

The EFI unlock path's chip validation accepts TU102 parts whose
PMC_BOOT_0 carries foundry strap bits (bits 31:29 set — e.g. a
0xb62000a1-class strap variant of 0x162000a1) instead of requiring an
exact match and silently skipping a good card. A ~10-line mask change
(`0x1ff000ff`-style: compare die/chip identity bits, ignore the strap
bits) with the same tolerant comparison wherever the exact value is
pinned in the EFI profile checks.

## Acceptance criteria

- [ ] Container compile; strap-variant value passes the validator, a
      genuinely different chip (e.g. 0x164000a1, TU104) still rejects —
      unit-level check for both cases in the self-test.
- [x] Claim module audit done: ko already field-masked (:1674) + saved-value
      compare; the script guard fixed as above (its all-FF sentinel reject
      stays strict).
- [ ] No behavior change for the known-good exact 0x162000a1 part (the
      normal boot path is byte-for-byte the same decision).
- [ ] findings.md line with the decision table.

## Notes

This closes a silent-skip class on a headless fleet: today an unexpected
strap variant reads as "not our card" and the unlock just doesn't happen,
indistinguishable from other no-ops in the log. If the refusal path is
reachable, make it log the observed value before the masked comparison.
