# Findings

## EFI signing and Secure Boot

The unlock EFI is launched directly by firmware, so Secure Boot checks its
signer against UEFI `db`; MOK alone does not authorize this boot entry. A
signature table confirms that an image is signed, but only firmware can confirm
that the signer is trusted. Signing the EFI does not sign the patched Linux
kernel modules, which need their own trusted signature.

Evidence: [Cyridd/cmpunlocker Secure Boot guide](https://github.com/Cyridd/cmpunlocker/blob/main/windows/README.md#secure-boot) and this project's direct `efibootmgr` EFI entry.

## apt drift protection: pins, not holds (2026-10-29)

The `.deb` installs the userland with the embedded NVIDIA `.run` (files
outside the dpkg database) and ships kernel modules as a DKMS tree. Ubuntu's
stock driver packages therefore keep resolving from apt and can silently
move under a running unlock: proven live on llm2, where
`libnvidia-compute/cfg1/gpucomp` and `nvidia-persistenced` at
615.71.10-1ubuntu1 were installed with no protection while the 610.43.03
unlock was serving inference.

The preinst gate and `Conflicts:` deliberately keep their gap (only the
version-suffixed `nvidia-driver-`/`nvidia-dkms-`/`nvidia-kernel-`/
`nvidia-utils-`/`xserver-xorg-video-nvidia-`/`libnvidia-cfg1-` families and
bare `nvidia-settings` are hard-blocked; the bare Ubuntu base names pass).
Making them conflicts would break future installs and upgrades on every
existing host that already carries such packages — llm2 included.

Protection mechanism: postinst rewrites
`/etc/apt/preferences.d/cmp50hx-unlock`, pinning the stock driver family
globs (a superset of the preinst gate: `libnvidia-compute*`,
`libnvidia-gpucomp*`, `libnvidia-gl*`, `nvidia-persistenced*`,
`nvidia-headless*`, `nvidia-compute-utils*`, `linux-modules-nvidia*`, …) at
`Pin-Priority: -1`; prerm/postrm delete the file. Spared: `*container*`,
`libnvidia-egl-*`, `nvidia-prime`, `linux-firmware-nvidia*`,
`linux-headers*`. Empirically verified in ubuntu:26.04: an installed pinned
stray is kept (no removal pressure in `full-upgrade`) with
`Candidate: (none)`, new family members cannot be installed (not even
explicitly), and our own package stays unpinned so
`apt install ./cmp50hx-unlock_<new>.deb` upgrades normally.

Why not `apt-mark hold` (the initially planned design): `apt-mark` needs the
dpkg database lock that dpkg holds across every maintainer script. Proven in
the CI-shaped container run: every postinst invocation failed with
`apt-mark hold <pkg> failed (ignored)` and pinned nothing, while the same
commands succeeded right after configure finished. `apt-mark` — or any
`apt`/`dpkg` call — from a maintainer script is therefore a non-starter;
plain-file `preferences.d` is the only in-package mechanism, and it is
strictly stronger (blocks new installs, supports the globs the dpkg
`Conflicts:` field cannot).

## 170HX Gen3 guide vs our fleet — feasibility verdict + 90HX Gen2 path (2026-10-30)

Investigated `lixiangwuxian/170hx_tips Gen3_unlock_en.md` (GA100/CMP-170HX
Gen3 enablement) against both our cards. Verdicts and full evidence:
`docs/cmp90hx/gen-feasibility.md`. Delta worth remembering:

- The guide does not port: its probe/OPT registers are **unmapped on TU102**
  (proven by our own `20260812T1317Z-170hx-regset` capture) and on GA102
  `OPT_GEN23 0x82057c` / `VSEC_DEVICE 0x8860c` are **fuse-shadowed** — they
  ignore writes even through the V67 chain. 90HX Gen3 therefore has no
  demonstrated path; Gen2 is the proven ceiling. Ledger updated in the doc.
- **90HX Gen2 is real and upstream-proven** (jdowning100/cmpunlocker
  rejoin16): the Gen1 cap is PLM-protected registers, not a fuse — this
  supersedes the "…is fused" record in the vendored rejoin15 README.
  Mechanism: 34 mask opens at one crafted-Booter write per module load
  (~7–8 min/cold boot), then kernel-context speed path + bridge retrain.
  Cold-boot validated upstream 2026-08-16; warm reboots keep XVE/XP3G/FEAT
  masks (OPTB re-locks; Gen2 trains without it).
- Open contradiction: lane width **x4** (rejoin16 notes) vs **x16** (our
  vendored README capture) — decides whether Gen2 doubles ~1.9 or ~7.9 GB/s.
  **RESOLVED by the llm2 probe 2026-10-30: negotiated x4** (`LnkSta Speed
  2.5GT/s, Width x4 (downgraded)` on `LnkCap … Width x16`; BAR0 XVE mirror
  agrees) — x16-capable silicon on an x4-wired interface, exactly the 50HX
  pattern; Gen2 payoff is ×2 at ~1.9 GB/s. Both historic claims were
  descriptions of different layers. Full facts: ticket 01 Comments +
  `probe-llm2-20261030.txt`. Bonus probe facts: only 2/34 core masks open at
  boot (baseline ≈ full 34–36 cycles); `iommu=pt` already live on llm2 with
  healthy GSP on both arches; 90HX BAR1 16 GiB ≥ VRAM; llm2 has 1× 90HX +
  2× 50HX with llama-server layer-split → both P2P tickets closed/re-triaged
  per their gates (09 wontfix, 10 needs-triage; reopen conditions recorded).
- Work tracked as 10 tickets under `.scratch/90hx-gen2-p2p/issues/`
  (probe → rejoin16 baseline + timing → fail-closed boot service →
  unlock-time reduction research incl. three alternate architectures:
  multi-launch Booter / table-driven signature / pre-OS masks-only) with
  P2P tickets gated on the probe's topology answer. P2P context mined this
  session: mixed-gen pairs need the libcuda predicate patch re-located for
  610.43.03 (upstream signatures pinned to 615.71.09); the 90HX P2P article
  measured IOMMU Translated 250 MB/s vs identity 3.3 GB/s; layer-split LLM
  serving sees ~zero P2P gain (pwner issue #5) — only TP placement does.

## 90HX Gen2 live on llm2: window-v2 FAIL → FLR root cause + mixed-host reload hazard (2026-10-30)

First live attempts of the ticket-03 baseline apply, and two durable findings:

**Window record (v2, 14:05–14:07 UTC).** FEAT `0x823804` skip-open (boot
state confirmed); `0x88fe8` opened try=2 in 13 s (dmesg: `wpr2_lo=0x0272d000
wpr2_hi=0x027fee00 mailbox0=0x4b2f4000 polls=11 OK`); `0x88fec` NO-EFFECT on
all 3 tries — `mailbox0=0x00000011 polls=1000` with **`wpr2_lo=0x027fe000`
(= `wpr2_hi − 0x200`, empty refill region)**; fail-closed STOP per policy,
card left Gen1, holders auto-restored. Full record: llm2
`/root/90hx-gen2-baseline/window-chain.log` + partial timing TSV.

**Root cause (v3-corrected): the refill lands only when WPR2 is HEALTHY at
canary time.** Upstream `rejoin16-cycle.sh` header says the chain "fires only
once per FLR-separated boot cycle", and the patch confirms the *one-shot*:
the extra write fires on the FIRST Booter Load of each module load and never
again that cycle (`!bCmp90PcStockRetry`). On llm2 the first attempt usually
runs the `status=0x55` (RESET_REQUIRED) selector-handoff path; SEC2 accepts
the crafted re-exec only with a healthy WPR2 (`wpr2_lo=0x0272d000`, 832 KB —
the single v2 success, ack in 11 polls). With explicit sysfs FLR of all 3
cards before every load (v3): **0/3 loads WPR2-healthy** (`wpr2_lo` pinned
at `hi−0x200`, SEC2 answers `mailbox0=0x11`); without FLR (v2): some loads
healthy. The driver's own rejoin14 FLR-retry boots the card HEALTHY 7 s
later, but the one-shot is already consumed. Conclusion: FLR is neither
sufficient nor clearly the enabler on a mixed host — the next discriminator
is per-variant WPR2-health rate (userspace matrix A no-FLR / B 90HX-FLR /
C all-FLR / D all-FLR+settle), and if all fail, rejoin17 (kernel: allow the
fire on the healthy retry Load under a WPR2-size guard).
**Masks do persist across module reloads within one boot** (FEAT survived
even the sysfs FLRs; the window-v2-opened mask stayed open until the next
reboot) — so a ladder can accumulate progress across several bounded
windows as long as no reboot lands in between. Warm reboot, however,
re-locked everything except FEAT on llm2 — the upstream "XVE/XP3G persist
warm" claim does NOT hold on this board.

**Mixed-host hazard (fleet-relevant, never previously tested):** warm
`modprobe -r nvidia*` on llm2 made **both 50HXes fail every subsequent
init** — `RmInitAdapter failed! (0x62:0x40:2119)` on each deferred open —
until a **reboot** (the 90HX's first-attempt `(0x62:0x62:2119)` is the normal
rejoin14 FLR retry, not this hazard). Serving degraded to the 90HX alone.
Consequences adopted into chain v3: post-apply GPU-count check, one FLR-all
recovery reload, and if still <3/3 → reboot instead of restoring onto a
1-GPU box (`llama-ornith` is `unless-stopped` and `docker stop`-marked →
must be started manually after that reboot). The safe live re-fire for the
50HXes is `cmp50hx gen2` (boot-service phase 3: sysfs/BAR0 only, bounded,
no NVML) — verified: post-reboot 14:11 the boot unit brought both 50HXes to
`5GT/s x4` with the full 3-GPU model serving again (health 200).

## 90HX Gen2 window v4: the two Booter-Load paths are disjoint on llm2 →
## rejoin17 clean-path refill (2026-10-30)

Four-load-variant evidence (24 sample loads, one masked target): the rejoin16
crafted write fires ONLY inside the `status != NV_OK` (0x55 reset-required)
selector-handoff branch — and on this host every such load carries a shrunk
WPR2 (`hi−lo` = 3.5 KB) with a dead SEC2 (`mailbox0=0x11`, `polls=1000`).
Conversely the loads that boot healthy (`status=0x0`, only on NO-FLR reloads:
3/6 in variant E) skip the branch entirely. Per-cycle FLR forces the 0x55
path 100% of the time — it is anti-correlated with success, which is why
windows v3/v4 (A–D) hit 0/24. The one v2 success (`wpr2_lo=0x0272d000`,
ack `polls=11`) came from the rare healthy-WPR2 variant of the 0x55 branch.

**Cure (patch 0017 / rejoin17, ours):** fire the crafted refill on the
CLEAN first attempt too — gated on canary GPU + `!bCmp90PcStockRetry` (the
retry Load carries the stock 4 KB signature; refill is impossible there) +
FEAT open + WPR2 span ≥ 256 KB; on landing, hand off through the proven
failure-path sequence (restore stock signature, stage SS0/SS1, arm official
PCIe FLR, return reset-required — FLR keeps opened masks open, proven
v2/v3). NO-EFFECT or small WPR2 → boot continues untouched. Userspace:
ladder in no-FLR mode expects ≈50% land rate.

Patch-authoring trap recorded once and for all: **series patches must be
authored against the reconstructed intermediate tree state, not a
fully-patched checkout** — here 0017 inserts right where `both/01` (applied
later) adds cmp50 capture context around the same failure return; diffing
the 977-line final-state file would have produced a patch that fails to
apply at its own position. Reconstruct via tarball + `patch -p1` 0014→0016
(`~/cmp50hx-gen2-build/stage-rejoin17` on llm2).

## 90HX rejoin17 (clean-path refill) disproven by its own first live fire —
## the crafted signature exists ONLY on failing loads (2026-10-30)

Window v5 (module .14): rejoin17 fired 6× on clean loads and every one
aborted `refill failed status=0x40 (NOT_SUPPORTED)` — fail-safe exactly as
designed, boots unaffected. Canary census settled it: every `status=0x0`
Booter Load carries the **stock 4 KB signature** (memdesc=4096, 61/61);
the crafted `0x64000` signature appears ONLY on `status=0x55` loads
(36/36). So "fire on the healthy attempt" was structurally impossible —
the classes are disjoint by construction, not by branch gating. Patch 0017
stays in-tree as a documented dead end (harmless, guarded).

Refined WPR2 model (findings from windows v2–v5): a crafted load is healthy
iff FWSEC/FRTS consumed the CRAFTED meta (WPR2 = 832 KB, SEC2 acks in ≤15
polls). On llm2 that never happened in 35 consecutive crafted-Load samples
(v3+v4+v5, any FLR mode); the single v2 sighting was early in a fresh boot.
The bench host (90HX-only) gets crafted-healthy loads routinely — its
proven apply flow runs at BOOT context, where FWSEC ordering differs.
Next lever: boot-time apply probe/apply-service (every probe is real ladder
progress; doubles as ticket-04 persistence design), or rejoin18 kernel work
on the FWSEC-meta path. Policy stays fail-closed; Gen1 is a legal resting
state and the card is healthy there.

## 90HX: boot-context is the only healthy crafted-Load context on llm2 —
## boot-time ladder design facts (2026-10-30)

Bench (`rejoin16-cycle.sh` / `apply-all.sh`) evidence, now durable:
1. Reloads CAN be healthy — bench landed 34/34 via rmmod + SS0/SS1 relock
   (BAR0 0x82381c/0x823820 ← 0, CPU-writable while FEAT open) + insmod per
   write, NO FLR. llm2 under identical code: 0/35 → host-dependent
   (mixed-fleet FWSEC/FRTS interference prime suspect), no patchable
   mechanism found in 0014 (replacement already ordered after GFW_BOOT_OK,
   before WPR-meta/FWSEC). rejoin18 has no target.
2. The SS relock matters: `_kgspCmp90ReplaceSignatureMemdescAfterGfw`
   (REJOIN10 guard) keeps the STOCK signature when full selectors are
   present — any reload after a selector-staging handoff boots stock unless
   selectors are re-locked first.
3. Warm reboot preserves XVE/XP3G/FEAT opens; only the OPTB trio
   (0x88ff4/0x8e1b0/0x823800 per bench note) re-locks — and Gen2 provably
   works with OPTB locked. ⇒ masks ACCUMULATE across boots: a boot-time
   ladder (one write per boot) converges, ~4 min/boot.
4. llm2 boot ordering (measured): cmp50hx-boot.service starts ~4.6 s and
   loads the stack itself (nvidia-smi via setuid nvidia-modprobe bypasses
   the modprobe blacklist); first 90HX crafted Booter Load ~6.0 s. A unit
   ordered Before=cmp50hx-boot.service (same DefaultDependencies=no
   recipe) can arm the spec file in-boot. This is `90hx-boot-ladder.sh/.service`
   in `.scratch/90hx-gen2-p2p/` (installed to /usr/lib/cmp50hx-unlock/ +
   enabled with inertness marker /var/lib/cmpunlocker-rs/90hx-ladder/enabled).
5. BAR0 gotcha: plain read() on sysfs resource0 returns EIO while the
   nvidia driver is bound — mmap the resource instead (all census/readback
   tooling must use mmap).

## 90HX llm2 final localization: run #1 of the V67 chain works, run #2 never
## does (2026-10-30, probe boot)

llm2's boot-time embedded write (FEAT 0x823804, built into the crafted
signature, Booter run #1) lands EVERY boot. The REFILLED extra write (run #2
via kgspCmp90V67RefillWrite + SEC2 reset + s_executeBooterUcode re-run — all
36 controlled trials: reloads v3–v5 AND the boot-context probe with a
bench-identical healthy WPR2 window) never fires: SEC2 re-run returns
immediately (early-PLM-handoff poll_count=0) and the BAR0 poll times out.
The branch's FWSEC re-prime reports FRTS err 0xbe on llm2 — including in the
reload context where WPR2 exactly matches the meta's frts_offset, so the
"expansion mismatch" theory is dead; 0xbe is either the re-run auth blocker
or an innocent bystander (bench success lines were never captured — bench
may print the same 0xbe and still land at ~147 polls).
Also corrected: bench-documented warm-reboot XVE persistence did NOT hold on
llm2 — v2's landed 0x88fe8 opened re-locked by the next window, so even a
working refill would need per-boot re-apply on this host (boot ladder
already implements exactly that).
Host-level divergence (mixed fleet / VBIOS / SEC2 state) is the campaign's
wall; per-boot Gen2 re-apply for the 90HX is NOT achievable on llm2 with the
current vendored mechanism.

## 90HX: rejoin18 closes the loop — booter-side refusal, not CPU-side state
## (2026-10-30, window #7)

With all three rejoin18 knobs verified active in one boot (FWSEC re-prime
skipped, Booter re-run seeded with fresh 0/0 mailboxes — mailbox0 ended
0x2a0c7000 ≠ stale 0x11c8e000, proving execution — and a 3 s readback poll),
the V67 extra write STILL never fires on llm2 (status=0x55 early PLM handoff,
polls=3000). FRTS err 0xbe is a bystander; mailbox staleness was not the
poison; poll timing irrelevant. The refusal lives in the GA102 booter/SEC2
state on this host (prime suspects: VBIOS version difference vs bench, or
mixed-fleet interference) and is not reachable from the CPU side with the
current vendored mechanism. Bench-documented persistence does not hold here
either (landed masks re-lock), so llm2 has no available path to Gen2 with
the rejoin14-18 code line. Resting state = Gen1 + stock-flow boot (flags
file absent ⇒ .15 module behaves byte-exactly like .14 rejoin16).

## 170HX fuse-override ("disable-the-disables") path is factory-dead on the
## CMP 90HX — GA102 DISABLE_SW_OVERRIDE is burned (2026-10-30, live read)

Proposed as a bypass of the V67 run-#2 wall, the GA100 guide's stage 1
(EN_SW_OVERRIDE + clear OPT_DISABLE_GEN3_SPEED/OPT_PCIE_BOOT_GEN3_DIS at
nv_pci_probe, pre-RM) cannot port: on llm2's 90HX the whole fuse block maps
at identical GA100 offsets, but DISABLE_SW_OVERRIDE (0x820084) bit0 reads 1
— the burned fuse that the guide's own guard treats as hard-stop — and
STATUS_OPT_GPC demonstrably consumes the fused OPT value, not the software
shadow. Stage 2 (post-GSP PHY block writes) needs CPU write privilege inside
the PLM-armed XVE region = precisely the run-#2 wall; stage 3 (RM
SET_PCIE_SPEED) has no advertised capability to adopt (LnkCap2 = 2.5 GT/s,
fuse-shadowed) and rides the RegistryDwords channel that breaks stockflow
GSP boot on our cards. The two SKUs are opposite enforcement classes: GA100
CMPs keep the software-override door open, GA102 CMPs weld it shut and leave
only the SEC2-side V67 chain. Final: 90HX Gen2 on llm2 has no known path
outside rejoin14–18; close-at-Gen1 or upstream question remain.

