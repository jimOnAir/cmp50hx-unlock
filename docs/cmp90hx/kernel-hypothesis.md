# Kernel-version hypothesis for the run-#2 refusal — source-level verdict

**Question.** Every published rejoin16 Gen2 success runs an older kernel
(jdowning bench 2026-08, Wh1stle05 on 6.8.0-139, pearlfortune validated on
6.12.95; iatethelogs' pwner caps at Ubuntu 24.04/≤6.8). llm2 is the only
≥7.x host in the corpus — and the only failure (run #2 refused 0/49).
Does the kernel version explain it? (Window #11 on 6.12.95 is the live
discriminator; this memo is the static answer, done 2026-10-31 with the
host powered off.)

**Verdict: not supported at the source level.** The entire run-#2 path is
kernel-version-independent, and every kernel-mediated primitive it uses is
shared with run #1, which lands 100% on this host under the same 7.0.0-38
kernel. Residual kernel influence is limited to load-time platform state
(config/BIOS-era effects), which no llm2 observation has ever implicated.

## Path traced (rejoin16 spec branch, patched tree `work/build.1vZgdr/source`)

`kernel_gsp_booter_tu102.c` REJOIN16 branch, in order:

1. Gate `GPU_REG_RD32(0x0008e1b0) == 0xffffffff` (XP3G_PLM) — BAR0 MMIO.
2. `kgspCmp90V67RefillWrite` (patch 0016 hunk in `kernel_gsp.c`) — core RM.
3. WPR2 lo/hi restore — `GPU_REG_WR32`.
4. FWSEC re-prime: `kgspPrepareForFwsecFrts_HAL` + `kgspExecuteFwsec_HAL`
   (core RM + falcon MMIO; fails here on llm2 with FRTS `err=0xbe`, but
   rejoin18 bit0 proved skipping it changes nothing).
5. SEC2 falcon reset — `kflcnReset_HAL` (MMIO).
6. `s_executeBooterUcode_TU102` → `kgspExecuteHsFalcon_GA102`: falcon
   register program + context DMA over **already-allocated** memdescs, then
   our REJOIN9 early-PLM-handoff poll (`kernel_gsp_falcon_ga102.c:299-400`):
   when `FEAT_OVR_PLM` reads `0xffffffff` it returns `NV_ERR_NOT_READY`
   (**0x55**) *as its normal success-style exit* — the chain fires
   asynchronously after that return. 0x55 therefore appears in jdowning's
   success lines too; the verdict lives entirely in step 7.
7. Readback poll: `GPU_REG_RD32(wrAddr)` ×1000 with `osDelay(1)`.
   `os_delay` → `nv_sleep_ms` → `msleep()` — API stable since 2.6.

Nothing between the spec-file read and the verdict print touches a
kernel-version-conditional code path.

## Sweep results (610.43.03 tree)

- `LINUX_VERSION_CODE` appears in exactly three non-generated files:
  `kernel-open/nvidia/os-interface.c` (the `os_get_version_info` report
  string), `kernel-open/nvidia/linux_nvswitch.c` (NVSwitch module — not
  loaded for GA102 CMP cards), `kernel-open/common/inc/nv-linux.h` (the
  `< 4.15` `#error` floor). **Zero** behavioral version gates anywhere.
- `kernel-open/nvidia/nv-pci.c`: no `LINUX_VERSION_CODE` at all, and around
  the device-load path its PCI API surface is a single
  `pci_enable_device()` — no `pci_save_state`/`pci_set_power_state`/
  `pcie_aspm`/`pci_alloc_irq` usage that 6.13→7.0 churn could alter.
- Patch 0016's only kernel-facing hunk (`nv_cmp90hx_gen2_config` in
  `nv.c`, standard config-space accessors) **never engages on llm2** — it
  is gated on `0x0008e1b0 == 0xffffffff`, which our card never reads.
- dkms conftests are regenerated per kernel, but none of the APIs on the
  path above are conftest-sensitized; all memdesc/DMA allocation is shared
  with run #1 and with normal serving (GSP RPC is the heaviest DMA user on
  the card and works flawlessly at 88–94 tok/s).

## Controls already run under 7.0.0-38

Window #10 executed, on the disputed kernel, in one window: stock FWSEC
runs with healthy FRTS (`frts_err=0x0`), two crafted run #1 landings
(`SS0=0x88888888`, V67 `status=0x0`), module unload/reload cycles, sysfs
FLRs, and a successful Gen2 config-space retrain on both 50HXes. Every
host-side primitive run #2 depends on demonstrably works here. The only
thing that ever refuses is the GPU-side decision to execute the chain a
second time inside one load — and its failure fingerprint (`polls=1000
NO-EFFECT`) is bit-identical across boot-load, warm reload, cold-boot, and
alternation contexts, i.e., across all the different kernel paths those
traverse.

## Residual kernel vectors (why window #11 still has value)

- **Ubuntu config, not upstream code**: 26.04's 7.0 kernel ships platform
  defaults (IOMMU policy, ASPM/portdrv config, D3cold behavior) that change
  the PCIe state the GPU sees at load time. Untestable statically; but note
  run #1 lands under the same config, so any such effect would have to be
  *second-execution-specific* — possible only if the gate reads live PCIe
  state, which no observation supports (identical fingerprint in solo-boot
  contexts with different link histories).
- **GPU-visible timing**: poll cadence/delay granularity differ by kernel
  tick config — excluded: the failure shape shows full-window timeouts with
  the readback latched (not mid-flight), and rejoin18's 3 s poll did not
  change anything.

**Bottom line.** Statistical correlation with the kernel era is real but
source analysis cannot give it a mechanism: run #2 shares its entire
host-facing surface with run #1, which works. The more parsimonious
explanation remains per-card gate state (window #9: FEAT-page CPU writes
inert + latched readbacks — llm2's card sits in a protection state the
bench cards demonstrably do not, e.g., their `relock()` readback checks
pass). Window #11 (boot 6.12.95, re-run alternation) remains the cheap
decisive test and is worth running mainly to close the corpus question for
the upstream thread; #3 (pre-OS EFI) is immune to the answer either way
and stays the primary implementation path.
