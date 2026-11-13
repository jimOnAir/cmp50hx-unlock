# Source evaluation — mined third-party repositories vs this repo

Work stream: `gtuu-mining` (see `issues/`). Posture for every row:
**static read only — no mined code was ever executed or imported.**
Classifications: ALREADY-HAVE (A evidence cited) / PORT-CANDIDATE (→
ticket) / NOT-APPLICABLE (reason) / RECORD-ONLY (knowledge lands in
findings.md or docs, no code).

## Sources under evaluation

- **B1** = `MindAllik/GPU-Tensor-Unlock-Universal`, evaluated at commit
  `1d6a508214c25f252df02eca7bb7866319c440de` (v1.2.9, 2026-11-10).
  Sweep clone: `/tmp/opencode/GTUU-sweep`. The `work/upstream/` corpus
  clone (CLONES.md) is at `ab7bfc0` (v1.3.0, 2026-11-11) — row anchors
  below pin the **evaluated** commit; verify against the corpus clone
  before citing anything newer.
- **B2** = `physicsdolphin/nv-uefi-unlocker`, evaluated at commit
  `bbcb92f018f3509dd851f76e634ad806a1b615e6` (v2.1.10, 2026-11-12);
  corpus clone at `36b4089` (v2.1.11+rc2). Sweep clone:
  `/tmp/opencode/nvuu-sweep`. **B2 table pending** — its sweep agent was
  cancelled mid-flight; section will be filled by the re-run. Preliminary
  rows from direct reads are marked (prelim).

## Lineage finding (shapes every row)

`claim-90hx/` and B1's `kernel/gpu_unlock/` are **divergent forks** of
the same Zagitta/gpu-unlock lineage (`7eb51bcc` per claim-90hx/README) —
not upstream/downstream. This repo is ahead: PM-notifier resume re-unlock
(`claim-90hx/main.c:115+`), 2-attempt retry, structured `stage=` dmesg
protocol. B1 is ahead in three areas only: host-testability, pre-flight
validation, failure forensics. B2 descends the same chain independently
(its credits name Zagitta `unlock_610.c` as its transaction-chain mother
— see docs/cmp90hx/SOURCES.md B2 entry).

## B1 kernel module (`kernel/gpu_unlock/`)

