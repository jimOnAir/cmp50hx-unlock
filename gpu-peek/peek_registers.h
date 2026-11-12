/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * BAR0 registers sampled by gpu_peek — mirrors of claim-90hx/registers.h
 * (the local authority for names and offsets, map gtuu-mining ticket 10).
 * Kept as a private copy so gpu-unlock-peek stays a standalone DKMS package;
 * if an offset or the unlock patterns change there, change it here too.
 * Falcon/GSP/FLR-era offsets the sampler does not use are deliberately not
 * mirrored: fewer names, smaller audit surface.
 */
#ifndef GPU_PEEK_REGISTERS_H
#define GPU_PEEK_REGISTERS_H

/* Fleet CMP display functions (kernel pci_ids.h ships no NVIDIA table). */
#define GPU_PEEK_DEV_CMP50HX            0x1e09u	/* TU102 */
#define GPU_PEEK_DEV_CMP90HX            0x220du	/* GA102, shared with the RTX 3090 */

/* PMC_BOOT_0 chip-identity field (bits 28:20) per family — the same values
 * the claim recipes gate on (claim-90hx/recipes.c TU102()/GA102()). */
#define GPU_PEEK_TU102_CHIP_ID          0x162u
#define GPU_PEEK_GA102_CHIP_ID          0x172u

#define GU_PMC_BOOT_0_OFFSET            0x00000000u

/* Permission PLMs the unlock opens or reads (claim-90hx/registers.h). */
#define GU_WPR_CFG_PLM_OFFSET           0x001fa7ccu
#define GU_WPR_PLM_OFFSET               0x001fa7c4u
#define GU_FBPA_PLM_OFFSET              0x009a0148u

/* GA102 FEAT aperture. */
#define GU_FEAT_PLM_OFFSET              0x00823804u
#define GU_FEAT_READOUT_1_OFFSET        0x00823818u
#define GU_SPEED_READOUT_MASK           0x07ffffffu	/* nine 3-bit units */
#define GU_FEAT_SS0_OFFSET              0x0082381cu
#define GU_FEAT_SS1_OFFSET              0x00823820u

/* Turing keeps the same FEAT fields at the TU102 register aperture. */
#define GU_TU102_FEAT_PLM_OFFSET        0x00409650u
#define GU_TU102_FEAT_READOUT_OFFSET    0x00409668u
#define GU_TU102_FEAT_SS0_OFFSET        0x00409664u
#define GU_TU102_FEAT_SS1_OFFSET        0x0040966cu

/* SS0 has eight 4-bit fields; SS1 has one. Value 8 selects full rate. */
#define GU_SS0_UNLOCK                   0x88888888u
#define GU_SS1_UNLOCK                   0x8u

/* Highest sampled offset + 4 (FBPA PLM): BAR0 must cover the whole read
 * window before any ioread32 is issued (mirrors claim-90hx's bar_len
 * precondition style). */
#define GPU_PEEK_WINDOW_END             (GU_FBPA_PLM_OFFSET + 4u)

#endif
