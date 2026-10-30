# Alternative paths to 90HX Gen2 — scoping notes (2026-10-30)

Status context: on llm2 the V67 **run #2** (refilled extra Booter write) never
fires (0/39; see `docs/cmp90hx/gen-feasibility.md` and ticket 03 journal),
while **run #1** (embedded FEAT write) lands **every boot**. Ranked levers
being pursued: #1 solo-context probe (live, `90hx-solo` unit), #2 solo
full-apply recipe (gated on #1), and the two research paths scoped here.

## #3 — Pre-OS EFI ladder (GA102 port of `efi-unlock/`)

**Why it attacks the wall:** everything run-1-shaped lands on this host. A
pre-OS unlock performs a *fresh full canary execution per payload* (construct
fake WPR meta → kill GFW → FWSEC → SEC2 Booter load with crafted signature),
so 36 mask opens = 36 independent **run-1s** between POST and OS boot — the
run-2 refusal never enters. Chainload with no intervening POST preserves the
opens into the OS, where the driver's XVE-context speed path (already in
0014/0016) just writes them — with masks open, plain kernel writes suffice,
and the REJOIN10 selector guard keeps the stock signature (no chain needed
at OS boot at all).

**Existing substrate (all in-repo, proven on TU102):** `efi-unlock/` —
`unlock50x_v1.c` (its header records descent from the GA102 90HX unlock work
+ V67 canary: Jon Pry, DOI 10.5281/zenodo.20916112), `extract_fwsec.py`
(PROM→FWSEC blob), `build.sh`/`sign-efi.sh`, ESP BootNext one-cycle
integration (`install-linux.sh`; the deb already manages this for 50HX —
`CMP_ESP_SKIP=1` on our installs). Wedge blast radius on llm2 assessed low
(dedicated root ports, no shared switch), power-cycle access confirmed
(ticket 01).

**Port work, honestly:**
1. Target 220d/1555: chipId0 FALCON boot base for GA102, GA102 Booter/SEC2
   images, fake-WPR meta geometry (fbSize 6 GB variant).
2. FWSEC blob for THIS card: dump the 90HX PROM first (VBIOS_DUMP path
   exists for 50HX; GA102 capture unverified) — unknown-unknown #1.
3. Payload loop: parameterize the signature's `value@0xf948` / `reg@0xf960`
   pair per iteration (the exact refill the OS-side rejoin16 does) +
   per-iter BAR0 readback gate; 36 iterations of the full canary sequence
   pre-OS (runtime: single 50HX run is a few seconds ⇒ order of a minute —
   acceptable pre-OS, verify).
4. SS0/SS1 full-selector set at the end (stock-signature contract), then
   existing chainload ladder.
5. Failure policy: any NO-EFFECT iteration ⇒ stop, skip remainder, chainload
   anyway (card left exactly as today: Gen1, healthy).