| Row | Mechanism | Class / disposition |
|---|---|---|
| K1 | `targets=` cmdline opt-in, `report_unmatched`, async per-card unlock, bound-driver `-EBUSY` guard | ALREADY-HAVE (`claim-90hx/main.c:14-200`) |
| K2 | Per-family `*_experimental` flags with mandatory single BDF | NOT-APPLICABLE — gate for unproven GeForce silicon; our CMP entries are production rows in the T09 table |
| K3 | devres-scoped `request_firmware` (CONFIG_FW_CACHE leak fix) | ALREADY-HAVE (`claim-90hx/firmware_610.c`) |
| K4 | `check_devres_empty` at entry + handoff | ALREADY-HAVE (same unwind logic in fork) |
| K5 | `poll_us` with per-call `timeout_is_failure` (bug-3419321 tolerance) | ALREADY-HAVE (`claim-90hx/falcon.c:27,48`) |
| K6 | badf0000/~0 PRI-sentinel on every read | ALREADY-HAVE (`claim-90hx/falcon.c:21` `inaccessible()`) |
| K7 | Falcon DMA address-space validation (24/32/49-bit rules, 256-B tail rounding) | ALREADY-HAVE (`claim-90hx/falcon.c:168+` `falcon_dma_valid`) |
| K8 | DMA buffer + module retention when started-but-unquiesced | ALREADY-HAVE (fork's "retained until power off" unwind) |
| K9 | Booter header pinned-geometry table + per-arch validator (TU102 ucode_id 3 **and 13**) | ALREADY-HAVE (`claim-90hx/recipes.h:32-40`); follow-up one-liner: cross-check ucode_id 13 acceptance against our table during ticket 06's audit |
| K10 | 76-byte RM_FLCN_BL_DESC Turing boot-desc parse | ALREADY-HAVE (`claim-90hx/prep_610.c:169`, stricter) |
| K11 | Live-PROM FWSEC extraction + FRTS repatch + fuse-version select in-kernel | ALREADY-HAVE (`stage=fwsec`, `vbios_610.c`) |
| K12 | Cold-entry safety: EALREADY open-PLM, -EBUSY WPR2-up | ALREADY-HAVE (fork + resume handling `main.c:79`) |
| K13 | Post-FLR containment suite (BAR0 wait, GFW wait, TRPND, WPR2 recheck, SEC2 reset w/ propagation logging) | ALREADY-HAVE (`claim-90hx/unlock_610.c:1446-1620`, `falcon.c:114`) |
| **K14** | **Turing no-FLR exit tail** (skip FLR: zero WPR2, PLM 0xffffffef, hold SEC2 reset) (`unlock_610.c:1665-1681`) | RECORD-ONLY — fallback knowledge for FLR-hostile boards; our FLR exit is field-proven, no OS-side FLR hostility observed. Revisit only if one appears |
| **K15** | `log_falcon_state` RISC-V trace-PC/rpc/priv_err(+addr)/hub_err dump; trap: RISC-V block lives in the **falcon2 window** (`unlock_610.c:523-565`) | **→ ticket 07** |
| K16 | AD102 permission sampling, 0x67b00001 mailbox, payload memcmp guards | NOT-APPLICABLE (GeForce Ada evidence path; our T09 gate table samples equivalent PLMs) |
| **K17** | `__has_include(<linux/aperture.h>)` feature-detect + name-only `drm_driver` fallback | **→ ticket 06** |
| K18 | Signature publish/restore 2-call protocol, defer restore while SEC2 halt unverified | ALREADY-HAVE (fork has publish/restore + halt bookkeeping) |
| K19 | DKMS NO_WEAK_MODULES/BUILD_EXCLUSIVE_CONFIG/AUTOINSTALL | ALREADY-HAVE (`claim-90hx/dkms.conf` + blacklist discipline) |

## B1 UEFI application (`windows/uefi/source/unlock/`)

| Row | Mechanism | Class / disposition |
|---|---|---|
| **U1** | Same kernel transaction code compiled for UEFI via compat shim (one codebase, two runtimes) | RECORD-ONLY, deferred until ticket 11 exists (their own precondition) |
| **U2** | Pre-flight config-space walker: capability-list validation (lengths, overlap map, loop detect, unknown-ID reject), PM D0, **FLR support in DEVCAP bit 28**, ROM disabled (`checks.c:22-144`) | **→ ticket 08** |
| **U3** | Cold-state classification incl. PARTIALLY_MODIFIED (SS0 xor SS1) (`port.h:138-164`) | **→ ticket 04** |
| **U4** | Chip-ID mask tolerant of foundry strap bits 31:29 (`0x1ff000ff`) (`port.h:109-132`) | **→ ticket 05** |
| **U5** | Live-PROM gate: BAR0+0x300000 read, SHA-256 vs pin, FWSEC parse + dry-run FRTS + digest latch, PROM dump on mismatch (`app.c:362-433`) | **→ ticket 09** |
| **U6** | Runtime SHA-256 attestation of every asset + live PROM into the log (`app.c:353-358`) | **→ ticket 09** (bundled) |
| **U7** | Upstream bridge MEM/BME enable + LIFO restore (`ownership.c:197-243`) | RECORD-ONLY — our CF8/RootBridgeIo path works on the real fleet; revisit if switch-board DMA failures appear |
| **U8** | BME containment bookkeeping; never re-enable master on exit; halt-and-retain when cleanup unprovable (`app.c:499-525`) | Pattern adopted into ticket 12's containment asserts; our ko-side equivalent already ALREADY-HAVE (K8) |
| U9 | EFI_PCI_IO exclusive claim, GOP owner-identity recheck | NOT-APPLICABLE — CMP cards expose no GOP; we deliberately use RootBridgeIo/CF8 |
| U10 | Interactive arm (30 s keypress) | NOT-APPLICABLE — unattended by design |
| U11 | Windows handoff (preload winload, ESP GUID pinning) | ALREADY-HAVE (our chainload handles Win+Linux headless) |
| U12 | ESP REPORT.TXT logging, dump-on-failure | ALREADY-HAVE (`50hx_log.txt`, `50hx_vbios.bin`) |
| U13 | Per-board build profiles | RECORD-ONLY — 20 GB variants handled at runtime already |
| U14 | SecureBoot/SetupMode variable policy | NOT-APPLICABLE (fleet runs SB-off; sign-efi.sh covers exceptions) |

## B1 tests / tools / packaging

| Row | Mechanism | Class / disposition |
|---|---|---|
| **X1** | Host simulation harness: real module sources `#include`d against fake Linux + 16 MiB MMIO array + synthetic fixtures + ~45 fail-injection knobs + containment asserts (`tests/test_unlock_adapter.c` 746 ln) | **→ ticket 11** (top infrastructure pick) |
| **X2** | Module-init orchestration test under pthreads (concurrency, skip-bound, firmware lifetime) | **→ ticket 11** |
| **X3** | ASan+UBSan host self-test of UEFI app: 43 core + 64 topology scenarios, incl. the probes that *produced* rows U2-U5 | **→ ticket 12** |
| X4 | Parser unit tests (booter/ELF/radix/WPR-meta/boot-desc/FWSEC/gfw) | **→ ticket 12** (near drop-in: our copies diff empty) |
| **X5** | Build-time firmware generation from pinned NVIDIA sources; V67 payload regeneration; per-chip JSON manifests; `fetch_artifacts.py` (HTTPS + pinned SHA + offline verify) | **→ ticket 13** (gap remainder: our deb already extracts boot assets; the committed `efi-unlock/blobs/` are the tail) |
| X6 | initramfs ordering before `nvidia` for all 3 generators + `?`-suffix guard | folded as one verification line into ticket 09 |
| X7 | RPM/Arch/multi-distro packaging | RECORD-ONLY — Ubuntu fleet; Manjaro remains experiment |
| X8 | Packaging/release CI pins (asset-hash regressions) | RECORD-ONLY, optional later |
| T1 | `read_sm_rates.py` ctypes `0x20801230` | ALREADY-HAVE — `native/verify.c:43+` reads the superset (V1 + V2 `0x2080123c` + throttle `0x2080123d`) |
| **T2** | `gpu_peek.ko`: read-only pre-driver BAR0 sampler (FEAT readout, PLMs), never writes/resets/enables | **→ ticket 10** |
| T3 | PTX tensor benchmark (randomized fragments, accumulator verification, UUID/BDF pinning, before/after history) | **→ ticket 01** (method port) |
| T4 | `diagnostics/bench/` extra tensor-mode kits + env-gated runner | SUBSUMED by ticket 01 |
| T5 | NVML power-limit setter w/ readback | ALREADY-HAVE (`native/tune.c`, autotune) |
| T6 | `print_boot_option.py` targets-string helper | RECORD-ONLY — deb conffiles make it moot |
| S1 | Tkinter GUIs + i18n + launchers | NOT-APPLICABLE (interactive garnish) |
| S2 | GeForce support matrix incl. CMP rows marked `experimental_simulated` | NOT-APPLICABLE — simulation rows; **never cite as CMP support evidence** |
| S3 | dmesg status parser | ALREADY-HAVE (richer: our `stage=` protocol + collect/smoke parsers) |
| S4 | Their research reports (rtx4090/ada-2705 register reports, "How Ampere was unlocked") | RECORD-ONLY — cite as corroborating FEAT/PLM decode in findings.md |

## B2 (nv-uefi-unlocker) — full sweep, rows P1–P42

Evaluated @ `bbcb92f018f3509dd851f76e634ad806a1b615e6` (v2.1.10 badge; main
carries v2.1.12-rc2 features — **cite by commit hash, never by version tag**).
Static analysis only; clone never executed. The full 42-row table with
per-anchor evidence lives in the B2 sweep session log; condensed to
decision-bearing rows here. Verdict shape: B2 is a serious,
Turing-silicon-tested lineage sibling — its EFI transaction chain
**independently converges** with A's on the TU102 boot path (P6–P12, P18 all
ALREADY-HAVE / corroborated), and where it leads, it leads in
completion-check rigor, forensics dictionaries, and platform-edge handling.

