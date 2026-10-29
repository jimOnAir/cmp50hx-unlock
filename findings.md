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
