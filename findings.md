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

**Where 615 dies:** the 615.78.08 signed Booters (TU102 **and** GA10x) reject
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
