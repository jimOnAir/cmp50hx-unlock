# 17 — Booter mailbox0/EXCI decode dictionary into failure paths

Type: build (EFI + claim ko + collect)
Status: in-progress (code landed + offline gates green; real/injected halt
render + findings row pending llm2 boot batch)
Blocked by: 16 (shared failure-dump surfaces; boot-proof batch)
Source rows: B2-P4 (tx_booter.rs:782-840; tu10x-booter-nsstub-disasm.md:62-75; round3-conclusions.md:15)

## What to build

Halt diagnostics get names, not magic numbers: mailbox0 dictionary v3
(0x31 NS-stub pre-secure marker, 0x89/0x8a meta-magic/field check, 0x91 =
live WPR geometry check — delta must be EXACTLY 1 MiB, 0x0B PSS final-hash
stage, 0x11 GetParam expected-value table) + EXCI/EXCAUSE decode
(exception cause bits [24:20]) printed alongside ticket 07's RISC-V dump,
in EFI log and claim `stage=` lines. Carry the two traps as code comments
verbatim: Turing `sec` readback is always scrub-poisoned (ns/dmem rows are
the verdict), and `0x00900100` INV_INS appears in SUCCESSFUL runs too —
the decoder must label it informational, never VERDICT.

## Acceptance criteria

- [x] Decode table shared between EFI and ko via one generated header (no
      string drift); every known code prints name + one-line meaning;
      unknown codes print raw + 'undecoded' (never a guess).
      Landed: common/booter_mailbox.h (dictionary v3 + poison predicate +
      EXCI accessors, static inline, ASCII, host-compilable); EFI includes
      it directly, ko via claim-90hx/booter_diag.{c,h} compose layer.
      Harness B1c proves the two sides render the IDENTICAL dictionary
      string for every code.
