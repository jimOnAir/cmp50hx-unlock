# 02 — Land the full source-evaluation tables (B1 GTUU + B2 nv-uefi-unlocker) + findings.md entry

Type: docs
Status: resolved (2026-11-12) — B1 + B2 tables both landed
Blocked by: — (can start immediately)

## What to build

`../source-eval.md` recording the complete static sweeps of BOTH mined
sources against this repo — every mechanism classified ALREADY-HAVE /
PORT-CANDIDATE / NOT-APPLICABLE with evidence anchors — so all other
tickets in this stream can cite a stable row ID (B1: K1–K19, U1–U14,
X1–X8, T1–T6, S1–S4; B2: P-rows assigned by its sweep) instead of
re-deriving. Plus the dated findings.md entry opening the work stream.

B2 = physicsdolphin/nv-uefi-unlocker @ bbcb92f (Rust UEFI chain,
Turing-hardware-tested, Zagitta-lineage sibling): the second sweep
section covers its loader/transaction mechanisms, TU10x forensics corpus
(booter 0x89/0x91 matrix, nsstub disasm, four documented Turing
generational differences), low-memory/4-GiB staging boundary handling,
warm-resume S3/S5 clearing semantics, sim/ methodology, provenance
tooling, and its peer-landscape docs — including any independent verdict
on B1's provenance that corroborates or refutes our red-flag notes.

## Required content

- The mechanism table as swept (B file:line; A file:line for ALREADY-HAVE
  rows — verified, not assumed; one-line value/reject reason per row).
- The lineage finding that shaped the sweep: claim-90hx and B's kernel
  module are divergent forks of the same Zagitta-lineage code — A is ahead
  on suspend/resume re-unlock, per-entry retry, and the `stage=` dmesg
  protocol; B is ahead on host-testability, pre-flight validation, and
  failure forensics.
- Safety-mechanism diff (the Q10 deliverable): pre-flight ROM validation
  ordering, SHA-256 latch of the verified FWSEC span re-checked before
  Bus Master, DMA-buffer retention with Bus Master disabled on post-start
  failure — each marked adopt (→ ticket 09), pattern-adopt (→ ticket 12's
  containment asserts), or already-have, with the A-side proof line.
- Record-only verdicts with reasons: U1 (single dual-runtime codebase —
  deferred until ticket 11 exists), K14 (no-FLR exit tail — fallback
  knowledge only, A's FLR exit field-proven, no OS-side FLR hostility
  observed), U7 (bridge MEM/BME enable — A's CF8/RootBridgeIo path works
  on the real fleet), U13 (per-board profiles — 20 GB handled at runtime),
  X6 (folded as a check inside ticket 09), X7/X8 (optional later), T4
  (subsumed by ticket 01), T6 (deb conffiles make it moot), S4 (cite
  their research reports as corroborating register decode, don't port).
- Red flags for any external citation of B: `provenance.json` shows the
  public tree built from a non-public master with per-file deltas (cite
  contents of 1d6a508 only); AD102 V67 payload provenance is a
  HuggingFace repo (never cite that lineage — their TU102 entry correctly
  credits Zagitta/gpu-unlock + xrip/cmp50hx-unlock, i.e. our own upstream);
  their packaging fetches re-published NVIDIA firmware from third-party
  distro mirrors (adopted pipelines must pin download.nvidia.com only);
  their CMP rows are `experimental_simulated` — simulation-only, never
  real-silicon-tested, must not be cited as support evidence.
- License note: B is GPL-2.0-only per file; this repo's kernel side is
  already GPL-2.0-only (root LICENSE is copyleft-next 0.3.1, efi-unlock
  inherits the 40HX MIT) — ports land as separate GPL-2.0-only files,
  no relicensing bleed either direction.

## Acceptance criteria

- [ ] source-eval.md complete with every sweep row and its classification,
      evidence anchors re-verified against the live clone (clone path and
      commit recorded at top).
- [ ] Safety-mechanism diff table present with per-item verdict.
- [x] findings.md gets the dated work-stream entry (posture: read-only
      static analysis, B never executed) linking ../source-eval.md and
      the issues/ folder.
- [ ] Row IDs used by tickets 03–13 all resolve to table rows.