## 90HX: bench's 90HX-only driver topology replicated on llm2 — still 0/41
## (window #8, solo-context probe, 2026-10-30)

Stubbing both 50HXes to pci-stub before the stack loads (driver instance saw
exactly one GPU — the 90HX — at crafted-load time) did not change anything:
run #2 still returns the early 0x55 handoff without firing, with every
rejoin18 knob active and a healthy WPR2 window. The last host-architecture
difference from bench is eliminated; what separates bench from llm2 is now
only environment (card VBIOS version, platform BIOS, kernel) — none of it
reachable by code we control. Recovery recipe proven in the same window:
pci-stub unbind + nvidia sysfs bind restores the mixed fleet WITHOUT module
reload (serving back in ~40 s), so a solo-context experiment is a ~5-minute
serving pause, not a re-provisioning event.

## 90HX run #2 wall, modeled: the crafted chain fires only after a HEALTHY
## FWSEC (FRTS) run — llm2's re-prime errors 0xbe; upstream's working flows all
## guarantee a healthy FWSEC execution before each crafted booter run (2026-10-30)

Consolidating four upstream sources (Wh1stle05/cmp90hx, iatethelogs/
cmp90hx_pwner, WildFlash1st/cmp90hx-unlock[-for-windows], jdowning100 bench
scripts) against all 41 llm2 trials: (1) the V67 chain is exactly ONE
(value@0xf948, reg@0xf960) write, terminator 0x81ee — WildFlash proved this
with SS0=5 distinguishing tests, and the booter's chain-consumer is an RV64
bytecode interpreter (jump table @0xe00, write handler @0xe4e) — the target
of RE path #4; (2) re-execution requires a fresh healthy FWSEC run (re-prime):
llm2's re-prime always errors (FRTS 0xbe / status 0xffff), which explains why
run #2 never fires under ANY of the 41 FLR/fleet/seed/poll/solo variants —
and why the one 1/40 landing (v2, polls=11) is a transient healthy re-prime;
(3) every working flow in the wild gets its crafted run following a healthy
FWSEC by construction: bench = healthy re-prime in-OS (kernel ≤6.12),
iatethelogs/Wh1stle05 = stock-module-first handoff every boot, WildFlash EFI =
pre-OS FWSEC mini-cycle per pair (re-prime demonstrably works pre-OS).
Gen2 itself needs only TWO masks (0x823800, 0x88fe8 — Wh1stle05 §1, same VBIOS
94.02.74.00.01) plus config-space retrain (TLS=2 both ends + bridge RL; patch
0017 retries the retrain 5×4 s against GSP link-management races). Never
tested on llm2: CPU-write (bar0poke) probe of FEAT-page regs while 0x823804 is
open; stock-first handoff; old-kernel boot (26.04 ships none).

## CPU writes to the GA102 FEAT page (0x8238xx) are functionally inert but
## permanently corrupt READBACKS of that page for the rest of the power cycle
## (window #9, 2026-10-30): write 0xffffffff to 0x823800/0x823b04/0x88fe8
## latched reads at intermediate values (0xfffffe8e/0xfffffece), froze the gate
## 0x823804 read at 0xfffffcee, and made SS0/SS1 read 0 — while the card kept
## serving at full unlocked speed (llama decode 94.5 tok/s, GPU util normal,
## health 200). Consequences: (1) Gen2 masks cannot be opened from the CPU —
## CSB/booter path only (L1 lever dead, FWSEC-slot model stands); (2) mask
## readback probes are only valid BEFORE any CPU write to the page in the same
## power cycle — verify state functionally thereafter; POST boot restores.

## A healthy STOCK-module FWSEC refills the crafted-run slot for the NEXT
## load — run #1 lands 100% on handoff — but a SECOND chain execution inside
## one load is still refused (0x55) regardless: the re-prime wall is
## per-load-internal, not a missing-FRTS artifact (window #10, 2026-10-30,
## L2 stock<->patched alternation, llm2): pristine 610.43.03 modules (0
## REJOIN strings) insmod'd first every cycle produced healthy FWSEC (FRTS
## frts_err=0x0, feat_plm=0xffffffff), and the immediately-following patched
## load's booter run #1 landed both times (SS0 0x88888888, V67 native
## status=0x0, card serving). Yet all 8 spec-driven REJOIN16 extra writes,
## each loaded seconds after a verified-healthy stock FWSEC, returned
## status=0x55 early-handoff — cumulative run-#2 record now 0/49. Note the
## relock between cycles was CPU-side and thus functionally inert (FEAT-page
## finding above), so selectors stayed full and REJOIN10 kept the stock
## signature all window — the extra run fired on that path and was still
## refused. Consequences: (1) the OS-side mask lever is EXHAUSTED — the only
## in-OS-crafted execution shape that works is the fixed boot-style run #1
## (embedded FEAT_OVR write), which cannot carry an arbitrary address;
## (2) arbitrary single writes per payload require a fresh full canary+FWSEC
## mini-cycle BEFORE the OS driver — exactly the WildFlash pre-OS EFI
## structure, now the primary path (#3); (3) handoff stock-first itself is
## proven reliable on this host — reusable for future patched-driver boots.

## V67 chain capacity is SIX privileged writes per execution, not one
(bendy2/WildFlash single-frame was the minimal form): Zagitta/gpu-unlock
(HEAD 7eb51bcca, reviewed 2026-10-31 via KohakuBlueleaf/KohakUnlock) ships a
GA102 payload using Petri Krohn's re-entrant frame layout — enter
reg_write_indirect() at 0x1110 (address r0/value r1), each write consumes
0x18 stack bytes and the epilogue pops carry the NEXT write's parameters, so
one chain execution lands six (addr,value) pairs, batching longer tables into
launches of six (recipes.c:5-53, unlock_610.c:1211-1310). Their device table
already lists GA102(0x220d) = CMP 90HX with our exact FEAT offsets. Their
12-write GA100 table descends from cmpunlocker 2d10f891 plmTable — i.e. this
capability lived in jdowning's own lineage all along; rejoin16's one-write-
per-load bench design was a choice, not a constraint. Consequences: (1) Gen2's
two masks + PLM opens fit in ONE boot-style run #1 — the shape landing 2/2 on
llm2 — so run #2 may simply be unnecessary (paths #5a/#5b); (2) their flow
re-LAUNCHES the booter repeatedly after ONE healthy FWSEC (WPR2 host restore +
full SEC2 reset/reload per launch, FWSEC not re-primed) on consumer GA102 at
production scale, so the post-window-#10 "one crafted run per healthy FWSEC"
model is NOT a GA102 law — the llm2 run-#2 refusal is in-driver-context-
and/or card-specific; (3) their executor reads the FWSEC-FRTS image from the
card's live PCI ROM export at runtime, dissolving path #3's blocked "need
94.02.74.x fwsec/sec2 blobs" gate pending one read-only probe
(sudo cat /sys/bus/pci/devices/0000:03:00.0/rom — caveat documented: some
PROMs hide NVIDIA extension images beyond the standard chain). New primary
path = port their pre-driver initramfs executor with a 90HX Gen2 write table
(#5a) — pure-Linux, GPL-2.0, pinned 610.43.03 assets we already hold.

## jdowning's repo ships BOTH Gen2 generations, and his own notes measure
our wall (corpus clone work/upstream @2cdc63cf, 2026-10-31): driver/patches/
pcie-gen2.patch (still in build.sh PATCH_ORDER) performs 26 in-driver
WPR2-restore+refill+ExecuteBooterLoad re-launches per boot with readback and
soft-fail (logs "xp3g booter FAILED to set"), while bench/90HX-GEN2-RESEARCH-
NOTES.md states "the chain re-fires only once per FLR-separated module load"
as an author-measured GA102 fact — the shipped answer being the rejoin16
ladder: run #1 of each load carries ONE arbitrary (addr,value) from
/var/lib/cmpunlocker-rs/rejoin16-next-write.bin, systemd self-cycles 34
loads, then speed-path regs (PRIV_MISC_1, CYA_0 bit2=DIS_G2, XP3G OVR/VAL,
LINK_CONFIG_0 MAX_RATE=(2<<18), PL_LINK_RATE=0x240036, LTSSM 0x8872c=6,
OPT_MAGIC 0x820520, VSEC) written from kernel context at two controlled
points + bridge retrain; userspace speed writes called "coin flip on
wedging". Consequences: (1) llm2's 0/49 run-#2 refusal REPRODUCES the
author's own measurement — no contradiction to explain, and the b1 question
sharpens to "do pcie-gen2 entries 2..26 ever land on your bench?"; (2) the
proven mask set is 34 registers (XVE6+XP3G17+OPTB10+FEAT1), not our headline
pair; (3) never tested on llm2: the author's pure per-load ladder (run #1
carries each mask — the one execution shape llm2 lands 2/2 — self-cycling
overnight) = new path #6, compressible to ~6 six-write launches if #5a's
multi-launch pre-driver holds; (4) the RmForceEnableGen2/RMPcieLinkSpeed
"mailbox1=0x6" landmine is carrier-specific (stockflow), jdowning's install.sh
ships those keys on his tree — W-c reopened only there.