- [x] Harness: each dictionary code decodes; unknown code falls through
      correctly; the 0x00900100 line is labeled non-verdict.
      Landed: efi-unlock/tools/mailbox-dict-selftest.sh — 32 C behavior
      checks (dictionary VERBATIM + booter_diag.c compiled in, EFI note
      helpers extracted VERBATIM behind a mini-rendering Print stub, so
      RENDERED lines are asserted) + 25 grep/structural asserts. Poison
      flavors proven never named (0xBADF5620 would decode as SP_OVERFLOW
      if the poison gate didn't fire first — B3b proves the trap is real);
      0x00900100 => 'info - also seen in SUCCESSFUL runs...', no emitted
      line carries the VERDICT token (B7); EXCI [24:20]/[19:0] proven
      against hand-computed fixtures incl. the corrected 0x09≠0x10 reading.
- [ ] One real or injected halt renders the decoded line; findings.md row.
      AWAITING LLM2 (offline bar met: injected-halt fixtures render the
      decoded lines in the harness; real halt joins the t04-16 boot batch).

## Landed notes (offline gate session 2026-11-12)

- Register provenance (from headers, not vibes): EXCI = falcon base+0x0d0,
  EXPC[19:0], EXCAUSE[24:20] — vendored open-gpu-kernel-modules
  src/common/inc/swref/published/nvswitch/lr10/dev_soe_ip.h:318-338
  (NV_SOE_FALCON_EXCI + EXCAUSE_* constants the cause-name table mirrors;
  Falcon IP common), live-silicon offset cross-check B2 loader/src/tx.rs:308
  ("EXCI", 0x0d0 @SEC2 0x840000) + tx_booter.rs:581 halt forensics.
  ko reads GU_SEC2_BASE + GU_FALCON_EXCI_OFFSET (new constant in
  claim-90hx/registers.h, cited); EFI reads SEC2_EXCI (NV_PSEC_BASE+0x0d0).
- 0x91 dictionary line STATES the contract: "delta must be EXACTLY 1 MiB
  (0x100000)" + reconciles the ticket-15 BOOTER_EXIT_SUB4G_READLOCK
  vocabulary in the same sentence; 0x89 likewise names the
  staging-undelivered class (BOOTER_EXIT_STAGING_UNDELIVERED) — one
  vocabulary, no contradiction.
- Attachments: EFI tu102 halt dump (mailbox note + NEW SEC2_EXCI read &
  note on the not-OK path, mirroring B2's halt forensics), [9][warm]
  returned-halt line, both STAGING-FALLBACK decline branches, LOW-band
  retry refusal, FWSEC gate [MAILBOX] reject (poison-gated, see below);
  ko gu_snapshot gains 'booter-diag mailbox0' after the boot line and
  'booter-diag exci' after ticket-07's riscv line, plus the
  invocation-failed dump.
- FWSEC scope decision (honest deviation from the blanket wording): the
  fwsec50 gate-failure mailbox prints are GSP-FWSECLIC values, a
  different producer than the SEC2 booter the v3 dictionary describes
  (B2's own FWSEC forensics print them raw, tx_fwsec.rs:704/976).
  Attaching booter-dictionary names there would be guessing — the note is
  attached ONLY on the [MAILBOX]-reject line and ONLY when mb0 itself is
  poisoned (that line then states poison, never a name). Comment in-source.
- Trap 1 (sec readback): encoded as rule + behavior — the note helpers
  receive values only (python asserts no mmio/port read in their extracted
  bodies), no call site passes a sec-derived value (grep assert), the
  IMEM_S readback line carries the verbatim rule comment and stays
  observational.
- Packaging (necessary out-of-list one-liner, reported): the claim DKMS
  tree builds STANDALONE (build-deb.sh tars only claim-90hx/), so
  ../common resolves nowhere at customer install. tools/build-deb.sh now
  stages a BYTE copy of common/booter_mailbox.h into the claim source dir
  (quoted include finds it there; in-tree builds use the Kbuild
  -I$(src)/../common path — booter_diag.c has one include line, both work).
  Proven by a faithful DKMS-staging simulation (tar+install into /tmp,
  make against 7.2.9: rc=0 zero warnings, booter_diag.o + gpu_unlock.ko
  built with no sibling common/ present). Asserted in the harness grep
  block so the staging line can't silently vanish.
- Harnesses touched to stay green (precedent: ticket 15 added the
  zero-DMA stub the same way): fwsec-gate-selftest.sh (shared-header
  include + counter, asserts the note fires ONLY on [MAILBOX]-with-poison-
  mb0 — 12/12), staging-ladder-selftest.sh (inert note stub + counters
  pinning refusal-site attachment on fixtures 1/5/7 and non-attachment on
  host-side refusals 4/8 — 12/12). preflight 13/13, reset-canary 44/44
  untouched.
- collect: NO change — its verdict/canary greps ('card N result:',
  '*** UNLOCKED', 'RESULT: PLM=', 'cold-state:', 'verdict=[a-z-]+')
  consume none of the new lines; no new grep was added, so the collect
  harness needs no extension. bash -n re-verified. Harness asserts the
  non-collision.
- Gates this session: mailbox-dict 57 PASS / 0 FAIL; preflight 13/13;
  fwsec-gate 12/12; staging-ladder 12/12; reset-canary 44 PASS; EFI
  container ubuntu:24.04 gcc-13.3 NEW+baseline both BUILD_OK, warning
  diff EMPTY (the single pre-existing ld .note.GNU-stack note only);
  claim ko make against BOTH /lib/modules trees (7.2.9-1-MANJARO,
  6.18.55-1-MANJARO) rc=0 zero warnings (artifacts cleaned); check_braces
  output identical to baseline; bash -n collect/build-deb/selftest.
- Not touched deliberately: dead booter_load_v67 legacy path (called only
  under `&& FALSE`), sec2_health canary probe (writes-and-restores, not a
  halt dump), warm-state probe prints (not failures), sanitize-done line
  (prints the value we ourselves wrote). No git state mutations.