Corroboration rows (A evidence): P6 START-bit1 + stickiness probe
(`unlock50x_v1.c:386,1584-1589`); P7 portal direct-write incl.
auto-increment-WRITE-only quirk (`:1602-1611,2135-2155`); P8/P9 RM_RISCV v4 +
BOOT_DIRECT semantics (`:2219,1806-1848`); P10 BTL1 Turing single-slot rule —
their docs cite **our** `prep_610.c` as the authority; P11 PLM 4-state naming;
P12 flow skeleton match; P18 FAT log open-write-flush-close discipline
(`:87-92` — A shipped it, B2 learned it the hard way); P24 in-OS resource0
verifier = `native/osunlock.c` + `native/verify.c`.

PORT-CANDIDATE rows -> tickets 14-22:
- P1 FWSEC completion gate (WPR2-exact AND GSP-CPUCTL-HALT AND
  scratch0e[31:16]==0 AND mailbox readback before ignition; "WPR2-up !=
  firmware done" — A's `unlock50x_v1.c:1613-1647` returns TRUE on WPR2 match
  alone = the machine-deterministic 0x91 race B2 root-caused; claim side
  already correct) -> **t14**.
- P2 staging-band fallback ladder HIGH->LOW on 0x89+magic-intact + VT-d
  preflight advisory + zero-DMA fingerprint (`cpuctl=0x0 + IMEM[0]=0xffffffff`
  => check BIOS VT-d) — A hard-pins >4 GB with no fallback (`:4788-4795`);
  B2's corpus proves the band requirement per-machine in BOTH directions
  (their #16 vs #14; A's v2.63 "<4GB read lock" confirmed real-but-machine-
  dependent) -> **t15**.