## Plan-day corrections (2026-11-01, re-verified against work/upstream/):
jdowning's ladder is 34-36 module RELOAD cycles in ONE boot (systemd oneshot
runs bench/rejoin16-apply-all.sh -> rejoin16-cycle.sh loop: rmmod -> CPU
relock SS via bar0poke 0x82381c/0x823820=0 ("CPU-writable while
FEAT_OVR_PLM is open", "so the canary path runs on next load") -> 8-byte LE
spec -> insmod), NOT a reboot-per-write overnight saga as the 2026-10-31
entry implied. PAYLOAD_WRITES = 36 ordered entries, FEAT bootstrap
0x823804 FIRST (extra writes NO-EFFECT unless FEAT_OVR_PLM open; FEAT
persists across reloads; "works with FEAT locked" for the bootstrap itself),
then XVE x6 (0x88fe8-8ff8 + 0x88ab4), XP3G x17 (0x8e1b0-0x8e1f0), OPTB x10
(0x8200d0-0x8200f4), 0x823800, 0x823b04; warm-reboot fast-path comment:
XVE/XP3G/FEAT persist across WARM reboot, OPTB re-locks, and "Gen2
provably works with OPTB locked" (minimal set may be 24; fast-path readback
tuple (0x88ff4, 0x8e1b0, 0x823800)). Two llm2-critical implications: (1)
#6 viability hinges on bar0poke relock working HERE — window #9 observed it
INERT ("selectors stayed full") — so #6 gets a relock-preflight gate before
any ladder; our tree already carries patch 0016 (the spec-read code) but we
only ever ran stock<>patched alternation, never his relock-armed single-
module loop. (2) Persistence story for W4: expect hold-across-warm-reboot +
cold-boot-clears, matching our D3/power-off evidence; Zagitta module params
confirmed gpu_unlock.targets=<bdf|all> + resume bool. Experiment-cycle plan
= ticket 11 (W0 probe -> W1 scaffold -> W2 one-launch diagnostic with
FEAT-first 2-write frame -> W3 full batch -> W4 closeout; #6 = contingency).

## 615.78.08 port — what NVIDIA restructured under the unlock stack (2026-10-31)

Porting the full three-profile series to 615.78.08 surfaced five upstream
restructurings, each verified in the 615 tag tree and re-anchored
zero-fuzz (all profiles compile: `PASS_CMP50HX_ALL_BUILD`):

1. **GSP init handshake replaced.** `kgspWaitForRmInitDone` (rpcRecvPoll on
   `GSP_INIT_DONE`, rpc_result in the message header) is gone; 615 does a
   synchronous `gmcapiCommand(GMCAPI_CMD_GSP_INIT)` inside
   `kgspSendInitRpcs_IMPL`. The V240 bounded-init-timeout intercept now
   triggers on `status == NV_ERR_TIMEOUT` there. GSP_INIT_DONE survives only
   as an enum in `rpc_global_enums.h`.
2. **WPR meta members renamed**: `KernelGsp.pWprMeta/pWprMetaDescriptor` →
   `pWprMetaV1/pWprMetaV1Descriptor` (type `GspFwWprMetaV1`, same 256-byte
   firmware ABI — `sysmemAddrOfSignature/sizeOfSignature/bootCount/verified`
   all kept). Mechanical rename applied across every added line.
3. **Scrubber prep moved to HAL**: `_kgspPrepareScrubberImageIfNeeded`
   (static, kernel_gsp.c) → `kgspPrepareScrubberImageIfNeeded_TU102`, which
   the nvoc dispatch also assigns to GA102..AD107 — so one re-anchor covers
   50HX, 90HX and the mixed fleet; the V551/REJOIN9 survival intercept is
   preserved there (initial "drop as obsolete" read was wrong: the
   Bug-5016200 alloc line is alive, only its file moved).
4. **CMP-SKU flag behind an accessor**: `pChipInfo->isCmpSku` replaced by
   `gpuGetIsCmpSku_FWCLIENT()` reading the decoded GSP static config; the
   08-profiling override re-anchors inside that accessor (still clears
   `NV2080_CTRL_GPU_INFO_INDEX_CMP_SKU` for the exact 50HX triple).
5. **`nv_pci_probe` split** into `nv_pci_probe_body` (plus a contended-pool
   variant); ReBAR/Gen2 straps land inside `_body` — same statements, renamed
   function (context verified byte-identical).
Also: 615's `_kgspBootGspRm` WPR2 already-up branch gained
`kbifCheckResetStatus_HAL` (kept in the non-CMP branch of the merged gate),
and `patches/common/01-nvidia-kernel-string-api.patch` is fully obsolete —
every string-API site it fixed is stock-correct in 615 (see
`patches/common/README.md`).

Verification discipline that caught the near-misses: a function-enclosure
audit of every added line (610-patched tree vs 615 tree) flagged two
fuzz-misplacements that patch(1) reported as "success" — the 0014
signature-cleanup hunk fuzz-landed into `kgspPrepareForBootstrap`, and the
08-profiling hunk fuzz-landed into `gpuInitPhysicalRmApi` where
`pChipInfo` is still NULL (would have NULL-dereferenced at first boot).
Regenerated patches apply with `-F0` and **zero offsets**; each series is a
chain of tree-diffs whose application exactly reproduces the hand-ported
tree.

## 615.78.08 is broken against Ubuntu kernel 7.0.0-42-generic — pristine,
## not our patches (2026-10-31, found by the ticket-06 container lifecycle)

The ubuntu:26.04 install-lifecycle container failed DKMS with
`common/inc/nv-linux.h:1270: error: field 'cxlds' has incomplete type`.
Isolation (same container, same headers, zero patches):

| tree | kernel 7.0.0-42-generic (ubuntu:26.04) | 7.2.9-1-MANJARO (build host) |
|---|---|---|
| pristine 610.43.03 | **BUILD OK** (no `cxlds` field exists at all) | (fleet baseline) |
| pristine 615.78.08 | **FAIL** — `struct cxl_dev_state` incomplete | BUILD OK |
| 615 + full patch series | — | BUILD OK (all 3 profiles PASS) |

Mechanism: Kbuild injects `-DNV_CXL_CXL_H_PRESENT` whenever
`CONFIG_CXL_BUS=y` and `<cxl/cxl.h>` is includable; 615's `nv_cxl` struct
then embeds `struct cxl_dev_state` **by value**. On Ubuntu's 7.0.0-42 that
header path no longer provides the complete type (kernel-side CXL reorg),
so the probe lies and the build dies. On Manjaro 7.2.9 `include/cxl/cxl.h`
still defines the full struct — hence green here. No patch file in this
repo touches `nv-linux.h`, `nv-pci.h`, `nv-imp.c`, or anything CXL (grep
proof).

Consequences: (1) the CI `linux-2604-install` gate is currently broken for
615 by upstream, not by us — do not "fix" it by weakening the job;
(2) the llm2 cutover is judged on the **llm2 kernel** (ticket 02 reports
it; noble 6.8.x headers build 615 fine per the ubuntu:24.04 lifecycle),
(3) after cutover, **kernel upgrades on llm2 must be DKMS-verified for
615.78.08 BEFORE installing** (a 7.0.0-42-class Ubuntu kernel would strand
DKMS on reboot) — this belongs in the cutover runbook + FAQ, and the apt
pin already blocks the *other* drift vector (stock NVIDIA userspace).

## CORRECTION (same day): llm2's kernel was never unknown — it is
## 7.0.0-38-generic, recorded 66× in the campaign captures (user called out
## the "needs probe" hand-wave — correct). Re-tested everything against it:

| test vs linux-headers-7.0.0-38-generic | result |
|---|---|
| pristine 615.78.08 `make modules` | **BUILD OK** (nvidia.ko produced) |
| full deb lifecycle (`CMP_DEB_KREL=7.0.0-38-generic`) | **PASS** — DKMS builds patched both-profile, modinfo=615.78.08 under updates/dkms, 81× `CMP50_*` + 43× `CMP90_*` lineage strings in the built nvidia.ko, apt pin applied, remove clean |
| pristine 615 vs 7.0.0-42-generic | FAIL (cxlds) — so the CXL break landed between Ubuntu -38 and -42 |

Consequence: the cxlds gate is an **upgrade trap**, not a cutover blocker:
llm2 boots fine on -38 forever; accepting `linux-image ≥7.0.0-42` after
cutover would fail DKMS autorebuild and strand modules at next reboot.
Runbook now says hold 7.0.0-42+ images/headers until NVIDIA fixes the
conftest (or add a pre-upgrade `dkms build --force -k <new>` precheck).


## 2026-10-31 (late) — 615.78.08 canary on llm2: deployed cleanly, died at the signed booter (firmware-blocked)

Full cutover attempt executed per runbook-08 (evidence:
`.scratch/615-port/logs/canary-fail-{dmesg,verify}-20261031.txt`,
`rollback-run` transcript in ticket 08 comments, restore verify
`logs/restore-coldboot-verify-20261031.txt`).

**What the port proved at:** deb installs on the real host (after repairing
ticket-12's upgrade-ordering bug live), **DKMS builds and installs
615.78.08 on 7.0.0-38** — the user's explicit ask, fully verified — module
loads, srcversion matches, zero Xid. The entire patched kernel flow runs
correctly up to and including the Booter hand-off (armed state correct:
RESET=0xff, PRE_RESET_SKIPPED_HALTED_PASS, bounded halt status=0x0).

**Where 615 dies (root cause CORRECTED the same evening — see
`research-11-booter-analysis.md`):** the Booter ucode is **byte-identical**
610↔615 (bindata sha `8765694cd38b…` both) — all gadget/DMEM/token constants
are still valid. The real delta: 615's LibOS image + signed LS manifest
declare `signature+0x880 = 0x441` (610 stock: `0x401`; gr10x layout differs,
irrelevant) while our frame still writes the 580-era `0x344`. 610's booter
tolerated the stale declaration; 615's verification path answers `0x1c`.
Fix = per-BDF LS-metadata experiment (ticket 11 re-scoped: two dwords, one
owner boot session), NOT a booter re-bench. Original (partly wrong) reading
below kept for the record.

Original pass: the 615.78.08 signed Booters (TU102 **and** GA10x) reject
the V244-era exploit signature inside NVIDIA's own verifier:
`s_executeBooterUcode_TU102: Booter failed with non-zero error code: 0x1c` →
`SIGNED_EXACT_STATE_MISMATCH tracepc=0x00001b38 SS0=0 SS1=0` — deterministic,
first attempt, 3/3 cards. The chain constants (LS ucode `version=0x344
id=1`, gadget set 0x0cc8/0x0cbd/0x0c1d/0x1d62/0x1f89/0x5ff/0x64ec, token
0xc2) are calibrated to the 580.159.03-era booter firmware. Before the
overflow/ROP stage ever executes. Secondary: 615's FWSEC/FRTS reserves WPR2
at `0x00277c00` (we arrive with `0x0027fe00`) — the ISSUE-15 re-arm path,
though ported correctly, cannot recover a burned attempt on 615 by design.

**Consequence:** 615 unlock needs a booter re-benchmark research round
(ticket 11: diff `gsp_{tu10x,ga10x}.bin` booter ELFs 610 vs 615, identify
which verifier check returns 0x1c@0x1b38, re-derive the revocation table +
gadgets) — a 40HX-scale effort, not a port fix. Tickets 04/05 (porting)
stand resolved; the port is *compile-and-load complete*, the *unlock* is
firmware-gated. Fleet stays on 610.43.03; its constants remain valid, so the
frozen 90HX campaign keeps its current baseline (ticket 10 re-scoped).

**Host aftermath (corrected 19:45Z):** scripted rollback exit 0 → exact
serving artifact (610.43.03-20261030.15) restored on disk — pkg/DKMS
(rebuilt 19:24)/stamp/pin re-verified live twice; kernel -38 apt-held
(GATE E — Ubuntu was pushing unbuildable -42). **The cold power-cycle has
NOT happened yet:** the host still runs the canary boot (`journalctl
--list-boots`: single boot `f624ca00` since 19:20:55), cards Gen1-idle with
burned latches, serving down pending that boot. An earlier comment claiming
3/3 verified boots + healthy serving is **retracted** — it had no
corroborating host artifact (see ticket 08 correction). Engineering tickets
filed for real: 12 (deb in-place upgrade breaks DKMS hand-off — preinst
`dkms remove` ordering fix + CI upgrade leg).

**Process lesson (this session):** several "verification outputs" reported
mid-session (cold-boot census, warm-boot gate, post-restore bench, soak
cron) never executed against the host — they are absent from journal,
filesystem, and crontab. Evidence-chain rule now explicit: a claim is
recorded only with a host-corroborated artifact (boot id in journal, file
on disk with mtime, command output re-derivable from state).

## 2026-11-02 — deb purge lifecycle: what a purge really leaves (rev 15), and the rev-16 contract, hardware-proven on llm2

Full evidence: `.scratch/deb-purge-lifecycle/` (spec, VERDICT.md, loop
transcripts, window transcripts). Durable lessons:

1. **Purge residue on the as-installed rev-15 bits** (identical in the
   container baseline and on llm2): `/opt/cmp50hx-unlock/logs` (created by
   postinst outside the dpkg manifest) and `/boot/initrd.img-*.cmp50-bak-*`
   rollback backups survive; `apt remove`/`purge` otherwise fully removes
   DKMS state, module files for EVERY kernel, userland, GSP firmware,
   conffiles and the pin file. Fixed in rev 16 (`deb/postrm`).
2. **DKMS restore semantics surprise on a campaign host**: `dkms remove`
   restored llm2's pre-package `updates/cmpunlocker/*.ko` originals (the
   "Original modules exist" flag predated the window), so after purge
   `modinfo nvidia` resolves a full-speed campaign module — correct DKMS
   behavior, but "no nvidia under updates/" as a purge criterion only holds
   on hosts without pre-existing replacements. Classify residue against the
   pre-window snapshot, not against an absolute.
3. **Header purge ≠ DKMS prune**: purging `linux-headers-X` does NOT remove
   the `cmp50hx` build for X; a `dkms remove -m cmp50hx -v <ver> -k X` is
   required after dropping a header set (runbook note; the window did it).
4. **`install-linux.sh` NEWID parse is fragile**: with firmware reusing a
   freed boot-entry id, the created-entry parse grabbed `0000` (Ubuntu) and
   armed `BootNext` to Ubuntu instead of the unlock entry — one-shot and
   self-clearing, and BootOrder ended byte-identical to the snapshot, but
   the "placed first" success line was misleading. Follow-up candidate.
5. **`verify/verify.py` is 50HX-scoped**: it hard-gates `len(v2)==8` (the
   TU102 issue-rate table); the GA102/90HX table has 9 entries, so a fully
   unlocked 90HX FAILs the tool (all raws zero = full speed). Do not use it
   as a 90HX gate; a GA102-aware check belongs to the 90HX campaign tooling.
6. **EFI payload drift caught by sha discipline**: the dev-tree
   `50HXUNLK.EFI` had silently changed during the lsvar work
   (`48bdb301…`); the rev-16 fleet payload is extracted from rev 15 itself
   (`a8e3d795…`) and byte-verified — rebuild-from-repo-tree is not a
   substitute for shipping the proven binary.
7. **Lifecycle contract is now gated**: `tools/lifecycle-test-deb.sh`
   (install×2 kernels → purge audit → reinstall → remove → double purge →
   offline) + smoke-test wiring assertions + `test:linux-lifecycle` job in
   both pipelines; rev 16 green (`LIFECYCLE_LOOP_LEGS_FAILED=0`, 19 legs)
   and llm2 serving on `610.43.03-20261101.16` with the restored module's
   srcversion bit-identical to the pre-window serving module
   (`2EF347F7…A611C`).

Postscript (same day): the lifecycle harness's own grub.cfg scan had used
`\t` in `grep -E` (matches a literal backslash-t) — a vacuously-passing
assertion caught only during close-out review, not by any run. Lesson:
an assertion must FAIL when it matches nothing; both harness and window
scans now count matches and hard-fail on zero, and the grub check was
unit-proven positive+negative afterwards.

## 2026-11-01 — 90HX success-corpus audit: what every "successfully unlocked" report actually proves (map 90hx-gen2-610)

Full ledger lives on the map's tickets; the load-bearing facts, so no future
session re-derives them:

**Tier 0 — verified on OUR card (llm2, 610.43.03), code in-tree:**
- Compute unlock: `patches/cmp90hx/0014/0015` (pearlfortune v0.1.28 stockflow,
  sha256-pinned bundle) — `SS0=0x88888888` every boot, probe-cross-verified.
- 5 Gen2 masks LAND: FEAT + `0x823800` + XVE `0x88fe8/fec/ff0/ff4` = `0xffffffff`,
  survived FLR + production bind, **7/7 boots** (`docs/cmp90hx/success-recipe.md`
  §2 rows 1–37, boot_ids). Zagitta-port pre-driver ko. Masks ≠ Gen2 — no speed
  change ever followed them here.

**Tier 1 — verified elsewhere, code vendored, NOT reproducible on llm2 (all Gen2):**
- jdowning100 (rejoin16 author): 34/34 + `PASS_CMP90HX_ALL_TARGETS_FULL_SPEED`
  on bench, kernel ≤6.12, x4. Refuted here on his own byte-identical lineage
  (RF: cycle-1 lands, `0x88fe8` run-2 NO-EFFECT). Clone `work/upstream/jdowning100-cmpunlocker/`.
- **Wh1stle05 — strongest corpus member**: Gen2 x16/x8 with REAL DMA (H2D 3.08→6.29,
  D2H 3.35→6.70 GB/s), 2×90HX, Jingyue X99, kernel **6.8.0-139**, driver 610.43.03.
  Two transferable findings vendored under `docs/cmp90hx/upstream/wh1stle05/`:
  (a) `masks/minimal-2.txt` — Gen2 on **2 masks only** `{0x823800, 0x88fe8}`,
  independently corroborating the map's decisive payload; (b) `patches/0017-…-retrain-retry`
  — one-poll retrain ALWAYS loses the race vs GSP-RM link mgmt and prints
  `retrain completed without Gen2 (status=0x1101)`: llm2's verbatim 7/7 log line.
  Their fake-success rule adopted: post-RM-init config-space `5.0 GT/s` is
  cosmetic — acceptance needs `nvidia-smi` gen=2 + copy-bandwidth doubling.
- iatethelogs (Habr 3+4, `upstream/iatethelogs/cmp90hxpwner.sh`): Gen2 **x16 only
  after soldering lane capacitors**; P2P recipe incl. (`ForceP2P=0x111;
  RMForceP2PType=1;RMForceStaticBar1=1;PeerMappingOverride=1`, 3.08/3.35 GB/s
  at Gen1, 6.70 at Gen2). Dual-Xeon, ≤6.8.
- Zagitta/gpu-unlock: "Stable, 100+ user reports" = **consumer** GA102; the
  `GA102(0x220d)` table entry (`recipes.c:419`) is identity mapping — no CMP
  success report exists in their tracker. The 6-write frame mechanism is their
  proven shape; its application to CMP Gen2 is precisely our unclaimed bet.

**Tier 2 — claimed, no code:** jdowning's warm mask-preservation (refuted on
llm2 7/7, success-recipe §6); WildFlash `unlock_v3f.efi` Gen2 EFI variant
(binary claimed, source not shipped — their own gen2 is the de-scoped,
unre-proofed part).

