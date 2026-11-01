# Success recipe — VERIFIED unlock methods only (CMP 90HX @ llm2)

> **FROZEN 2026-10-31 (615-port):** every address, canary and constant in this
> recipe is measured on driver **610.43.03** and is **invalid on 615** until
> re-baselined. The 90HX campaign is paused for the NVIDIA 615.78.08 port and
> llm2 cutover — see `.scratch/90hx-gen2-p2p/freeze-615-port.md` and
> `.scratch/615-port/spec.md`. Historical record below stays authoritative
> for 610.43.03 boots only.
>
> **UNFROZEN 2026-11-01:** the product pin is back on **610.43.03** (owner
> call; 615 closed "stay on 610"), and the campaign's speed-path question is
> answered — **Gen2-at-boot LANDED**, productized in `cmp50hx-unlock` rev
> `20261101.19+`. The 610-only constants rule above remains in force forever.

**Status: ACTIVE — canonical method: the pre-driver first claim lands a
5-write frame with strict persistence, reproduced 7/7 window boots.**
The Zagitta-port ko (`gpu_unlock_full.ko`, `gu_window=0:6`) claimed once
per boot BEFORE the production driver lands FEAT `0x823804` + XVE
`0x88fe8/8fec/8ff0/8ff4` = `0xffffffff`, surviving FLR and the production
driver bind — identically on seven consecutive boots (`18d94504` …
`41ebb379`, §2 rows 4–37). Measured boundaries: the standalone ko fires
exactly once per boot (§3 law — all reload routes closed), and warm reboot
resets the masks (§6), so the claim must run every boot. A link-speed change
was not claimed at freeze time (§5); **it is claimed now — see
Gen2-at-boot below.** This file is the canonical, reproduction-grade log of unlock methods
that are **proven on real hardware** — fleet rollout, cold-boot re-apply
logic, and any upstream result-note all derive from it. Populated during the
same work cycle as each success; rules in ticket 11 (`Success logging`).

## Gen2-at-boot — PRODUCT PATH (VERIFIED unattended 2026-11-01, deb rev `20261101.19`)

The §-body above is the compute-unlock recipe; this section is the canonical,
reproduction-grade record of the **PCIe Gen2** path that now ships in
`cmp50hx-unlock` on 610.43.03. Full acceptance matrix:
`.scratch/90hx-gen2-610/issues/06-product-integration.md` §Answer.

- **Mechanism (two halves, one deb).** (1) `cmp90hx-claim.service` insmods the
  sibling DKMS module `gpu-unlock-claim` once per boot **before** the nvidia
  bind, running the proven **6-entry gate-first table** (Wh1stle05 minimal-2
  `{0x823800, 0x88fe8}` plus openers; `0x823800` = config gate, table index 36
  — its absence is why pre-November "7/7" sets never trained Gen2). (2) the
  patched production module's speed path (series `0016` + retrain-retry `0019`)
  trains the link at device init: `LNKCTL2=2` both sides, `LnkSta 5.0 GT/s x4`.
- **Per-boot verification (3 reads).**
  `journalctl -b 0 -u cmp90hx-claim.service | grep gen2-claim` →
  `claim-ok 6/6 landed`; `journalctl -b 0 -u cmp50hx-boot.service | grep
  cmp90hx-gen2` → `landed 5.0 GT/s`; `setpci -s 03:00.0 CAP_EXP+12.w` → `1042`.
- **Verdict discipline (boots 1–2 lessons, 2026-11-01).** A rebooted card has
  memory-decode off: every BAR0 offset reads `0xffffffff` — **never**
  equate all-FF with "open"; trust a read only when `PMC_BOOT_0 (0x0) ==
  0xb72000a1` (constant-register control). Post-`insmod` re-reads are also
  untrustworthy (the ko restores the command register at handoff): the ko's
  own synchronous log (`pass=N/6 … ret=0` ×6 + `unlocked`) is the authoritative
  claim verdict, and post-bind sysfs is the authoritative link verdict.
- **Fail-closed + kill-switch.** If the claim doesn't land, the speed path
  skips at its privilege gate and the link stays Gen1 (boots never block,
  never retry across boots — ADR-0001). Ops: `GEN2_90HX=disabled` in
  `/etc/cmp50hx/boot.conf` → `gen2-claim: disabled` + digest `FALLBACK`,
  fleet otherwise untouched; debug: `touch /var/lib/cmpunlocker-rs/gen2-trace`
  → one `decl-readback:` dmesg line per boot (series `0020`).
