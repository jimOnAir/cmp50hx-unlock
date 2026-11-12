// SPDX-License-Identifier: GPL-2.0-only
/* booter_diag.c — compose one printable decode fragment from the shared
 * mailbox0/EXCI dictionary (gtuu-mining ticket 17, row B2-P4).
 *
 * Register sources for the VALUES fed here (provenance lives in the
 * dictionary header; the offsets are read at):
 *   mailbox0: GU_SEC2_BASE + GU_FALCON_MAILBOX0_OFFSET (0x840040),
 *   exci:     GU_SEC2_BASE + GU_FALCON_EXCI_OFFSET     (0x8400d0) —
 *     NV_SOE_FALCON_EXCI per the vendored open-gpu-kernel-modules
 *     nvswitch/lr10/dev_soe_ip.h:318-338 (EXPC 19:0, EXCAUSE 24:20).
 *
 * Trap (1) — Turing `sec` readback is always scrub-poisoned, the ns/dmem
 * rows are the verdict: both formatters take ONLY these ns-visible
 * register values; nothing here reads (or could read) a secure-port
 * value, and a poisoned register prints raw+undecoded, never a name.
 * Trap (2) — 0x00900100 INV_INS@0x100 appears in SUCCESSFUL runs:
 * booter_exci_info_class() attaches the `info - ...` class to exactly
 * that value and this file never elevates it.
 */
#ifdef __KERNEL__
#include <linux/kernel.h> /* snprintf */
#else
#include <stdio.h>
#endif
#include "booter_diag.h"
/* In-tree builds find this via Kbuild's -I$(src)/../common (the single
 * shared header, house pattern of ../common/cmp50hx_regs.h); in the
 * standalone DKMS tree, tools/build-deb.sh stages a byte copy beside
 * these sources and the quoted include resolves locally. */
#include "booter_mailbox.h"

const char *gu_booter_mailbox_diag(unsigned int mbox0, char *out, size_t cap)
{
	const char *name;

	if (booter_reg_poisoned(mbox0)) {
		snprintf(out, cap,
			 "raw=0x%08x undecoded (poisoned readback - no verdict derived from it)",
			 mbox0);
		return out;
	}
	name = booter_mailbox0_name(mbox0);
	if (name)
		snprintf(out, cap, "0x%08x decode: %s", mbox0, name);
	else
		snprintf(out, cap, "raw=0x%08x undecoded", mbox0);
	return out;
}

const char *gu_booter_exci_diag(unsigned int exci, char *out, size_t cap)
{
	const char *name, *info;

	if (booter_reg_poisoned(exci)) {
		snprintf(out, cap,
			 "raw=0x%08x undecoded (poisoned readback - no verdict derived from it)",
			 exci);
		return out;
	}
	name = booter_exci_cause_name(BOOTER_EXCI_EXCAUSE(exci));
	if (!name) {
		snprintf(out, cap, "raw=0x%08x undecoded", exci);
		return out;
	}
	info = booter_exci_info_class(exci);
	if (info)
		snprintf(out, cap, "0x%08x EXPC=0x%x EXCAUSE=0x%x decode: %s - %s",
			 exci, BOOTER_EXCI_EXPC(exci), BOOTER_EXCI_EXCAUSE(exci),
			 name, info);
	else
		snprintf(out, cap, "0x%08x EXPC=0x%x EXCAUSE=0x%x decode: %s",
			 exci, BOOTER_EXCI_EXPC(exci), BOOTER_EXCI_EXCAUSE(exci),
			 name);
	return out;
}
