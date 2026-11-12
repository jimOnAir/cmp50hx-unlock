// SPDX-License-Identifier: GPL-2.0-only
#ifdef __KERNEL__
#include <linux/errno.h>
#else
#include <errno.h>
#endif

#include "gfw_eval.h"

int gpu_unlock_gfw_assess(const struct gpu_unlock_gfw_sample *sample)
{
	if (!sample || !sample->config_ok)
		return -ENODEV;
	/* All-ones satisfies the bit tests below and is not a live device. */
	if (sample->plm == (u32)~0U || sample->boot == (u32)~0U ||
	    sample->cpuctl == (u32)~0U)
		return -ENODEV;
	if (!(sample->cpuctl & GU_GFW_CPUCTL_HALTED))
		return -EAGAIN;
	if (!(sample->plm & GU_GFW_PLM_LEVEL0))
		return -EAGAIN;
	if ((sample->boot & 0xffu) != GU_GFW_BOOT_COMPLETED)
		return -EAGAIN;
	return 0;
}

u16 gpu_unlock_command_restore(u16 original, u16 live)
{
	u16 mask = GU_PCI_COMMAND_MEMORY | GU_PCI_COMMAND_MASTER;

	return (live & (u16)~mask) | (original & mask);
}

bool gpu_unlock_pmcsr_d0(u16 pmcsr)
{
	return (pmcsr & GU_PCI_PM_CTRL_STATE_MASK) == GU_PCI_PM_STATE_D0;
}

/* PMCSR next value that pins D0 while preserving every upper control bit.
 * Returns true when a write is needed (state not already D0). Row B2-P13:
 * FLR is defined only in D0; row P32a: a D3-notified card should be woken
 * before the claim refuses it. Pure function — harness-extractable. */
bool gpu_unlock_pm_force_d0_value(u16 pmcsr, u16 *next)
{
	*next = (u16)(pmcsr & ~GU_PCI_PM_CTRL_STATE_MASK);
	return *next != pmcsr;
}
