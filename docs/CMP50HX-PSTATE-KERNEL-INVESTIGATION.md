# CMP 50HX native automatic P-states — kernel/firmware investigation

Status: **active research** (wayfinder: `.scratch/cmp50hx-native-pstate/`).
Goal: make the card lower its own P-state like RTX/GTX (governor removable).
This doc is the evidence base; ticket 01 = S2 capability trace.

## Method note (2026-10-28)

IDA is not installed; the analysis runs on the **actual signed firmware**:
`llm2:/lib/firmware/nvidia/610.43.03/gsp_tu10x.bin` → outer wrapper ELF
(`.fwimage` @file 0x40, per-chip `.fwsignature_*` 4 KiB blocks GA100/TU11X/TU10x
alongside the image) → inner RV64GC ELF `EXEC`, base `0x4000000`, **VA parity
with the IDB confirmed** (0x55658F4 gate decodes as the IDB describes).
Full RM-task text `0x4BF7000+0xFF1000` disassembled with `llvm-objdump` to
`work/gsp/rm_text.asm` (gitignored). IDB comments/JSON memos mined via
`strings decompil/*.i64` → `work/gsp/idb_strings.txt` (906k lines).

## Established chain (GSP-RM, TU10x)

1. **Engine enable**: `RmPerfSetDynamicPstateEngineEnabled` @0x553b470 builds
   firmware request **cmd 0x1300 / sub 2** (0x14-byte params, sender
   `sub_57B541C`) and sets backend `+0x8E5C8` only on firmware success.
   **It has NO capability check — it enables unconditionally once invoked.
   Its ONLY caller is the readiness-barrier callback.**
2. **Readiness barrier**: `RmPerfRegisterDynamicPstateEngineCallback` requires
   events **4, 21, 24, 29** (+optional 7/11/35). Registration is skipped
   SILENTLY (returns NV_OK, no assert, nothing logged) unless
   `cap = *(pGpu+0x2050)` is non-null, `cap[0xDCC]` passes the index check,
   and **`cap[0x74D] != 0`**. Same gate in both `g_RmPerfDynamicPstateMethods`
   V1 and V2 — swapping method-table slots buys nothing (IDB, 2026-08-26).
3. **A053 handler** (`0x2080A053` = NVAPI→`RmPerfSetDynamicPstateEnabled`)
   gate order (IDB-verified): `pPerf+0x2E2==0 && pPerf+0x2B6!=0` else
   **0x56**; then `backend+0x11DC==0` else **silent success**; then
   `+0x14D8` engine-active else **silent success**. Two silent exits are why
   every host probe "succeeds with no effect".
4. `cap+0xDCC` = `RmPmuBootstrapMode` via identity jump table
   `jpt_RmPmuBootstrapMode_to_Dcc` @0x41AFF10 (cases 0..4). Live test
   2026-08-26: `RmPmuBootstrapMode=0` (forces DCC=0) did NOT make the card
   transition — so the remaining wall is `cap==0` or `cap+0x74D==0`, and
   which one has never been measured live (explicit IDB caveat).

## Q1 — the writers of `cap+0x74D` (NEW, 2026-10-28)

Exactly 3 stores to `+0x74D` exist in the whole RM task (12 refs total; 9
reads = the gates, incl. V1-style `lw -0x234(base+0x1000)` for `+0xDCC`):

| site | value | nature |
|---|---|---|
| **0x57CB5AC** (fn @0x57CB328) | `1` | W1: unconditional straight-line init of ~300 capability bytes (`li a5,1; sb a5,0x74d(a1)` at ~0x300 bytes of offset-stores) |
| **0x57CBAC0** (fn @0x57CB8A4) | `1` | W2: sibling variant, near-identical byte-set |
| **0x5925CC0** (region @0x59253XX) | `1` | **NEW — not in IDB**: conditional runtime path (`andi,bit0 → sb 1,+0x74c then +0x74d` on base+0x1000 object) |

