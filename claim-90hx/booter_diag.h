/* SPDX-License-Identifier: GPL-2.0-only */
/* booter_diag.h — halt-diagnostic compose layer over the shared decode
 * dictionary (gtuu-mining ticket 17, row B2-P4).
 *
 * The dictionary itself lives in common/booter_mailbox.h — the single
 * source of truth shared with the EFI unlocker (no string drift). This
 * pair only composes one printable fragment per register read:
 *   known code   -> "0x%08x decode: <dictionary string>"
 *   unknown code -> "raw=0x%08x undecoded"          (never a guess)
 *   poisoned     -> "raw=0x%08x undecoded (poisoned readback - no verdict
 *                    derived from it)"              (trap 1 behavior)
 * The 0x00900100 EXCI shape carries the `info - ...` class suffix from
 * booter_exci_info_class() — label info, never a verdict (trap 2).
 *
 * Compiles for the kernel, and for the host selftest harness
 * (mailbox-dict-selftest.sh includes booter_diag.c VERBATIM with
 * __KERNEL__ undefined, mirroring diagnostic.h's dual-build idiom).
 */
#ifndef GPU_UNLOCK_BOOTER_DIAG_H
#define GPU_UNLOCK_BOOTER_DIAG_H

#ifdef __KERNEL__
#include <linux/types.h>	/* size_t, house dual-build idiom of prep_610.h */
#else
#include <stddef.h>
#endif

/* Compose the printable decode fragment for a booter mailbox0/exit code.
 * Returns out (the caller's buffer); cap >= 320 holds the longest
 * dictionary string (snprintf only ever truncates, never overruns). */
const char *gu_booter_mailbox_diag(unsigned int mbox0, char *out, size_t cap);

/* Compose the printable decode fragment for a SEC2 falcon EXCI register
 * value (NV_SOE_FALCON_EXCI layout: EXPC[19:0], EXCAUSE[24:20]). */
const char *gu_booter_exci_diag(unsigned int exci, char *out, size_t cap);

#endif /* GPU_UNLOCK_BOOTER_DIAG_H */
