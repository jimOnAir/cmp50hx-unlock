# CMP 50HX on driver 615.78.08 — the 2026-11-01 investigation (closed: stay on 610)

**Status:** CLOSED with both mechanisms falsified. Production on all fleet
hosts stays **610.43.03 + in-driver unlock** (this deb). Nothing here
changes the shipped product; the 615 experiment lived in `.scratch/`
(gitignored) and is summarized durably below.

Audience: whoever asks in 2027 "can we move to 615 (or 620, or 700)?" — this
document is the playbook of what breaks and how to re-derive it cheaply.

## TL;DR decision table (measured on llm2, 2026-11-01, TU102 CMP 50HX ×2)

| 615 mode | Compute | Gen2 link | Issue rate | Verdict |
|---|---|---|---|---|
| **610.43.03 + in-driver unlock** | ✓ | ✓ | full ×3 | **production** |
| 615 + in-kernel unlock (H2 ROP port) | ✗ | ✗ | — | **closed** — 615 gate rejects non-stock frame *shape* pre-parse (§in-kernel) |
| 615 + pre-OS EFI unlocker (compute only) | ✓ *survives stock boot* | ✗ | **asymmetric** (one card 1/32) | interim at best, not production (§pre-OS) |

## The in-kernel closure, in one paragraph

Our 610 unlock is a bounded overflow in the signed SEC2 *booter* verifier:
we hand it a crafted 0xFA00-byte signature descriptor (610 accepted it;
the tail pivots into ROP gadgets that open FECS PLM/SS0/SS1 and the XP3G
PCIe gate). On 615 the booter (`BooterLoadUcode`, recompiled: TU102 blob
`0xe700 e0f0fc93` → `0xe900 38fc45e4`) rejects **every** crafted frame with
a bit-identical `error 0x1c @ tracepc 0x1b38` regardless of contents:
descriptor statics (V1), the verifier's spilled task state (V2), and even
the card's **own genuine 615 signature records** copied verbatim over the
frame head (V4a/V4b, `n=4096` overlay proven at runtime) all fail
identically. The discriminating experiment (V7, boot `14c52ec0`): a
byte-exact **stock-size** (0x1000) genuine frame sent through *our own*
fresh-metadata re-run path **passes** (`status=0x0`, halt `0x7de4`) while a
crafted frame fails on the other card in the same boot. Conclusion: the
615 check keys on the frame **shape** (advertised `sizeOfSignature` beyond
stock, or the tail region it implies) **before parsing**, and since a
useful ROP tail must land at DMEM `0xff0c` (buffer ≥ 0xF9D8), **no crafted
frame of any content can pass** — the primitive is closed on 615 TU102.
The path (provenance, second-launch) is innocent: re-running stock-shape
frames works fine.

## The pre-OS (EFI) probe, in one paragraph

The ESP unlocker (`efi-unlock/unlock50x_v1.c`, shipped as UEFI apps) drives
its own **610-era, FWSEC-accepted** booter blob — so 615's hardened-driver
gate does not apply, and the compute unlock (FECS PLM/SS0/SS1) demonstrably
**survives the whole 615 stock GSP boot** (BAR0-verified in-OS: `SS0=0x88888888`,
`SS1=0x8`, boot `ff1b2315`). Extending it to write the XP3G PCIe gate the
in-kernel path needs failed at the mechanism level: the unlock's own FWSEC
commit kills the only privileged channel — a second `booter_load_v67` run
resets cleanly but the RISC-V fetch block is dead (trace `rdidx=0`, all
`pc=0`, `EFI 0x12`), so extra writes must ride the **single** unlock run,
which requires chain surgery inside an opaque prebuilt payload (every
guess = one physical bench boot; budget exhausted, not attempted).
Independent negative: on the same boot the IMLA0 issue-rate came up
asymmetric (`01:00.0` 1/32, `04:00.0` full) — the in-kernel stage's
feature/issue-rate policy never runs in EFI-only mode, so even a
successful Gen2 write would not yield a production-grade card.

## Re-derive checklist for the NEXT driver bump (the class recurs)

The 610→615 breakage was invisible to normal porting (source applied
cleanly; userland fine; failure was *inside signed firmware*). On every
driver version jump that touches GSP/SEC2, before wasting bench time:

1. **Booter blob diff**: extract `BooterLoadUcode` from both driver versions
   (`nvidia.ko` bindata or the `.manifest`/sec2 blobs); if bytes/size
   changed (615: +0x200 app region), assume the verifier was recompiled and
   the overflow may be gone. Quick check: does a stock booter-load succeed
   while every crafted frame dies at ONE fixed `tracepc`?
