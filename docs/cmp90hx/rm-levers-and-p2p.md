# RM-side levers for 90HX Gen2 + the published P2P recipe (2026-10-31)

Source: user-provided links (ledger: `SOURCES.md`): Habr part 4 (1087254),
lixiangwuxian {cmpunlocker@2d10f89, 170hx_tips@0d30567, 170hx-rir-tool@03a612a},
iatethelogs/cmp90hx_pwner@73bc5ea. All tree claims verified against our
campaign source `work/build.1vZgdr/source` (610.43.03 base).

## 1. Habr part 4 = first published CMP 90HX P2P + Gen2-x16 datapoint

Published 2026-09-27, same author as part 3 (1082724). Content:
- P2P achieved on 2×90HX (Gen1): 3.08/3.35 GB/s vs 1.60 GB/s staged-through-RAM.
- **The 250 MB/s trap**: real P2P at 0.24-0.26 GB/s until IOMMU groups switched
  `Translated` → `identity`. ACS was exonerated (001d→0011 changed almost
  nothing). Cross-socket pairs limited by Xeon interconnect (NODE).
- After his Gen2 unlock (his own ladder impl, 20–30 min for 5 cards, 1–26
  re-init cycles/card — rejoin16-shape): **both cards 5.0 GT/s x16, P2P 6.70
  GB/s symmetric** — clean physical-layer validation.