- **Effect measure (this platform).** Host pinned-copy bandwidth is
  platform-capped ≈1.6/1.7 GB/s on ALL three cards regardless of link gen —
  use the serving pp-rate A/B instead (`-tb 32` layer-split, unique
  ~17k-token cold prompts): **Gen1 ≈3,450 → Gen2 ≈3,720 tok/s (+7.8%)**.

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
- **Stubbed-card reads are untrustworthy** (measured RF window): a BAR0
  mmap read on a pci-stub-bound card returns **all-FF for every offset**
  while the PCI command register has memory-decode off (`COMMAND=0100`,
  lspci shows Region 0 `[disabled]`) — indistinguishable from "every mask
  open". Check `setpci -s <bdf> COMMAND` bit 1 (or read post-driver-bind)
  before believing any value from a stubbed card. This artifact briefly
  produced a false "FEAT warm-persisted open" claim (RF boots
  `4c850625`/`8857dbe3` `rf-check` lines — void).

## 1. Preconditions (state required before running the method)

*Filled from W0 probe (boot `49066f2d-ce5a-4e58-95cf-db6a17714766`), full
record `pre-driver-probe-w0.md`. Confirmed sufficient by seven landing
window boots W3b–W3h (§2).*

| Item | Required value | Evidence |
|---|---|---|
| Secure Boot state | disabled (Setup Mode) | W0.1 `mokutil --sb-state` |
| iommu mode / group types | `iommu=pt`; card+bridge groups `identity` | W0.1 `/proc/cmdline` |
| FLReset present on 03:00.0 | **yes** (DevCap FLReset+) | W0.1 `lspci -vv` |
| Card bound-to at claim time | unbound through initramfs (cmdline blacklist; `cmp50hx-boot` binds only at multi-user) | W0.1 journal 10:01:47 |
| Driver context | pre-driver, initramfs `local-top`, module loaded `targets=… resume=0` | W2 success (2) |
| PROM/FWSEC availability | BAR0 `+0x300000` PROM window: FWSEC **v3, engine_mask 0x400**, ucode 9 (PCI ROM BAR irrelevant — zeroed by firmware); Zagitta resolves it | W0.3 `tools/parse-prom-fwsec.py`; W2 `stage=fwsec version=3` |
| FEAT state at production runtime | `0x823804 = 0xffffffff` OPEN **after** driver bind (production canary; the pre-driver claim-time value is locked `0x4cb8f` — §6 warm row) | W0.4 BAR0 read; `before=` lines §4 |
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
| 33–37 | 2026-10-31T14:05:23Z | `41ebb379` | W3h | user-ladder cycle 1 (`0:6`, jdowning-shape reload interleave) | same five addresses | `0xffffffff` ×5 | `0xffffffff` ×5 | FLR ✓ · production bind ✓ — seventh identical reproduction; window finding: full driver init between loads STILL refuses re-claim (§3 law final); both 50HXes paid the warm-reload GSP cost (§3 known-bad), power-cycle done 14:52 (`5b05bf0d`) — 3/3 recovered, §6 cold row |
| 38–42 | 2026-10-31T15:05:32Z | `6e35d708` | WD | route-D window, single-cycle ladder (`0:6`), no reload legs | same five addresses | `0xffffffff` ×5 | `0xffffffff` ×5 | FLR ✓ · production bind ✓ — **eighth** identical reproduction; window finding: RETRAIN=2 lever pulled live — card-side LNKCTL2 write NOT latched (`CAP_EXP+30=0001` after `0x0002`; RP holds `0002`), link stays Gen1, health 200 throughout (§5) |

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
documented), `evidence/wd-success.jsonl` + `evidence/wd-journal-6e35d708.txt` +
`evidence/wd-mono-6e35d708.txt`
(WD route-D: eighth identical landing + RETRAIN=2 lever live — card-side
LNKCTL2 write dropped with masks landed, Gen2 bound to deeper masks
and/or kernel-context method; §5).

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
   per-boot lineage (`90hx-boot-ladder.service`), not ko reloads — though
   note that lineage's OWN llm2 history (windows #6–#9, 2026-10-30, host
   `verdicts.tsv`) is NO-EFFECT ×4 on `0x88fe8` with the fleet-interference
   theory already killed by a solo run; those verdicts are trustworthy
   (kernel-side write lines + mmap grader). The driver-vehicle-vs-ko
   asymmetry on the same target is an open upstream question. Warm reboot
   resets all masks (§6), so cross-boot accumulation of landed targets is
   impossible and any full-ladder must fit one boot — arithmetically
   unreachable by the standalone ko (6-entry budget/boot).
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
                    -> 6 lines "pass=1/6..6/6 … ret=0"; every target line
                       before=0x4cb8f (locked at claim — proves per-boot
                       reset, §6), after=0xfffff0ff (0x1fa7cc) /
                       0xffffffff (the five landed masks)