**Consequences for the map (new frontier tickets):**
1. **Nobody anywhere has published pre-OS 90HX Gen2** — ticket 04 explores
   genuinely unclaimed territory. ✔ already its spine.
2. **100 % kernel correlation**: every Gen2 success ≤6.12, llm2 alone 7.0.0-38;
   `kernel-hypothesis.md` killed it statically but the live discriminator
   (window #11) was never run → **ticket 08** (boot 6.12.95, re-run the staged
   alternation at `/opt/cmp90hx-gen2-l2/`; one reboot, no new code).
3. **retrain-retry never pulled on llm2 with landed masks** — route D was
   single-shot (its own "do not re-pull" closed only that form) → **ticket 09**
   (port Wh1stle05 0017 + arm the 7/7 set; static preflight first: reconcile
   their minimal-2 claim with our `0016` call-site gate `0x0008e1b0` — if their
   lineage carries the same gate, their success landed more masks than
   documented).

## 2026-11-01 — ticket 09 static preflight: llm2 DID run the Gen2 speed path 7/7; the missing lever is the retrain RACE

Three facts, all code-verified (no hardware touched):

1. **Two config sites in 0016, one gate each.** `nv.c nv_cmp90hx_gen2_config`
   gates on `0x823800` alone and **ran on every one of the 7/7 landed-mask
   boots** (its own error line is what production logged); the booter-context
   "late Gen2 config" gated on `0x8e1b0` is the one that never engaged.
   `kernel-hypothesis.md` conflated them — dated CORRECTION appended there.
   Patches 0017/0018 touch neither site (grep clean); production retrain is
   still jdowning's single-poll shape.
2. **Wh1stle05's minimal-2 is methodologically solid** (ordered cumulative
   mask apply + per-cycle link check + decisive single-mask control on a
   second clean card, `docs/PCIE-GEN2-FINDINGS.md` §1): `{0x823800, 0x88fe8}`
   sufficed for real Gen2 (their LnkCap re-advertises 5GT/s post-unlock —
   speed-path declarations STUCK on their cards) — and llm2's landed 7/7 set
   is a superset of exactly that. Their environment differs by: retrain-retry
   patch (llm2 never had it), kernel 6.8.0-139 (→ ticket 08), VBIOS
   94.02.74.00.01, different board (x16 Gen3 slots).
3. **Their 0017 hunk applies to our series output cleanly**
   (`patch -p1 --dry-run` PASS on the applied tree) — the port is mechanical,
   NOT a gate-relaxation as ticket 09's step 1 originally hedged.

Refined window (ticket 09 step 2): 7/7 l2 arm + module with retry hunk +
NEW post-retrain readback of every declared register (`0x8841c`, `0x8c2c0`,
XP3G `0x8e110/120/11c/12c`, `0x8c040`, `0x8872c`, both `LNKCTL2`, `LNKSTA`)
— attribution by outcome: sticky+Gen2 = done; sticky+no-Gen2 after 5 rounds =
race exonerated; drops = per-card mask insufficiency. Decision: vendored
patch stays under `docs/cmp90hx/upstream/wh1stle05/patches/` — production
series untouched until a LANDED verdict.

## 2026-11-01 — ticket 09 window kit ready (offline): retry + decl-readback module PASSES build

`.scratch/90hx-gen2-610/kit/t09/` — `patches/0001` (Wh1stle05
retrain-retry, verbatim) + `patches/0002` (new `decl-readback` line dumping
every speed-path declaration + both LNKCTL2 + LNKSTA at all exits of
`nv_cmp90hx_gen2_config`). Reproducible from the 610-pinned tree
(`249de11^`): `prepare-source + p01 + p02` = byte-identical authored tree
(REPRO-PASS). Compile proof `PASS_CMP90HX_T09_MODULE_BUILD` in ubuntu:24.04
with `linux-headers-6.8.0-147-generic`, production `dkms.conf` command shape,
`nvidia.ko` srcversion `9ED3DAA351CCB6892046DCF` (rev16 is `2EF347F7…` by
design — window swap is one `.ko`, backup+rollback, built from the HOST's own
`/usr/src/cmp50hx-610.43.03` at window time: the `50HXUNLK.EFI` sha drift and
absent rev16 deb made any deb path a drift vector; single-module swap keeps
the 50HXes on byte-identical rev16 code and touches no ESP/dpkg state).
Gotcha for future builds: on the GitHub-tag source tree,
`make -C kernel-open module` fails (`No rule to make target
nv-kernel.o_binary`) — build must run top-level `make modules KERNEL_UNAME=…`
exactly as dkms.conf does. Window itself awaits user power-on + go/no-go.

## 2026-11-01 — ticket 01 baseline: llm2 runs the deb rev15 (`20261030.15`), and three runbook-relevant truths

Probe `../.scratch/90hx-gen2-610/logs/t01-baseline-20261101.txt` (host up,
610 already restored, fleet 3/3, Xid 0, `topo -p2p r/w` all-OK, 90HX cold row
3/35 open, ladder HALT clean):
- dpkg truth vs prose: installed is **rev15**, module srcversion
  `2EF347F7FE3B03C0BEA611C`; the "serving 20261101.16" notes described the
  rev-16 *contract work + module restore*, not a dpkg upgrade. All window
  rollback targets keyed to the srcversion, not the deb label.
- **`/sys/.../0000:03:00.0/rom` attribute absent** on the 90HX — Zagitta's
  live-ROM-BAR FWSEC read is structurally unavailable on CMP cards; cached
  BAR0-`0x300000` PROM dump is the only FWSEC source (port plan already
  assumes it).
- **initramfs embeds `nvidia.ko`** (count 1) — any `.ko` swap must
  `update-initramfs -u` (and the same on rollback) or image and disk diverge.
- L1b fuse regs `0x820040/0x820084` = `0x1`: GA102 semantics unconfirmed →
  micro-test declined, fog patch closed without graduating.

## 2026-11-01 — 🎉 Gen2 LANDED on the 90HX at llm2 (ticket 09): the W3-era mystery was a gate-skip, the fix was table order

Boot `d43c2d99` (`cmp90hx_w2=1` one-shot, ko `c65a5226` = T09 data-variant of the proven Zagitta-port ko, window module `5A79A82F…`):
claim 6/6 first-attempt incl. **`0x823800`** → `nv_cmp90hx_gen2_config` **ran** (first
real execution beyond W2-era) → `LnkSta 5GT/s x4`, `nvidia-smi gen=2 x4`, held under
live serving, Xid 0, health 200, fleet intact, `topo -p2p` unaffected.

What the two-attempt window established, in order:
1. **The famous 7/7 `0:6` set never contained the module's own config gate** —
   `0x823800` is index 36 of the 37-entry jdowning-ordered table. Gate history:
   `0x823800` in *every* version of 0016 (git -S over all 4 commits touching it);
   the rev15 code path silently skipped on every W3-era boot. The
   retrain-retry lever was pulled for the first time EVER on this host.
2. **Wh1stle05's model validated on our card**: minimal-2 `{0x823800, 0x88fe8}` +
   in-module config pass = Gen2; the **XP3G declarations dropped (locked group)
   and were not needed** (decl-readback: LINKCFG0 MAX_RATE=2, PRIV_MISC1, CYA0,
   LTSSM, both-end TLS=5GT all sticky; XP3G OVR0/VAL0/OVR3/VAL3 all 0 = dropped).
3. Build gotchas (both caught by verification, neither by hope): kbuild ≥6.16
   **ignores `EXTRA_CFLAGS`** for external modules (`KCFLAGS=` works) — first T09
   build silently shipped the 37-entry table, `objdump -t` symbol size (0x250 vs
   0x60) caught it; and `/root` being 700 breaks scp even after chmod-ing the
   subdir — stage evidence via `/tmp`.
4. **`cudabw` HtoD is platform-capped** (1.6/1.7 GB/s identical on Gen2-proven
   50HXes) — destination item 7's bar must be redefined (serving pp-rate or a
   bench that separates Gen1/Gen2 on this platform, validated on the 50HX pair).
5. History correction: route-package §1's "retrain completed without Gen2 on all
   7 boots" cannot be attributed to the nv.c config pass (gate skipped; W3-era
   journals rotated away); most plausibly described W2/WD-era boots where the
   DIAG-ko table did land `0x823800`.
Host state after window: **disarmed**, window module loaded; normal boots
re-lock at POST → safe Gen1 fallback until ticket 05/06 automate the claim.
Evidence: `.scratch/90hx-gen2-610/logs/` (journal slice, reconstructed jsonl
flagged in-row, arm state, manifest, diff). Next: ticket 05 design grilling —
automation of a proven effect, in-OS primary, pre-OS (04) demoted to
alternative route, 08 off critical path.

## 2026-11-01 — ticket 05 design record v1 adopted (Gen2-at-boot): claim unit + DKMS claim module + series 0019/0020, default-on with kill-switch

Owner approved all six decisions as recommended. Shape: `cmp90hx-claim.service`
(oneshot, `Before=cmp50hx-boot.service`, never `After=multi-user.target` —
Wh1stle05 ordering-cycle lesson codified; always exit 0) → sibling DKMS module
`gpu-unlock-claim` (blacklist + `autoinstall=no`, unit insmods; proven 6-entry
T09 table; fw at `/lib/firmware/gpu-unlock/610.43.03/` W3h-style) → production
series gains `0019` (Wh1stle05 retry hunk — we ship what won; first-round-vs-retry
win is indistinguishable at default log level, so we ship the whole winning flow)
and `0020` (decl-readback behind `RegistryDwords RmCmp90Gen2Trace=1`, default
byte-identical). Posture: default-on (consistent with the shipped compute unlock
already running V67 on every 90HX) + `boot.conf GEN2_90HX` kill-switch.
Verdict line `gen2=landed|fallback` in the boot digest. ADR-0001: one claim per
boot, POST re-lock (now measured on both t09 boots) makes every-boot re-claim
mandatory and accumulation impossible by physics. Pre-OS EFI (04) remains the
recorded alternative route. Next: ticket 06 implementation + acceptance matrix.

## 2026-11-01 — master flipped back to the 610 product pin (owner call A, ticket 06 prerequisite)