Binding: installer **@0x57CA110** (single caller chain 0x57CA2CC→0x57CA6FC→
0x57CA9B8, no static callers → entered via HAL binding; matches IDB "cap[0x74D]
is die-level via RmHalInstallChipMethods") stores **W1 → slot `+0x98`** of the
constructed object (`lui 0x57cb; addi -0x390; sd 0x98(s1)`) plus 4 sibling
callbacks (+0xd8/+0xe0/+0xe8 → 0x57AAE34/ED0/C60, +0xf0 → 0x57CAF50).
W2 (0x57CB8A4) has 5 `lui 0x57cb / addi -0x75c` load sites still to be
disambiguated: 0x4DC2194, 0x5601388, 0x569A7AC, 0x569BF38, 0x582B56C.
No static file-data pointer to W1/W2/installer exists — all runtime-bound.
The single `GPU+0x2050` clear-site (constructor `sd zero`) is @0x5866458;
no unambiguous OBJGPU setter found by offset-pattern scan (false-positive at
0x57F37F8 = child-descriptor ctor storing `lhu chipDesc+0x2CA << 2`).

## Q3 — CLOSED (negative)

`RmPerfLimitsOverride` = three **2-bit** fields, 1=clear/2=set (IDB, exact
sites): bits 0-1→`backend+0x11DC` (0x5550E50/0x5550DA0), bits 2-3→`+0x11DD`
(0x5550EC8/E64), bits 4-5→`perf+0x2F6` (0x5550ED8/E74). `+0x11DC` is the
dynamic-event **suppression** byte (nonzero = suppressed) — NOT the
capability byte. **No value of the key reaches `cap+0x74D` or the barrier.**
Patch 05 (0x01) only cleared the suppression leg. The registry route is
architecturally dead for native DVFS.

## Q2 — open, with a mapped path

0x1300/2 sender: `sub_57B541C`; PMU transport branches (IDB JSON 2026-10-09):
zero-branch send `0x57C3BA0`/recv `0x57C4DAC`, nonzero-branch send
`0x57B213C`/recv `0x57C479C`, queue writer `0x57AC448..0x57AC6CC`; unit15/
function10 ownership untraced; TU102-37 PMU capability-init slot `+0x328` is
bound to the **return-86 stub 0x59D5400**. Receiver-side acceptance of
0x1300/2 remains unproven — but note the enabling call itself has no gate;
the wall is reaching it at all.

## Decisive next experiment (dynamic leg-split — FIRST RUN 2026-10-28)

`verify/a053-probe.c` (NV_ESC_RM_ALLOC client/device/subdevice on
`/dev/nvidiactl` + `/dev/nvidiaN`, then NV_ESC_RM_CONTROL): on bare llm2
(governor stopped, stock stack) `0x2080A053 {0,0}` returns **NV_OK silently**.
Gate-order reading (IDB): `pPerf+0x2E2/0x2B6` P-State-object leg **passes**
(it is what would return 0x56) — so `RMDisablePStates`/`AllowMaxPerf` are NOT
the wall on stock; the silent exit is the engine-inactive predicate
(`+0x14D8`/backend `+0x8E5C8`) — the barrier never armed, exactly as the
static cap-gate says.

Remaining for the live verdict: which cap-gate condition fails (cap==0 vs DCC
vs +0x74D). Plan = ticket 02 cold-boot matrix: each boot injects one
`RmPmuBootstrapMode`/`RmPerfLimitsOverride` corner, then re-runs
`a053-probe -i N -p 0 -s 8` + `pstate-trace`; a corner that changes the
silent-NV_OK behaviour pinpoints the failing condition. If no corner changes
it, the wall is `cap==0`/`+0x74D==0` and only ticket 03/04 (HAL variant
binding, runtime-bound — no static pointers found) can reach it.

Issue `0x2080A053` directly (NV_ESC_RM_CONTROL on NV20_SUBDEVICE) with
enable=1, after each of: baseline / RmPerfLimitsOverride sweep corners /
RMDisablePStates=0+AllowMaxPerf=1 (these two feed the `pPerf+0x2B6`
P-State-object rejection leg via `perf+0x1AF8/9`):

* `0x56` → P-State object rejected: policy legs (0x1AF8/9) are the wall → registry combos matter after all, continue sweep.
* silent-success with engine-inactive (`+0x14D8` false via GET_CURRENT_PSTATE behaviour / trace) → cap-gate wall (0x74D/cap==0) → ticket 03/04 (HAL variant) becomes the only route.

## Artifacts

* `work/gsp/inner.fwimage`, `rm_text.asm`, `idb_strings.txt` (gitignored)
* sha256 inner fwimage: `73065619db9ec921d19fc4e519dd04d91a9199b525eaca9b257b89fb8c5ec52c` (outer wrapper)


## Operational hazard (2026-10-28, measured twice): NVreg_RegistryDwords breaks stockflow boot

With the CMP `both` stockflow module, **any non-empty
`NVreg_RegistryDwords` makes GSP boot fail**: the stockflow booter ROP
sequence completes, but the post-FWSEC exact-state check sees
`WPR=00000000:1ffffe00` instead of the VBIOS-latched `027fee00:027fe000`
(`mailbox1=0x6`, `POST_FWSEC_COMMIT_FAIL status=40`, RmInitAdapter
0x62:0x40:2119). Repro: FLR -> `modprobe nvidia
NVreg_RegistryDwords="RmPerfLimitsOverride=0x01;"`. Recovery: FLR + reload
without the param recovers most cards, but repeated failed attempts exhaust
the GSP boot budget (4/4) and can leave a card needing a full power cycle
(c4f78ddb @04, 2026-10-28). Consequence: GSP registry keys can only be
delivered by the patched driver path (`_kgspPrepareRegistry`), never by the
standard Linux modparam. Never suggest `NVreg_RegistryDwords=` experiments
for this stack again.


## Registry corner matrix — live result (2026-10-28): NEGATIVE

Corners built as module variants (`_kgspPrepareRegistry`
`osWriteRegistryDword`, corner-parameterized via sed-baked
`CMP50_PSTATE_CORNER`): `Ovr=0x2A` and patch05-full put the card at
**P8 at rest but PINNED P8 under load** (FMA 4.4-4.5 TFLOP/s vs ~13.4
unlocked — same arbitration-inversion family as patch 05, ×3 compute loss);
`Ovr=0x01/0x15/0x02/RmPmuBootstrapMode=0` stay P0. A053 returns silent
NV_OK in every corner, including the P8-pinned ones — the dynamic engine
never armed. **No registry value arms the barrier or reaches `cap+0x74D`;
native DVFS is not host-reachable through the GSP registry.** Next possible
walls: runtime HAL binding of the W1/W2 capability initializers
(tickets 03/04).


## Q1 VERDICT (2026-10-28): the `cap+0x74D` binding is variant-KEYED, not ID- or ROM-keyed

Disassembly of the runtime path (VA parity with IDB re-confirmed):

* Gate exactly as IDB: `lui 0x2 + ld 0x50(a5)` = `[container+0x2050]` -> cap;
  `lui 0x1 + lw -0x234` = `cap+0xDCC`; `lbu 0x74d` = the byte (sites
  0x55681f0 V2 / 0x5569e08; V1-style identical).
* Constructor chain to the installer: `0x57c8cd8 (child-attach ctor caller) ->
  0x57c8b04 -> 0x57c8994 (generic ctor wrapper, LA `a1=0x57ca9b8`) ->
  0x57CA9B8 -> 0x57CA6FC -> 0x57CA2CC -> installer 0x57CA110` storing
  **W1 (0x57CB328) at `+0x98`** (+ siblings at +0xd8/e0/e8/f0). No static data
  pointers — everything reached via `auipc+jalr` and LA pairs.
* **The variant binder**: `0x5B38000` — a mask-driven HAL variant table writer
  (a5 = `HalVarIdx & 0x1F`): for bits set in mask `0x3E0` (indices 5,6,7,9) it
  stores **W1 -> slot `+0x318`** (site 0x5b382ac). TU102 HalVarIdx = 37 ->
  low5 = **5** -> in-mask -> **CMP's die variant DOES bind the `74D=1`
  initializer.** The key is a static chip-descriptor field; no PCI/device-ID
  or board-ROM input participates on this leg.

Consequences:
1. **`CLOSES-ALIAS` (ticket 04)**: the alias experiment already showed RM
   re-derives identity from the board ROM (`CMP_SKU=1` under the 1e07 alias),
   and now the binder leg provably takes no ID input. The 1e07 route cannot
   reach the P-state engine.
2. The "capability byte missing on CMP" hypothesis is **demoted**: if the
   constructor runs for CMP, `74D` should be 1. The remaining live candidates
   for the silent skip are **(a) the cap constructor never invoked for CMP**
   (the child-attach list at 0x57c8b04/0x57c8d4c is built elsewhere and may be
   gated by a perf/board condition), or **(b) the readiness events
   {4,21,24,29} never complete** — e.g. event-21 producer sits behind
   `lbu 0x79b(obj)` (site 0x55658a8/8f0) and event 4 ties to PMU bootstrap.
3. S3 framing (ticket 03) shifts: patching a variant mask is pointless (TU102
   already in-mask); the target is now the attach-gate and event producers.

Next static thread (follow-up under ticket 01): trace the child-attach list
construction feeding `0x57c8cd8` (who builds it, under what chip condition),
and the event-21/4/24/29 producer gating.


## Follow-up round 2 (2026-10-28): reachability of the whole engine class

* V1/V2 gate functions are real methods of class **`0x58C5A6C`**
  (methods-table V1 @0x4040E98, V2 @0x4040FC8 — these ARE
  `g_RmPerfDynamicPstateMethods_V1/V2`; class_def @0x401EB78/0x401EBA8).
* Class ctors (`0x57c8f74` etc.) are invoked ONLY from NVOC child-attach
  tables of the shape `{relOffset, classId 0x58c5a6c, ...}` — classId
  0x58C5A6C occurs in ~647 clustered references (child lists across the
  multi-chip mega-build).
* The binder dispatcher for the variant tables (`0x5B37CC8`, `HalVarIdx>>5`
  group switch) itself has exactly one entry: a computed `jr` at 0x59DADF4 —
  and **zero absolute/relative data references** to the entire cluster
  (method tables' class_defs are referenced only by each other and by these
  child lists; verified with a scan proven sane on control rows 0x5238BAC).
* Event-21 producer (`0x5565724`, gated by `cap+0x79B == 0`) also has ZERO
  data references: its registration/wiring lives in the same cluster.

Interpretation (one coherent story for ALL observations): the
dynamic-P-state engine class is **not attached by any TU102-37 chip/engine
child list in this image** — `OBJGPU+0x2050` stays NULL on TU10x, the V1/V2
gate exits on `cap==0`, the barrier never registers, and no host input
(registry — ticket 02 matrix; controls — A053 leg-split; variant mask — Q3)
can arm it. GeForce TU102 idle-downclock does not use this engine either
(same `gsp_tu10x.bin`, real DVFS = legacy PMU path, SKU-gated on CMP).
The remaining 10% doubt = whether some TU102 child list DOES attach class
0x58c5a6c; closing that requires IDA's xref graph over the 647 clusters
(enumerating list owners) — parked as the sole follow-up for a future IDA
session.

## Closure position (per stop rule)

Native automatic P-states on CMP 50HX: **architecturally absent from the
host-reachable surface of this firmware generation** — static (Q3 closed,
binder variant analysis) + dynamic (corner matrix, A053 leg-split, DCC-forced
boot) evidence all agree. Contingency fires: governor is the shipping answer
(default-on landed 2026-10-28); the deferred adaptive-debounce is now the
next shipping item.


## Incident + recovery procedure (2026-10-28, warm reboot clears it)

After the RegistryDwords-poison experiments, card `e92ff076` (01:00.0) lost
its VBIOS-latched WPR2 range (`027fee00:027fe000` -> booter commits hit
`0:1ffffe00`, `mailbox1` mismatch, RmInitAdapter 0x62:0x40:2119, 4/4 attempts
per load; FLR alone did NOT re-latch it). A recovery attempt with FLR +
`bus` reset (SBR) DID re-latch WPR2 (first attempt logged
`STOCK_RANGE_CAPTURED 027fee00`) but left Falcon/ACR half-POSTed: the next
booter run then corrupted the latches of ALL three cards (0 devices after
reload, every link downgraded to Gen1).

Recovery that worked: one plain WARM REBOOT. BIOS POST re-runs VBIOS init on
every slot -> all latches re-established, all three cards initialized with
zero RmInitAdapter failures, Gen2 x4 adopted again; SS0=88888888/SS1=08
(issue-rate unlock) survive warm reboot because power is never cut, so the
warm unlocker lottery is irrelevant for already-unlocked cards.

Rules of thumb added to bench lore:
1. Never combine repeated failed booter runs with FLR/SBR attempts while any
   poison source (bad module params, custom corners) still loads - fix the
   poison first, then reset ONCE.
2. Latch corruption (WPR shows 0:1ffffe00 where 027fee00 is expected) is a
   POST-level problem: warm reboot fixes it; PSU cycle only if a card stays
   down after POST.
3. After any bench reboot: `nvidia-smi -L` + `dmesg | grep -c 'RmInitAdapter
   failed'` + LnkSta check + `verify-governor.sh`, then
   `docker compose start ornith` (compose-stopped containers do not
   auto-resume).