FLR survival        sudo journalctl -k -b <id> | grep 'stage=flr'
                    -> "… plm=0xffffffff …"   (FEAT mask survived reset)
handoff             grep 'stage=handoff'  -> "ret=0 state=4 retained=0"
                    on cycle 1 (later reload cycles: ret=-114, §3 law)
landed readback     sudo python3 /root/l2-w2/maskread.py 0000:03:00.0 \
                        0x823804 0x88fe8 0x88fec 0x88ff0 0x88ff4
                    -> 0xffffffff x5           (in production runtime)
speed (NOT expected to change):
                    sudo lspci -vv -s 0000:03:00.0 | grep LnkSta
                    -> "Speed 2.5GT/s, Width x4"  (masks alone do not
                       retrain — measured false, §5)
serving             curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/health -> 200
disarmed            sudo grep -c cmp90hx_w2 /boot/grub/grub.cfg -> 0
                    sudo lsinitramfs /boot/initrd.img-$(uname -r) | grep -c gpu_unlock -> 0
                    sudo systemctl is-enabled 90hx-w3h-ladder.service -> not-found
                    sudo ls /lib/firmware/gpu-unlock -> No such file
```

Observed exactly so on every W3 window boot; canonical transcript
`evidence/w3h-journal-41ebb379.txt` + `evidence/w3h-mono-41ebb379.txt`
(seventh identical reproduction). W2-era single-write diag variant:
`evidence/w2-journal-da354d66.txt`.

## 5. Boundary — what the method does NOT do

- Does **not** change link speed. The cycle-1 frame (FEAT + XVE×4, §2)
  does not trigger the Gen2 negotiation: production init still logs
  `CMP90 Gen2: retrain completed without Gen2 link status=0x1041` and
  `LnkSta` stays 2.5 GT/s x4 post-bind on every one of the seven landing
  boots (per-window `check` output). The earlier expectation that landing
  masks pre-driver would let production init finish the negotiation is
  **measured false**.
- The explicit retrain lever does **not** bridge the gap either (WD boot
  `6e35d708`, route-D experiment): with the five masks landed and live
  under production, `CAP_EXP+30.w=0x0002` latched the root port
  (`0002`) but the **card-side write was dropped** (raw readback `0001`,
  `Target Link Speed: 2.5GT/s`); the bridge RL retrain then kept the link
  at Gen1. Zero Xid/DPC, health 200 uninterrupted — lever confirmed safe,
  and TLS latch on this card evidently requires the speed-path masks
  and/or the driver kernel-context method, not config-space writes.
  (W3b-era companion datapoint: same non-latch even before any masks
  landed.) The remaining delta for Gen2 is therefore the unlanded ladder
  targets (XVE `0x88ff8`/`0x88ab4`, XP3G `0x8e1b0..0x8e1f0`, OPTB
  `0x8200d0..0x8200f4`, `0x823b04`) plus whatever mechanism is needed to
  latch card TLS — an open upstream question.
- Does **not** land the full ladder. The once-per-boot law (§3) confines
  the standalone ko to a single ≤6-entry frame per boot; the 30+ targets
  of the rejoin16 apply-table proved unreachable through the ko by BOTH
  tested reload shapes — initramfs reload (#5a, W3g) and userspace
  full-driver-init interleave (#6, W3h). Multi-target on llm2 requires
  the driver-embedded one-crafted-write-per-boot lineage
  (`90hx-boot-ladder.service`), not ko reloads.
- **Route RF — the author's own rejoin16 lineage reproduces the wall on
  this card** (RF window 2026-10-31; warm boot `4c850625`, cold boot
  `8857dbe3` → warm `867c2fa1`; evidence `evidence/rf-*`, harness
  `llm2:/root/rf/`, lineage pins in `SOURCES.md`). Built exactly per his
  recipe (bundle 0014+0015 + repo 0016 @`2cdc63cf` →
  `PASS_CMP90HX_6104303_STOCKFLOW_REJOIN16_BUILD`), run with his bench
  (`rejoin16-apply-all.sh`, unmodified bar one accessor patch), campaign
  fully out of circuit (3 cards pci-stubbed early, `cmp50hx-boot`/
  `cmp-idle-governor` masked, `gputempd` disabled, ladder HALT set).
  Grade, identical on warm and cold starts: the stock V67 chain's FEAT
  write lands every load (`0xffffff8f→0xffffffff`) — the card *can* take
  booter-context writes — while his crafted extra write to `0x00088fe8`
  completes with matching codes (`status=0x55 mailbox0=0x00000011`) but
  never sticks (readback stays `0xffffffcf`, `polls=1000 NO-EFFECT`,
  apply auto-aborts per his design). Cycle-1 `polls=0 OK` on the FEAT
  spec is **vacuous** here (chain already opened FEAT in the same load —
  §0 attribution law). Conclusion: the extra-write gate is
  card/booter-side, not build- or flow-side (E2's preemption theory
  cannot explain this: campaign was out of circuit and his own canary
  fired); the identical-card assumption is falsified at the
  booter-payload level — his cold-validated rig takes the same write at
  ~147 polls. Robustness finding for his lineage on this host: repeated
  cycle loads after a FWSEC `FRTS 0xbe` first-boot hiccup entered a
  selector-handoff `rc=-5` loop (0016's FLR-retry path asserts on the
  consumed stock-signature memdesc, `kernel_gsp.c:5986`); recovery by
  warm reboot measured; endpoint stayed sane throughout (real BAR0 reads,
  zero Xid/DPC, link intact).
- ECC `0x823800` landed **once**, in the W2 diagnostic frame (row 1,
  `da354d66`). The current `0:6` frame does not target it and later-boot
  post-bind checks read `0xffffff8f` (not landed); no reproduction claim
  is made for that address.
- Does **not** survive reboots: warm AND cold reset both MEASURED (§6).
  A fleet re-apply must run the claim on every boot; upstream's warm-boot
  "skip if sample masks read open" fast path never fires here.
- The write does not make runtime userspace BAR0 pokes safe or necessary;
  do not add runtime pokers (ticket 11 prohibition stands).
- OPTB and XP3G remain untouched by any landed frame; the upstream note
  that OPTB re-locks per init is unreproduced here (never attempted).
  XVE is landed ×4 (subset of the six upstream rows).
- `10de:220d` is rewired from `GA102()` in the port — 0x220d also names the
  RTX 3090; these builds are experiment-only, never fleet builds.

## 6. Persistence matrix

| Event | Masks held? | Speed held? | Evidence |
|---|---|---|---|
| module reload (FLR) | ✓ the landed frame — `0x823804` + XVE `0x88fe8/8fec/8ff0/8ff4` (`0x823800` ✓ W2 only); WPR_CFG re-locked by design | n/a — Gen1 before/after | jsonl `post-flr-post-production-bind` checkpoints, §2 rows 1–37; W2 `stage=flr` line |
| production driver bind | ✓ same set, 7/7 boots strict (`landed=true`) | Gen1 (never raised) | per-window `check` `persisted post-production-bind: 5/7`; §2 rows 4–37 |
| warm reboot | ✗ **RESET** — every ladder boot's first pre-driver ko read of each target is the locked `0x4cb8f`, although the previous boot ended at `0xffffffff` (final window checks) | n/a | all seven boots W3a `6b8b83b1` … W3h `41ebb379`: `grep 'pass=2/6'`/`pass=3/6` in `evidence/w3*-journal*`/`w3*-mono*` |
| cold boot (power cycle) | ✗ **RESET — measured 2026-10-31** (cold boot `5b05bf0d` after W3h): all four XVE addresses read post-bind at the production partial baseline (`0xffffffcf/0xffffff8f`), **zero `0xffffffff`**, although the previous boot ended with `0xffffffff` held at every one through production bind | n/a | `maskread.py 0x823804 0x88fe8 0x88fec 0x88ff0 0x88ff4 0x823800` post-cold-boot; FEAT `0xffffffff` = production canary, not carried-over (§1 row) |
| runtime D3 round-trip | n/a — this host never D3s the card: `nvidia-persistenced` masked, `gputempd`/`cmp-idle-governor` hold it; `power_state=D0` in every window read | n/a | W3h `pre-state … power=D0`; production topology notes, ticket 11 |

RF-window addendum (2026-10-31, boots `8857dbe3` cold / `867c2fa1`):
cold re-latch re-confirmed with trusted in-driver reads — the stock
chain's own `FEAT_PLM_before=0xffffff8f` line fires on every boot's first
successful Booter execution (warm AND cold), i.e. FEAT is locked at
handoff regardless of how the previous boot ended; the chain — not
persistence — is why runtime FEAT is open (§1 row). Two earlier readings
are hereby **voided**: the `rf-check` `FEAT baseline=0xffffffff` lines on
stub-bound cards (all-FF artifact — §0), and an analysis note claiming
`0x8e1b0` "read `0xffffffff` with no table write" (address misalignment —
`0x8e1b0` read `0xffffff8f` at every RF sample point; the stable
`0xffffffff` is at `0x8e1f0`, present already at cold baseline in both
RF sweeps, untouched by any write this campaign).

## 7. Rollback

- **Unplug/reboot-to-stock is unnecessary**: the armed state is one-shot by
  construction (next_entry consumed; local-top inert without the cmdline
  flag). Post-disarm the machine carries zero experiment state — re-verified
  after every window, latest at the W3h close (2026-10-31): hook/script
  gone, unit + `ladder.env` + gate + `/lib/firmware/gpu-unlock/` gone,
  initrd rebuilt (`73a798c7…`, no ko inside — `lsinitramfs | grep
  gpu_unlock` empty; the md5 itself varies per rebuild, only the grep is
  meaningful), grub entry 0, `next_entry=` empty, module not loaded,
  health 200.
- If a future normal boot ever misbehaves: power cycle (restores BAR0 masks
  to stock — §6 shows even warm reboot already does), then `sudo apt
  reinstall` of the nvidia driver package is *not* needed — driver was
  never touched.
- Staged artifacts to delete if abandoning the experiment: `/root/l2-w2/`,
  `/root/zagitta-port/`, `/etc/grub.d/40_custom` W2 block, the
  `/boot/initrd.img-*` (rebuild via `update-initramfs -u`), `/root/l2/`;
  W3h user-ladder set: `/etc/systemd/system/90hx-w3h-ladder.service`
  (+`systemctl disable`), `/root/l2-w2/{w3h-ladder.sh,ladder.env,user-ladder-enabled}`,
  `/lib/firmware/gpu-unlock/` (pure copy of the assets cache — arm
  regenerates). `disarm` purges all of it idempotently.
  `success.jsonl` copies live in this repo (`evidence/`) and scratch
  `l2/w2-out/`.

## 8. Version pins

| Component | Value | Provenance |
|---|---|---|
| card VBIOS | 94.02.74.00.01 | ticket 01 |
| kernel | 7.0.0-38-generic (Ubuntu 26.04, uutils coreutils) | `uname -r` |
| unlock module srcversion | `C46DB4B43EEECB86EE15E91` (both variants) | W1 build |
| diag ko md5 (W2 frame) | `c237dd5f0ce953b92a6cdd65225376e4` | `l2-w2.sh state` (W2/W3a arms) |
| full ko md5 — **the window ko, all seven landing boots W3b–W3h** | `ae2c409bc14ed342e9bd548d8686aed5` (carries patch 0003 `gu_window`; the earlier full build `02ccc795cee548f90ea5e009b8624f6b` predates 0003 and never landed a window) | host `/root/zagitta-port/gpu_unlock_full.ko`; `ko_md5_used` in W3h arm state |
| ss-relock accessor binary | `618ffad4d7a18aaed2d84baf4a2fbbba` (v4: 16 MiB mmap + cfg rw, stage-named failures) | host `/root/l2-w2/ss-relock` |
| harness `l2-w2.sh` | `ee8becb5b5664b6953ece8fe03e8b1b4` (GU_LADDER_USER arm mode + disarm purge) | repo `.scratch/90hx-gen2-p2p/l2/` = host `/root/l2-w2/` mirror |
| W3h ladder + unit | ladder `eefb234769d9…` (post-fix: 3/3-GPU readiness gate, no EXIT-trap starts); unit `9d239177bb54…` | host mirror `/root/l2-w2/`; both inert (unit disabled+deleted at disarm) |
| Zagitta base + port | upstream `7eb51bcc` + series `patches/zagitta-gpu-unlock/000{1,2,3}` (0001 Gen2 mask family, 0002 `GU_CMP90HX_DIAG`, 0003 `gu_window=START:LEN` ladder param) | commit `140d000` + patch 0003 |
| production driver | campaign build 610.43.03 (`cmp50hx-boot` binds at multi-user) | pre-existing |
| repo commit under test | `cbd62c8` (W3h closeout) | local-only, never pushed |

## Appendix A — `success.jsonl` schema

Location on host: `/root/l2/success.jsonl` (created by `l2-w2.sh`; the
contingency #6 wrapper appends to the same file). Copies: repo scratch
`.scratch/90hx-gen2-p2p/l2/w2-out/l2/success.jsonl` (via `pull`) +
per-window snapshots in repo `docs/cmp90hx/evidence/w*-success.jsonl`.
One JSON object per privileged-write **attempt** (failures included; the
record is self-contained):

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
