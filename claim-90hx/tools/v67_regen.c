/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * v67_regen.c — synthesize the V67 canary payload image exactly as the
 * claim module does at launch (gu_payload_build(payload, image, NULL, 0))
 * and print its bytes to stdout (gtuu-mining ticket 13: proves the
 * committed EFI blob v67_payload.bin is generated, not magic — the
 * recipe tables are the source of truth, same as claim-90hx/recipes.c).
 *
 * Host build only (ticket 11's kernel-API shim; payload.c/recipes.c are
 * the production files verbatim):
 *   gcc -std=gnu11 -I claim-90hx/tests/shim claim-90hx/tools/v67_regen.c \
 *       claim-90hx/payload.c -o v67_regen
 */
#include "../tests/shim/compat.h"	/* same shim the t11 harness uses */
#include "../recipes.c"		/* production tables, verbatim */

#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
	const struct gu_payload *p = &ga100_v67;
	u8 *img;

	if (gu_payload_check(p)) {
		fprintf(stderr, "v67_regen: payload check failed\n");
		return 2;
	}
	(void)argc; (void)argv;
	img = malloc(p->size);
	if (!img)
		return 3;
	if (gu_payload_build(p, img, NULL, 0)) {
		fprintf(stderr, "v67_regen: build failed\n");
		return 4;
	}
	if (fwrite(img, 1, p->size, stdout) != p->size)
		return 5;
	return 0;
}