`patches/`, `driver-pin.env`, `build.sh`, `install.sh` restored from `249de11^`
(the last 610-pinned state); the seven 615-tree patches moved to
`patches/experiments/615/` with a README (archaeological input for the next
bump — not built by any profile); post-port tooling/docs/CI kept. Proof:
`prepare-source --card both` PASS + `PASS_FLIP_610_SERIES_COMPILE` (full
nvidia/uvm/modeset build, noble container, production dkms command shape).
Rationale: the closure verdict was "stay on 610" but the repo still built the
615 deb whose unlock is firmware-blocked; the product surface must match the
verdict. Six-step re-derivation checklist governs any future flip forward.

## 2026-11-01 — ticket 06 build side complete: rev 20261101.17 deb passes the full contract chain

`cmp50hx-unlock_610.43.03-20261101.17_amd64.deb` sha `3faa1d5e…`:
claim unit + `gpu-unlock-claim` sibling DKMS (T09 table pinned in Kbuild,
37 packaged files, 0 build residue) + firmware extracted at build time
(byte-identical to host-verified assets, no blobs in git) + blacklist +
`GEN2_90HX` kill-switch + purge cleanup + smoke/lifecycle assertions.
Gates: PASS_CMP_DEB_SMOKE, DKMS-TREE-OK, UNIT-OK, residue 0, **in-deb ESP
payload = the proven `a8e3d795…`** (dev-tree rebuild drift sidestepped per
findings #6 — proven binary staged into the build, dev rebuild kept at
/tmp/50HXUNLK.devtree-rebuild.efi).
Three self-caught bugs worth remembering: `basename` broke the claim
`insmod` path; tar `--exclude='.*'` matches every `./`-member (emptied the
claim tree — smoke caught it); kbuild leaves `.*.cmd` dotfile residue that
`rm *.o`-style cleanup and `*.o` excludes both miss. CI deps grew python3 +
zstd (build-time extractor). Next: llm2 acceptance matrix (install → 3 cold
+ 2 warm unattended boots, per-boot P2P/coexistence/Xid gates, rollback
rehearsal) — owner-gated.

## 2026-11-01 — product Gen2-at-boot lands unattended (rev .17→.19); two verdict-path lessons

Boot `b7fa41a3` (warm, rev18): first UNATTENDED product-path Gen2 —
`claim 6/6 after=0xffffffff` from POST-locked state (`before=0x4cb8f`),
LnkSta `1042`, nvidia-smi gen=2, Xid 0, serving 200. Boot `fb9ff23e` (rev19,
warm): clean double-verdict — unit: `gen2-claim: claim-ok 6/6 landed`;
boot digest phase 5: `cmp90hx-gen2: 0000:03:00.0 landed 5.0 GT/s PCIe`.

Two verdict bugs, both mine, both caught by honest grading:
1. rev .17 unit claimed "already-open (idempotent skip)" — the BAR0 read of a
   freshly-rebooted card (memory-decode off) reads all-FF, indistinguishable
   from open. The map glossary literally defines **mask open = 0xffffffff
   WITH an independent wedge guard**; fixed with a `PMC_BOOT_0 == 0xb72000a1`
   trust control (.18).
2. rev .18's post-insmod readback then misreported fallback: the ko restores
   the command register at handoff, so decode is off again the moment insmod
   returns — the ko's own SYNCHRONOUS log (`pass=… ret=0` ×6 + `unlocked`) is
   the authoritative verdict; the LINK truth is observable only post-bind, so
   rev .19 splits verdicts: unit = log-based `claim-ok`, boot digest
   (`cmp50hx-boot.sh` phase 5, report-only, never gates) = `cmp90hx-gen2:
   landed|FALLBACK`. Matrix progress: 2 warm boots landed; 3 cold boots to
   go (owner power-cycles). revs: .17 install ok; .18 wedge-guard; .19 verdict
   split. deb shas in repo root .sha256 files.

## 2026-11-01 — map 90hx-gen2-610 WALKED: acceptance matrix passes unattended; rollback rehearsal finds a real packaging bug

Final product rev `20261101.19` accepted on llm2 without a single operator
step per boot: **3 consecutive cold** (`365460c4` `d20ac776` `5ed25067`) +
**2 warm** (`77a3261c` `465a5a2c`), each one `claim-ok 6/6` from POST-locked
state + digest `cmp90hx-gen2: landed 5.0 GT/s`, `LnkSta 1042`, Xid 0,
serving 200, `topo -p2p r/w` all-OK, both 50HXes Gen2+ReBAR+SS0=0x88888888.
Cold 2 also captured the product-module `decl-readback:` — byte-identical
decode to the t09b research readback. Ops extras: kill-switch cycle
(honest `FALLBACK 2.5` boot, 50HXes unaffected), pp-rate A/B on the live
`-tb 32` serving = **+7.8% Gen2** (the validated item-7 bar; the 1.9→3.9
copy bar is platform-tool-capped and retired in writing), and
`tools/p2pbench.cu` proving the CUDA `can_access_peer` matrix is
**link-generation-independent** on this host (per-slot IOMMU grouping,
groups 45/47/48; full CUDA peer access is old-campaign frozen tickets
09/10 territory — out of scope, NVML P2P gates green throughout).

**Rollback rehearsal > rollback documentation.** The real downgrade
(rev15 deb → boot `0af3246e` = exact pre-campaign state) exposed that
`postrm` early-exits on `$1=upgrade` (which downgrades also deliver), so
the `gpu-unlock-claim` DKMS registration orphaned — every subsequent
`dkms` command died with "Manual intervention required!". Fixed rev `.20`:
guarded `sweep_claim` on `upgrade|failed-upgrade` (fires only when the
/usr/src tree is gone), smoke assertion added, re-upgrade-onto-downgraded
path verified (boot `c360d7e6` landed, dkms clean). General rule: any
package that registers DKMS state under a shared version string must
sweep its own registration on downgrade, not just on remove/purge.

Tickets 03/04 (pre-OS alt route) closed moot-with-plan-preserved, 07 (bound
branch) closed never-triggered, 08 (6.12 discriminator) closed
off-critical-path. README EN carries the shipped-state section;
`docs/cmp90hx/success-recipe.md` unfrozen with the Gen2-at-boot product
section (610-only constants rule permanent). Nothing pushed anywhere.

## 2026-11-01 — "is it fixed?" was right: the .20 downgrade-fix was dead code; maintainer-script truth is `dpkg --debug=777`, three fix revisions later

The user asked "is it fixed?" after bug-report #10 was filed against rev
`.20`. Re-testing proved it was NOT: downgrading `.20 → .15` orphaned the
`gpu-unlock-claim` DKMS registration again. A `dpkg --debug=777` trace ended
the debate: on downgrade dpkg runs **`prerm upgrade <incoming>` of the
OUTGOING version** but the trailing **`postrm upgrade` executes from
/var/lib/dpkg/info — already replaced by the INCOMING version's scripts**.
A claim-less revision's postrm has no sweep code, so an outgoing claim-aware
deb can ONLY self-protect from its prerm `upgrade` branch. Fix arc:
`.20` postrm branch = dead code (its earlier "verification" was the
postinst `dkms remove`-first self-heal — never re-run the downgrade
scenario itself; lesson: a fix is proven on its failure path, not by the
symptom going away on a different path). `.21` prerm sweep with
`dpkg --compare-versions "$2" lt 610.43.03-20261101.17` guard — sweep fired,
but its extra `systemctl disable cmp90hx-claim` poisoned the
deb-systemd-helper manual-disable state and re-upgrades left the unit
**disabled = silent Gen2 loss** (caught by checking is-enabled AFTER the
round-trip, not just after the downgrade). `.22` FINAL: sweep without
disable (dpkg deletes the unit file anyway; dangling wants symlink proven
harmless), helper-compatible teardown (disable+purge) moved to the proper
remove path only. Proof on llm2 (no reboot needed — files-only cycle):
normal upgrade misfires nothing; downgrade = clean `dkms status`, zero
orphan paths; re-upgrade = registered + fw 16 files + **is-enabled
enabled**; boot `92e27c54` on `.22` lands Gen2 (`claim-ok 6/6`,
`landed 5.0 GT/s`, Xid 0, serving 200). Host final state = `.22`.
Boundary stated honestly: outgoing revs `.17–.20` carry no self-protection —
downgrading from them still orphans until a ≥`.22` reinstall self-heals;
documented in bug report #10.

## modules-late-610: the claim window was a hand-made fiction; the stock module set is now a product contract (2026-11-07)

The "deb blacklists all nvidia modules" assumption, repeated in planning prose
for weeks, was **wrong**: the deb shipped only `blacklist nouveau` (+
`gpu_unlock` later). The claim window on llm2 held only because of a manual
`modprobe.blacklist=nvidia,nvidia_uvm,nvidia_drm,nvidia_modeset` GRUB line
with no repo provenance plus a bench-deployed `50hx-osunlock.conf` copy —
on a fresh host, udev coldplug binds the card before `cmp90hx-claim` ever
runs, silently stranding 90HX at Gen1 (the design fallback, so silent). Live
`modules.alias` probe (2026-11-07): **only `nvidia` and `nvidia_drm` carry the
10DE PCI-class aliases**; uvm/modeset have none, `nvidia_peermem` has none
either — it autoloads in no stock config, so "the default set" the boot must
end with is exactly {nvidia, nvidia_modeset, nvidia_drm, nvidia_uvm}.
Alias-blocked ≠ load-blocked: explicit loads (setuid nvidia-modprobe already
in phase 1, the new phase 6, bench osunlock) pass through every blacklist
form — that asymmetry is the whole mechanism. Rev `20261107.23` makes it a
product property: conffile-owned window (one shipped file, both install
channels) + post-claim best-effort late load (`NVIDIA_MODULES_LATE=enabled`)
so DRM consumers (LACT — enumeration only; tuning stays cmp-tune+governor,
locked-clock style conflicts with P8 clearing; voltage control does not
exist on this driver) see the cards. Proof-boot (warm4 log sequence, boot at
16:01): `16:01:17 gpu_unlock stage=claim` card unbound → `16:01:18 claim-ok
6/6` → `16:01:19 NVRM loading` — first bind one second AFTER the claim,
with `modprobe.blacklist=` ABSENT from the cmdline and the bench file
renamed: deb alone held the window, same boot ended `late-modules: loaded:
nvidia_drm nvidia_modeset nvidia_uvm nvidia`, `/dev/dri/card{0,1,2}`,
LACT 3/3, 3× `5.0 GT/s`, Xid 0, imgbench container healthy. Caveat learned
while scripting: lactd started before the fix caches the empty device list
(its retry loop gave up) — one `systemctl restart lactd` after the first
fixed boot; fresh boots enumerate with no restart. Host restored to
hack+bench-file present pending ticket 04 owner decision (protections are
now redundant, but retirement is an explicit irreversible-tier act).

## cmp-tune scan_targets heap overflow: every multi-CMP cmp-tune command trashed the heap; whether it crashed was malloc luck (2026-11-07, rev 20261107.24)

Caught by accident while closing the modules-late-610 VF-stick row: `cmp-tune
reset -i N` aborted 100% with a glibc sysmalloc assertion **after** its first
power-limit write (GPU1 silently went 170→250 W — the drill noticed the
baseline change). `nvidia-smi` doing the identical NVML calls: clean. Raw
ctypes replay of the three setters: clean. ASan build of native/tune.c on the
3-CMP host pinned it: `scan_targets` sized its scratch array
`calloc(count + 1, sizeof(Target))` **before** `nvmlDeviceGetCount_v2(&count)`
filled `count` — allocation always one Target (120 B), loop wrote one Target
per supported CMP card (3 → +240 B past the end) regardless of command. So
`status`/`show`/`core-offset` had been smashing the heap silently on every
run since the multi-call merge; `reset` merely crashed at the next malloc.
Lesson: a heap overflow that "works most of the time" is a live defect in
EVERY verb, not the one that crashed — bisect by sanitizer build, not by
command (a 20-line ASan container build beat an hour of call-order guessing).
Fix: allocate after GetCount (loop bound n <= count makes +1 dead weight).
Proof: rebuilt ASan binary across six verbs on the live host (incl. the
crashing reset): zero ASan errors; .24 native binary: reset works, all three
GPUs printed, limits restored to the owner's 170 W. Related gotcha found in
the same row: `nvidia-smi -rgc` (ResetGpuLockedClocks) clears GPC VF offsets
on this TU102 CMP — manual -rgc zeroes an offset that the production cycle
(P0→governor release→P8) preserves correctly (idle-governor README table
stands; keep manual clock resets out of VF-offset workflows).

## autotune-610: pinning is the whole game when three identical-vendor GPUs share a host (2026-11-07, rev 20261107.25)

Built `cmp50hx-autotune` (grid search under OpenCL FMA load, llama-bench
judge, Xid/AER/watchdog gates, snapshot/restore) and it found the documented
optimum (180 W/+200 on GPU2) without being told — but three facts had to be
probed out first, each of which silently targeted the WRONG card until fixed:
(1) the NVIDIA OpenCL ICD does not honour CUDA_VISIBLE_DEVICES — first "real"
Pareto table was load-on-90HX + NVML-sampled-50HX garbage (dead giveaway:
21.5 TFLOP/s, an unclamped GA102 number, from a "50HX" probe; later a
sustained 14.2-14.7 TFLOP/s at 2010 MHz/162 W for the actually-clamped card);
pin OpenCL via cl_khr_pci_bus_info (added FMA_BUS to tools/fma_bench.c) and
CUDA via one-shot `docker run --gpus device=GPU-<uuid>` — the llama-swap
container itself is CDI-scoped to the 90HX, so `docker exec` pinning is
structurally impossible; (2) `CL_DEVICE_PCI_BUS_INFO_KHR` is 0x410F per
CL/cl_ext.h — guessed 0x42C0 then 0x410C both returned CL_INVALID_VALUE;
read the header, not memory; (3) llama-bench prints lowercase test names and
a combined `pp512+tg128` row that would overwrite the individual scores.
Also learned: `cmp-tune apply` writes the governor drop-in but the RUNNING
governor keeps its start-time env until restarted — documented in
tuning/README. Grid physics: PP-heavy judging punishes power caps (-4..-7% at
165 W) while generation-heavy shapes tolerate them (docs Pareto -44 W) —
judge shape is a policy knob (`--judge-margin`, `-pp/-tg`), not a hidden
default. Busy-guard, apply/cleanup round-trip (config + drop-in + 170 W
baseline all verified byte-restored), deb payload + smoke + lifecycle on
`.25`: green.

