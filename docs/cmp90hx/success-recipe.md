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

*Filled from W0 probe (2026-11-01, boot `49066f2d-ce5a-4e58-95cf-db6a17714766`),
full record `pre-driver-probe-w0.md`. These describe the llm2 platform as
probed — still no method has run (see §2).*

| Item | Required value | Evidence |
|---|---|---|
| Secure Boot state | disabled (Setup Mode) | W0.1 `mokutil --sb-state` |
| iommu mode / group types | `iommu=pt`; card+bridge groups `identity` | W0.1 `/proc/cmdline` |
| FLReset present on 03:00.0 | **yes** (DevCap FLReset+) | W0.1 `lspci -vv` |
| Card bound-to at claim time | unbound through initramfs (cmdline blacklist; `cmp50hx-boot` binds only at multi-user) | W0.1 journal 10:01:47 |
| Driver context | (pre-driver initramfs / in-driver) — TBD by first window | |
| PROM/FWSEC availability | BAR0 `+0x300000` PROM window: FWSEC **v3, engine_mask 0x400**, ucode 9 (PCI ROM BAR irrelevant — zeroed by firmware) | W0.3 `tools/parse-prom-fwsec.py` on md5 `ac0752e8…` |
| FEAT bootstrap state at boot | `0x823804 = 0xffffffff` OPEN (production canary opens it every boot) | W0.4 BAR0 read |
| Speed-path baseline | CYA_0 `0x8c2c0` bit2 DIS_G2=**1**; masks `…8f`/`…cf` locked bits present | W0.4 BAR0 read |

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
