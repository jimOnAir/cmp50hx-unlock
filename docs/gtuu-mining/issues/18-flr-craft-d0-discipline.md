# 18 — FLR craft upgrade + force-D0 before resume re-unlock

Type: build (EFI + claim ko)
Status: ready-for-agent
Blocked by: 17 (same failure/handoff paths; boot-proof batch)
Source rows: B2-P13 (totorong-comparison FLR/PCI-restore rows; tx_booter.rs:1384+; evidence/warm-resume-entry/report.md:64-65) + B2-P32a

## What to build

Two resets hardened. (a) EFI FLR today is devctl bit15 + a flat 200 ms
stall: upgrade to the documented craft — wait Transactions-Pending clear,
set FLR preserving other Device Control bits, honor ≥100 ms silence, poll
config identity return, restore state high-BAR dword first and COMMAND
last with BME never re-enabled; PMCSR saved/restored and D0 pinned around
the FLR ("PCIe defines FLR only in D0"). (b) Claim module's PM-notifier
refuses a non-D0 card outright (unlock_610.c:660-666): instead force D0
(PMCSR write + readback) once, re-verify, and only then refuse if it
still won't wake — D3-cold-notified cards become recoverable instead of
silently staying locked.

## Acceptance criteria

- [ ] Both changes compile through existing gates (bench EFI + 3-gen ko).
- [ ] Harness/extraction tests: TP-pending wait honors timeout with named
      failure; D0 force path unit-proven with a fake PMCSR that wakes on
      the second write; refuse-after-force still refuses.
- [ ] Live: normal boot FLR timing logged (ms deltas vs old flat 200 ms);
      one warm-reboot cycle unaffected; findings.md rows for both.
