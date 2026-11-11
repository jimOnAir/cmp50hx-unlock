/* SPDX-License-Identifier: GPL-2.0-only
 *
 * Ported from GPU-Tensor-Unlock-Universal @ 1d6a508
 * windows/uefi/source/unlock/sha256.{c,h} (gtuu-mining ticket 09,
 * rows U5+U6). Semantics unchanged; only the include prelude adapted.
 */
#ifndef SHA256_H
#define SHA256_H

#include <efi.h>

/*
 * One-shot SHA-256 (FIPS 180-4 §4.2.2/6.2). Data must contain Size
 * readable bytes, Size < 2^61, Digest room for 32 bytes. Data may be
 * NULL when Size is zero. No heap allocation or firmware services.
 */
VOID GuSha256(const VOID *Data, UINTN Size, UINT8 Digest[32]);

/*
 * Compare against a NUL-terminated string of exactly 64 hex digits.
 * Upper- and lower-case accepted; malformed hex fails closed.
 */
BOOLEAN GuHashMatches(const VOID *Data, UINTN Size, const char *Hex64);

#endif