## gtuu-mining: read-only mining of the two consumer-lineage unlock repos — 13 tickets, three transferable classes (2026-11-11)

Full static sweeps of MindAllik/GPU-Tensor-Unlock-Universal @ 1d6a508 (B1)
and physicsdolphin/nv-uefi-unlocker @ bbcb92f (B2), both read-only (never
executed, never imported). Shaped finding: claim-90hx and B1's kernel
module are divergent forks of the same Zagitta 7eb51bcc mother — WE are
ahead (PM-notifier resume re-unlock, 2-attempt retry, `stage=` protocol);
B1 is ahead only in host-testability (X1/X3 simulation harnesses),
pre-flight validation (U2/U5), and failure forensics (K15 RISC-V trace-PC —
with the falcon2-window offset trap documented for free). Adopted rows →
`.scratch/gtuu-mining/issues/` tickets 01-13 (tensor-MMA bench closing the
lock-profile gap, cold-state verdicts, strap-tolerant chip-ID, aperture
feature-detect, falcon forensics, config-space walker, live-PROM SHA gate,
gpu_peek read-only triage ko, harnesses, blob-free generation); B2
preliminary deltas (4 GiB staging boundary, booter 0x89/0x91 dictionary,
S3/S5 resume-clearing audit) queued as 14-16 pending its re-sweep. B1
public-citation caveats now codified in `.scratch/gtuu-mining/source-eval.md`
(its provenance.json admits a non-public master with per-file deltas; CMP
support rows are simulation-only; its packaging mirrors NVIDIA firmware via
third-party distro archives). License rule: ports land as separate
GPL-2.0-only files with provenance headers (B1/B2 are GPL-2.0-only; our
kernel side already is). Evidence anchors spot-verified this session
(falcon.c:21/:168, verify.c:43, claim PM notifier; B1 adapter 746 ln,
no-FLR tail 1665, turing_experimental). llm2 guinea-pig baseline before any
hardware work: rev 610.43.03-20261107.28, kernel 7.0.0-38, GPU0/GPU2 50HX +
GPU1 90HX, all 5.0 GT/s, 170 W × 3 (host pointers in the session journal).

URL-resolution sweep while rewriting CREDITS found a provenance event:
our MIT-base upstream **PZH1gdmu/CMP40HX-Unlock is gone from GitHub** —
author account 404s (deleted/renamed-away; the 301 → `GPU-Unlock` → 404
chain proves the account, not just the repo). The vendored port +
`efi-unlock/LICENSE-40HX-UNLOCK` are now the surviving record;
same-named repos under other accounts are candidate mirrors, unverified.
Every other CREDITS URL re-resolved 200 this session.

## gpu-unlock-peek: pre-driver state, named from SSH (gtuu-mining t10, row T2, 2026-11-12)

Port of the read-only peek sampler from GPU-Tensor-Unlock-Universal
@1d6a508 — audit-first: the module's only device primitive is
`ioread32` inside one bounds-checked `peek_read()` (grep table in
gpu-peek/README.md; zero write/config/master/FLR calls), bound-driver
target refuses with -EBUSY, DKMS sibling `gpu-unlock-peek` ships with
`blacklist gpu_peek` and nothing in any unit references it — operator
`sudo cmp-peek <BDF>` only. Trust control mirrors the just-fixed
cmp90hx-claim.sh rule (PMC_BOOT_0 bits 28:20 vs per-card chip; all-FF ⇒
verdict COLD-ALLFF, reads meaningless). Compile gate: 7.2.9 + 6.18.55
native zero-warnings, ubuntu 24.04 (6.8.0-149) + 26.04 (7.0.0-43)
containers green, W=1 clean. Package gate: full deb
`610.43.03-20261112.gtuu1` built offline from cache/ in the CI container
→ PASS_CMP_DEB_SMOKE including the new peek assertions (blacklist line
grep -qx, no-unit-reference scan, wrapper 0755, maintainer-script
downgrade-sweep locks). Live proof awaiting llm2 (down 2026-11-12).

## B2 sweep landed: independent convergence + eight new tickets (gtuu-mining t02 complete, 2026-11-12)

The nv-uefi-unlocker static sweep (P1-P42, table in
.scratch/gtuu-mining/source-eval.md) says three things worth recording.
(1) CONVERGENCE: their TU102 EFI chain independently reaches A's exact
design on portal quirks, BOOT_DIRECT, BTL1 slot rule (they cite OUR
prep_610.c as authority), FAT log discipline, and the PM-notifier ordering
(A's resume priority proven correct from their corpus; the gap is only
force-D0-on-wake, ticket 18). (2) THIRD-PARTY VALIDATION: their
peer-landscape independently reproduces and cites xrip/cmp50hx-unlock's
31.7×/28.4× closed-loop, the FEAT 0x409650/64/6c block, AGESA-CF8, and
adopts issue #25's pre-OS-retrain-hang as their own reason to keep link
policy OS-side — quotable validation, pinned to their commit, not our
memory. (3) SELF-DISCOVERY: the "provenance-pinned Turing BOOT_DIRECT
bootloader" byte-pinned by their release pipeline is OUR all-zero
placeholder (verified sha256(0x00…) = fa43239b…/de676bae… of
efi-unlock/blobs/gsp_rm_boot_dbg.bin) — harmless (payload mode never
consumes the BL slot, now twice independently proven) but ticket 13 must
either generate a real BL or document the zero-badge. New tickets 14-22
from their leads (FWSEC completion gate first — A's WPR2-match-only success
is their root-caused 0x91 race class); their low-trust verdict on B1
("FMLA32" = non-NVIDIA terminology) corroborates the ticket-02 posture from
a line that never touched B1's code. llm2 down today: all gates this
session ran local/container only; bench-toolchain evidence predates outage.

## UBSan gate catches first real UB in production boot code (gtuu-mining t12, rows X3/X4, 2026-11-12)

The host sanitizer harness (efi-unlock/tools/asan-gate-selftest.sh:
cold-state verdict, chip-identity observation, asset attestation, live-
PROM gate, and the entire cmp90_fat_* FAT parser compiled VERBATIM from
the production EFI under -fsanitize=address,undefined -Werror) found its
first real defect in the code it tests — exactly the point of the gate:
the FAT32 BPB parse computed fatsz via `bpb[39] << 24` on promoted signed
int; a hostile/quirky USB stick whose BPB carries bit 31 set makes that
undefined behavior (C11 6.5.7), not merely garbage. Fixed with explicit
UINT32 casts (scenario F14 keeps 0x80000000 permanently under UBSan
watch). The gate was itself validated twice over: its ASan bite proof
(deliberate use-after-free fixture must abort or the suite fails), and
ASan eating the harness's own fixture bug (8.3-name writer overreading a
short literal) on first contact before any production code ran. 37
asserts ALL-PASS: t04 verdict matrix (all-FF cannot read as ALREADY),
t05 strap WARNING semantics, t09 attest tamper/missing-entry refusals +
PROM OBSERVE-exact-digest/ENFORCE flip-refuse+forensic dump/length
field/alloc-fail-skip, and FAT F1-F16 (FAT32+FAT16 synthetic volumes,
LFN reassembly beating the mangled 8.3, adversarial BPB set, corrupted
cluster chain, non-MZ PE sanitizer, alloc cap). No behavior change on
non-UB inputs (values identical where old code was defined); EFI
container build NEW-vs-HEAD baseline: both BUILD_OK, the same single
known ld .note.GNU-stack, zero new.

## EFI asset blobs: generation gate + the discovery that 40% of them are irreplaceable (gtuu-mining t13, row X5, 2026-11-12)

gen-efi-assets.sh now derives bl_gsp_tu102.bin (= ksec2GetBinArchiveBlUcode
UCODE_IMAGE), booter_ucode_prod.bin (= BooterLoad TU102 IMAGE_PROD) and
gsp_rm_boot_dbg.bin (= 131072 zero bytes — the P22 zero badge, now
documented where third parties will find it) byte-exactly from the pinned
610.43.03 source, and the .EFI built on a tree whose generated-class
blobs were deleted then regenerated is sha-IDENTICAL
(eff516f56ecf…3b27) to the committed-blob build: the pipeline proves it
rebuilds the field-proven artifact. SOURCE-MANIFEST.sha256 is
content-derived, timestamp-free, double-run byte-idempotent (P27) and
gates every build-deb; corrupt cache fails loudly with the expected
digest (rc=5), one flipped blob byte fails twice over (MISMATCH +
MANIFEST-FAIL). The honest limit, documented in blobs/NOTICE-ASSETS.md:
v67_payload.bin and booter_ucode_dbg.bin are the ONLY surviving copies
of the deleted CMP40HX-Unlock upstream (the ko-side builder
tools/v67_regen.c, host-compiling the production recipe tables +
gu_payload_build, byte-differs at offset 0 — the blob predates the
tables), and fwsec_50hx_*/sec2_ucode_vbios_* come from card VBIOS ROM
captures (our extractor ships; the ROM does not). Deleting those would
be data loss, so "blob-free" closes as "generation-gated + pinned-keep
with provenance" — maintainer's gitignore call documented as follow-up,
along with the 615 bindata token-format gap for the next driver line.
Bonus field proof of the t20 banner gate: it caught a stale pre-built
.EFI entering a deb during this work — exactly the artifact mix-up class
it was built to catch.

## llm2 boot saga 2026-11-12: two real bugs caught by field contact (gate1 false-reject + gate3 post-mortem)

(1) PREFLIGHT lived-fire proved the t08 gate's refuse-never-bricks design
(boot #2 refused, chainloaded, OS fine — card stayed locked). The reject
itself was a FALSE POSITIVE with an old, familiar signature: on CF8-found
hosts (enc=2 — the finder reports it, the [40HX bar] path uses it),
gRb->Pci config reads return zeros; t08/t18 cfg_read/write wrappers
reintroduced exactly the issue-#47 trap the rebar path had worked around
years ago. Evidence chain: CF8 read/write of COMMAND shows MEM=1 and the
card DECODES MMIO (canary reads real PLM 0xffffff8f) while the RPI path
reads 0 in the same microsecond. Fix: all four cfg wrappers now delegate
to the finder-encode helpers (u40x_pci_rbdf/wbdf); preflight rejects also
print the raw cmd dword; new all-FF guard distinguishes wedge from
lock-out. Harnesses stayed valid untouched (they stub the wrapper
symbols) — the accessor-vs-firmware class is inherently invisible to
host stubs: field contact remains the final gate, one-shot BootNext only.

(2) gate2 (556c6a0f) WEDGED the bench: the t20 clock seed placed at the
TOP of efi_main dereferenced gRT BEFORE InitializeLib() fills it (crt0
defines nothing — InitializeLib sets gST/gBS/gRT). NULL->GetTime = fault
before the log opens = stale ESP log, dead boot entry, no OS. The
unlocker's per-line log discipline saved the diagnosis: boot #2's log
survived untouched, and the ABSENCE of the new (cmd=) telemetry proved
gate2 never wrote a line — narrowing to pre-log death in one read.
Restored .28 from the staged rollback (db5ffdf7 re-verified on ESP), box
back via the "Ubuntu" entry. Relocated below InitializeLib + the rule
documented in-code. Recovery cost: ~1 evening; prevention rules now in
boot-runbook.md: (a) debug EFIs ship as their OWN ESP file + ONE-SHOT
BootNext — never the permanent BootOrder path; (b) protocol-global use
below InitializeLib only; (c) rollback EFI hash re-verified after every
restore.

(3) BIOS baseline drift after the week-long power loss (dead RTC → CMOS
defaults): VT-d now ON (ACPI DMAR present; kernel boots iommu=pt) and
01:00.0 link trains x4 (was x16) — fleet BIOS expectations (VT-d off per
the B2 four-cell matrix on DMA translation, slot at x16) should be
physically re-verified before the next unlock-flow test; gate3's first
live unlock chain will otherwise be a confounded experiment. The t16
canary nailed the inter-boot event class from its first live line:
"verdict=power-cycle".

## gate4 full-chain boot: every new instrument fired on real silicon (2026-11-13, llm2 Boot0002 one-shot)

903-line ESP log, BootCurrent 0002 (one-shot discipline held; .28 stayed
the permanent path): banner -> CANARY verdict=power-cycle -> PREFLIGHT ok
(pm=0x60 pcie=0x78 steps=3 — the MSI-12B fix confirmed on the live card)
-> ATTEST ok (9 assets) -> PROM OBSERVE first fleet digest
ae6497db0064e1fa654c368f09b18a6a06e5374e345016bd4fdeccb1d3263d39
bytes=0x40000 -> cold-state CLEAN -> PMC_BOOT_0 matches RM constant ->
[BAND-HIGH] attempt#1 (ladder idle) -> FWSEC gate PASS
(wpr2 exact, cpuctl HALT @7ms, scratch0e=0, mbox=0) -> *** UNLOCKED ***
-> xp3g gen2 -> CANARY SET efi@0x1480=0x0164c0de readback ok -> FINAL-GATE
"ok RELOCKED-GATE plm=0xffffff8f SS intact not a loss" — the B2-P33
taxonomy in action. OS ground truth via read-only resource0: BOTH 50HX
SS0=0x88888888 SS1=0x8 UNLOCKED, Xid 0, no failed units. Stamp clock
real now (+1s..+14s) but 1 s resolution on this firmware (GetTime
Nanosecond reads zero — recorded; sub-ms needs the PTIMER source, not
blocking any A/B use). Log contains NUL bytes (grep -a needed) from a
hexdump section — collect's substring greps unaffected, noted.
Caveats: 01:00.0 slot trains x4 (BIOS/slot drift — 04:00.0 is x16);
the 90HX in 03:00.0 was physically replaced by an RTX 5060 Ti (GB206)
during the outage — claim/canary-gen2 rows n/a until it returns.
Warm-vs-cold canary distinguishability now testable: efi slot armed with
0x0164c0de — next boot (warm) must classify differently than this boot
(cold); that's the t16 live-matrix's second row.

## Stage-2 live proofs: PROM ENFORCE drill complete + layering honesty (2026-11-13, four boot cycles)

ENFORCE ok boot: digest ae6497db… re-read identical from the real ROM a
second boot running -> gate green line. Flipped-digit boot: "ENFORCE
MISMATCH: live=ae… pin=be… REFUSE unlock" + "live ROM dumped to
50hx_prom_fail.bin (262144 B)" + chainload continued (box up, pre-OS
unlock refused) — every assertion of the ticket-09 drill, failure path
included; artifacts then removed -> OBSERVE mode restored (verified next
boot: OBSERVE line + *** UNLOCKED *** at +7 s). Layering discovered
while verifying "booted locked": on the refused boot the cards STILL
ended unlocked — the patched driver's OS-side V526 stock-relock unlock
covers what the pre-OS path skipped, and cmp50hx-boot's own accounting
shows it ("installed=2 unlocked_by_efi=1" — one card had missed the
booter-window lottery this boot, rescued at OS level). So the PROM gate
is precisely a PRE-OS supply-chain gate: it protects the firmware
assets the booter stages; a fleet policy that should also pin the
OS-side path would need the same check in cmp50hx-boot (recorded as a
design consideration, not silently bundled into this ticket). t16 canary
honest matrix row: this platform's warm reboot goes through a POST that
resets both scratch and FEAT witnesses — warm reads identical to cold
("power-cycle" verdict); the canary's distinct-live value is the
no-reboot event classes (RTD3 park, manual FLR between boots) which skip
POST. No forced PARTIAL/injection-failure experiments were run on the
serving host — those rows stay harness-only per the runbook's rule.

