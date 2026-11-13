# 20 — Per-line ms stamps in the ESP log + build banner assert

Type: build (EFI + build gates)
Status: resolved (code+LIVE llm2 2026-11-13)
Blocked by: 19 (log-surface serialization; lands after all line additions)
Source rows: B2-P17 (loader/timing.rs:1-48) + B2-P19 (check_efi.py:1-21)

## What to build

(1) Each 50hx_log.txt line carries [+ NNNNms] from a rdtsc-calibrated
base so A/B run docs can decompose wait-vs-work (the September matrix's
13.5-vs-14.9 clock puzzle becomes readable data). (2) Build-identity
gate: the stamped/unlocked and read-only diagnostic artifact variants
embed distinct banner strings; build.sh and the deb smoke gate assert
the banner of each shipped .EFI matches its intended role — artifact
mix-up becomes a failed build, not a field surprise.

## Acceptance criteria

- [ ] Log lines gain monotonic ms deltas; calibration handles the UEFI
      timer gracefully (PTIMER seed already exists); duplicate-line
      suppression unchanged.
- [ ] Banner assert green on the current u1/u3/u4 variants; flipping the
      variant name fails the smoke gate (proven on the failure path).
