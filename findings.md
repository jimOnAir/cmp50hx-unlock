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