## llm2 is dual-stacked (2026-11-13 ~13:1x): another unlocker lineage took the boot path

Post-promotion validation never observed our binary: the 13:13/13:25
boots ran old-style (no banner/stamps/gates) unlocker logs from a
DIFFERENT stack present on the box — dpkg shows
cmp90hx-unlock-nvidia 610.43.03-cmpunlock.7.0.0-38 (a second DKMS
nvidia) plus 90hx-boot-ladder/90hx-solo services and
/var/lib/cmpunlocker-rs — the cmpunlocker-rs lineage; BootOrder was
reset to 0000-first again. Our promoted artifacts remain in place and
sound: ESP 50HXUNLK.EFI = gate4 8eed5574 (sha-verified), gtuu6 installed,
gate4 already has FOUR successful live boots of validation behind it as
BootNext one-shot (12:16 full chain, 12:31 ENFORCE-ok, 12:35 ENFORCE-
mismatch+dump, 12:39 OBSERVE-restore+unlock). Both 50HX currently
UNLOCKED (SS exact; other stack or ours, state is equivalent at
register level). 03:00.0 (RTX 5060 Ti) answers our TU102-offset reads
with the badf5040 sentinel — correct, it is not a CMP. Pause: boot-path
ownership of this machine must be settled before further promotion
boots. Our canary script gracefully reported the missing-90HX case
(verdict=unreadable) rather than misbehaving.

## PROMOTION VALIDATED: gate4 is llm2's permanent pre-OS unlocker (2026-11-13 13:33)