- P3 reset-scratch canary (arm 2 magics in PBUS sw-scratch after last
  deliberate FLR; later read classifies the culprit: rail-off vs FLR/SBR vs
  re-writer) — the only mechanism naming WHO wipes the unlock between boots;
  distinct from t04 entry-state classification -> **t16**.
- P4 mailbox0 dictionary v3 + EXCI decode (0x31 NS-stub marker, 0x89/8a meta
  magic, 0x91 = live-WPR-geometry delta != exactly 1 MiB, 0x0B PSS hash,
  0x11 param-table id; EXCAUSE bits [24:20]; trap: `0x00900100` appears in
  SUCCESS runs too — never a verdict alone) -> **t17**.
- P13 FLR craft (TP-pending clear -> FLR bit preserving devctl -> 100 ms
  silence -> config-identity poll -> restore high-BAR dword first, command
  last, BME never restored; **PMCSR saved/restored, D0 pinned — "FLR is
  defined only in D0"**) + P32a force-D0-before-re-unlock on the PM-notifier
  path (A currently refuses non-D0, `unlock_610.c:660-666`; a D3cold-notified
  card should be woken to D0, not skipped) -> **t18**.
- P36-C4 fresh-MMIO final gate before StartImage: re-read PLM/SS/readout as
  the LAST action before handoff; silicon not-as-true => refuse — "log green"
  becomes "green at the boundary" -> **t19**.
- P17 rdtsc per-line ms stamps in 50hx_log.txt + P19 banner-string assert
  (TX vs read-only artifacts) in build gates -> **t20**.
- P16 free ~84 MB+ staging pool before Windows chainload / log largest-block
  (A never frees; `alloc_high` falls back below 4 GB silently `:1092`) —
  documented `0xc000009a` Windows-bootmgr class -> **t21 (needs-info: does
  any real deployment chainload Windows through this EFI?)**.
- P26 RTD3 keep-powered pin (`NVreg_DynamicPowerManagement=0x00` conffile +
  `--check`): D3cold rail-off erases AON-kept unlock; free insurance for
  non-server boards -> **t22**.

Fold-ins: P27 content-derived SOURCE-MANIFEST + field-proven-binary hash +
P28 sha-attached collect profile -> scope appended to **ticket 13**.
P23 sim/ Faults catalog (esp. `meta_magic_corrupt` platform-vs-self-fault
discriminator and `fbif_write_dead_after_run` — engine reset does NOT restore
FBIF writes after a full booter run, only FLR does) + reverse-assertion
discipline -> **input to ticket 11**. P20 badf named taxonomy (`0xBADF<code>
<info>`: 5040 PRIV_VIOLATION, 1100 UNDECODED, 20xx FLOORSWEPT, 5620
domain-locked) + P24 register tables + P34 selector decode -> **input to
ticket 10 follow-ups** (verdict-string enrichment). P36-C2 entry-SS latch ->
**folded into ticket 04** matrix. P29/P30 payload-generator frame constants +
golden byte-repro standards (`b0ec9029`/`2a0aa1f8`/`44c36b2d`) + P30 boundary
"booter contains no 4 GiB logic — the wall is FBIF aperture + platform DMA"
-> **corroboration + roadmap input to ticket 13**.

DOC-PORT rows (knowledge cited, zero code): P21 GSP version-insensitivity
(525.60->621.01 measured; edges = container generation >=525 +
fwimage<->fwsignature MUST swap as a pair) de-risks the 610->615 migration;
P22 the "provenance-pinned Turing BOOT_DIRECT bootloader" circulating in
third-party pipelines is **A's own zero-bytes placeholder** (verified:
`sha256(0x00...)` = `fa43239b...`/`de676bae...` of
`efi-unlock/blobs/gsp_rm_boot_dbg.bin`) — corroborates payload-mode BL
non-consumption (t13: generate a real BL or document the zero-badge);
P31 0x91 forensics methodology + two false-verdict traps (Turing `sec`
readback always scrub-poison; marker-parser eating `0x` voids a round);
P32 warm-resume semantics (**A's PM-notifier priority ordering proven
correct** — replay-before-recovery; hibernate = fresh boot = claim re-runs =
covered) + `WPR2_HI != 0` driver-consumed marker + warm-entry fingerprint
SS0 = fuse-derived (e.g. 0x5112071); P33 relock taxonomy (relocked gate
`0xffffffef`/`8f` + intact SS = still unlocked — never call PLM != open alone
a loss; wording feeds collect verdicts); P34 selector = tier code not clamp
depth (3090 vs 2070 identical fuse signature, different outcome) + GA106
factory SS0 + fuse dict at GA100-0x7FF000 — calibrates verify.c decode; their
open request is exactly a 50HX calibration sample (A holds it); P35 Gen2 XP3G
map mirror-check + TU106 PLM0-open datapoint + LnkSta-is-truth + X79
BIOS-slot-speed dependency + independent Zagitta reproduction of the X99/CSM
Code-12 hang endorsing A's issue-#25 decision; P37 SR-IOV VF reads zero-filled
(zero != badf) — guest readings are not host evidence; P39 modded-VBIOS
P8-lock runbook ("unlocked-but-slow => check VBIOS lineage first"); P41
evidence rules; P42 TOTORONG adopt/reject ledger.

