# Pre-OS EFI PCIe-Gen2 unlocker for the CMP 90HX (GA102, `10de:220d`) — port plan

Wayfinder ticket: `.scratch/90hx-gen2-610/issues/02-efi-port-recon.md` (research).
Downstream: ticket 03 (offline build) → ticket 04 (decisive one-execution window)
→ ticket 05 (full ladder) → ticket 06 (product integration).
Written 2026-11-01 from in-repo sources only (no host, no network, no hardware).

**Shape of the bet (given, not re-litigated):** on llm2 every OS-side and
pre-driver-in-OS vehicle is measured dead by run-2 refusal (0/49 cumulative);
the surviving mechanism is *pre-OS*: each fresh FWSEC re-prime inside the EFI
app + one crafted Booter payload = an independent run-1, and Zagitta's public
GA102 payload is **multi-write — 6 privileged writes per single chain
execution** — so ~6–7 chain executions cover the whole 34-mask ladder between
POST and OS boot, then a no-POST chainload carries the opens into the OS where
the existing kernel speed-path/retrain logic (patches 0016/0017) finishes the
job. Driver pin 610.43.03; all constants 610-valid.

Anchor conventions below:
- `E:` = `efi-unlock/` (our proven TU102 substrate)
- `WF:` = `docs/cmp90hx/upstream/wildflash-efi/` (vendored GA102 EFI, pinned `76940ae5` per `docs/cmp90hx/upstream/CLONES.md:22`)
- `Z:` = `work/upstream/Zagitta-gpu-unlock` @`7eb51bcc` (clone on disk; provenance `docs/cmp90hx/upstream/zagitta-gpu-unlock/README.md`)
- `D:` = `docs/cmp90hx/`

---

## 1. Substrate inventory — what exists and is proven

### 1a. Our TU102 EFI substrate (`efi-unlock/`) — proven live on real hardware

`E:unlock50x_v1.c` (5102 lines) — full V67 canary flow pre-OS on `10de:1e09`:
find card → BAR0 → wait GFW + seed PTIMER → alloc payloads >4 GB → fake GSP
image (dummy FW + radix-3 page table + `GspFwWprMeta`, V67 payload as the
oversized signature) → GFW kill (GSP engine reset) → conditional FWSEC fallback
→ SEC2 Booter load (canary ROP opens the PLM) → SS0/SS1 → SEC2 sanitize →
no-POST chainload. Status "WORKING — proven live" and the stock-driver A/B
matrix: `E:README.md:10-11,39-51`. Descent from the GA102 90HX unlock work is
recorded in its header `E:unlock50x_v1.c:1-35`.

Key proven facts we inherit:

| Fact | Anchor |
|---|---|
| ESP one-cycle integration: idempotent boot entry + `BootNext` (auto-fallback), BootOrder-first promotion only after proof, both read back | `E:install-linux.sh:161-195`; `E:README.md:201-229` |
| Above-4G-decoding / Secure-Boot-off / CSM-off / Fast-Boot-off prerequisites | `E:README.md:141-148` |
| Chainload ladder over own FAT16/32 parser on BlockIo, loader **preloaded before the unlock**, no SimpleFileSystem anywhere (SFS hangs whole firmware families); last resort = return to firmware | `E:README.md:114-126`; `E:unlock50x_v1.c:4730-4740,5073-5090` |
| `--return-to-grub` load option and compile-time `U40X_FORCE_RETURN` (unlock → return to firmware, skip chainload); OS loader preloaded before the unlock | `E:unlock50x_v1.c:25-26,4718-4720,4722-4728` |
| Multi-entry pre-OS chains with no POST between entries work: the shipped llm2 shape is `50HXU1.EFI → 50HXU4.EFI` (per-bus builds, `-DU40X_TARGET_BUS=0x01/0x04 -DU40X_FORCE_RETURN`), then the OS entry | `.scratch/warm-multi-unlock/issues/03-warm-settle-curve.md:22`; `.scratch/615-port/research-11-booter-analysis.md:208` |
| Pre-OS Gen2 on **TU102** is dead and was removed (XP3G gate `0x8e1b0` reads `0xffffff8f` pre-OS; X79 `LNKCTL2` RO; X99/X299 retrain hang) — GA102 needs the *chain*, not register pokes | `E:README.md:260-266,318-327`; `E:unlock50x_v1.c:5050-5068` |
| Build discipline: objcopy per-blob symbol assertions, `-j .reloc` mandatory, sha256 + `BUILD_OK` | `E:build.sh:28-72,93-97`; `E:README.md:363-378` |
| Secure-Boot signing with sbctl/sbsign + `sbverify` gate, `--efi` install path | `E:sign-efi.sh:44-51`; `E:README.md:150-174` |
| PASS-marker discipline to mirror: `PASS_CMP50HX_PREPARE`, `PASS_CMP50HX_ALL_BUILD`, `PASS_CMP50HX_INSTALL`, `PASS_CMP50HX_ISSUE_RATE_AND_COUNTS` | `build.sh:288,318`; `install.sh:409-428` |
| A *second* Booter run after the unlock's own FWSEC commit is dead on TU102 pre-OS (RISC-V fetch block dies: `rdidx=0`, all `pc=0`) — extra writes must ride the **single** execution | `docs/CMP50HX-615-UNLOCK-INVESTIGATION.md:41-55` |

`E:extract_fwsec.py:1-25` — TU102 **V2-descriptor** FWSEC extractor (driver-parser-faithful); *not* the GA102 tool (see W-4).

### 1b. WildFlash GA102 pre-OS implementation (`WF:src/unlock_v2.c`, 5493 lines) — the GA102 flow, proven on GA102 compute; gen2 variant compiled but de-scoped upstream

The single file builds every variant behind load-bearing flags
(`WF:src/unlock_v2.c:53-75`; `WF:src/build.sh:92-107`; `WF:BUILDING.md:56-70`).
Relevance by area:

- **GA102 early path** (the flow that works): GSP BL ucodeId=1 → FWSEC v3 on GSP
  → FRTS → WPR2 latch → ResetIntoRiscv + LibosBootArgs → SEC2 Booter load on a
  fresh SEC2 — `WF:unlock_v2.c:2032-2120` (`early_unlock_path`), FWSEC HS-boot
  `:1249-1580`, Booter load `:1655-2032`. Flag table + protocol digest
  `:1-93`. Compute unlock shipped working (llama-bench 3705 t/s, `WF:README.md:43-50`).
- **The complete gen2 ladder already compiled** (`PCIE_GEN2_REJOIN`): 37-entry
  rejoin16 mask table `:992-1051`; FLR-separated mini-cycle fire walk with
  booter#1 stock + booter#2 crafted pair (`value@v67Phys+0xf948`,
  `reg@+0xf960`) `:5014-5116`; host-side speed path `:5124-5146`;
  GFX_SPEED_SELECT `:5148-5170`; SS0/SS1 `:5171-5207`; bridge TLS +
  Retrain-link phase3 `:5208-5295`.
- **Their measured bench laws** (GA102 EFI context): exactly **2 Booter
  executions per FLR-separated FWSEC mini-cycle** (stock#1 + crafted#2), never
  a third (`:5020-5027` v2.99e; `WF:docs/GOTCHAS.md` "За один бут-цикл…");
  masks survive FLR but die at warm/cold reset (`:5028-5030`); near-FF
  (`0xffffffcf/8f`) can require a 2nd/3rd multipass to reach exact FF
  (`:5037-5115`); NVRAM calls and SFS after unlock **hang the platform**
  (v2.99o; `WF:docs/GOTCHAS.md`; `WF:KNOWN-ISSUES.md:60-70`) → exit is
  Print+return, BDS continues BootOrder with no POST (`:5306-5322`).
- **Gen2 de-scoping history**: v3.02-full Code-43 regression (latched WPR2 +
  live SEC2 ROP spinner → GSP-RM fail), fixed for NOGEN2 by tail cleanup
  (kill SEC2, final FLR, no MMIO after FLR) `:5324-5348`; `WF:KNOWN-ISSUES.md:14-33`;
  the full table lives only in `unlock_v3f.efi`, pending re-proof; a 37-entry
  walk cost ~10 min and **two boards rebooted mid-walk** (Kaby Lake 36/37,
  Ryzen 24/37) `WF:KNOWN-ISSUES.md:25-33`.
- Blobs and provenance (booter `SIG_PROD[0]` patched at `0x8A10`, FWSEC from
  the card's own VBIOS via `extract_fwsec.py`-family tool, runtime
  `gsp_ga10x.bin` from the 610.43.03 package): `WF:BUILDING.md:33-76`.

### 1c. Zagitta 6-write frame + multi-launch gating (`Z:`) — the payload model we port

| Item | Anchor |
|---|---|
| Re-entrant 6-write frame: enter `reg_write_indirect()` at `0x1110` (r0=address, r1=value), one write per `0x18`-byte stack frame starting `0xff54`, popped r0/r1 carry the next write; cleanup at `0xff54+6*0x18=0xffe4` (`0x576b → 0x84c8 → 0xd52 → 0x81ee` HS exit); a 7th write would need `0x1000c` | `Z:kernel/gpu_unlock/recipes.c:5-23` (comments), `:24-45` (`ga102_words[]`), `:46-53` (`ga102_slots[]`) |
| Slot geometry, `(value_off, address_off)` order: `0xf944/48, 0xf95c/60, 0xf974/78, 0xf98c/90, 0xf9a4/a8, 0xf9bc/c0`; image = fill `0x0000019c` over `0xfa00` + static words + 6 (val,addr) pairs | `Z:kernel/gpu_unlock/payload.h:24-28`; `payload.c:41-65` |
| Booter expectations GA102: image 60416 B (`0xEC00`), 2 sigs of 768 B, os_data 35328, app_code 35072, patch_loc 35344 (`0x8A10`), ucodeId 3, launch flavor `GU_SEC2_HS` | `Z:recipes.c:246-259` |
| Write-table batching: any table → launches of 6; **last entry repeated to fill the fixed slot count**; launch ≥2 requires prior **HALT evidence** (`invocation_halted`, `fresh` = reset asserted+released+reloaded+started+halted, `cleanup_complete` = fresh ∧ `RESET_PLM==0xff`, ECHO variant checks mailbox meta echo) + host **WPR2/FRTS restore** (`restore_frts`) before refill; ≤2 attempts per batch; readback per write with `0xbadf0000` = inaccessible gate; stock signature pointer restored at the end | `Z:unlock_610.c:1209-1330` (`run_privileged_writes`), `:1230-1233` (fill rule), `:1168-1206` (`restore_frts`), `:1156-1166` (stock restore), `:1081-1092` (halt evidence) |
| GA102 opener table: `{0x1fa7cc WPR_CFG_PLM = 0xfffff0ff (source-control bits significant), 0x823804 FEAT_PLM = 0xffffffff}` then host-side SS0/SS1 are plain CPU writes | `Z:recipes.c:200-228`; `Z:registers.h:76-77` |
| FWSEC sourced at runtime from the SPI PROM window at **BAR0+0x300000** (1 MiB `memcpy_fromio`, mirrors `kgspExtractVbiosFromRom_TU102`), parsed through the PCI chain + NPDE/NVIDIA extension images, version-checked (`fwsec_version=3`, GSP `engine_mask==0x400`), FRTS offset patched into the image, signature chosen by fuse version among 3×384 B sigs | `Z:unlock_610.c:775-860`; `Z:registers.h:10` |
| FB geometry detected at runtime from BAR0 `0x1183a4` (MB) — `usable_fb = mb<<20`, VGA/PRAMIN top-1 MiB fallback | `Z:unlock_610.c:486-511`; `Z:registers.h:64` |
| `GA102(0x220d)` in their family table; register constants identical to our lineage | `Z:recipes.c:419`; `D:upstream/zagitta-gpu-unlock/README.md:26-29` |

### 1d. llm2 ground truth (campaign measurements that constrain the design)

- **W0 probe** (`D:pre-driver-probe-w0.md`): PCI option-ROM BAR is zeroed by
  firmware (no sysfs `rom`), **but the BAR0 `0x300000` PROM window reads fine**
  and the PROM carries the FWSEC V3 descriptor (`@0x41208: version=3,
  engine_mask=0x400, ucode=9, image 0xEA00, dmem 0x800, pkc 0x5A4`, 3 sigs
  sigver 0x7) — exactly the shape the port needs; parsed by
  `tools/parse-prom-fwsec.py` (faithful port of Zagitta's `vbios_610.c`).
  Mask baseline at production boot: `0x823804=0xffffffff` (production canary
  opens it every boot), `0x823800/0x823b04=0xffffff8f`, `0x88fe8=0xffffffcf`,
  `0x88ff4/0x8e1b0/0x8200d0=0xffffff8f`; FLReset+ present; Secure Boot off.
- **The 6-write frame already lands 5 masks on THIS card in one execution**:
  W3b–W3h, pre-driver ko ladder cycle-1 window `0:6` landed
  `0x823804, 0x88fe8, 0x88fec, 0x88ff0, 0x88ff4` — eight identical
  reproductions; landed frames **survived FLR + production bind**
  (`D:success-recipe.md:24-45,327`; executor law "WPR_CFG first, FEAT before
  0x823800" `D:success-recipe.md:§3.1`). The remaining law: the standalone ko
  fires **exactly once per boot** (2nd SEC2 launch in-load times out `-110`;
  re-claim later refused `-114`) — which is precisely what the EFI's own
  fresh FWSEC re-prime is meant to sidestep.
- **The 34-mask apply table** (values all `0xffffffff`): FEAT bootstrap
  `0x823804`; XVE `0x88fe8/8fec/8ff0/8ff4/8ff8/8ab4`; XP3G
  `0x8e1b0..0x8e1f0` ×17; OPTB `0x8200d0..0x8200f4` ×10; `FEAT_OVR_ECC
  0x823800`; GFX PLM `0x823b04` — `D:rejoin16-RESEARCH-NOTES.md:104-118`;
  hazards: never `PL_LINK_RATE` before `LINK_CONFIG_0`; never keep poking a
  card that reads `0xffffffff`; `OPT_GEN23`/`VSEC_DEVICE` are fuse-shadowed
  (no chain effect — skip) `:129-139`; "Gen2 provably works with OPTB locked"
  (rejoin16 cited in `WF:unlock_v2.c:5051-5057`).
- **Minimal Gen2 set bisect** (another owner's clean GA102, same VBIOS family):
  `{0x823800, 0x88fe8}` suffices (XVE_A covers `PRIV_MISC_1 0x8841c` + LTSSM
  `0x8872c`); XP3G/OPTB/other-XVE/`0x823b04` not required for Gen2 —
  `D:upstream/wh1stle05/docs/PCIE-GEN2-FINDINGS.md:7-38`. Also: a fresh
  first Booter write often reads NO-EFFECT at polls=1000 while an identical
  second write lands `:87-90` → per-write retry is part of the gate design.
- Wedge semantics (map glossary, `.scratch/90hx-gen2-610/map.md` "Notes"):
  *mask open* = exact `0xffffffff` **with an independent wedge guard**;
  `0xffffffff` from an unreadable device means error, not open.

---

## 2. Port work items

Base: new translation unit `efi-unlock/unlock90hx_v1.c` (sibling of
`unlock50x_v1.c`, same build/sign/install skeleton), seeded by diffing the two
already-related files (50HX descends from the GA102 lineage; keep all shared
helpers byte-identical where behavior is common).

### W-1 Target identity & card find
**Change:** accept only `10de:220d` (subsystem `10de:1555` logged, not
matched — future SKUs); BOOT0 arch check becomes `0x17<<24` (GA102) instead of
`0x16<<24` (pattern: `E:unlock50x_v1.c:4750-4756`); per-card log
`\90hx_log.txt` with the open-append-close-per-line logger (0-byte-log lesson
`E:README.md:379-380`); keep the fast-probe + bus-sweep + CF8 fallback.
**Evidence:** `WF:unlock_v2.c:9-11` (identity), `E:README.md:94-99`.
**Effort/risk:** S / low. Subsystem mismatch = log-and-continue only.

### W-2 GA102 chipId0 / FALCON boot base / engine-model differences vs TU102
**Change (each value is WildFlash-proven, not inferred):**
1. **GSP_RM (FWSEC path):** replace the hard-coded `0x162000A1`
   (`E:unlock50x_v1.c:1425`) with a **live `NV_PMC_BOOT_0` read** — GA102 =
   `0x172000A1` (`WF:unlock_v2.c:1323,2631` write
   `mmio_read32(0x00100000)`).
2. **SEC2_RM (booter load):** keep `0xb72000a1`, the driver-trace value both
   lineages write on GA102 and on our TU102 build (`WF:unlock_v2.c:1744-1747`;
   `E:unlock50x_v1.c:1827-1830`); log BOOT0 alongside.
3. **Booter image & geometry:** GA102 SEC2 booter `0xEC00` bytes, `SIG_PROD`
   patched at `0x8A10` → `hsSigDmemAddr=0x10`, ucodeId **3**
   (`WF:unlock_v2.c:179-191`; `Z:recipes.c:246-259`) vs TU102 `0x8700`/
   ucodeId 13 (`E:unlock50x_v1.c:400-425`).
4. **FWSEC boot model:** GA102 is **V3 direct** (BROM params: ucodeId 9,
   ENGIDMASK `0x400`, PARAADDR0 = sig DMEM addr `0x5A4`, MOD_SEL RSA3K, DMEM
   patch sig@`0x5A4` + FRTS mapper cmd `0x15` — `WF:unlock_v2.c:289-317,
   1249-1460`) vs TU102 V2 WITH_LOADER over `bl_gsp_tu102.bin`
   (`E:README.md:352-361`). GA102-only stages: GSP BL ucodeId=1 (IMEM
   `0x4000`/DMEM `0x2400`, sig copy `0x8A10→0x6010`, MAILBOX0=0xFE,
   `WF:unlock_v2.c:2052-2085`), and **ResetIntoRiscv + LibosBootArgs** before
   the Booter load (BCR `0x111` RISCV|VALID|BRFETCH; mailboxes = WPR-meta phys;
   `:2091-2115`). GSP `HWCFG2.RESET_READY` works, **SEC2's does not** (poll
   must be timeout-tolerant there) — v2.80 comment `:2091-2098`.
5. **WPR meta below 4 GB is mandatory on GA102:** the GA102 booter reads
   mailbox0 as a 32-bit address; meta above 4 GB yields garbage (`exit 0x91`) —
   `cmp90_meta_low()` fresh copy at every use (`WF:unlock_v2.c:1575-1605,
   1663-1666`). Our TU102 build deliberately removed the low-copy (TU102
   booter is 64-bit LO32/HI32, `E:unlock50x_v1.c:1746-1749,2294-2300`); the
   GA102 build **must keep it**. Other exploit buffers stay >4 GB as in the
   proven flow (`WF:unlock_v2.c:618`, `E:README.md:101,141-144`).
6. **Scrub/reset hygiene (GA102-specific):** driver-faithful
   `kflcnPreResetWait` (HWCFG2 bit31) + post-reset **scrub wait**
   (DMACTL[2:1]==0 ∧ HWCFG2[12]==0, else DMA races the `DEAD5EC*` scrubber) —
   `WF:unlock_v2.c:1122-1163`; SEC2 reset order **ENGINE reset → BCR
   switch-to-Falcon (0x0, fallback 0x1)**, never BCR first
   (`WF:unlock_v2.c:1668-1687`).
**Effort/risk:** L / medium-high — this is where a wrong constant wedges the
card. Mitigation: take WildFlash's sequence *whole* (it is the proven GA102
ancestor for exactly this die), keep our diff surface to shared helpers,
add the boot-state dump before the first write.

### W-3 GFW kill & FWSEC re-prime (the run-1 engine)
**Change:** GFW wait (`GFW_BOOT_OK 0x118234 == 0xff`) + PTIMER RTC seed
(`WF:unlock_v2.c:1056-1097`) + GSP `ENGINE` reset kill at `0x1103C0` —
mechanically identical base to TU102 (`E:unlock50x_v1.c:1366-1380`).
Behavioral difference: **do not copy the TU102 "skip FWSEC when WPR2 is up"
fallback** (`E:unlock50x_v1.c:4868-4897`); on GA102 the re-prime *is* the
mechanism. Use WildFlash's unconditional `early_unlock_path()` per mini-cycle
(their bench POST left `WPR2=0x1FFFFE00`, wrong geometry — booter may
validate-and-exit; `WF:unlock_v2.c:1723-1733`). Before the kill, log BOOT0,
GFW, WPR2 lo/hi (the llm2 POST state is unmeasured pre-OS — open question
O-1). Re-prime loop per launch: `FLR → restore BAR0 → BL → FWSEC → WPR2 poll
(FRTS values) → ResetIntoRiscv → crafted booter load → readback gate`
(pattern: `WF:unlock_v2.c:5069-5089`). Force WPR2 to the FRTS pair before the
booter load only if `restore_frts`-equivalent is gated on WPR_CFG being open
(`Z:unlock_610.c:1168-1206` documents that the host WPR2 write is *denied*
until frame 1 opened `0x1fa7cc`).
**Effort/risk:** M / medium. Kill timing on GA102 (RISC-V GSP vs TU102 Falcon)
is WildFlash-proven on *their* board; on llm2 it is O-1.

### W-4 FWSEC/FRTS blob sourcing
**Decision: embed the blob extracted from llm2's own PROM; keep the live read
as a logged probe, not the source of truth.**
- Provenance already exists: `cache/90hx-prom-0x300000.bin`
  (md5 `ac0752e8…`, 1 MiB, W0) parsed by
  `tools/parse-prom-fwsec.py` → FWSEC V3 descriptor `@0x41208` matches the
  GA102 family expectation exactly (`D:pre-driver-probe-w0.md:§2`).
  Step: extend that tool to also emit `fwsec_ga102.bin` (image 0xEA00) +
  the fuse-selected 384 B signature (sigver selection per
  `Z:unlock_610.c:821-833`), i.e. our equivalent of WildFlash's
  `fwsec_ga102.bin + fwsec_ga102_sig.bin` (`WF:BUILDING.md:49`).
- Live-PROM-from-EFI alternative (Zagitta precedent is **under the OS**, BAR0
  `0x300000`, `Z:unlock_610.c:791-800`): pre-OS exposure is unproven — read
  BAR0+0x300000 in EFI and check for the `0xAA55` root + type-`0xe0` chain.
  Falsifiable, cheap, logged in the decisive window (O-5). If it reads, a
  later revision can re-derive FRTS-patched FWSEC per card (product
  generalization, ticket 06+); if not, embedding costs nothing extra.
- `E:extract_fwsec.py` is V2/TU102-specific — **do not port it**; the V3 port
  is `tools/parse-prom-fwsec.py`.
- FRTS offset patching: same primitive either way (rewrite the interface
  `frtsRegionOffset4K = frts>>12`, `WF:unlock_v2.c:1331-1348`;
  `Z:gpu_unlock_fwsec_patch_frts`).
**Effort/risk:** S-M / low — gate dissolved by W0; residual risk is a
firmware update changing the PROM (re-extract from a fresh dump on any FWSEC
hash mismatch, refuse to run rather than run stale).

### W-5 Fake-WPR meta geometry (the "6 GB fbSize variant" question)
**Change:** keep the shared `build_wpr_meta` (already GA102-flavored in both
files: `WF:unlock_v2.c:3688-3747` ≈ `E:unlock50x_v1.c:3288-3347`; GA102 facts:
frtsSize **1 MB**, PRAMIN top **1 MB**, `vgaWorkspaceOffset = fbSize - 1MB`
(no display fuse), 128 KB-aligned wprEnd, heap sizes by fbSize
{10 GiB→`0x7F00000`, 20 GiB→`0xFE00000`, default→`0x6900000`}), but make
`fbSize` **detected, not chosen**:
1. BAR0 `0x1183a4` (FB MB, Zagitta's layout input, `Z:unlock_610.c:486-506`)
   → `fbSize = mb<<20`;
2. cross-check against POST-latched `WPR2_LO/HI` back-derivation
   (`frts = lo<<8`, span `0xE00` — pattern `E:unlock50x_v1.c:611-638`);
3. fall back to `0x280000000` / `FRTS 0x27FE00000` — the WildFlash-proven
   GA102 geometry, back-solved from a working unlock's `frts_offset` dmesg
   (`WF:unlock_v2.c:3664-3674`).
**On "6 GB":** the only repo source for a 6 GB variant is
`D:alt-paths-scope.md:32`; the ticket context carries it forward. Every
*proven* GA102 datapoint in-repo is 10 GB (WildFlash card; a 6 GB entry would
land `fbSize=0x180000000`, `FRTS=0x17FE00000`, default heap `0x6900000` via
the same formula). Resolution = the detection ladder above + the decisive
window logging the actual `0x1183a4`/WPR2 values (O-2). No hardcoded 6 GB
constant is added.
Also carry WildFlash's meta-content verification (magic/heap/sig/flags dump
after the low-copy; `WF:unlock_v2.c:1592-1602`).
**Effort/risk:** S / low; wrong geometry fails closed at the booter
(exit-0x91 class), no card damage.

### W-6 Payload parameterization — replace the blob-refill with an in-binary 6-write frame builder
**Change:** do **not** embed/patch `v67_payload.bin`'s single-write pair
(WildFlash's `value@0xf948` / `reg@0xf960` refill of the bendy2 blob,
`WF:unlock_v2.c:5044-5082`; terminator `0x81ee@0xf9ec` model,
`D:alt-paths-scope.md:54-57,163-169`). Build the payload **in RAM per launch**
by porting `Z:payload.c:41-65` + `Z:recipes.c:24-53`:
- fill the `0xFA00` image with `0x0000019c`;
- write the static GA102 words: `0x1100=0x7`; `0xf93c/54/6c/84/9c/b4=0x6140`
  (canary-pointer r3 per frame); ret-gadgets
  `0xf950/68/80/98/b0/c8=0x1110` (`reg_write_indirect` entry, r0=addr, r1=val,
  prologue-skipped so `r3` must point at a word equal to r9 — `0x6140` holds
  the same canary); frame-6 cleanup `0xf9cc=0x6140`, `0xf9d8=0x3`,
  `0xf9e0=0x576b`, `0xf9e4=0x84c8`, `0xf9f0=0xd52`, `0xf9f4=0x81ee`
  (HS clean exit; note the terminator sits at `0xf9f4` in the 6-write layout,
  not `0xf9ec`);
- write the launch's ≤6 `(value, addr)` pairs into slots
  `(0xf944,0xf948) (0xf95c,0xf960) (0xf974,0xf978) (0xf98c,0xf990)
  (0xf9a4,0xf9a8) (0xf9bc,0xf9c0)` — **value word first, address word at
  +4** (`Z:payload.h:24-26`); unused slots repeat the last pair (fill rule,
  `Z:unlock_610.c:1230-1233`);
- point the WPR-meta signature fields (`meta+72` = crafted DMA, `meta+80` =
  `0xfa00`) at the built image before each launch, restore the stock pointer
  at the end (`Z:unlock_610.c:1156-1166,1284-1288`) — stock-signature
  contract for the OS-side production canary;
- per-launch gating (from `Z:unlock_610.c:1209-1330`, ported to EFI polling):
  prior invocation **HALT evidence** (`CPUCTL` bit4 ∧ `RESET_PLM==0xff`
  reopened ∧ reset/reload/started ledger — `:1081-1092`) before any refill;
  WPR2/FRTS restore via host write before launches ≥2 (works only because
  frame 1 opened WPR_CFG); pre-launch readback must not be `0xbadf0000`;
  ≤2 attempts per batch; per-write readback after completion.
Rationale for one crafted launch per mini-cycle (not WildFlash's stock#1 +
crafted#2): we need **no** stock execution — the crafted table itself carries
`WPR_CFG + FEAT bootstrap` in frames 1–2 (`Z:recipes.c:200-203`), and llm2 has
already landed exactly this kind of launch pre-driver (W3 rows). It also
sidesteps both conflicting bench laws (2-per-prime vs unlimited-per-prime vs
1-per-boot): the design never depends on a second execution after one prime.
**Effort/risk:** M / medium. Failure mode = dead chain (no effect / no halt),
fail-closed; a wrong slot order (addr vs value) is a *silent wrong-address
write* risk — hence the mandatory offline frame test (W-11) and ticket 03's
unit gate on the frame bytes.

### W-7 Ladder packing — 34 masks → 6 launches (+1 optional GFX)
Table = the proven rejoin16 order (`D:rejoin16-RESEARCH-NOTES.md:104-118`,
`WF:unlock_v2.c:1027-1045`), all `0xffffffff` unless noted. Ordering rules:
**WPR_CFG_PLM `0x1fa7cc=0xfffff0ff` first** (executor law,
`D:success-recipe.md:§3.1`; expected readback is `0xfffff0ff`, not FF);
**FEAT bootstrap `0x823804` next**; `0x823800` only after `0x823804` (PLM
law); `0x823b04` last (FEAT page); Gen2-critical tier first (Wh1stle05:
`0x823800` + XVE `0x88fe8` suffice on their bench
`D:upstream/wh1stle05/…:15-35`).

| Launch | Frames (addr = value) |
|---|---|
| L1 | `0x1fa7cc=0xfffff0ff`, `0x823804`, `0x823800`, `0x88fe8`, `0x88fec`, `0x88ff0` |
| L2 | `0x88ff4`, `0x88ff8`, `0x88ab4`, `0x8e1b0`, `0x8e1b4`, `0x8e1b8` |
| L3 | `0x8e1bc`, `0x8e1c0`, `0x8e1c4`, `0x8e1c8`, `0x8e1cc`, `0x8e1d0` |
| L4 | `0x8e1d4`, `0x8e1d8`, `0x8e1dc`, `0x8e1e0`, `0x8e1e4`, `0x8e1e8` |
| L5 | `0x8e1ec`, `0x8e1f0`, `0x8200d0`, `0x8200d4`, `0x8200d8`, `0x8200dc` |
| L6 | `0x8200e0`, `0x8200e4`, `0x8200e8`, `0x8200ec`, `0x8200f0`, `0x8200f4` |
| L7 (optional) | `0x823b04` (+5 fills) — GFX render bin, **not** Gen2; skip in v1 |

35 Gen2-relevant writes over 6 launches. Notes:
- **Re-prime per launch** (W-3), each an independent run-1 — never a 2nd
  crafted execution riding the previous prime (the 615 TU102 negative
  `docs/CMP50HX-615-UNLOCK-INVESTIGATION.md:41-55` and llm2's `0/49` both say
  don't).
- `0x823804` is included once (frame 2) and re-opened **only if the sweep
  finds it re-locked** (it survives FLR on WildFlash's bench
  `WF:unlock_v2.c:5023-5024`; whether an FWSEC re-prime re-locks it on llm2
  is measured by the L1 sweep, zero cost).
- OPTB tier may be **skipped wholesale** without losing Gen2
  (`D:rejoin16-RESEARCH-NOTES.md:190` "Gen2 works without it";
  `WF:unlock_v2.c:5051-5062` skips it after guest resets on their stand;
  Wh1stle05 confirms not required). Shipped order keeps it (proven-superset
  contract) but the ladder accepts tier-skip via load option for
  risk-reduction in early windows. If OPTB is skipped: L5/L6 collapse → 5
  launches.
- **Host-side speed path and link retrain are NOT in this ladder.** They run
  OS-side in the existing 0016/0017 module (two controlled kernel-context
  points + retry retrain, `D:rejoin16-RESEARCH-NOTES.md:119-127`,
  `D:upstream/wh1stle05/docs/PCIE-GEN2-FINDINGS.md:40-62`) once the EFI hands
  over masks open. Deliberate: pre-OS EFI-side retrain/TLS is where the 50HX
  product hung X99/X299 boards (`E:README.md:260-266`), the LTSSM kick hard-
  hangs real WildFlash hardware (`WF:docs/GOTCHAS.md`), and llm2's WD window
  measured card-side LNKCTL2 writes dropped even with XVE masks landed
  (`D:success-recipe.md` §5) — retrain is kernel-context work, mask-opening is
  chain work; the EFI does only the latter. WildFlash's phase3
  (`WF:unlock_v2.c:5208-5295`) stays available as an explicitly
  compiled-out experiment.
- Multipass sweep (W-8) replays any launch table idempotently; near-FF
  registers can need a 2nd/3rd pass (`WF:unlock_v2.c:5037-5115`).

### W-8 Per-iteration readback gate + wedge-sanity (BAR0 MMIO pre-OS)
- BAR0 MMIO pre-OS works (both lineages are built on it; `enable_mem_decode`
  + config-space BAR restore after FLR, `WF:unlock_v2.c:5340-5348`).
- Per launch: build → load → poll **exact expected value** per frame
  (async write; ≤1000×1 ms poll per register, `WF:unlock_v2.c:5084-5089`),
  then a **full-table sweep** with exact-value criterion (FF-exact; WPR_CFG
  expects `0xfffff0ff`) — after-launch sweep is the ladder's progress state,
  enabling pass-2/3 with pre-check skip of already-exact entries
  (`WF:unlock_v2.c:5063-5065,5097-5115`).
- **Retry semantics:** one re-attempt inside the launch (Wh1stle05 fresh-mask
  NO-EFFECT→OK behavior, `D:upstream/wh1stle05/…:87-90`) before declaring
  NO-EFFECT.
- **Wedge-sanity rule** (map glossary): an exact-FF read counts as *open* only
  when the independent guard is healthy — config-space
  vendor/device `== 0x10de:220d` and `BOOT0 != 0xffffffff`, read before each
  launch and after each FF readback. Guard bad ⇒ **wedge, not open** ⇒ stop
  writes (rejoin16 hazard: never keep poking a `0xffffffff`-reading card,
  `D:rejoin16-RESEARCH-NOTES.md:131-137`), still run the handoff tail (W-10).
  Any read with `(v & 0xffff0000) == 0xbadf0000` = privilege-gated/unreachable
  (Zagitta's gate, `Z:unlock_610.c:1262-1272,1290-1297`), never treated as a
  value.
- All gate outcomes logged with PTIMER timestamps to the ESP log (the log, by
  itself, never grades anything — see ticket 04's mmap-readback grading).

### W-9 ESP / BootNext integration
- Installer variant of `E:install-linux.sh`: copy to `\EFI\90HX\90HXG2.EFI`,
  entry "90HX Gen2", **BootNext one-cycle first** (auto-fallback on hang),
  BootOrder promotion only after the acceptance boots; read back `BootOrder`/
  `BootNext` after every write (`E:install-linux.sh:161-195`). The deb already
  manages the 50HX side with `CMP_ESP_SKIP=1` on 90HX hosts
  (`D:alt-paths-scope.md:21-28`) — ticket 06 folds the 90HX entry into it.
- **Independence from the 50HX unlockers:** each app binds exactly one device
  id (1e09 vs 220d; `E:README.md:94-95,328-329`), all exploit state is
  per-card; BootOrder position only adds pre-OS wall time. Recommended order:
  `U1(01) → U4(04) → 90HX → OS`, all as firmware boot entries — the proven
  FORCE_RETURN chaining shows entries run back-to-back **without an
  intervening GPU POST** (`.scratch/warm-multi-unlock/issues/03:22`,
  `.scratch/615-port/research-11-booter-analysis.md:208`). During gated
  windows the 90HX entry is reached via **BootNext only** (one cycle, no
  standing change to BootOrder).
- **FORCE_RETURN:** keep the compile-time flag (`E:unlock50x_v1.c:4718-4720`;
  llm2 firmware can't take dash-leading load options via efibootmgr, so the
  bench builds use the flag). Semantics preserved: return-to-firmware, no
  chainload.
- **Chainload-always policy (default build):** preload the OS loader into RAM
  **before** any unlock activity (own FAT parser on BlockIo, no SFS —
  `E:README.md:114-126`), then after the ladder + tail, chainload it with no
  POST so the opens survive; fallback order = BootNext-file paths →
  shim/grub/systemd-boot/bootmgfw → ESP filename walk → return to firmware.
  WildFlash's bare return-to-firmware is the *last-resort* (their boards
  hang NVRAM/SFS post-unlock, `WF:unlock_v2.c:5306-5322`; our v71fix note
  shows some firmware re-inits on return, `E:unlock50x_v1.c:5087-5090`) —
  both hands are kept, chainload first.
- **Zero NVRAM writes after the first unlock action** (SMM hang,
  `WF:docs/GOTCHAS.md`; `WF:KNOWN-ISSUES.md:66-70`): no WildFlash-style
  boot-to-boot NVRAM counters — the 6-write frames make the ladder finish in
  one execution of the app; the only NVRAM traffic is efibootmgr from Linux.

### W-10 Failure policy (fail-closed ladder)
- Any launch NO-EFFECT (after its in-launch retry) ⇒ **stop the ladder**, skip
  remaining launches; never re-run a failed launch a third time; never fight
  the next boot ("any NO-EFFECT ⇒ stop, stay Gen1, serve" —
  `D:alt-paths-scope.md:42-43,137`; `.scratch/90hx-gen2-610/map.md`
  acceptance #5).
- Wedge detected at any point (guard bad) ⇒ stop writes immediately, still run
  the handoff tail.
- **Handoff tail always** (mirrors `WF:unlock_v2.c:5324-5351`): kill the SEC2
  ROP spinner (ENGINE toggle) → **final FLR** (the only reset that clears a
  latched WPR2; masks/selectors survive it — `WF:unlock_v2.c:46,5022-5030`;
  llm2 evidence `D:success-recipe.md:327`) → restore BAR0 config → no MMIO
  after the FLR → chainload OS. Rationale: a latched WPR2 + live spinner
  handed to the OS GSP boot is the Code-43 class failure
  (`WF:KNOWN-ISSUES.md:20-23`); FLR+production-bind is exactly the state the
  production 610 canary re-opens FEAT from every boot
  (`D:pre-driver-probe-w0.md:§3`).
- Card left as today on any failure: **Gen1 + compute-unlocked**. The ladder
  never writes SS0/SS1 or the speed path; production in-kernel V67 keeps doing
  compute every boot regardless.

### W-11 Build & sign procedure (ticket-03 gates; PASS-marker discipline)
Build: `efi-unlock/build-90hx-efi.sh`, a clone of `E:build.sh` (gnu-efi ELF
link; per-blob `nm` symbol assertions; `-j .reloc`; **plus `-j .rodata*`** —
the gnu-efi ≥3.0.18 string-section trap, `WF:BUILDING.md:20-27`):
- blobs: `booter_ucode_prod_ga102.bin` (`0xEC00`, SIG_PROD patched at `0x8A10`
  per `WF:docs/RE-PATCH-PROCEDURE.md`, from the pinned-610.43.03 bindata we
  hold; Zagitta's `fetch_artifacts.py` route is an equivalent source),
  `gsp_rm_boot_ga102.bin` (GspRmBoot `0x6000`), `fwsec_ga102.bin(+sig)` from
  W-4. No `v67_payload.bin` needed (frame builder in-binary; keep the blob
  only if the single-write fallback is ever enabled). `gsp_ga10x.bin`:
  WildFlash streams it from USB for the radix3 table
  (`WF:BUILDING.md:71-76`); the 50HX dummy-FW precedent (`E:README.md:101-103`)
  suggests a same-size dummy suffices — **decide by dry-run in ticket 03**,
  risk noted, not a blocker either way.
- Frame-builder unit test (no GPU): build each of the 6 planned launch tables,
  assert image bytes at every slot/word offset from the tables in §1c (fill
  `0x0000019c`, `0x1110` ret-words, terminator `0x81ee@0xf9f4`,
  slot `(val,addr)` order, fill-rule repeats) → marker.
- Absent-card path: on the dev box (no 220d) the app must log `GPU not found`
  and exit clean without touching NVRAM/other GPUs.

Proposed markers (mirroring `PASS_CMP50HX_*`, `build.sh:288,318`,
`install.sh:409-428`):
- offline: `PASS_CMP90HX_EFI_BUILD <artifact-dir>` (+ sha256 of
  `90HXG2.EFI`), `PASS_CMP90HX_EFI_SIGN` (sbverify-listed),
  `PASS_CMP90HX_EFI_FRAME` (frame unit test), `PASS_CMP90HX_EFI_NOCARD`
  (clean absent-card exit);
- runtime ESP-log lines (telemetry only, never grading):
  `PASS_CMP90HX_L1_LANDED`, `PASS_CMP90HX_LADDER_DONE` (sweep all-exact with
  guard healthy);
- OS-side (ticket 05/06 scope): `PASS_CMP90HX_EFI_HANDOFF` (post-boot mmap
  agreement + zero Xid), `PASS_CMP90HX_GEN2_LANDED` (`LnkSta 5.0GT/s` +
  `pcie.link.gen.current=2` after retrain).
Build host: same Ubuntu 24.04 + gnu-efi recipe as 50HX (`E:README.md:176-186`).

---

## 3. Decisive-first window design (what ticket 04 runs)

**One execution, one launch, nothing else.** Sequence: banner → find 220d →
enable BAR0 → *log-only* pre-state (BOOT0, GFW, WPR2 lo/hi, FB-size `0x1183a4`,
first 16 words of the `0x300000` PROM window, all 34 mask addresses + guard) →
PTIMER seed → GFW kill → fresh BL+FWSEC re-prime (WPR2 up on FRTS values) →
**single crafted 6-frame launch**:

| Slot | Write | Why it must be there |
|---|---|---|
| f1 | `0x1fa7cc = 0xfffff0ff` | executor law (WPR_CFG first, `D:success-recipe.md:§3.1`); opens the host WPR2-restore path; readback `0xfffff0ff` proves frame 1 executed |
| f2 | `0x823804 = 0xffffffff` | FEAT bootstrap — the known-reliable run-1 opener (`D:pre-driver-probe-w0.md:§3`); precondition for f3 |
| f3 | `0x823800 = 0xffffffff` | FEAT_OVR_ECC — module gate, required half of the minimal Gen2 set (Wh1stle05) |
| f4 | `0x88fe8 = 0xffffffff` | **the decisive target**: XVE_A covering `PRIV_MISC_1`+LTSSM; W0 baseline `0xffffffcf` makes any change unambiguous |
| f5,f6 | `0x88fe8` (repeat fill) | Zagitta fill rule; idempotent |

Readback gate per frame (W-8) + halt evidence before declaring anything;
then handoff tail (W-10) + chainload; **no second launch regardless of
outcome** (one window, one verdict — ticket 04).
Grading is kernel-side mmap readback with the wedge guard after boot, never
the EFI log alone (ticket 04 wording).

What each outcome tells us (why this minimal set is informative):
- f1–f4 all exact (or f1–f3 exact + f4 exact after boot): fresh-FWSEC run-1
  works pre-OS **and** the 6-frame machine executes past frame 4 on this card
  → pre-OS is the live path → ticket 05 (ladder = 6 more-ish launches).
- f1–f3 land, f4 does not (guard healthy, value stuck at `0xffffffcf`): the
  chain executed and the fresh prime is healthy, yet the XVE mask resists even
  pre-OS → every vehicle class refused on this card → ticket 07 (bound
  closure) with a *mechanism-attributed* negative.
- Nothing lands / no HALT evidence: pre-OS execution itself dead on this card
  → ticket 07, attribution = execution channel.
- Guard goes bad (all-FF + `0x10de:220d` unreadable): wedge, not landing —
  logged, FLR tail, honest negative on the window.
Side-bonus: the window's log-only pre-state answers O-1/O-2/O-5 telemetry at
zero extra risk.

---

## 4. Open questions — answerable only by hardware / EFI execution
Each phrased as a falsifiable check; all are logged by the first boots.

- **O-1 · GA102 GFW-kill timing & POST state on llm2.** Does the GSP ENGINE
  reset kill POST's GFW and leave WPR2 down (or at `0x1FFFFE00` as on
  WildFlash's bench), and does our own BL+FWSEC re-prime then latch WPR2 to
  the FRTS pair? *Check:* EFI log — WPR2 before kill, +100 ms after kill, and
  post-FWSEC-poll must equal the geometry pair (e.g. `027fe000:027fee00` on
  10 GB). *Falsified if:* SEC2 stays `0xbadf56xx` after the kill, or WPR2
  never latches ≤5 s (then: per-launch re-prime is impossible and the ladder
  design collapses to one launch per boot → bound closure).
- **O-2 · Real FB geometry (the "6 GB variant" claim).** *Check:* log
  `0x1183a4` (MB) + POST-latched WPR2 back-derivation at first EFI entry.
  Expected 10240 / `0x27FE00000`; any other value (e.g. 6144 →
  `fbSize=0x180000000`, `FRTS=0x17FE00000`) is auto-adopted by the W-5
  detection ladder. *Falsified if:* detection contradicts a successful
  unlock's FRTS evidence (then geometry source precedence flips).
- **O-3 · EFI-side readback validity.** Are the 34 mask addresses readable
  pre-OS with meaningful values (not `0xbadf****`, not `0xffffffff` under a
  healthy guard)? *Check:* first-boot baseline sweep must equal the OS-side W0
  row (`0x88fe8=0xffffffcf`, `0x88ff4/0x8e1b0/0x8200d0=0xffffff8f`,
  `0x823800/0x823b04=0xffffff8f`). *Falsified if:* values differ structurally
  → the per-iteration gate must be redesigned (post-boot grading only), which
  is ticket-05 design input, not a silent pass.
- **O-4 · Per-execution runtime vs POST budget.** Wall time of one full
  re-prime+launch (WildFlash ~15 s/mini-cycle → ladder ≈ 1.5–2.5 min, vs the
  37-walk ≈ 10 min that rebooted two boards mid-walk,
  `WF:KNOWN-ISSUES.md:25-33`). *Check:* PTIMER-timestamped ladder log on the
  first full-ladder boot; boot completes and the app reaches the handoff tail.
  *Falsified if:* firmware resets the machine at N launches — then tier-split
  the ladder (OPTB-first drop, Wh1stle05 minimal-first) or accept one launch
  per BootNext cycle.
- **O-5 · Pre-OS PROM-window FWSEC exposure (completes the ticket-01 probe).**
  Under the OS the BAR0 `0x300000` window reads and parses clean
  (`D:pre-driver-probe-w0.md:§2`); pre-OS it is unmeasured. *Check:* EFI reads
  `BAR0+0x300000`; first word must be `0xAA55`, chain must reach the type-`0xe0`
  extension. *Falsified if:* gated (`0xffffffff`/`0xbadf`) — embedded blob
  (W-4) already covers it; only the per-card live-source upgrade dies.
- **O-6 · Multi-prime independence (ticket-05 gate, one notch past
  decisive).** Does launch L2 after a **second** in-app FWSEC re-prime also
  land, i.e. is run-1 genuinely per-prime on this card (WildFlash: 2
  executions/prime; Zagitta: many; llm2 ko: 1/boot — all disagree)?
  *Check:* in the first LANDED boot of ticket 05, L2's fresh masks land and
  the sweep gains ≥1 exact per launch. *Falsified if:* L1 lands and L2 never
  does → per-boot capacity = 1 launch = 6 masks → ladder spans BootNext
  cycles (masks survive warm? re-lock 7/7 on this host,
  `.scratch/90hx-gen2-610/map.md`) or closure.
- **O-7 · OS-handoff acceptance on Linux.** After SEC2 kill + final FLR +
  chainload with masks open, does the production 610 GSP boot come up clean
  (zero Xid, bind OK, its own canary re-opens FEAT, landed masks still exact)?
  W2/pre-driver bind precedent (`D:success-recipe.md:327`) says yes; the
  Code-43 Windows datapoint says the tail is mandatory
  (`WF:KNOWN-ISSUES.md:20-23`). *Check:* post-boot 0 + readback row.
  *Falsified if:* Xid storm / bind fail → keep tail but drop the re-prime's
  WPR2 latch via fuller cold-state sanitize (50HX sanitize pattern,
  `E:unlock50x_v1.c:5014-5047`).

---

*End of plan. Implementation lives in ticket 03; nothing here authorizes a
hardware window by itself — windows are scheduled only from ticket 04's gate.*