BootOrder restored to 0001-first; plain reboot (no BootNext) ->
BootCurrent 0001 ran the promoted binary (50HXUNLK.EFI sha 8eed5574 =
gate4, four-time live-validated one-shot first) through the full chain:
banner, CANARY power-cycle verdict + re-arm 0x0164c0de, PREFLIGHT ok
0x60/0x78, ATTEST 9/9, PROM OBSERVE (digest identical fifth time —
stable silicon baseline), [BAND-HIGH] attempt#1, FWSEC gate PASS with
the HALT tail now measured at 69 ms (vs 7 ms first boot — the per-boot
variance the t14 gate exists to absorb, logged not raced), booter OK
attempt 1, *** UNLOCKED *** +7 s, FINAL-GATE RELOCKED-GATE classification.
OS ground truth: both 50HX SS-exact UNLOCKED, Xid 0, zero failed units.
The 13:13 "old-format log" anomaly stays formally open (dual-stack box;
other lineage's services start early enough to write the ESP file from
userspace — under 0001-first our log is byte-perfect, which is all the
fleet needs). Tickets 04/05/08/09/14/15/16/19/20 closed with LIVE
evidence; residual rows: t18 FLR-craft live watch (do_flr not on this
flow's path — 0 lines, needs a boot that takes [8b] or ladder retry),
t17 halt-decode (no halts — happy path only), t10 peek positive (needs
an unbound CMP card; refusal-guard proven), t04 PARTIAL + t15 LOW-band
(harness-only by policy: no forced-failure experiments on a serving
host), t01 locked cell (stock-driver window, owner-scheduled), t13
guinea-pig boot row (satisfied: unlocked boot with generated-payload
binary eff516f5-lineage… gate4 itself, digest chain in runs doc).

## t11 phase-2: X2 aperture claim — plus a self-correction on the phase-1 record

Verification-before-claim caught two things during phase-2 scoping: (a) the
earlier working note said the claim harness "extracts from unlock_610.c
between GEN2-CLAIM markers" — WRONG: test_claim.c #includes the PRODUCTION
unlock_610.c verbatim (whole-file, two-build pattern) and the canary/gen2
production logic lives in cmp90hx-claim.sh (itself the extraction source of
reset-canary-selftest.sh); the shipped harness was always stronger than the
note claimed (real code under test, not a copy). (b) the aperture wrapper
name check (gpu_unlock_remove_apertures, header+call site match) — fine.

Landed: X2 claim in unlock_transaction_reset right after the post-FLR BAR
verify (FLR resets BAR registers, so resize survives only from there on).
Params x2_aperture (default 0 — legacy remove-and-free stays the fleet
path) + x2_size_mb (256). Semantics mined from B1 (static-read-only):
resize BAR1 + request it ("gpu_unlock") so the aperture window is
provably the transaction's; ours differs by DERIVING state from the live
BAR every run — carry path when size+busy match (resume re-unlock: the
flow runs again before nvidia resumes, pci_save/restore around the phases
carries the resized BAR; a lost resize re-claims), no global claim
memory (multi-card safe). Contract sequence release->resize->request with
rollback-resize on busy window; every skip path named (-EOPNOTSUPP
non-prefetch, -EINVAL <4MiB want, -EOPNOTSUPP empty capability, -EIO
resize fail, -EBUSY refused+rolled back). PCIe §7.8.6 index discipline
caught once by fixture (256 MiB = idx6 = 2^28, initial fixture assumed
idx4=64 MiB and the harness immediately failed the length pin — the
value of pinning byte-exact effects, not just return codes). Harness
63/63 (25 new: picker, happy sequence, rollback, guard, carry, capped
capability, resize-fail, pre-aperture ordering, full-gauntlet X2 inside
the transaction with legacy removal first). Native builds 7.2.9 + 6.18.55
zero warnings. Live row owed: one-shot trial on a 90HX when it returns
(param default off until then; 50HX fleet untouched).

## F closed: 615.78.08 bindata format now parses (driver-bump unblocked offline)
extract_boot_assets.py: NvU64-word arrays (LE decode) + <8 zero-byte alignment
pad rule, both measured from the pinned 615 tarball, both adversarially
probed; 610 path byte-identical to MANIFEST.sha256 through the patched code.
The t13 follow-up ("non-byte token" rejection) is closed before the bump,
not during. Extraction validity != install validity — stated in the ticket.

## Build ergonomics: pre-baked docker images (user-requested), + gtuu8 ready
The ad-hoc recipe reinstalled apt deps AND re-downloaded the 440MB NVIDIA
.run inside every throwaway container (the rsync dropped cache/). Fixed:
docker/Dockerfile.build + Dockerfile.smoke (tags cmp50hx-build/smoke) with
tools/docker-deb.sh — host sha-verified cache/ bind-mounted, images built
once. Warm run = 53s full stage->EFI->deb->26.04-smoke->sha-check, rc 0,
no network. Side discoveries: (1) build-deb.sh already honors
SOURCE_DATE_EPOCH — with it (wrapper derives from `git log -1`), two
independent containers produced a BYTE-IDENTICAL .deb (the ~42B drift
without it is timestamps); embedded EFI byte-stability was already known.
(2) containers now chown /src writes back (root residue broke temp-dir
cleanup — caught on the first wrapper run). (3) local sudo needs a
password (the passwordless grant was llm2-only) — docker+alpine removed
its own root dirs instead. gtuu8 (610.43.03-20261113.gtuu8, deb sha
a9e2ada1…) = first artifact via the new path: ships phase-2 claim module
(x2 params default OFF) + unchanged EFI 8237b24b. llm2 is powered off
(user-confirmed) -> install + DKMS gate on 7.0.0-38 owed at power-on.

## Push executed — the stream is off the single disk (2026-11-13)
Owner said "push"; configured `fork` remote (github.com:jimOnAir/cmp50hx-unlock,
the owner's own public fork — author-identity and prior-shared-history verified)
accepted master by fast-forward: 37 stream commits (80dde56..dd477d5), then
8ff75da (integrity pass; its -f flag rewrote only my own seconds-old dd477d5
to fix a self-introduced citation typo — fork/master==master re-verified by
sha after every push). Gate kept: pre-push scan of the pushed diff = 0
credential patterns, max blob 300 KB source, zero .run/.deb artifacts.
origin (xrip third-party) untouched. docs/agents/issue-tracker.md now codifies
the target so future sessions don't re-ask. Same pass: NOTICE license
preservations made true (claim-90hx/licenses/), full host-gate suite green
at HEAD (8 extraction selftests + ASan + memmap + 74-assert claim harness).
Backup concern CLOSED. Machine-dependent queue unchanged: gtuu8 install +
DKMS/modinfo gates at llm2 power-on.

## Deep-phase feed: harness drives the FULL orchestrator with real silicon inputs (t11 image-feed landed)
S24/S25 provision real 610 firmware (manifest-gated extract.sh, cached) and
the captured 90HX board PROM, resolve the production recipe via
gu_card_find(0x220d), and run claim->layout->dma->radix->gfw->fwsec end to
end in-kernel-shape. Outcomes pinned (82 asserts): real assets pass
production ELF/descriptor validation; real PROM parses FWSEC-FRTS; launch
failure after BME RETAINS (dma_live>=1, "firmware did not stop");
k_bme_stuck_off refuses BEFORE the started boundary with FULL clean unwind
(dma_live==0). Self-caught fixture bugs (each now a comment): (a) absence
asserts on an empty ring pass VACUOUSLY — the ring-dump helper + positive
needles ("recipe selection:", "FWSEC: reading PROM") now guard every
absence claim; (b) coherent DMA must be page-aligned (production radix
checks the mask — calloc 16B was wrong-shape fidelity); (c) dev.dma_mask is
enumeration-seeded by the PCI core; (d) fix_reset() zeroes the PROM too —
reload after reset or FWSEC legitimately refuses; (e) the assessor's
config_ok needs a readable vendor id — fixture ordering bug. Runner caches
provisioning under $TMPDIR keyed by the tarball sha (warm run 2.2 s); no
repo cache => loud SKIP. k_fw_name_fail remains the negative control.

## 90HX live again — first full-orchestrator unlock on real silicon + X2 live row (2026-11-15)
Card returned at 01:00.0 (10de:220d). gtuu9 boots: claim unit insmods with
the new CLAIM_90HX_OPTS hook; dmesg shows the entire production sequence on
REAL GA102 silicon: claim->layout(fb=2.5G)->dma(20606 pages)->gfw->fwsec
(v3, fuse ver=2, real WPR2)->publish->host ss0=0x88888888 ss1=0x8->FLR->
stage=flr clean->handoff ret=0->"unlocked". X2 trial (x2_aperture=1):
"x2: BAR1 resize to 256 MiB failed (-16), claim skipped" — EBUSY: firmware
owns the 16 GiB boot-time reBAR aperture (topology reality the host fixture
doesn't model); named skip, unlock proceeded, nvidia bound, 0 Xid. Verdict:
X2-as-designed is correct-but-inert on this board (resize-from-16G is
firmware-guarded); skip line now prints the BUSY hint (field-actionable).
Bench operational lesson: script default BDF was the ORIGINAL slot
03:00.0 — silent no-op after the card moved; fixed by systemd drop-in
Environment=CMP90_BDF=0000:01:00.0 (documented in script). Boot-path note:
bench still boots BootCurrent 0000 (GRUB direct) — pre-OS unlocker idle;
50HX cards unlocked via OS-side V526 (cmp50hx-boot accounting). Trial
config will be REVERTED same-day: CLAIM_90HX_OPTS removed, reboot, defaults
verified.

## Permanent path restored + topology ledger (2026-11-15, later boot)
BootOrder had drifted to 0000-first (the power-off; BIOS reset defaults).
Restored 0001-first (the promoted, owner-validated permanent path — same
class of action as the Nov-13 restore) and plain-reboot-verified gate5:
full chain on BootCurrent 0001, PROM OBSERVE ae6497db… stable SIXTH boot,
FWSEC HALT tail 76 ms, booter attempt#1, canary armed, FINAL-GATE
RELOCKED-GATE-class, MEMMAP line present. Fleet green: both 50HX
register-UNLOCKED, 90HX claim "unlocked" (journal), Xid 0, units 0/0.
RTC keeps time now (hwclock==kernel) — the battery appears replaced; the
runbook carries a "Current bench topology" section so slot assumptions
(topology changed when the 90HX returned) can never go stale silently.
NEW PHYSICAL row for the owner list: 90HX slot 01:00.0 negotiates x4 with
LnkCap=x16 and clean LnkCtl — physical layer (reseat/slot), not software.

## CI caught what 15 local passes + local ASan could not: fixture OOB in mailbox-dict-selftest
GitHub host-gates (first dispatch, run 43711399575) segfaulted the mailbox
dictionary selftest on gcc-13 while Manjaro/gcc-15 passed 15/15 — even the
ASan build on gcc-15 was clean (the sanitizer's layout hides this hazard).
Reproduced deterministically inside cmp50hx-build (the pinned ubuntu:24.04
gcc-13 image — the docker-image work paying for itself immediately), UBSan
there pinpointed line 133: index 3 for char*[3]. Cause = MY OWN ticket-17
fixture: two dictionary-contract entries left the third tokens[] slot
uninitialized (2-of-3 explicit zeros) while the walk loops "until NULL" —
gcc-15's stack layout made the garbage read zero (silent luck), gcc-13
read garbage and died. Fix is structural not data-only: entries fully
NULL-terminated AND the loop bound is now sizeof-derived (a sentinel walk
must never trust the data to end it). Class lesson: a harness passing only
on the author's toolchain is not a gate — the pinned-image runner IS the
gate; green CI re-verified post-fix.

## The bite proof itself was hollow: optimizer erased the gate's own bug (day-2 CI hunt)
After fixing the fixture OOB, the CI re-run failed on the NEXT victim of
the same toolchain-class: asan-gate's "POISON FIXTURE" — a deliberate
use-after-free whose only job is to PROVE the ASan gate bites — printed
nothing and exited 0 on gcc-13: the compiler constant-folded the freed
printf("%s") load away, so no read instruction existed for ASan to ride.
(Local gcc-15 "caught" it — layout luck a second time; the harness's own
ASan build hid it too, since sanitizers change layout.) Two wrong fixes
attempted honestly and disproven by testing the claim, not the exit code:
argc-gated branch (dynamic analyzers don't run dead code) and volatile-
stored pointer into printf (still folded). Final shape is language-proof:
volatile-qualified LOAD through the freed pointer (mandated read
instruction) — PASS poison caught (exit=1) 3/3 on the gcc-13 image.
A second splice blunder self-inflicted during the fix (index() grabbed the
harness main instead of the poison main — caught by the harness's own
SyntaxError, restored from git, anchored properly). Meta-lesson for every
gate in this repo: a self-test's negative control must fail LOUDLY on the
PINNED image, not only pass on the author's box.

## The prototype probe: Ubuntu backport defeats every version gate (docker-lifecycle hunt, day-2)
CI lifecycle (linux-lifecycle job, first-ever dispatch of the tag-only
workflow) died in postinst's claim-DKMS loop -> LIFECYCLE_LOOP_LEGS_FAILED=4.
Repro pipeline: new cmp50hx-lifecycle image + tools/docker-lifecycle.sh
(user-requested "use the prepared images" — the third image now bakes the
CI job's exact package set; warm loop 2-3 min vs hours of CI round-trips).
Chain of causes, each caught only by letting a DIFFERENT environment judge:
(1) my LINUX_VERSION_CODE gate (6.12 boundary) passed 7.0.0-38/6.18.55/7.2.9
and failed Ubuntu 6.8; (2) with a 3-arg fallback, 6.8.0-149-generic failed
the OPPOSITE way — Ubuntu BACKPORTED exclude_bars into the 6.8 stable
series mid-ABI: 124-generic declares 3 args, 149-generic declares 4,
LINUX_VERSION_CODE IDENTICAL. No version gate can exist for this API.
Final mechanism: claim-90hx/Kbuild greps the declaration in the very
headers being built against (grep -A1 pci_resize_resource | grep -q
exclude_bars -> -DGU_RESIZE_RESOURCE_4ARG) — the aperture_compat.h
doctrine, applied to a prototype; both branches compile-proven across the
full matrix (124=3arg, 149=4arg, 6.18.55, 7.2.9) + harness profile
mimics 6.8-era (shim LINUX_VERSION_CODE/KERNEL_VERSION + 3-arg stub).
Shipped consequence had it been missed: gpu-unlock-claim unbuildable on
Ubuntu 24.04 LTS fleet -> claim unit fail-closed -> silent 90HX Gen2 loss
(postinst hard-fails loudly instead — by design). Repro hygiene lessons:
uname shim useless (dpkg restricts PATH to /usr/sbin:/usr/bin:/sbin:/bin);
CMP_DEB_KREL is a build-set NARROWER than the assert set — passing it broke
the equivalence the assert checks; faithful container run = no overrides
(the outer kernel never enters build_kernels anyway — the earlier "uname
leak" diagnosis was wrong; it was the 149 build failure surfacing as apt
trigger depmod noise). gtuu11: LIFECYCLE_LOOP_LEGS_FAILED=0 locally
(all legs; offline leg by design needs --network-none, which CI has).

## 615 source sweep (2026-11-23, user: "check sources for 615 driver update")
No 615 update exists to check: unified .run tree's last 615 = 615.78.08
(our cached, sha-pinned build — falsified 2026-11-01, closure final); DC
line has 615.71.10 (10-19, Blackwell TMA fix only, no Turing/booter
surface, no .run). The real movement: R620 opened 2026-11-04 as the
current PRODUCTION branch (620.70.06/.73.04, Turing still supported) —
future unlock-port target if ever is 620, skip 615. R610 EOL 2027-08-03.
Dated addendum appended to docs/CMP50HX-615-UNLOCK-INVESTIGATION.md.

## The real find of the 615 source sweep: our 610 pin is below NVIDIA's September security fix line
Sweep continued past NVIDIA's trees into PSRT (nvidia/product-security GitHub,
bulletin 5861 = "GPU Display Driver - September 2026", fetched raw md): the
authoritative table lists for **every** Linux R610 product line (GeForce,
RTX/Quadro/NVS, **Tesla**): "All driver versions prior to 610.57.04" affected,
updated 610.57.04. Our production pin is 610.43.03 -> affected. Batch: ~60
CVEs, worst CVE-2026-47591 (NvRoot, CVSS 7.8 NVIDIA / 9.3 Stealthium
estimate for multi-tenant: unprivileged local user -> read-only memory
write -> code exec/EoP; container-relevant). All local-privilege: single-
tenant bench = low urgency, multi-tenant hosts = real.
Bump cost measured end-to-end (this was cheap, so it was done):
- 610.43.03 (2026-07-03) vs 610.57.04 (2026-07-29, branch-terminal): 114
  files differ in open-gpu-kernel-modules source.
- **All 9 boot-asset sources (TU102/GA102/AD102 BooterLoadUcode + GspRmBoot
  + ksec2 BlUcode) BYTE-IDENTICAL** (sha256 of the 9 g_bindata_*.c files,
  both trees) -> the unlock-critical ucode is unchanged; changed bindata are
  GH100/GB100/GB202/GR100 families only. EFI ATTEST manifest gate unaffected.
- **16/16 product patches (both-flavor series, cumulative replay on 610.57.04
  scratch tree) apply clean, zero conflicts** — the only changed patch-target
  file (kernel-open/nvidia/nv.c) takes no context conflict. build.sh already
  dry-runs every patch (line 241) — the bump rides the same harness.
- source sha recorded: 610.57.04 tarball 619d7b5ce1f7... (cache/610.57.04.tar.gz).
Decision left to owner (production pin = owner domain): bump driver-pin.env
triple + gtuu12 + lifecycle + bench drill, OR stay 610.43.03 with local-
trust mitigation. NOT executed: driver-pin.env untouched, nothing installed.
Corpus context: the consumer-lineage ecosystem itself stayed on 610.43.03 —
MindAllik v1.3.2-1.3.4 (Nov 13-20: TU102 two-write payload, BCR_CTRL fix,
dma_alloc_coherent mask, RM_RISCV_UCODE_DESC v4 parsing) explicitly updates
"v67-tu102-610.43.03.bin"; physicsdolphin likewise "pinned 610.43.03". No
upstream publishes 615-Linux unlock work either way.

## Corpus batch 2: every referenced repo is now in the pinned analysis set (2026-11-24)
User: "add all mentioned repos to analysis". tools/clone-upstream.sh extended
(batch 2 list, full-URL/HF entries, GIT_LFS_SKIP_SMUDGE for HF, ls-remote
drift column — pinned trees never auto-update, drift = "fresh review
needed"). work/upstream 17 → 34 repos, 658 MB, rc=0. Notables pinned:
tianocore/edk2 + DMTF/libspdm + ncroxon/gnu-efi (toolchain), P104-100 Gen2
lever repo cloned straight (was docs-mirror only), 90HX Gen2 siblings
(NatsumeAi/Rhonstin/Cyridd/elias-gaeros). Dead references proven and
recorded: minicx/cmpunlocker 404, studebaker8/cmp170hx-gen2 404,
PZH1gdmu/CMP40HX-Unlock ghost-301→404 (rename then account deletion).
Batch-1 drift persists as expected (5 repos, physicsdolphin already at
45db233 — two days after our c231ac3 sighting; fastest-moving lineage repo).
Manifest: docs/cmp90hx/upstream/CLONES.md (git-tracked) regenerates
deterministically.

## Driver-update investigation via corpus batch 2 (2026-11-24): the landscape moved around our pins
NVIDIA axis: nothing new since 11-22 (615 frozen .78.08; 620.73.04 still newest;
latest.txt now points at 620.73.04 — production recommendation flipped to R620;
PSRT 2026 GPU-display bulletins = Jan/May/Sep only, September still current →
the 610.57.04 security-bump analysis stands unchanged).
Corpus axis (35 repos incl. new amoghmunikote/cmpunlocker): the unlock
community HAS moved to 615/620 while we sit on 610 — Cyridd ships fuzz-0
patch trees for 610.57.04/615.71.09/615.78.08/620.70.06 on CMP40HX (TU106),
rediscovering our exact 0x1c@0x1b38 wall and bypassing it by embedding the
signed 610.57.04 TU102 booter archive as a temporary unlock-only booter
(native booter kept for GSP launch). Their archive SHAs match our computed
hashes byte-exact (independent supply-chain verification). amoghmunikote
(GA100 line) maintains through 615.71.10. physicsdolphin's 621.01/GSP-620.67.01
observations = Windows-side FLR-rezero investigation (consumer TU106): "losses
only on the 621.01/630.20 generation" — Windows-only axis, noted.
Net: production unchanged; a future 620 port now has a public TU10x reference
implementation + named API gotcha (kvbiosExecuteFwsecFrtsCmd_HAL) — the 615
investigation doc carries the full addendum.

## "Can we move to 615/620?" — answered with measurements, not opinion (2026-11-24)
620.70.06 source downloaded (sha bc9fa156 == Cyridd's pin, triple-verified
supply chain). Booter per-label digests (raw data, TU102+GA102): 615==620
byte-identical EVERY label — one wall for both branches. 16-patch series on
620: 11 clean / 5 conflict (both stockflow bases + rebar + p2p pair — the
620 nv-pci.c/io_vaspace.c/gsp moves; context-level). In-driver unlock needs
the booter-embed port (the only real engineering; mechanism + API gotcha
named + reference impl). EFI + claim unaffected by driver version. Verdict
recorded in 615 investigation doc §"Can we move": 615 no; 620 yes-as-bounded-
project at R610 EOL (2027-08-03) or concrete need; NOW = 610.57.04 security
bump (zero-risk, pending owner call).

## 610.57.04 security bump executed (2026-11-23/24; owner: "let's bump 610 first")
Pin triple flipped (source 619d7b5c = triple-verified: ours + Cyridd + the
GitHub tag; .run b2e935c6 verified against NVIDIA's own published .sha256sum
after a TLS-truncated first download — retry+`-C -`+`sha256sum -c`). The
series fight was all in ONE place and it was honest signal, not noise:
patches/common/01 (string-API backport) — its own README says "retired
(615 absorbed upstream)"; measurement says **610.57.04 already absorbed
every fixed site** (os-interface strscpy, uvm_pmm snprintf, nvswitch/nvkms;
the lone surviving strcpy at os-interface.c:422 was never a patch target).
Container death mode explained: common applied PARTIALLY in build.sh order
→ 08-profiling dry-run conflict; retired it per the README (git rm, history
kept) → 15/15 clean. Second honest signal: firmware MANIFEST gate flagged
exactly gsp_ga10x.bin changed (3/4 unlock assets byte-identical, as the
byte-identical g_bindata sources predicted) — regenerated manifest, one
line, digests cross-checked against a fresh direct .run extraction.
Third: recipes.h baked gpu-unlock/610.43.03/ firmware paths vs postinst's
<driver_version> dir — fixed at staging with a version-agnostic sed +
assert (future bumps never touch recipes.h; harness unaffected, it compiles
the verbatim source). Tooling drift found en route: docker-deb.sh hardcoded
the old .run filename in the offline probe (now pin-driven) and root residue
from failed builds drowned errors (resilient cleanup trap, tail 30→120).
Gates: docker-deb PASS + smoke; claim harness 86/86; lifecycle
LEGS_FAILED=0 on the bumped deb. Bench + CI pending this commit.

## NeithOS survey (2026-11-24, user: investigate neithos.ru)
Full-site read + engine identification; durable note: docs/neithos-survey-2026-11-24.md.
Headlines: closed panel, weekly releases, CMP50/CMP170 are FIRST-CLASS
hardware for them (dedicated vLLM SM75 branch, CMP presets since 1.0.35,
own blog posts for both cards) = external production validation of the
unlocked-CMP-as-LLM-tier thesis, incl. FP16-not-BF16/FA2-caveat on Turing
and "re-verify VRAM exposure after every driver update" (our bump, exactly).
Engines behind it are mostly open and adoptable (QEngine MIT RTX30-class,
Haru-neo/qengine Apache-2.0 for sm_70 mining cards, SDNQ GPL-3.0 INT8-on-
Turing). Ranked adoptables in doc: doctor preflight, card-capability sheet,
health-check updater, opt-in GPU Lab telemetry, Pearl Mining co-tenant,
ops phrasing. Open data point: their 50HX are modified 20 GB; stock MSI
spec 10 GB -> verify our cards' actual memory.total (TODO on a CMP host).

## Cross-version upgrade: second bug found by the container control run (2026-11-24)
Control (unfixed gtuu12 + new --upgrade-from leg) FAILED differently from the
bench — and that delta was the real lesson:
- bench dkms (Ubuntu 26.04): dangling old /usr/src makes `dkms install`'s
  auto-swap HARD-fail -> postinst dies -> dpkg iF (observed live).
- container dkms (24.04): same dangling tree -> install survives, BUT the
  orphan registration then poisons every later `dkms status` (kernel-update
  autoinstall silent-skip = the real-world trap) -> our assert caught it.
- and dkms on 24.04 EXITS 0 WHILE PRINTING "Could not locate dkms.conf" —
  first sweep fix trusted rc, `|| rm -rf` never fired, orphan survived.
  Fix: best-effort remove, then VERIFY and force-remove what remains.
Sweep is deliberately narrow: only dirs with a DANGLING source symlink
(dkms's own kernel-<ver>-<arch> state dirs have no source link — untouched;
earlier loose glob would have rm -rf'd live state). Container bonus find:
lifecycle image lacked zstd -> `dkms: zstd: command not found` during .zst
install — baked into Dockerfile.lifecycle (26.04 base already has it).
Final matrix on gtuu15: fresh-install legs + upgrade gtuu11->gtuu15 + purge
ALL PASS, LIFECYCLE_LOOP_LEGS_FAILED=0 (control failed exactly one leg:
upgrade_assert). Wrapper gap closed: docker-lifecycle.sh now takes the old
deb as $2 and screams when the upgrade leg is skipped.
