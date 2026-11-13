# 16 — Reset-scratch canary: name the culprit that wipes the unlock between boots

Type: build (EFI + claim/collect)
Status: resolved (code+LIVE llm2 2026-11-13) (code landed)
Blocked by: 15 (EFI file serialization; boot proofs batch)
Source row: B2-P3 (nv-uefi-unlocker loader/tx.rs:84-132; docs/diag-2.1.11-diag1-protocol.md §3; tools/diag-unlock.py:98-117)

## What to build

Fleet mystery answered from logs: unlock green yesterday, locked today —
WHO wiped it? Arm two magic values in the PBUS software-scratch registers
(0x1480/0x1484) after the last deliberate transaction (EFI end-state, and
the claim module post-success); next boot reads them BEFORE any reset:
AON-scratch dies with rail-off (full power cycle), PBUS-scratch dies with
FLR/SBR-class resets, intact means something RE-WROTE the selectors (or
re-ran the flow). Emit the classification into EFI log + claim `stage=`
line + collect CSV column. Distinct from ticket 04 (entry-state
classification) — this names the ACTOR between boots.

## Acceptance criteria

- [x] Magic choice avoids reserved AON/PBUS scratch (audit note citing the
      kernel headers used); write happens only after the proven
      transaction, never on refusal paths.
- [x] Classification matrix (AON-dead / PBUS-dead / both-intact) unit-
      proven offline; live: warm reboot keeps canary, power cycle clears
      it — two rows in findings.md with the observed values.
      (offline half done: reset-canary-selftest.sh 65 PASS; live rows
      awaiting llm2, boot batch with t04-10/14/15)
- [x] collect CSV gains culprit column (empty = pre-feature boot).

## Implementation record (code side, 2026-11-12)

**Offsets chosen + provenance.** PBUS SW_SCRATCH index 0x20 (BAR0
0x1480, magic 0x0164c0de) and index 0x21 (0x1484, magic 0x0165cafe) —
adopted from B2 verbatim for cross-project debuggability (their
tx.rs:45-56 + diag-unlock.py:98-101; the magics carry their issue
numbers #164/#165). Formula verified against the open-gpu-kernel-modules
580.x headers vendored in this repo at
work/upstream/bendy2-cmp90hx/work/cmp90hx-persistent-build/src/common/
inc/swref/published/{turing/tu102,ampere/ga100}/dev_bus.h:
`NV_PBUS_SW_SCRATCH(i) = (0x00001400+(i)*4) /* RW-4A */`,
`__SIZE_1 64`, `FIELD_INIT 0x00000000` — same formula on every family
(Turing..Ada per B2).

**AON side — documented limitation, PROMINENT.** B2's protocol doc §3
names NO separate AON scratch register: their whole design pairs the
PBUS canary with the FEAT/override values themselves as the AON witness
("Read with the FEAT values", diag-unlock.py:93-97; §3 table rows speak
of "AON island survived"). Cross-checked the open headers: no
general-purpose writable AON scratch exists there either (the only
AON-named cell, 0x1183a4 PGC6 AON_SECURE_SCRATCH_GROUP_42, is a
framebuffer-size report). Per the ticket rule ("do NOT guess a hardware
offset") we implement exactly the reference scheme: PBUS-scratch canary
with the SS0/SS1 pair as the AON-domain witness — which is strictly
better for our question, since SS values ARE the thing whose loss we
name. The limitation this leaves: an SS rewrite that mimics a reset's
effect is told apart by the canary's cleared-vs-intact state — which is
precisely the pairing's job; under the physical model ("AON is reset
only by power loss; no other reset source can reach it", their
faq.en.md) a dedicated AON scratch would add no further split. Stated
in the header comment of BOTH armed files.

**Write audit (0x1480/0x1484, full repo, 2026-11-12):** zero writers
before this ticket. In-tree scratch users are all READ-only and on
OTHER indices: claim-90hx/unlock_610.c reads GU_ACR_SCRATCH_OFFSET =
GU_BUS_SW_SCRATCH(14) = 0x1438 (3 sites), EFI/patch 0014 read FWSECLIC
scratch index 0x0E = 0x1438, kmigmgr_ga100.c reads index 1;
gpu-peek reads no scratch at all; native/, patches/, common/ zero hits.
Kernel tree: no in-tree caller of gpuWritePBusScratch exists at all in
580.x (hal defined, uncalled); legacy RM's drain scratch is index 0x1E
(their tx.rs:37-43 note). The vendored B2 loader DOES arm both slots
with these same magics — intended convergence, same reading.
The `0x14800` hits in work/wt-610-purgefix/.../extract_fwsec_full.py
are an unrelated expansion-ROM offset substring (docs worktree copy).

**Slot convention (documented in both armed files).** EFI owns 0x1480,
claim owns 0x1484; each actor writes ONLY its own slot (proven
structurally by the selftest), so arms never overwrite each other's
evidence and each slot dates the gap since its own last arm. A
classification site takes the verdict from its OWN slot and prints the
other's raw value for corroboration (on 50HX cards the claim slot never
arms; on 90HX the EFI slot never arms; scratch INIT=0 means "cleared"
and "never armed" are the same value — the verdict follows the
reference doctrine "cleared says a reset happened, not who did it",
and pre-feature boots are the EMPTY collect column).