2. **Frame-shape gate first, contents later**: cheapest discriminator is
   the *stock-shape control* (genuine records, stock advertised size,
   through our path). Run it BEFORE any content-class experiments — V1/V2/V4
   each cost a physical boot and only V7 (the shape control) actually
   partitioned the hypothesis space. Design boot #1 accordingly.
3. **Manifest/task geometry** moves every bump (`task_init`/`task_rm`
   `stack_top`/`entry_pc` are the 8-byte manifest diffs; rm text/data
   geometry lives OUTSIDE the manifest, in page-table images). Spilled
   verifier slots ≠ manifest fields; do not trust either across versions.
   The crafted-frame offset map (buffer↔DMEM `+0x600`) is in
   `.scratch/615-gen2-h2/research/manifest-tlv-dmem.md` (gitignored;
   regenerate per bump from the new booter).
4. **WPR handoff down-extension**: 615 FWSEC hands off WPR2 lo 0x80000
   below its capture (`0x27fe000→0x277e000`); equality guards written for
   610 misfire — check `g_cmp50StockWprLo` consumers (patch 12 gated the
   tolerance).
5. **Bench protocol invariants** (why every failure stayed recoverable):
   auto-rollback deb preserved + `rollback-610.sh` armed for every
   experiment boot; cold cycles only (failed booter attempts burn FWSEC
   latches — off ≥30 s cures); ESP log freshness is the boot script's
   unlock verdict (stale logs = protective skip, which correctly caught a
   harness bug twice); verify `BootNext` is **deleted** (`efibootmgr -n
   ffff`), never "set to 0000", when you want the U-chain to run; `pgrep
   dpkg --configure` empty before any shutdown; same-version `apt install`
   after a DKMS pre-remove = **reinstall** or the module is simply absent.
6. **Counters and kill rules are load-bearing**: six physical boots total,
   each designed as a binary discriminator with a pre-registered reading
   rule; no-op/harness boots were recorded as no-ops (owner ruling), so the
   falsifications stayed honest and the negative is *attributed*, not
   statistical.

## Rejected routes (do not re-litigate without new information)

- In-kernel crafted-frame ROP on 615 (any content: statics, spilled state,
  genuine records, header lengths) — falsified above, mechanism-attributed.
- GA102/90HX face on 615 via the same technique — inherits the closed gate
  (same hardened booter family); its desk verdict already carried the
  auto-shrink rule (`research/90hx-gen2-verdict.md`, gitignored).
- ESP booter *re-run* as an extra-write channel — dead after FWSEC commit
  (fetch block locked; measured `ff1b2315`).
- Size-sweep probes for a tolerant overflow length on 615 — cap (if any)
  lies in (0x1000, 0xF9D7], no useful tail reachable below 0xF9D8; cannot
  finish in budget and would yield no exploit even if a cap were found.

## Productization (out of scope, named for completeness)

A hypothetical 615-supporting deb rev (dual-610/615 pinning, fleet rollout
notes) is NOT built and NOT recommended by this investigation; the interim
EFI-only-615 mode works for compute but is documented above as not
production-grade (issue-rate asymmetry, Gen2 gap). 610 remains the
pinned, unlocked, serving configuration (see README "Fresh performance
results" for the parity baseline).

## Evidence index (paths relative to repo root; `.scratch/*` gitignored —
copy from the bench host before cleanup if needed again)

| Artifact | Where |
|---|---|
| Wayfinder map (decisions, kill rule, fog) | `.scratch/615-gen2-h2/map.md` |
| Tickets 01–14 (questions, answers, reading rules) | `.scratch/615-gen2-h2/issues/` |
| Boot verdicts + dmesg (per boot id) | `.scratch/615-gen2-h2/logs/` |
| Key boots | `593de4d4` V1/V2 falsify · `c41283fb` V4 genuine-records falsify · `14c52ec0` **V7 shape gate PASSED** · `ff1b2315` compute-survives + re-run-dead |
| Experiment debs | `615.78.08-0.615rc4.framematrix` `f0fe6b7e…` · `rc5.recordtrust` `728bb028…` · `rc7.v7live` sha in kit |
| Frame machinery patches (committed) | `patches/both/12-…`, `13-…`, `14-…` (all inert without per-BDF `RmCmpFrameVariant` keys) |
| ESP experiment modules | `.scratch/615-gen2-h2/kit/50HXU1b/U4b.EFI` (`ca67b051…`/`5d72b073…`); production ESP pair restored `492978ad…`/`9d063186…` |
| Bench kit + runners | `.scratch/615-gen2-h2/kit/` (checksums), llm2 `/root/615-port/kit/` |

Commits: `f04ed34` (booter-correction narrative), `328a199` (patch 12),
`43f35f0`/`3a9861e` (patch 13/14), `7694c14` (xp3g ESP phase) — local
only; `origin` is the third-party upstream and was never pushed.
