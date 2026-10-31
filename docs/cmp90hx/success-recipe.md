# Success recipe — VERIFIED unlock methods only (CMP 90HX @ llm2)

**Status: EMPTY.** No method has landed a privileged write on llm2 yet
(run-#2 record 0/49, window #10 last attempt). This file is the canonical,
reproduction-grade log of unlock methods that are **proven on real
hardware** — fleet rollout, cold-boot re-apply logic, and any upstream
result-note all derive from it. Populated during the same work cycle as
each success; rules in ticket 11 (`Success logging`).

## 0. Evidence rules

- Only VERIFIED steps live here. Anything inferred, expected, or copied
  from upstream docs goes to §5 or the analysis docs, never §2/§3.
- A write counts as **landed** only if readback == value AND it survived
  the next checkpoint (post-FLR; post-driver-bind; post-reboot when a
  persistence claim is made). Otherwise it is `unverified`.
- Every claim cites its evidence: `boot_id` + line in `success.jsonl`
  (schema in Appendix A). No evidence reference ⇒ not a success entry.
- `success.jsonl` is copied off-host at the end of every window BEFORE
  fleet restore; repo-cache copies are append-merged, never overwritten.

## 1. Preconditions (state required before running the method)

*To be filled from W0 probe + first successful window (W2/#6).*

| Item | Required value | Evidence |
|---|---|---|
| Secure Boot state | | W0 |
| iommu mode / group types | | W0 |
| FLReset present on 03:00.0 | | W0 |
| Card bound-to at claim time | (unbound / pci-stub) | |
| Driver context | (pre-driver initramfs / in-driver) | |

## 2. Landed writes (successes only)

One row per `landed=true` line in `success.jsonl`:

| # | ts | boot_id | window | context | addr | value | readback | survived |
|---|---|---|---|---|---|---|---|---|

## 3. Exact procedure

*Reproducible step list, in order — geometry (frames/launches, ordering
constraints like FEAT-first), timings, command lines. Written from the
journ + success.jsonl, then re-checked against a later reproduction boot.*

## 4. Verification commands + expected outputs

```
# e.g.
LnkSta:  (lspci -vv -s 0000:03:00.0 | grep LnkSta)      -> Speed 5GT/s, Width x4
readback: (bar0 read of each §2 addr)                   -> 0xffffffff
serving:  (curl -s -o /dev/null -w '%{http_code}' <health>) -> 200
```

## 5. Boundary — what the method does NOT do

*Known non-goals and unfought walls (e.g. does not survive power-off;
does not make userspace speed writes safe; OPTB re-lock behavior…).
Upstream-copied expectations live here until locally reproduced.*

## 6. Persistence matrix

| Event | Masks held? | Speed held? | Evidence |
|---|---|---|---|
| module reload (FLR) | | | |
| warm reboot | | | |
| cold boot (power cycle) | | | |
| runtime D3 round-trip | | | |

## 7. Rollback

*Exact steps to return to the known-good serving state if the method or a
future host/driver change breaks it (driver reinstall, cmdline revert,
power-cycle-to-stock).*

## 8. Version pins

| Component | Value | Provenance |
|---|---|---|
| card VBIOS | 94.02.74.00.01 | ticket 01 |
| kernel | 7.0.0-38 (Ubuntu 26.04) | |
| unlock module srcversion | | |
| driver build | (campaign 610.43.03 / Zagitta / jdowning candidate) | |
| repo commit under test | | local-only |

## Appendix A — `success.jsonl` schema

Location on host: `/root/l2/success.jsonl` (created by `l2-w2.sh`; the
contingency #6 wrapper appends to the same file). Copies: scratch mirror
`/tmp/90hx-gen2-p2p-scratch/` + repo `cache/`. One JSON object per
privileged-write **attempt** (failures included; the record is
self-contained):

```json
{"ts":"2026-11-XX…Z","boot_id":"…","window":"W2|W3|#6",
 "context":"pre-driver|initramfs|kernel|cpu-poke","bdf":"0000:03:00.0",
 "addr":"0x00823804","value":"0xffffffff","readback":"0x…",
 "status":"…","landed":true,
 "lnksta_speed":"2.5GT/s|5GT/s","lnksta_width":"x4",
 "wpr2_health":"ok|…","module_srcversion":"…","cmdline_targets":"…"}
```

`landed` is set by the harness per §0 rules (readback match + checkpoint
survival), never manually.