- His Gen2 remains the 220 nF lane-cap x16 story from part 3 (x4 otherwise);
  our llm2 counter-example stands (his ladder = rejoin16 shape; our 0/49 on
  the run-#2 mask step is the documented failure delta).

## 2. The P2P recipe (published, script-extractable)

`cmp90hxpwner.sh:832` (pwner@73bc5ea) — load the patched (stockflow/rejoin16)
`nvidia.ko` via direct `insmod` with:

```
NVreg_EnableResizableBar=1
NVreg_DmaRemapPeerMmio=0
NVreg_RegistryDwords="ForceP2P=0x111;CLForceP2P=0x111;RMForceP2PType=1;RMPcieP2PType=0;RMForceStaticBar1=1;PeerMappingOverride=1;RMDisableFeatureDisablement=1"
```

plus per-CMP IOMMU group → `identity` (`/sys/kernel/iommu_groups/N/type`,
script lines 729-757) and strict srcversion-verified stack unload/reload.
Key audit vs our tree: `ForceP2P` (nvrm_registry.h:1082, kernel_bif consumer),
`RMForceP2PType` (:1110, consumed kernel_bif.c:1140-1144 → p2p_caps.c:138+),
`PeerMappingOverride` (:1138, kernel_bif.c:1154), `RMForceStaticBar1` (:1209,
consumer osapi.c:5959), `RMPcieP2PType` (present in header),
`DmaRemapPeerMmio` (kernel-open/nv-reg.h). **`CLForceP2P` and
`RMDisableFeatureDisablement` have NO consumer in the open 610.43.03 tree** —
inert no-ops on Linux or artifacts of private patches; harmless to include.

Relevance: llm2's P2P goal (ticket folder is `90hx-gen2-p2p`) now has a
published, card-matched recipe whose remaining dependencies are (a) patched
stockflow driver (we have one) and (b) Gen2 link (our wall). Note P2P worked
on Gen1 too — 3 GB/s — **the P2P half of the campaign is NOT blocked by the
Gen2 wall**; it was simply never scheduled. Candidate cheap window: P2P
enablement test on llm2 at Gen1.

## 3. RM link-speed levers we have never used (all present in our tree)

1. **`RmForceEnableGen2=1`** — consumed in open RM chipset.c:75-80 →
   `PDB_PROP_CL_PCIE_FORCE_GEN2_ENABLE` (synced to GSP via CL_SYNC_PDB,
   chipset.c:757). Pure `NVreg_RegistryDwords` config. Untested on 90HX.
2. **`RMPcieLinkSpeed`** — bitfield (nvrm_registry.h:1915+):
   `ALLOW_GEN2 1:0` (1=ENABLE), Gen3 in next field; the 170HX guide uses
   `0x5` = Gen2+Gen3 enable. Stock shorthand `NVreg_EnablePCIeGen3` writes
   this key (osinit.c:201-208) — proof the knob is live in the unix layer.
   Untested on 90HX.
3. **`NV2080_CTRL_CMD_BUS_SET_PCIE_SPEED` (0x20801805)** — control + speed
   constants (2500/5000/8000/16000) compiled into our build
   (ctrl2080bus.h:683-693). The 170HX guide ships a complete standalone RM
   client (`set_pcie_speed.c`) doing **staged driver-performed training**
   Gen1→Gen2→(setpci TLS on both ends)→Gen3; error map: `0x1b` = deviceMinor
   vs deviceInstance confusion, `0x0f`/fallen = stop + power-cycle. Our
   campaign has retrained only via bridge setpci (patch-0017 shape); the
   RM-native path is untested on 90HX. **Mask-interaction hypothesis:** if
   RM clamps speed from the same FEAT/fuse state our chain mask rewrites,
   then RM SET(2) after a landed mask may train Gen2 natively — and conversely
   the registry keys alone might not suffice without the mask. Either answer
   is decisive for path design.

## 4. The GA100 (170HX) Gen3 guide — mechanism to borrow, platform to distrust

`170hx_tips/Gen3_unlock_en.md` (2026-10-20, driver 615.71.09 reference):
- Probe-stage **software fuse override**: `nv_pci_probe()` writes
  `EN_SW_OVERRIDE 0x820040=1` then clears Gen3-disable bits `0x820250`/
  `0x820580` with readback — **direct CPU writes STICK on GA100 at probe
  time** ("verified with the gen3 pair"), before RM/GSP boot. Guard: if
  `DISABLE_SW_OVERRIDE 0x820084` bit0 is burned → skip (on 170HX it was,
  cleared by an **irreversible RIR burn** — `170hx-rir-tool`, GA100-only,
  NOT applicable to GA102 90HX, do not run near llm2 cards).
- FEATURE_OVERRIDE regs `0x82380C/0x823810/0x82382C` CPU-writable on GA100
  (mask 0x7FFFFFFF) — **the same 0x8238xx page our Gen2 mask (`0x00823800`)
  lives on**. Our window #9 found CPU writes inert on the 90HX — but #9 wrote
  steady-state, WITHOUT the EN_SW_OVERRIDE prelude and not at probe-stage
  pre-GSP-boot. If the 90HX reports `0x820084` bit0 = 0 (unburned), an
  L1-retest with the 0x820040 prelude and/or probe-stage timing is currently
  an untested variant (call it **L1b**). GA100 addresses ≠ GA102 offsets;
  read-only probe first.
- Their full flow = fuse-override + post-GSP register block (dlmgr/
  `0x8c040` rate encode) + RM staged training + `LnkSta` acceptance + single-
  pass no-retry discipline. Register-level parts are GA100-specific; the
  **method skeleton** (override → driver-native training → LnkSta-only
  acceptance) transfers.

## 5. Lineage note

`lixiangwuxian/cmpunlocker` HEAD **`2d10f89`** = the exact commit Zagitta and
jdowning notes cite as "cmpunlocker 2d10f891, sec2-postbl-plm-ss-cfg.patch,
plmTable" (patch present: `driver/patches/sec2-postbl-plm-ss-cfg.patch`).
This is the root repo of our whole CMP unlock lineage (170HX/GA100), forked
onward to jdowning100/pearlfortune (90HX/GA102 ports).

## 6. New test candidates (each = its own user-gated window; llm2 off)

- **P0 probes (read-only, first power-on):** 90HX `resource0` reads of
  0x820040/0x820084 (GA102 fuse-override regs IF mapped — unknown until probed);
  kernel cmdline `iommu=` state; `/sys/kernel/iommu_groups/*/type`.
- **W-a (P2P-at-Gen1):** apply §2 recipe to 90HX via our patched driver
  (`RegistryDwordsPerDevice` scoping), run a two-card read test → unblocks
  the P2P half of the campaign without touching the Gen2 wall. Needs ≥2
  cards visible to patched driver; fleet-restart window.
- **W-b (RM-native Gen2):** with mask landed (chain run #1 — reliable), call
  `cmp-pcie-speed 2` + bridge TLS set, read `LnkSta`; single pass, fail-closed.
- **W-c (registry-only discriminator):** reload with
  `RmForceEnableGen2=1;RMPcieLinkSpeed=0x1` and NO chain mask, attempt RM
  SET(2): success ⇒ RM-side gate only; refusal + LnkSta Gen1 ⇒ card-side
  FEAT mask required (confirms rejoin16 architecture).
- **W-d (L1b, only if 0x820084 bit0=0 on GA102 probe):** probe-stage
  EN_SW_OVERRIDE + CPU write 0x823800 with readback — if it sticks, the whole
  booter dependency evaporates for Gen2.

Ordering to discuss with user: W-a has standalone payoff (P2P at 3 GB/s even
at Gen1); W-b/W-c are cheap discriminators riding existing windows; #5a
(Zagitta port) stays primary for the Gen2 wall itself.

## 7. Corpus-day findings (repo clones, 2026-10-31) — jdowning's TWO Gen2 generations

`work/upstream/` analysis (cloned via `tools/clone-upstream.sh`; manifest
`docs/cmp90hx/upstream/CLONES.md`) surfaced `jdowning100-cmpunlocker@2cdc63cf`:

- **`driver/patches/pcie-gen2.patch` (310 lines, still in `build.sh`
  PATCH_ORDER)** — a *legacy-generation* design: inside `kgspBootstrap` it
  loops a **26-entry table** (XVE 3, XP3G_PLM 4, OPTB 10, FEAT_OVR_ECC_PLM
  0x823800, OPT_GEN23 clear, XP3G OVR/VAL 0/3) doing per entry:
  WPR2 restore via CPU (`0x1fa824/828`) →
  `kgspSec2PostblTimingRefillPayload(addr,value)` →
  `kgspExecuteBooterLoad_HAL` → readback, ×2 attempts, SOFT-FAIL (logs
  `xp3g booter FAILED to set …` and continues). Then CPU writes for the
  speed path + VSEC_DEVICE/PRIV_MISC_1 via booter launches + LTSSM poke.
- **`bench/90HX-GEN2-RESEARCH-NOTES.md` (identical to our vendored copy)
  states the wall as the author's own GA102 measurement**: "the chain
  re-fires **only once per FLR-separated module load** (first Booter
  execution after FWSEC/FRTS)". His shipped answer = rejoin16 ladder:
  **run #1 of each load carries ONE arbitrary (addr,value) from
  `/var/lib/cmpunlocker-rs/rejoin16-next-write.bin`**;
   `systemd/cmp90hx-gen2.service` runs `bench/rejoin16-apply-all.sh` once
   per boot; it loops `bench/rejoin16-cycle.sh`: rmmod stack → CPU-relock
   selectors via `bar0poke wr 0x82381c/0x823820=0` ("CPU-writable while
   FEAT_OVR_PLM is open… so the canary path runs on next load") → write
   8-byte spec → insmod → RM init. **34–36 RELOAD cycles within ONE boot
   (~minutes), not reboots** (corrected 2026-11-01); masks-open then speed
   path written **from kernel context
  at two points** (post-Booter late-boot + first device open), then GPU +
  bridge TLS + bridge Retrain toggle. Userspace speed writes warned as
  "coin flip on wedging" (GSP-RM race) — matches our window #9 inert-CPU
  + DPC-family precedents.
- Consequences for llm2:
  1. **No llm2-vs-jdowning contradiction on run #2** — his design never
     uses it; our 0/49 reproduces his own measurement. (b1 Q9 must ask the
     *sharper* discriminator instead: on his bench, do entries 2..26 of
     pcie-gen2.patch ever land, or do they log FAILED?)
   2. **Author’s pure LOOP SHAPE untested on llm2** = single patched
      module reload ×34 with bar0poke relock arming + spec file (his
      cycle.sh), not our stock≠patched alternation. Caveat found
      2026-11-01: his relock arming was INERT on llm2 window #9
      ("selectors stayed full") — if arming cannot work here, his loop
      has no mechanism to re-fire the canary and #6’s viability must be
      gated on a relock preflight test, not assumed. Note our tree already
      carries his patch 0016 (patches/cmp90hx/0016) + 0017/0018 follow-ups.
  3. **Mask set is 34 registers** (XVE×6, XP3G×17, OPTB×10, FEAT_OVR×1;
     "minimal subset unknown") — our "2 masks" model was the headline pair
     (0x823800+0x88fe8), not the proven set.
  4. Full GA102 Gen2 register map now on file: **CYA_0 0x8c2c0 bit2 =
     DIS_G2** (CPU-writable post-open), LINK_CONFIG_0 0x8c040 MAX_RATE
     (0x2<<18), PL_LINK_RATE 0x8c1c0=0x240036, LTSSM override 0x8872c=6,
     OPT_MAGIC 0x820520, VSEC_DEVICE 0x8860c bit0 (booter-written),
     PRIV_MISC_1 0x8841c bits(11|13)~(12|14), XVE_OVR@0x8872c.
  5. **§3 correction re: registry landmine**: our Aug-2026 finding
     "RegistryDwords break stockflow GSP boot (mailbox1=0x6)" was on the
     pearlfortune-stockflow carrier; jdowning's own `install.sh:229`
     SHIPS `RmForceEnableGen2=1;RMPcieLinkSpeed=0x1` with his patched tree
     (+booter-verify, +persistent-sw-state…) — unknown whether his tree
     fixes the landmine. W-c stays open only on HIS carrier, not stockflow.
- Path addition: **#6 = run the author's shipped LOOP SHAPE on llm2**
  (build via `90hx/build-candidate-with-rejoin16.sh`, then his relock-armed
  reload loop — ~minutes within ONE boot, not an overnight reboot saga;
  fail-closed with our LnkSta+WPR2 checks between cycles; viability gated
  on a bar0poke relock preflight, see consequence 2). #5a remains primary
  (6 pre-driver launches, no relock-dependency); #6 is the maximally-
  faithful fallback and the b1-thread empirical bridge.
