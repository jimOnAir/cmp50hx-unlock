# gpu-peek — read-only pre-driver BAR0 sampler (`gpu_peek.ko`)

Map `gtuu-mining` ticket 10. The read-only diagnostic sibling of
`gpu-unlock-claim` (`claim-90hx/`).

## Provenance

- Ported from the **unaudited third-party GTUU-sweep clone**
  `diagnostics/peek/gpu_peek.c`, evaluated commit `1d6a508`, GPL-2.0-only,
  GTUU row **T2**. Port + audit — not vendored: the reference was never
  executed as part of this work.
- Local changes against the reference: required single-card `targets=<BDF>`
  parameter replaces the scan-all-GPUs mode (which also leaked its final
  `pci_dev` reference); bound-driver refusal added; PMC_BOOT_0 chip trust
  gate added (no verdict is derived from untrusted reads); the AD102 GFW /
  falcon / fuse-block extras outside the ticket read set were dropped; all
  offsets come from our registers mirror.
- Register **names/offsets authority**: `claim-90hx/registers.h` (mirrored
  into `peek_registers.h`, sync note inside). Readout field order:
  `docs/CMP50HX.md` (proved TU102 readback table) and the post-driver
  verifier `native/verify.c`. Chip gate: `claim-90hx/cmp90hx-claim.sh`
  `bar0_reads_trustworthy` (row U4, the masked 28:20 fix) and
  `claim-90hx/recipes.c` (`TU102 = 0x162`, `GA102 = 0x172`).

## Distribution discipline — read this first

> **Shipped modprobe-blacklisted. Operator `insmod` (or `cmp-peek`) only.
> Nothing in the boot flow may ever load `gpu_peek` — no unit, no alias, no
> modules-load entry, ever.**

DKMS `AUTOINSTALL=yes` only keeps the `.ko` rebuilt across kernel updates —
exactly the `gpu-unlock-claim` semantics: the module is installed and
loadable, never load-bearing. Blacklist: `deb/blacklist-gpu-unlock-peek.conf`
→ `/etc/modprobe.d/gpu-unlock-peek.conf`.

## Read-only audit (hard acceptance criterion, ticket 10)

Every MMIO access is an `ioread32`-class primitive; zero writes, zero
resets, no Bus Master / MEM-space enable changes, no config-space writes.
Reproduce with these greps against `gpu_peek.c` (all hits listed are in
comments or in the `peek_read` single-load wrapper):

```text
pattern                              verdict                code hits
-----------------------------------  ---------------------  ---------------------------------
iowrite*, writel, write*             none                   —
readl / ioread32                     only ioread32          peek_read(): 1 (the module's only MMIO primitive)
writel                               none                   —
pci_write_config*                    none                   —
pci_read_config*                     READ only              pci_read_config_word(PCI_COMMAND): 1 (cold-vs-wedge context)
pci_enable_device* / pci_set_master  none                   — (a cold card is REPORTED, never enabled)
pci_alloc_irq* / FLR / *_reset       none                   — (reset words appear only in comments/strings)
pci_iomap / pci_iounmap              map/unmap balanced     1 + 1 around the sample
pci_dev_lock + pdev->driver guard    refuse-if-bound        unlock_one posture from claim-90hx/main.c
notifiers / request_irq / pm hooks   none                   — (rmmod is always clean)
```

## What it prints (one card per invocation)

`insmod gpu_peek.ko targets=0000:03:00.0` → synchronous `dmesg` lines:
`PMC_BOOT_0` + `PCI_COMMAND` context, the permission PLMs (`WPR_CFG_PLM`,
`WPR_PLM`, `FBPA_PLM`, family `FEAT_PLM`), the `SS0`/`SS1` speed-select
words (TU102 `0x409664`/`0x40966c`, GA102 `0x82381c`/`0x823820`), the
`FEAT_READOUT` cluster (9×3-bit fields `IMLA0/FMLA16/DP/FMLA32/FFMA/IMLA1..4`,
0=full .. 6=1/64) with the raw SS0 override nibbles, and the verdict:

| verdict | meaning |
|---|---|
| `UNLOCKED` | SS0=`0x88888888` **and** SS1=`8` — full-rate selectors landed |
| `PARTIAL` | exactly one of the two — ticket 04 `PARTIALLY_MODIFIED`, unknown half-open state |
| `LOCKED` | neither word shows the full-rate pattern |
| `COLD-ALLFF` | trust control failed (`PMC_BOOT_0` unreadable or chip field ≠ `0x162`/`0x172`): **verdict withheld** — MEM decode off = cold since last reset (normal); decode on = wedge, power-cycle before trusting anything |

## Usage

```bash
sudo cmp-peek 0000:03:00.0     # refuse-if-bound checks, insmod, print, rmmod
sudo cmp-peek --help
```

Manual equivalent: `sudo insmod gpu_peek.ko targets=<BDF>; dmesg | grep
gpu_peek; sudo rmmod gpu_peek`.

## Build

```bash
make                                          # running kernel
make KDIR=/lib/modules/<ver>/build            # any header tree (DKMS entry: same)
```

Compiled warning-free (also with `W=1`) against `7.2.9-1-MANJARO` and
`6.18.55-1-MANJARO` headers on 2026-11-12.