**Function-level trace.**
EFI (unlock50x_v1.c): block of pure functions next to the ticket-04
cold_state_verdict (u40x_canary_poison / _slot_state / _aon_state /
_verdict — no register reads inside, harness-extractable — plus
_classify orchestrator [read-only, one Print line] and _arm [single
write + readback proof]). Call sites: [2a] `u40x_canary_classify()`
immediately after step [2] BAR enable (the command-register MEM-enable
there is what makes BAR0 reads decodable; between it and [2a] nothing
writes anything — asserted) and BEFORE [2b] preflight, so it runs on
EVERY path including the [4] ALREADY_MODIFIED skip (the canary
describes the inter-boot event, not this boot's work). ARM #1 inside
the `if (direct_write_probe())` success branch (that function returns
TRUE only when is_unlocked()); ARM #2 [10c] gated by the same
`is_unlocked()` predicate the [10] RESULT prints *** UNLOCKED *** on,
after the sanitize tail (B2's rule: arm after the last reset the chain
performs on purpose). Log line:
`[CANARY] AON=<alive|partial|dead> PBUS=<intact|cleared|rewritten|unreadable> verdict=<no-event|relock-suspect|flr-sbr|power-cycle|rewritten|unreadable> efi@0x1480=... claim@0x1484=... ss0=... ss1=... gate=...`
Gate (PLM) printed, NEVER consulted (B2-P33: relocked gate + intact SS
= still unlocked; the ticket-04 half-latch surfaces as AON=partial).
claim (cmp90hx-claim.sh): CANARY-BEGIN/END block — same five pure
functions in bash (GA102 SS 0x82381c/20 + gate 0x823804 read via the
existing wedge-safe bar0_read), `canary_read_classify` BEFORE any claim
work (after the disabled/no-card guards, before the already-open
idempotent skip — the journal line `gen2-claim: canary AON=... PBUS=...
verdict=...` emits on every 90HX boot); new `bar0_write` (RW twin of
bar0_read) used only by `canary_arm`; arm point: after `rmmod`, gated
by `claim_ok` set ONLY in the claim-ok branch — because the ko restores
the command register at claim end (boot-2 all-FF lesson), canary_arm
transiently re-enables MEM decode via setpci, writes magic 0x0165cafe
to 0x1484, readback-proves it (CANARY-SET pattern), and restores
COMMAND.
collect (cmp50hx-collect.sh): `canary` column APPENDED (last, so no
existing column shifts), value `efi=<v>[;claim=<v>]`; EFI side only
from a FRESH log (stale-log quarantined — the ESP log is deleted and
recreated per EFI run), claim side from `journalctl -t cmp90hx-claim -b`;
empty = pre-feature boot.

**Gates (offline — llm2 down).** efi-unlock/tools/reset-canary-selftest.sh
65 PASS / 0 FAIL: (1) C extraction harness (VERBATIM block + define
name-closure, offsets/magics drift-asserted) over the full matrix —
dead/dead→power-cycle, dead/alive→flr-sbr, alive/dead→relock-suspect
(+SS-partial variants), alive/alive→no-event, third-value→rewritten,
0xffffffff & 0xBADF5040→unreadable, gate-invariance proof, classify
zero-writes proof, arm-writes-EFI-slot-only + readback ok/FAILED
fixtures; (2) bash harness sourcing the claim block VERBATIM with
stubs (same matrix, verdict strings byte-for-byte, arm slot
discipline, COMMAND-unreadable degradation); (2b) collect block
fixture run (composition, stale-log quarantine, last-line-wins, EMPTY
pre-feature); (3) call-site structure assertions on all three live
files (arm exactly twice, both success-gated; ALREADY/PARTIAL/refusal
paths reach no arm; [2a] before any write; per-actor slot ownership;
CSV column appended not reordered); (4) bash -n on both scripts +
itself. bash -n clean; check_braces identical to HEAD; container build
ubuntu:24.04 gcc-13.3: NEW vs git-HEAD baseline both BUILD_OK with the
same single pre-existing `ld .note.GNU-stack` warning — zero new
(diff = expected +1984-byte EFI size only). Three existing harnesses
stay green (preflight, fwsec-gate, staging-ladder).

**Pending boot proofs (llm2 batch, awaiting host).** warm reboot keeps
canary + power cycle clears it (two findings.md rows with observed
values); [CANARY] line on ESP log; claim journal line; claim arm
readback on the 90HX (first field test of the transient COMMAND
re-enable); collect column fill.

