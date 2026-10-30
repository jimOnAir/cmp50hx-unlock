# PCIe gen feasibility — the 170HX Gen3 guide vs our CMP 50HX / CMP 90HX fleet

Researched 2026-10-30. Answers the question raised by
[lixiangwuxian/170hx_tips `Gen3_unlock_en.md`](https://github.com/lixiangwuxian/170hx_tips/blob/main/Gen3_unlock_en.md):
can its CMP 170HX PCIe Gen3 enablement be applied to our cards? Short answer:
no, not as written — the guide is GA100-specific. Each card × gen verdict
below, with the mechanism, the proven ceiling, and the evidence.

## Verdict matrix

| Card | Gen | Verdict | Mechanism / blocker | Proven ceiling | Evidence |
|---|---|---|---|---|---|
| CMP 50HX (TU102, `10de:1e09`) | Gen2 | **✓ shipped** | XP3G PLM open + Gen2 policy writes + endpoint/bridge retrain, all kernel-side, OS-only | Gen2 at board-wired ×4 | patches `01`/`04`; README link section; 2026-08-12 capture (below) |
| CMP 50HX | Gen3 | **✗ as per guide / ? open research** | Guide's `OPT_GEN23`/`OPT_GEN3` regs proven **unmapped on TU102**; XP3G block PLM-locked pre-patch. Leads: stock-GSP `RMPcieLinkSpeed` policy branches; pre-OS barred (issue #25) | even unlocked, ~3.4 GB/s (×4 wiring) | `experiments/cmp50-pcie-gen2/runs/20260812T1317Z-170hx-regset/capture.txt`; IDA pass (`RMPcieLinkSpeed` @ `0x4cb25b8`, see `docs/CMP50HX.md`); README §pre-OS |
| CMP 90HX (GA102, `10de:220d`) | Gen2 | **✓ proven upstream** (port = tickets 03–04) | Cap is PLM-protected registers, **not** a hard PHY fuse: 34 mask opens via one-privileged-write-per-load (V67 chain), then kernel-context speed path + bridge retrain | Gen2 (`LnkSta 5GT/s` live) | jdowning100/cmpunlocker rejoin16 + research notes; cold-boot validated 2026-08-16 |
| CMP 90HX | Gen3 | **✗ no demonstrated path** | `OPT_GEN23` (`0x82057c`) and `VSEC_DEVICE` (`0x8860c`) do not take writes **even via the exploit chain** (fuse-shadowed); no alternative demonstrated | Gen2 is the ceiling | rejoin16 notes §Hazards |

## Why the 170HX guide does not port

The guide targets the CMP 170HX (`10de:2082`, GA100) and leans on
GA100-specific surface at every step: probe fuse registers `0x820250`/`0x820580`
with `EN_SW_OVERRIDE` at `0x820040`, a post-GSP RM policy patch gated on device
ID `2082`, and RM-side link training via `SET_PCIE_SPEED`. The guide itself
warns against generalizing, and its own validation section records one card
lost during a Gen3 transition.

- **On TU102 (50HX)** the guide's OPT register set is not merely locked but
  **unmapped** — proven by our read-only capture of 2026-08-12
  (`docs/CMP50HX.md`, run `20260812T1317Z-170hx-regset`: config-space and BAR0
  mirror both read as unclaimed; the same capture shows `LinkCap2=0x0002`,
  2.5 GT/s only, and the XP3G override block PLM-locked).
- **On GA102 (90HX)** the same-named OPT registers exist but are
  fuse-shadowed: the rejoin16 work established they "do not take writes even
  via the chain" — so not even our privileged-write route can use them.
  bendy2's warning (in the V67 exploit lineage, bendy2/cmp90hx) against
  copying GA100 Gen2 sequences to `220d` was correct — the register map
  differs — but it was never an impossibility proof for a *native* path; see
  the 90HX Gen2 verdict.

### 170HX disable-path deep dive (2026-10-30, first-party GA102 reads)

Porting the guide's fuse-override to the 90HX was proposed as a possible
bypass of the V67 run-#2 wall (windows #6–#7 closed that wall host-side).
Read-only BAR0 capture on llm2's 90HX (`0000:03:00.0`, driver bound, mmap —
the guide's own access pattern) settles it. The GA100 fuse block **maps at
identical offsets on GA102**:

| Register | GA102 read | Meaning for the port |
|---|---|---|
| `DISABLE_SW_OVERRIDE 0x820084` | `0x00000001` | **bit0 burned** — the guide's own guard (`if (rd & 1) skip: "fuse is burned"`) refuses this card class outright |
| `EN_SW_OVERRIDE 0x820040` | `0x00000001` | reads 1 yet is not in effect (next row) — not a usable entry point |
| `STATUS_OPT_GPC 0x820c1c` | `0x0000000c` | tracks **fused** `OPT_GPC_DISABLE 0x820350 = 0xc`, not the `_CP` shadow `0x82022c = 0x8` ⇒ consumer reads fuses, override shadow dead |
| `OPT_DISABLE_GEN3_SPEED 0x820250` / `OPT_PCIE_BOOT_GEN3_DIS 0x820580` | `1` / `1` | the two Gen3-disable bits the guide clears are burned on GA102 too — and with `DISABLE_SW_OVERRIDE` burned there is no supported clear path |
| `0x8841c/0x880a8/0x88610/0x8872c/0x8c040/0x8c1c0/0x8c2c0/0x8b8c0` | plausible GA100-consistent values | guide's post-GSP PHY set maps on GA102, but the enclosing 0x88xxxx XVE block is PLM-armed (`0x88fe8 = 0xffffffcf`) — CPU-writing these is exactly the privilege rejoin16 run #2 cannot obtain on llm2; no bypass |
| cfg space `LnkCap`/`LnkCap2` | 2.5 GT/s only | speed capability fuse-shadowed into config space ⇒ stage 3 (`NV2080_CTRL_CMD_BUS_SET_PCIE_SPEED` + LnkCtl2) has no Gen3 capability for RM to adopt; and the guide's `RmForceEnableGen2`/`RMPcieLinkSpeed` ride `NVreg_RegistryDwords`, which breaks stockflow GSP boot on our cards (documented landmine, findings 2026-08) |

**Verdict: the 170HX disable-fuse path is not applicable and not portable to
the CMP 90HX.** Stage 1 is factory-fused off by `DISABLE_SW_OVERRIDE`; stage 2
needs the same PLM privilege our wall lives behind; stage 3 has no capability
to train to and arrives via a poisoned config channel. The two mechanisms are
orthogonal SKU-enforcement classes: GA100 CMP ships with software-override
*fuse disabled* (their path is CPU-side from probe), GA102 CMP ships with it
*enabled* (our only path is the SEC2-side V67 chain — the thing we are
already running). One card lost during the GA100 procedure additionally
bars any experimental "override the override" attempt on a production fleet
card under our fail-closed policy.

An earlier analysis claiming the 90HX link is immutably eFuse-locked
(WildFlash1st/cmp90hx-unlock, 2026-08-17; its README — vendored as
`docs/cmp90hx/rejoin15-README.md` at commit `76940ae` — records "the link
stays Gen1 x16 … and is fused") is **refuted for Gen2** by rejoin16's live
`LnkSta 5GT/s` and its cold-boot validation: the enforcement is privilege
masks, and the speed path can be applied from kernel context on every boot.

## 50HX Gen3 — remaining leads (research only)

1. **Stock-GSP policy branches.** The IDA pass over
   `gsp_tu10x_610.43.03.elf` located `RMPcieLinkSpeed` @ `0x4cb25b8`
   (documented in `docs/CMP50HX.md`); unexplored target values `3`/`4` inside
   the speed-policy routine + our already-working capability-publish path are
   the native way a Gen3 policy could be adopted without inventing a fuse
   story. Gain is bounded anyway: the SKU is board-wired ×4, so Gen3 ≈ 3.4
   GB/s vs today's ≈ 1.7 GB/s.
2. **Pre-OS is closed.** The only firmware-side Gen attempt was retired after
   pre-OS retrain hung X99/X299 hosts (issue #25, recorded in README); the
   shipped design keeps every link operation OS-side.
3. Our XP3G mechanism (the shipped 50HX Gen2 path) remains the TU102-native
   equivalent of the guide's "override + policy + adopt" pattern — a Gen3
   experiment would extend *that*, not the GA100 guide.

## 90HX Gen2 in one paragraph (port spec lives in the tickets)

GA102's V67 chain (already used by the compute unlock we vendor) yields
**one** crafted Booter write per FLR-separated module load; opening the 34
privilege masks therefore costs 34 reload cycles (~7–8 min), after which the
patched module writes the Gen2 speed path from kernel context at two fixed
points and toggles the bridge retrain. Masks re-latch on every **cold** boot;
warm reboots preserve XVE/XP3G/FEAT (OPTB re-locks; Gen2 trains without it).
Field refinements and hazards are recorded in iatethelogs/cmp90hx_pwner
(re-lock `SS0`/`SS1` before unload; `0xffffffff` BAR0 = wedge, stop; Debian 13
`readback=none` loop, issue #7; multi-socket XVE-PLM open failures, issue #2).
Our integration plan: `.scratch/90hx-gen2-p2p/issues/03–05` (baseline, fail-closed
boot service, time-reduction research incl. three alternate unlock
architectures).

## Open contradiction — 90HX lane width (settled by ticket 01 probe)

- jdowning100's research notes: ships fused to "Gen 1 (2.5 GT/s) **x4**".
- Our vendored rejoin15 README (line "the link stays Gen1 **x16**"): a
  read-only capture saw `LnkCap2` 2.5 GT/s only on an x16 link.

These disagree on width, which is the ×2-payoff multiplier for Gen2
(~3.8 vs ~15.2 GB/s at Gen2). Both may be card-revision-dependent. Live
`LnkSta` width + `LnkCap`/`LnkCap2` from the ticket-01 probe decides; the
answer is to be recorded on that ticket.

## P2P landscape (why the P2P tickets are shaped as they are)

- **Proven on our fleet, 50HX side**: xrip/cmp50hx-unlock issue #14 —
  aikitoria's BAR1-P2P method ported to 610.43.03 + our patches by avb80
  (RTX 2080 Ti ↔ 3× CMP 50HX full peer matrix; GPU-to-GPU latency 13–16 µs →
  1.2–1.4 µs); merged as our patches `06-aikitoria-p2p`, `07-turing-p2p`
  (Turing chipHal extension — upstream explicitly does not support consumer
  Turing) and `05-rtx2080ti-rebar`. Recipe: `iommu=pt`,
  `pci=realloc,hpmemsize=8G,hpmmiosize=256M`, `disable_acs_redir=<switch
  ports>`. A workload datapoint from the thread: ≈ +70 tok/s prefill in vLLM
  (27B) on a multi-50HX rig.
- **Landmine**: on the maintainer's host `intel_iommu=on iommu=pt` broke GSP
  startup (recorded in `docs/P2P.md`); the long-form article behind the 90HX
  P2P demo (Habr 1087254, part 4) measured Translated-mode ≈ 250 MB/s vs
  identity-domain ≈ 3.3 GB/s. Per-host verification is mandatory, not
  optional.
- **Mechanism facts** (aikitoria/open-gpu-kernel-modules @ `615.78.08-p2p`):
  BAR1 exposes VRAM to peers (`p2pOverride=0x11`, `pcieP2PType=BAR1`, peer
  PTEs on SYS_COH/SYS_NONCOH aperture); each GPU needs ReBAR with BAR1 ≥
  usable VRAM; **same-generation pairs need kernel modules only**;
  mixed-generation pairs additionally need the `patch-libcuda-p2p.py`
  userland patch (three chip-family predicates; signatures pinned to
  libcuda 615.71.09 — re-location needed for our 610.43.03).
- **90HX P2P status**: demonstrated on GA102 by the article author via a
  driver-force chain; our route (tickets 09–10) reuses the in-tree patches,
  which already carry the GA102-generation HAL path. Honest caveat, matching
  the pwner tracker (issue #5): layer-split LLM serving does not exercise
  P2P — only tensor-parallel placement does.

## Rejected-path register ledger (negative evidence, do not re-try)

| Register(s) | Card | Result | Source |
|---|---|---|---|
| `0x820250`, `0x820580`, `0x820040` (170HX probe/OPT) | 50HX/TU102 | unmapped (read as unclaimed) | our capture `20260812T1317Z-170hx-regset` |
| `DISABLE_SW_OVERRIDE 0x820084` (+ whole 170HX fuse-override class) | 90HX/GA102 | bit0 **burned** (=1); STATUS_OPT consumes fused OPT not `_CP` — guide's own guard refuses; not portable | llm2 live read 2026-10-30 (gen-feasibility.md deep dive) |
| GA100 post-GSP PHY set `0x8841c/0x880a8/0x88610/0x8872c/0x8c040/0x8c1c0/0x8c2c0/0x8b8c0` | 90HX/GA102 | maps + reads GA100-consistent, but XVE block PLM-armed (`0x88fe8=0xffffffcf`): CPU-write privilege = same V67 run-#2 wall | llm2 live read 2026-10-30 |
| `RmForceEnableGen2`/`RMPcieLinkSpeed` via `NVreg_RegistryDwords` | 90HX/GA102 | config channel itself breaks stockflow GSP boot (mailbox1=0x6) on our cards | findings 2026-08 (commit 55277f2) |
| `OPT_GEN23 0x82057c`, `VSEC_DEVICE 0x8860c` | 90HX/GA102 | writes ignored even via V67 chain (fuse-shadow) | rejoin16 notes §Hazards |
| GA100 PJTAG PLM `0xc840`/`0xc848` | 90HX/GA102 | region returns `0xbadf1xxx` — unmapped | rejoin16 notes §Open questions |
| pre-OS retrain (any card) | both | host hang (X99/X299); retired | issue #25, README |

## Sources

- lixiangwuxian/170hx_tips — `Gen3_unlock_en.md` (GA100 guide, device `2082`).
- jdowning100/cmpunlocker — `90hx/0016-6104303-cmp90hx-stockflow-rejoin16-pcie-jtag-plm.patch`, `90HX-GEN2-RESEARCH-NOTES.md`, `bench/rejoin16-apply-all.sh` (proven 36-row apply table incl. warm fast-path), `systemd/cmp90hx-gen2.service`.
- pearlfortune/cmpunlocker v0.1.28 — compute unlock / stockflow base (MIT); lineage bendy2/cmp90hx V67.
- WildFlash1st/cmp90hx-unlock @ `76940ae583281daa2b883518a2e89b56c11d3a46` — vendored as `docs/cmp90hx/` (its "fused" verdict superseded by rejoin16).
- iatethelogs/cmp90hx_pwner — apply automation; issues #2, #5, #7.
- xrip/cmp50hx-unlock issue #14 — 50HX P2P proof + `iommu=pt`/GSP counter-case; our patches `05-rtx2080ti-rebar`, `06-aikitoria-p2p`, `07-turing-p2p`; `docs/P2P.md`.
- aikitoria/open-gpu-kernel-modules — branch `615.78.08-p2p`; `patch-libcuda-p2p.py` @ `c8bff54` (615.71.09 pin).
- Habr 1087254 (part 4) — 90HX P2P chain; IOMMU Translated vs identity (250 MB/s vs 3.3 GB/s).
- Internal: `docs/CMP50HX.md` (regset capture + `RMPcieLinkSpeed` IDA pass), `docs/cmp90hx/rejoin15-README.md:43` (width record), `README.md` (pre-OS retirement), `.scratch/90hx-gen2-p2p/issues/` (ticket set this report feeds).