B1 cross-verdict (their independent line): peer-landscape files MindAllik
under garbage/AI-slop citing "FMLA32" as **non-NVIDIA terminology** —
corroborates A's low-trust posture on B1 from a source that never touched
B1's code; neither confirms nor refutes A's non-public-master finding (that
stands on A's own evidence). Their treatment of **xrip/cmp50hx-unlock (this
code's upstream): favorable, specific, correctly pinned (df2fe11) —
independently reproduces the 31.7x/28.4x closed-loop, the FEAT
0x409650/64/6c block, the v2.63 <4GB note, AGESA-CF8, and adopts issue #25's
pre-OS-retrain-hang as their own reason to keep link policy OS-side.**
Third-party validation; quotable with commit pins.

RED FLAGS for citing B2 publicly: (1) `make-usbroot.sh:150-172` calls the
zero placeholder a "provenance-pinned bootloader byte-identical to the fired
run" — substance fine (BL unconsumed), narrative wrong: cite findings, not
asset-provenance claims; (2) download channels include re-published NVIDIA
firmware via cachyos/archlinux mirrors + gh-proxy relay (A's
download.nvidia.com-only rule covers it); (3) ships `ssdiag/pmxdrv.sys` —
Intel-signed BYOVD-class physical-memory driver extracted to %TEMP%
(Windows-only pattern; never recommend to the fleet); (4) Rust/cargo build
chain (A deliberately stays gnu-efi+gcc: port patterns/docs, not toolchain);
(5) shallow-clone snapshot, single visible author identity — history quality
argued from docs only.

License: B2 GPL-2.0-only throughout (incl. sim/, tools; docs are copyrighted
expression — quote+pin+credit). A's kernel side already GPL-2.0-only ->
file-level ports clean as separate GPL-2.0-only files; do NOT graft into the
MIT-base efi-unlock translation units — land as new files, mirroring the
claim-90hx arrangement (same rule as B1). Knowledge/tables/dictionaries =
facts + quoted attribution: license-neutral.

## Safety-mechanism diff (the Q10 deliverable)

| B1 mechanism | Our state | Verdict |
|---|---|---|
| Pre-flight ROM validation **before** GOP/controller disconnect | EFI does zero live-PROM validation (embedded blobs only) | ADOPT → ticket 09 |
| SHA-256 latch of verified FWSEC span, re-checked before Bus Master | no re-check exists | ADOPT → ticket 09 |
| DMA buffers retained + Bus Master disabled on post-start failure; "no cleanup you can't prove → halt holding everything" | ko-side ALREADY-HAVE (K8/unwind); **EFI-side absent** | ADOPT pattern → ticket 12 asserts; EFI-side folded into 09's exit paths |

## Red flags for citing B1 publicly

1. `provenance.json` records `private_source_sha256` ≠ committed sha for
   most files — the public tree is **built from a non-public master**.
   Cite contents of `1d6a508` (or the corpus pin) only, never "their design".
2. AD102 V67 payload provenance is the HuggingFace TOTORONG repo — weak
   chain; do not echo that lineage. (Their TU102 entry correctly credits
   Zagitta + xrip/cmp50hx-unlock — our own upstream chain.)
3. Their packaging fetches re-published NVIDIA firmware from third-party
   distro mirrors (archlinux/cachyos archives) — any adopted pipeline
   uses `download.nvidia.com` only.
4. CMP rows in their matrix are `experimental_simulated` — simulation,
   never silicon. (Also recorded independently in SOURCES.md 2026-11-11:
   "No CMP support → zero applicability"; the transferable bits listed
   there = rows T3/T1/U5 of this table.)
5. No malware indicators found (static grep: no telemetry/exec/eval/
   obfuscated blobs outside fixtures; network confined to documented
   artifact fetch + commit-pinned GitHub-raw reads).

## License posture

B1 is GPL-2.0-only per file. This repo: root LICENSE copyleft-next
0.3.1; kernel-side files already SPDX GPL-2.0-only; efi-unlock = MIT
40HX base + own. **Rule for every port:** ported code lands in separate
GPL-2.0-only files with a provenance header (URL @ evaluated commit +
row ID); no copyleft-next ↔ GPL-2.0-only relicensing bleed; combined EFI
binary with GPL-2.0-only ports is GPL-2.0-only (acceptable — MIT base
permits it, documented here). Generated NVIDIA assets keep the driver
license, shipped alongside per their split-package pattern if ticket 13
lands. B2 also GPL-2.0-only — same rule applies.