**Estimate:** focused-days; main risks are (2) blob extraction and GA102
GFW-kill timing differences. **Gate:** start only if the solo-context probe
(window #8) fails — if solo works, #2 gives Gen2+serving without EFI.

## #4 — Multi-write crafted signature (kill run-2 entirely)

**Idea:** encode all 36 opens in the *embedded* chain so the reliable run-1
does the whole table per boot.

**Ground truth from our tree (patch 0014 synthesis):** the crafted 0xfa00
signature carries the chain as sparse words — value `0xf948`, reg `0xf960`,
terminator `0x81ee @0xf9ec`, plus fixed gadget words (`0xf950=0xd44`,
`0xf968=0x1fce`, `0xf97c=0x1101`, `0xf980/8c=0x84c8`, `0xf984=0x8e18`,
branch words up to `0xf9e8`). That is **not** a self-describing (addr,value)
array; the booter microprogram consuming it is stock GA102 code (from
`gsp_ga10x.bin`). Upstream chose single-write even on a working bench — no
public evidence the chain has a loop-back over payload pairs.

**Work items:** disassemble the GA102 booter ucode consumer (methodology is
in-repo from the TU10x GSP pass: llvm-objdump + string-parity VA mapping),
decide between (a) chain-level N-write payload if a loop primitive exists,
or (b) appending repeated ROP gadget bodies (size-bounded by 0xfa00 vs the
stock 4 KB signature geometry — headroom analysis needed), then craft +
bench-order the table so a boot does FEAT→34 masks→GFX in one execution.

**Estimate:** research-grade, uncertain horizon (days–weeks); highest payoff
if it exists: per-boot one-load full unlock, no reload loops, no pre-OS, and
it would also collapse #2's 10-minute boot-apply to seconds. **Gate:**
cheaper paths first (#1→#2→#3); pursue if they all dead-end and Gen2 still
matters on llm2-class hosts.

## #2 (recorded for when #1 lands) — solo full-apply + in-boot rebind recipe

1. Boot solo (`90hx-solo` marker + ladder in `chain` mode, or scripted
   bench-style loop once FEAT is open at boot).
2. 34 reload cycles (~10–15 min; masks persist across reloads within one
   boot — journaled; FLR does not relock them — journaled).
3. `solo-rebind.sh`: pci-stub unbind + nvidia bind for the 50HXes (no driver
   reload ⇒ masks survive), `docker restart llama-ornith`, health gate.
4. Gen2 verify (`LnkSta 5GT/s`, bandwidth spot-check) + per-boot replay
   (masks re-latch at every POST on this host — the corrected model).

Every step fail-closed; any NO-EFFECT ⇒ stop, stay Gen1, rebind, serve.

## Update 2026-10-30 (night) — after upstream recon + window #9 (L1)

- **L1 (CPU-write masks) is DEAD** (window #9): CPU writes to the FEAT page
  never open 0x823800/0x88fe8 (readbacks latch at intermediates and freeze —
  read-path corruption only, card keeps serving unlocked; details
  `findings.md`). CSB/booter path is the only mask writer from the OS side.
- **OS-side lever L2 TESTED & CLOSED (window #10, ran 2026-10-30)** —
  stock-first boot + **stock<->patched alternation** per Wh1stle05/iatethelogs
  known-good recipes (all four vendored under `upstream/` with provenance):
  a healthy stock FWSEC gates run #1 (handoff landed 2/2, SS0=0x88888888,
  V67 status=0x0) but run #2 was still refused 8/8 (`status=0x55`,
  cumulative 0/49) => the refusal is per-load-internal; the OS-side mask
  lever is exhausted and **#3 (pre-OS EFI, fresh FWSEC mini-cycle per
  payload) is now the primary path**. Tools + pristine stock set remain
  staged at `/opt/cmp90hx-gen2-l2/` — the handoff recipe itself is proven
  on this host and stays reusable.
- **#3 reclassified: build+port, not greenfield.** WildFlash1st ships GA102
  EFI source (`upstream/wildflash-efi/src/unlock_v2.c`, gnu-efi) whose
  pre-OS FWSEC-re-prime+crafted-pair mini-cycle provably works; gen2 variant
  (`unlock_v3f.efi`, full table + ECAM TLS phase) exists but is de-scoped
  upstream pending re-proof. Remaining gate = THIS card's fwsec/sec2 blobs
  (PROM dump) + Linux ESP integration (chainload GRUB, reuse 50HX BootNext).
  Items 1-5 above stand; item 2 gains a design candidate: userspace PROM dump
  via NV_PFLASH over NV0080_CTRL EXEC_REG_OPS under the stock driver.
- **#4 feeds the slot model:** the booter's chain-consumer is an RV64
  bytecode interpreter (jump table @0xe00, write handler @0xe4e, single
  value@0xf948/reg@0xf960 write, terminator 0x81ee — WildFlash ground
  truths). Multi-write payload OR a re-run-flag read explanation comes from
  disassembling the bindata booter (extraction route mapped; kernel
  `s_allocateUcodeFromBinArchive` PROD/DBG image pairs inside
  `gsp_ga10x.bin` `.fwimage`).
