# Success recipe — VERIFIED unlock methods only (CMP 90HX @ llm2)

**Status: ACTIVE — 1 attributable landed write.** W2 diagnostic window
(2026-10-31, boot `da354d66-dce9-44c2-ba0f-c20c5840a9cf`) landed
`0x823800 = 0xffffffff` with strict persistence (post-FLR + post-production
bind). This file is the canonical, reproduction-grade log of unlock methods
that are **proven on real hardware** — fleet rollout, cold-boot re-apply
logic, and any upstream result-note all derive from it. Populated during the
same work cycle as each success; rules in ticket 11 (`Success logging`).

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

*Filled from W0 probe (boot `49066f2d-ce5a-4e58-95cf-db6a17714766`), full
record `pre-driver-probe-w0.md`. Confirmed sufficient by the W2 success
boot (§2).*

| Item | Required value | Evidence |
|---|---|---|
| Secure Boot state | disabled (Setup Mode) | W0.1 `mokutil --sb-state` |
| iommu mode / group types | `iommu=pt`; card+bridge groups `identity` | W0.1 `/proc/cmdline` |
| FLReset present on 03:00.0 | **yes** (DevCap FLReset+) | W0.1 `lspci -vv` |
| Card bound-to at claim time | unbound through initramfs (cmdline blacklist; `cmp50hx-boot` binds only at multi-user) | W0.1 journal 10:01:47 |
| Driver context | pre-driver, initramfs `local-top`, module loaded `targets=… resume=0` | W2 success (2) |
| PROM/FWSEC availability | BAR0 `+0x300000` PROM window: FWSEC **v3, engine_mask 0x400**, ucode 9 (PCI ROM BAR irrelevant — zeroed by firmware); Zagitta resolves it | W0.3 `tools/parse-prom-fwsec.py`; W2 `stage=fwsec version=3` |
| FEAT bootstrap state at boot | `0x823804 = 0xffffffff` OPEN (production canary opens it every boot) | W0.4 BAR0 read |
| Speed-path baseline | CYA_0 `0x8c2c0` bit2 DIS_G2=**1**; masks `…8f`/`…cf` locked bits present | W0.4 BAR0 read |
| Assets staged pre-arm | `gsp_ga10x.bin`, `gsp_boot_desc_ga102.bin`, `gsp_boot_ga102.bin`, `booter_load_ga102.bin` (610.43.03) readable by the initramfs hook | W1/§3 step 1 |

## 2. Landed writes (successes only)

One row per `landed=true` line in `success.jsonl`:

| # | ts | boot_id | window | context | addr | value | readback | survived |
|---|---|---|---|---|---|---|---|---|
| 1 | 2026-10-31T10:40:05Z | `da354d66` | W2 | pre-driver initramfs | `0x00823800` | `0xffffffff` | `0xffffffff` (in-boot `after=` + production runtime read) | FLR ✓ · production nvidia bind ✓ (jsonl line 6: `landed=true`, `checkpoint_attributable=true`) |
| 2 | 2026-10-31T10:40:05Z | `da354d66` | W2 | pre-driver initramfs | `0x00823804` (FEAT) | `0xffffffff` | `0xffffffff` | FLR ✓ · production bind ✓ — **non-attributable**: production canary opens FEAT every boot (W0.4), so the write is a no-op-safe idempotent opener, not independent proof |
| 3 | 2026-10-31T11:04:28Z | `6b8b83b1` | W3a | pre-driver initramfs (full-table launch #1) | `0x00088ff4` (XVE_PLM) | `0xffffffff` | `0xffffffff` | FLR ✓ · production bind ✓ — first attributable non-opener landing (rows initially tagged `W2`, relabeled from state; fixed in harness) |
| 4 | 2026-10-31T11:49:46Z | `18d94504` | W3b | pre-driver initramfs (ladder cycle 1, `gu_window=0:6`) | `0x00088fe8` | `0xffffffff` | `0xffffffff` | FLR ✓ · production bind ✓ |
| 5 | 2026-10-31T11:49:46Z | `18d94504` | W3b | same launch | `0x00088fec` | `0xffffffff` | `0xffffffff` | FLR ✓ · production bind ✓ |
| 6 | 2026-10-31T11:49:46Z | `18d94504` | W3b | same launch | `0x00088ff0` | `0xffffffff` | `0xffffffff` | FLR ✓ · production bind ✓ |
| 7 | 2026-10-31T11:49:46Z | `18d94504` | W3b | same launch | `0x00088ff4` | `0xffffffff` | `0xffffffff` | second independent confirmation of row 3 |
| 8–12 | 2026-10-31T12:04:22Z | `cdee788d` | W3c | ladder cycle 1 (`0:6`) | `0x823804`, `0x88fe8`, `0x88fec`, `0x88ff0`, `0x88ff4` | `0xffffffff` ×5 | `0xffffffff` ×5 | FLR ✓ · production bind ✓ — same set as rows 3–7: cycle-1 landing reproduced **identically** on independent boot (ladder determinism) |
| 13–17 | 2026-10-31T12:42:48Z | `50c2df42` | W3d | ladder cycle 1 (`0:6`) | same five addresses | `0xffffffff` ×5 | `0xffffffff` ×5 | FLR ✓ · production bind ✓ — third identical reproduction; W3d added certified C-side pacing (`CWAIT-PROBE delta=2s [up=4s]`) |
| 18–22 | 2026-10-31T12:56:03Z | `c211e3a9` | W3e | ladder cycle 1 (`0:6`) | same five addresses | `0xffffffff` ×5 | `0xffffffff` ×5 | FLR ✓ · production bind ✓ — fourth identical reproduction; gate finding: `en_rc=0` (MEM enable proven; chip reading later exposed as accessor artifact, §3) |
| 23–27 | 2026-10-31T13:21:53Z | `38a6664d` | W3f | ladder cycle 1 (`0:6`) | same five addresses | `0xffffffff` ×5 | `0xffffffff` ×5 | FLR ✓ · production bind ✓ — fifth identical reproduction; window finding: BARs survive FLR, pread accessor exposed (§3) |
| 28–32 | 2026-10-31T13:31:04Z | `f60bf796` | W3g | ladder cycle 1 (`0:6`) | same five addresses | `0xffffffff` ×5 | `0xffffffff` ×5 | FLR ✓ · production bind ✓ — sixth identical reproduction; window finding: healthy device still refuses re-claim (§3 law) |
| 33–37 | 2026-10-31T14:05:23Z | `41ebb379` | W3h | user-ladder cycle 1 (`0:6`, jdowning-shape reload interleave) | same five addresses | `0xffffffff` ×5 | `0xffffffff` ×5 | FLR ✓ · production bind ✓ — seventh identical reproduction; window finding: full driver init between loads STILL refuses re-claim (§3 law final); both 50HXes paid the warm-reload GSP cost (§3 known-bad), power-cycle pending |

Supporting (write verified in-boot, `landed=false` per §0 — re-locked at
production init **by design**, documented upstream behavior, kept for
completeness): `0x001fa7cc` (WPR_CFG) `→0xfffff0ff`, in-boot readback exact,
survived FLR (`stage=flr … plm_wpr_cfg=0xfffff0ff`), then re-locked to
`0x0004cb8f` when the production driver initialized — expected every boot.

Evidence files (tracked): `evidence/w2-success.jsonl` (6 lines: 3 ×
`status=absent` from harness-bug attempt `0cdbe414`, 3 × `ok` from
`da354d66`), `evidence/w2-journal-da354d66.txt` (raw journal incl. all three
`pass=…/3 … ret=0` lines and `stage=flr`/`stage=handoff`),
`evidence/w2-journal-0cdbe414-abort.txt`, `evidence/w3a-success.jsonl` +
`evidence/w3a-journal-6b8b83b1.txt` (W3a: launch #1 6/6, launch #2 timeout
— the multi-launch law measurement), `evidence/w3b-success.jsonl` +
`evidence/w3b-journal-18d94504.txt` (W3b: cycle 1 full success incl. four
XVE landings; cycles 2–9 refused at gfw `-114` — the readiness-law
measurement), `evidence/w3c-success.jsonl` + `evidence/w3c-journal-cdee788d.txt`
(W3c: cycle-1 reproduction; poll-loop pacing bug exposed via
short-monotonic stamps), `evidence/w3d-success.jsonl` +
`evidence/w3d-journal-50c2df42.txt` + `evidence/w3d-mono-50c2df42.txt`
(W3d: certified 45 s wait + `chip=… cfg_vendor=0x220d10de` — MEM-decode
lead, later corrected in §3: the chip value was an accessor artifact),
`evidence/w3e-success.jsonl` + `evidence/w3e-journal-c211e3a9.txt` +
`evidence/w3e-mono-c211e3a9.txt`
(W3e: `en_rc=0` — MEM enable itself works; read path still blind).
`evidence/w3f-success.jsonl` + `evidence/w3f-journal-38a6664d.txt` +
`evidence/w3f-mono-38a6664d.txt`
(W3f: BARs bit-exact post-FLR; honest accessor prints `err` — pread
masked-failure discovery), `evidence/w3g-success.jsonl` +
`evidence/w3g-journal-f60bf796.txt` + `evidence/w3g-mono-f60bf796.txt`
(W3g: mmap accessor truth — healthy from t0, re-claim still `-114`),
`evidence/w3h-success.jsonl` + `evidence/w3h-journal-41ebb379.txt` +
`evidence/w3h-mono-41ebb379.txt`
(W3h: jdowning-shape full driver-reload interleave — re-claim STILL
refused; #5a and #6 both closed by measurement; warm-reload GSP cost
documented).

## 3. Exact procedure

Reproduces the W2 diagnostic frame (the *speed* ladder is W3 — §5). Geometry
from code (`work/zagitta-port` `unlock_610.c run_privileged_writes`),
timings from the success journal (whole claim ~1 s, 10:39:07→:08).

1. **Build** (pinned, §8): Zagitta fork `7eb51bcc` + port series
   `patches/zagitta-gpu-unlock/000{1,2}-*.patch`, DIAG variant:
   `make -C kernel KCFLAGS='-DCONFIG_DRM_GPU_UNLOCK -DGU_DRIVER_VERSION="610.43.03" -DGU_CMP90HX_DIAG'`
   → `gpu_unlock.ko` (md5 `c237dd5f0ce953b92a6cdd65225376e4`). The diag
   table is exactly the 3-entry frame
   **[0x1fa7cc=0xfffff0ff, 0x823804=0xffffffff, 0x823800=0xffffffff]** in
   that order: WPR_CFG first is required by the executor (its own
   `ga10x_plm` opener), and FEAT must precede `0x823800` (PLM law). 3
   entries ≤ 6-slot DMA frame ⇒ **exactly one launch**.
   *Measured law (final form; W3a `6b8b83b1`, W3b `18d94504`, W3g
   `f60bf796`, W3h `41ebb379`):* **the standalone-ko V67 chain fires
   exactly once per boot on this host — the first claim after firmware
   init.** A second SEC2 launch inside one load times out
   (`completion error=-110`, `fhstate=0xfff8 csberr=0x400000`). Re-claim in
   a later load is refused (`gfw error=-114`) **no matter what happens
   between the loads**: pure waiting with a chip-id-healthy device
   (W3g: `ready after 5s chip_seq[t0=0xb72000a1]` yet `ret=-114` ×2) AND a
   full nvidia stack load + serialized GSP-RM init + unload + verified
   SS0/SS1 re-lock (W3h: `device ready after 6s/11s chip=0xb72000a1
   relock=verified` yet `ret=-114` ×2). The W3g-era inference "driver
   boot handshake re-arms the GFW" is hereby MEASURED FALSE for the
   standalone ko. jdowning's 34/34 bench reloads ride a different
   mechanism: the payload is consumed by FWSEC **inside the patched
   driver's own canary path on each load** (spec file
   `/var/lib/cmpunlocker-rs/rejoin16-next-write.bin`), not by a
   standalone-ko launch — and llm2's own windows v2–v5 census had already
   found reloads never produce crafted-healthy here (one success only
   early in a fresh boot, which is exactly cycle-1's behavior). Multi-
   target on llm2 therefore requires the driver-embedded one-crafted-write-
   per-boot ladder lineage (`90hx-boot-ladder.service`), not ko reloads.
   Ladders of any kind therefore get one claim-load per ≤4 targets
   (+2 auto-reopened openers, port patch 0003 `gu_window`); the
   initramfs reload-ladder (#5a) AND its userspace driver-interleave
   variant (#6/W3h) are both closed by measurement.

   *Known-bad (W3h cost, honest ledger):* warm-reloading the nvidia stack
   while the driver's **serialized** `nv_start_device` init is still in
   flight for other GPUs orphans their GSP boots — both CMP 50HXes then
   failed `RmInitAdapter: Cannot initialize GSP firmware RM`
   (`0x62:0x40:2119`, ×16 each) for the whole boot, recoverable only by
   cold reset. Any future reload-based procedure on this host MUST gate
   on **all three GPUs enumerated** before unloading, and treat this
   class as a capacity-costly operation.
   *Instrument caveat (W3d→W3g, resolved):* a pre-claim chip-id poll via
   the module-style path is **structurally blind** twice over — (a) FLR
   clears `COMMAND.MEM` (bit 1 of config 0x4), so decode must be
   re-enabled first (`ss-relock en`: dword 0x4 |= 0x2, in-binary; W3e
   `en_rc=0`); (b) on kernel 7.0.0-38 sysfs **`pread`** of `resource0`
   returns EIO even on a healthy bound card, and old `wait-rd` printed its
   zero-init after a failed pread — the W3d/W3e `chip=0x00000000` were
   masked failures, not device values. Truthful accessor = maskread's
   16 MiB `mmap` (`ss-relock` v4, `ERR_OPEN`/`ERR_MMAP` on failure, never
   a fabricated value). With v4, **W3g `f60bf796` saw the device
   chip-id-healthy from t0, BARs bit-exact, config alive** — so there is
   no observable "death timeline"; the refusal (`-114`) is purely the
   GFW needing driver init, per the §3 law above. FLR clears COMMAND.MEM
   but does NOT clear device-side BARs (W3f: `BAR0=0xf9000000` bit-exact).
2. **Stage** on target: ko → `/root/zagitta-port/gpu_unlock_diag.ko`; the 4
   ga102-suffix assets (§1) under `/root/.cache/gpu-unlock/assets/610.43.03/`.
3. **Arm** (`l2-w2.sh arm`, deployed `/root/l2-w2/`): install initramfs
   hook + `local-top/gpu-unlock-w2`; `update-initramfs` bakes ko + 4 assets;
   clone the real menu entry into `/etc/grub.d/40_custom` appending cmdline
   flag `cmp90hx_w2=1` (deliberately not `gpu_unlock.*` — unknown
   module-prefixed params would go to the module parser); `grub-editenv
   set next_entry=…` (one-shot; default entry untouched); write `state`
   (md5s, boot_id).
4. **Reboot (warm)**. On the armed boot only, `local-top` fires: guard
   `[ -L /sys/bus/pci/devices/0000:03:00.0/driver ]` must show *unbound*
   (NOT `readlink -f` — it prints paths for absent links, see Gotchas in
   ticket 11), then `insmod gpu_unlock.ko targets=0000:03:00.0 resume=0`.
   Executor pipeline runs: claim → fwsec (PROM via BAR0 `+0x300000`) → gfw
   → publish → privileged launch (per-entry `pass=N/M … after=` log) →
   host CPU writes SS0=`0x88888888`/SS1=`0x8` → function-level reset →
   handoff `ret=0`.
5. **Verify**: production boots normally (`cmp50hx-boot` binds nvidia at
   multi-user); `l2-w2.sh check` → post-boot BAR0 reads + LnkSta + health,
   parses journal slice, appends `success.jsonl` (idempotent per boot_id),
   prints verdict.
6. **Pull** evidence off-host (`l2-w2.sh pull`), then **disarm** (remove
   hook/local-top, `update-initramfs`, delete custom entry, clear env) and
   verify clean state. Never leave armed.

## 4. Verification commands + expected outputs

```
# all on llm2, post-window:
boot flag seen      grep cmp90hx_w2=1 /proc/cmdline
chain fired         sudo journalctl -k -b <id> | grep 'gpu_unlock: pass='
                    -> 3 lines "pass=1/3|2/3|3/3 … ret=0", after= matching value
FLR survival        sudo journalctl -k -b <id> | grep 'stage=flr'
                    -> "… plm=0xffffffff …"   (FEAT mask survived reset)
handoff             grep 'stage=handoff'  -> "ret=0 state=4 retained=0"
                    + line "gpu_unlock: unlocked"
landed readback     sudo python3 /root/l2-w2/maskread.py 0000:03:00.0 0x823800
                    -> 0xffffffff             (in production runtime)
speed (NOT expected to change with diag frame):
                    sudo lspci -vv -s 0000:03:00.0 | grep LnkSta
                    -> "Speed 2.5GT/s, Width x4"  (retrain is W3's job)
serving             curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/health -> 200
disarmed            sudo grep -c CMP90HX /boot/grub/grub.cfg -> 0
                    sudo lsinitramfs /boot/initrd.img-$(uname -r) | grep -c gpu_unlock -> 0
```

Observed exactly so on boot `da354d66…` (2026-10-31 10:39–10:42 UTC) —
`evidence/w2-journal-da354d66.txt` is the raw transcript.

## 5. Boundary — what the method does NOT do

- Does **not** change link speed: diag frame lands the FEAT-adjacent mask
  opener only; LnkSta stayed 2.5 GT/s x4 during and after the success boot
  (observed). The Gen2 ladder (XVE×6 + XP3G×17 + OPTB×10 + `0x823b04`) is
  W3, untested.
- Context for W3 expectations (observed, `da354d66` dmesg): the production
  campaign driver already attempts a Gen2 retrain at every init
  (`CMP90 Gen2: retrain completed without Gen2 link status=0x1041`) — it
  fails only because the masks are locked at that point. If W3 lands the
  ladder pre-driver, production init itself may complete the negotiation;
  check `LnkSta` before using the manual retrain lever.
- Does **not** claim power-off persistence (untested; cold boot expected to
  reset — §6).
- Warm-reboot persistence of `0x823800` is **not yet proven** — only
  same-boot checkpoints (FLR + production bind). Observation method: on the
  first NORMAL (unflagged) warm reboot, read
  `sudo python3 /root/l2-w2/maskread.py 0000:03:00.0 0x823804 0x823800`
  before any experiment code runs (initramfs pre-reads are infeasible:
  executor `before=` values are selector-page garbage, and /dev/mem→ECAM
  is silently unreliable — see ticket 11 gotchas).
- The write does not make runtime userspace BAR0 pokes safe or necessary;
  do not add runtime pokers (ticket 11 prohibition stands).
- OPTB/XVE/XP3G untouched by this frame; upstream note that OPTB re-locks
  per init is unreproduced here (no OPTB write attempted).
- `10de:220d` is rewired from `GA102()` in the port — 0x220d also names the
  RTX 3090; these builds are experiment-only, never fleet builds.

## 6. Persistence matrix

| Event | Masks held? | Speed held? | Evidence |
|---|---|---|---|
| module reload (FLR) | `0x823800` ✓ (`0x823804` ✓; WPR_CFG re-locked by design) | n/a — Gen1 before/after | W2 `stage=flr` line + production reads (`da354d66`) |
| production driver bind | `0x823800` ✓ | Gen1 (never raised) | W2 jsonl line 6 checkpoint |
| warm reboot | TBD — read via `maskread.py` on first unflagged boot | TBD | plan: W3 disarm reboot |
| cold boot (power cycle) | TBD | TBD | — |
| runtime D3 round-trip | TBD | TBD | — |

## 7. Rollback

- **Unplug/reboot-to-stock is unnecessary**: the armed state is one-shot by
  construction (next_entry consumed; local-top inert without the cmdline
  flag). Post-disarm the machine carries zero experiment state — verified
  2026-10-31: hook/script gone, initrd md5 `216312a6…` (no ko inside),
  grub entry 0, `next_entry=` empty, module not loaded, health 200.
- If a future normal boot ever misbehaves: power cycle (restores BAR0 masks
  to stock), then `sudo apt reinstall` of the nvidia driver package is
  *not* needed — driver was never touched.
- Staged artifacts to delete if abandoning the experiment: `/root/l2-w2/`,
  `/root/zagitta-port/`, `/etc/grub.d/40_custom` W2 block, the
  `/boot/initrd.img-*` (rebuild via `update-initramfs -u`), `/root/l2/`.
  `success.jsonl` copies live in this repo (`evidence/`) and scratch
  `l2/w2-out/`.

## 8. Version pins

| Component | Value | Provenance |
|---|---|---|
| card VBIOS | 94.02.74.00.01 | ticket 01 |
| kernel | 7.0.0-38-generic (Ubuntu 26.04, uutils coreutils) | `uname -r` |
| unlock module srcversion | `C46DB4B43EEECB86EE15E91` (both variants) | W1 build |
| diag ko md5 | `c237dd5f0ce953b92a6cdd65225376e4` | `l2-w2.sh state` |
| full ko md5 (W3, unused so far) | `02ccc795cee548f90ea5e009b8624f6b` | `l2-w2.sh state` |
| Zagitta base + port | upstream `7eb51bcc` + series `patches/zagitta-gpu-unlock/000{1,2}` (`-DGU_CMP90HX_DIAG`) | commit `140d000` |
| production driver | campaign build 610.43.03 (`cmp50hx-boot` binds at multi-user) | pre-existing |
| repo commit under test | `140d000` + working docs | local-only, never pushed |

## Appendix A — `success.jsonl` schema

Location on host: `/root/l2/success.jsonl` (created by `l2-w2.sh`; the
contingency #6 wrapper appends to the same file). Copies: scratch mirror
`/tmp/90hx-gen2-p2p-scratch/` + repo `docs/cmp90hx/evidence/`. One JSON
object per privileged-write **attempt** (failures included; the record is
self-contained):

```json
{"ts":"2026-10-31T10:40:05Z","boot_id":"…","window":"W2|W3|#6",
 "context":"pre-driver-initramfs|kernel|cpu-poke","bdf":"0000:03:00.0",
 "addr":"0x00823804","value":"0xffffffff","readback":"0x…",
 "status":"ok|absent|readback-mismatch|…","landed":true,
 "lnksta_speed":"2.5|5","lnksta_width":"x4",
 "wpr2_health":"ok|…","module_srcversion":"…","cmdline_targets":"…",
 "checkpoint_readback":"0x…","checkpoint_kind":"post-flr-post-production-bind",
 "checkpoint_attributable":true}
```

`landed` is set by the harness per §0 rules (readback match + checkpoint
survival), never manually. `checkpoint_attributable=false` marks writes
whose survival is indistinguishable from platform baseline (FEAT canary).
