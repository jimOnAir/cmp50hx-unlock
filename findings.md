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
