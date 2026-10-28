/* cmp50hx_regs.h — TU102 (CMP 50HX / TU104-106 family) BAR0 register map,
 * the single source of truth shared by:
 *   - the pre-OS EFI unlocker        (efi-unlock/unlock50x_v1.c)
 *   - the merged OS-side binary      (native/: gen2 policy, osunlock)
 *   - the in-kernel policy           (patches/ — kept in sync deliberately:
 *     the patch set ships inside the DKMS tree and cannot include headers
 *     from here, so patch 01/04 duplicate these values on purpose)
 *
 * Values verified on live silicon 2026-08..2026-10 (see README + docs/).
 * Macro-only header: safe for -ffreestanding EFI builds and glibc userland
 * alike. Unsigned-long literals: 0xFFFFFFFF would be int on some compilers.
 */
#ifndef CMP50HX_REGS_H
#define CMP50HX_REGS_H

/* --- compute unlock feature overrides (patch 01 / EFI / osunlock) -------- */
#define CMP50_REG_FEAT_OVR_PLM      0x00409650UL  /* PLM: 0xffffffff = open  */
#define CMP50_REG_FEAT_SS0          0x00409664UL  /* SS0: 0x88888888 = full  */
#define CMP50_REG_FEAT_SS1          0x0040966CUL  /* SS1: 0x00000008 = full  */
#define CMP50_VAL_PLM_OPEN          0xFFFFFFFFUL
#define CMP50_VAL_SS0_UNLOCKED      0x88888888UL
#define CMP50_VAL_SS1_UNLOCKED      0x00000008UL

/* --- PCIe Gen2 unlock policy (patch 04 / EFI skip / cmp50hx gen2) --------
 * GSP reverts the target-speed set ~100 ms after the driver's boot-window
 * policy; re-applying after that one-shot revert is stable. Adoption is
 * one-shot per power cycle (LTSSM kick), so this must run before anything
 * else adopts the locked set. XP3G_VAL3/OVR3 are deliberately omitted: an
 * A/B on 2026-09-13 proved the unlock works without them. */
#define CMP50_REG_PCIE_MISC1        0x0008841CUL
#define CMP50_REG_PCIE_LTSSM        0x0008872CUL
#define CMP50_REG_PCIE_CFG0         0x0008C040UL
#define CMP50_REG_PCIE_PL_RATE      0x0008C1C0UL
#define CMP50_REG_PCIE_CYA0         0x0008C2C0UL
#define CMP50_REG_PCIE_XP3G_OVR0    0x0008E110UL
#define CMP50_REG_PCIE_XP3G_VAL0    0x0008E120UL
#define CMP50_REG_PCIE_XP3G_PLM0    0x0008E1B0UL  /* gate: 0xffffffff = open */

/* --- WPR2 / GSP bring-up (ticket 10/12; EFI + osunlock) ------------------ */
#define CMP50_REG_PFB_MMU_WPR2_LO   0x001FA824UL
#define CMP50_REG_PFB_MMU_WPR2_HI   0x001FA828UL
#define CMP50_REG_GSP_BASE          0x00110000UL

#endif /* CMP50HX_REGS_H */
