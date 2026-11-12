/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Host failure-injection harness for the 90HX claim module (gtuu-mining
 * ticket 11; method ported from GPU-Tensor-Unlock-Universal @ ab7bfc0
 * tests/test_unlock_adapter.c — READ-ONLY reference, never executed — plus
 * the named-fault-axis / reverse-assertion discipline from nv-uefi-unlocker
 * sim/ (row B2-P23)).
 *
 * TWO-BUILD PATTERNS: this TU #includes the PRODUCTION unlock_610.c
 * verbatim (like the extraction selftests, but whole-file), linking the
 * sibling production .c files. What runs here is the shipped code, not a
 * copy — the only fake is the kernel API surface (tests/shim/).
 *
 * Scope: the transaction phases reachable without firmware images —
 * entry guards, claim (D0/FLR/BME/region/mapping), GFW cold-entry
 * classification, and unwind containment. Deeper phases (fwsec/booter,
 * k_flr_identity_gone / k_bme_stuck_off / k_fw_name_fail axes) are
 * phase-2 once the fixture feeds staged images.
 */
#include "shim/compat.h"
#include "../device.h"
#include "../unlock_610.c"	/* production file, verbatim */

/* ---- fixture surface (tests/shim/shim_impl.c) ---- */
void fix_reset(void);
u8 *fix_mmio(void);
u32 *fix_config(void);
int log_has(const char *frag);
void log_clear(void);
extern int k_pmcsr_stuck, k_cmd_allf, k_fail_alloc_at;
extern unsigned long vms;
extern unsigned dma_live;

static const struct gu_family fx_fam = {
	.name = "harness",
	.feat_plm = GU_FEAT_PLM_OFFSET,
	.feat_ss0 = GU_FEAT_SS0_OFFSET,
	.feat_ss1 = GU_FEAT_SS1_OFFSET,
};
static const struct gu_card fx_card = {
	.device = 0x1e09, .chip = 0x221200a1, .family = &fx_fam,
};
static struct pci_dev fx_pdev;

static void pdev_reset(void)
{
	memset(&fx_pdev, 0, sizeof(fx_pdev));
	fx_pdev.vendor = 0x10de;
	fx_pdev.device = 0x1e09;
	fx_pdev.pm_cap = 0x40;
	fx_pdev.current_state = PCI_D0;
}

static void bar_w32(unsigned off, u32 v)
{
	memcpy(fix_mmio() + off, &v, 4);
}

static int fails;
static void ck(const char *name, int cond)
{
	if (!cond) {
		printf("FAIL %s\n", name);
		fails++;
	} else {
		printf("PASS %s\n", name);
	}
}

/* A claim fixture reaching the full success path: D0, FLR-capable,
 * firmware-handed BME (the Supermicro X11 handoff case), memory on. */
static void claim_ready(struct unlock_transaction_work *w)
{
	fix_reset();
	pdev_reset();
	memset(w, 0, sizeof(*w));
	w->pdev = &fx_pdev;
	w->card = &fx_card;
	fix_config()[PCI_COMMAND >> 2] = 0x0006;	/* MSE | BME */
	fix_config()[(0x40 + PCI_PM_CTRL) >> 2] = 0x0100; /* PMCSR D0 */
}

int main(void)
{
	struct unlock_transaction_work w;
	int ret;

	/* ---- S1: claim happy path (D0, FLR+, BME cleared, BAR mapped) ---- */
	claim_ready(&w);
	ret = unlock_transaction_claim(&w);
	ck("S1 claim returns 0", ret == 0);
	ck("S1 stage=claim line emitted", log_has("stage=claim device="));
	ck("S1 firmware BME cleared in config",
	   (fix_config()[PCI_COMMAND >> 2] & PCI_COMMAND_MASTER) == 0);
	ck("S1 original_cmd recorded post-clear", w.original_cmd == 0x0002);
	ck("S1 region+BAR mapped, cmd_valid, master off",
	   w.region && w.bar && w.cmd_valid && !w.master && w.enabled == false);
	/* S8 (B2-P23 reverse assertion): the happy transaction emits NO
	 * dev_err/dev_warn — no "[E]" needle may appear. */
	ck("S8 happy claim logs zero dev_err", !log_has("[E] "));

	/* ---- S2: D3hot card is woken to D0 once, then claims (t18) ---- */
	claim_ready(&w);
	fx_pdev.current_state = PCI_D3hot;
	fix_config()[(0x40 + PCI_PM_CTRL) >> 2] = 0x0103;	/* D3hot */
	ret = unlock_transaction_claim(&w);
	ck("S2 forced-D0 claim returns 0", ret == 0);
	ck("S2 named force line logged", log_has("pm: forced D0 on"));
	ck("S2 PMCSR written D0 with upper bits intact",
	   (fix_config()[(0x40 + PCI_PM_CTRL) >> 2] & 0xffffu) == 0x0100);
	ck("S2 no failure snapshot on recovery path",
	   !log_has("[E] "));

	/* ---- S3: PMCSR deaf (rail-woken dead card) still refuses ---- */
	claim_ready(&w);
	fx_pdev.current_state = PCI_D3hot;
	fix_config()[(0x40 + PCI_PM_CTRL) >> 2] = 0x0103;
	k_pmcsr_stuck = 1;
	ret = unlock_transaction_claim(&w);
	ck("S3 deaf PMCSR -> -EOPNOTSUPP", ret == -EOPNOTSUPP);
	ck("S3 named force-failure line", log_has("pm: D0 force failed"));
	ck("S3 failure snapshot once", log_has("failure unlock_transaction_claim"));
	ck("S3 refused before claiming anything",
	   !w.cmd_valid && !w.region && !w.bar);
	k_pmcsr_stuck = 0;

	/* ---- S4: platform forbids FLR -> refuse, nothing touched ---- */
	claim_ready(&w);
	fx_pdev.dev_flags |= PCI_DEV_FLAGS_NO_FLR_RESET;
	ret = unlock_transaction_claim(&w);
	ck("S4 NO_FLR -> -EOPNOTSUPP", ret == -EOPNOTSUPP);
	ck("S4 refusal snapshotted", log_has("failure unlock_transaction_claim"));
	ck("S4 no BME write happened",
	   (fix_config()[PCI_COMMAND >> 2] & PCI_COMMAND_MASTER) != 0);

	/* ---- S5: config wedge (all-FF) without PM cap -> -ENODEV ---- */
	claim_ready(&w);
	fx_pdev.pm_cap = 0;
	k_cmd_allf = 1;
	ret = unlock_transaction_claim(&w);
	ck("S5 wedged config -> -ENODEV", ret == -ENODEV);
	ck("S5 nothing claimed", !w.cmd_valid && !w.region && !w.bar);
	k_cmd_allf = 0;

	/* ---- S5b: wedge WITH PM cap refuses earlier (force-D0 fail) ----
	 * Documents current ordering honestly: a wedged config reads
	 * PMCSR==0xffff, so the D0 gate fires before the COMMAND 0xffff
	 * check; both are named refusals, neither proceeds. */
	claim_ready(&w);
	k_cmd_allf = 1;
	ret = unlock_transaction_claim(&w);
	ck("S5b wedge with PM cap -> -EOPNOTSUPP at D0 gate", ret == -EOPNOTSUPP);
	ck("S5b refusal named", log_has("failure unlock_transaction_claim"));
	k_cmd_allf = 0;

	/* ---- S6: GFW cold entry with WPR2 latched -> power-off-first ---- */
	claim_ready(&w);
	w.bar = (void __iomem *)fix_mmio();
	w.bar_len = 16u << 20;
	bar_w32(GU_GFW_PLM_OFFSET, 0x1);		/* LEVEL0 */
	bar_w32(GU_GFW_BOOT_OFFSET, 0xff);		/* completed */
	bar_w32(GU_GFW_CPUCTL_OFFSET, 0x10);		/* halted */
	bar_w32(GU_FEAT_PLM_OFFSET, 0xffffffef);	/* closed, not open */
	bar_w32(GU_FEAT_SS0_OFFSET, 0x05112071);
	bar_w32(GU_FEAT_SS1_OFFSET, 0x00000001);
	bar_w32(GU_WPR2_ADDR_HI_OFFSET, 0x10000000);	/* WPR2 enabled */
	ret = unlock_transaction_gfw(&w);
	ck("S6 driver-initialised card -> -EBUSY", ret == -EBUSY);
	ck("S6 names the culprit + remedy",
	   log_has("card already initialised since power on (WPR2 enabled); power off first"));

	/* ---- S6b: truly cold card passes the same gate (reverse) ---- */
	bar_w32(GU_WPR2_ADDR_HI_OFFSET, 0x0);
	log_clear();	/* the S6 refusal line must not leak into this check */
	ret = unlock_transaction_gfw(&w);
	ck("S6b cold entry accepted", ret == 0);
	ck("S6b no power-off-first line", !log_has("power off first"));

	/* ---- S6c: open PLM = already unlocked or not cold -> EALREADY ---- */
	bar_w32(GU_FEAT_PLM_OFFSET, 0xffffffff);
	ret = unlock_transaction_gfw(&w);
	ck("S6c open PLM -> -EALREADY", ret == -EALREADY);
	bar_w32(GU_FEAT_PLM_OFFSET, 0xffffffef);

	/* ---- S7: unwind containment — firmware started, not quiesced ---- */
	claim_ready(&w);
	{
		dma_addr_t dma;
		void *cpu = dma_alloc_coherent(&fx_pdev.dev, 4096, &dma, 0);

		w.firmware_started = true;
		w.state = GU_ACTIVE;
		w.master = true;
		w.cmd_valid = true;
		w.original_cmd = 0x0006;
		w.boot.cpu = cpu;
		w.boot.dma = dma;
		w.boot.size = 4096;
		fix_config()[PCI_COMMAND >> 2] = 0x0006;	/* BME ours, live */
		ret = unlock_transaction_unwind(&w);
		ck("S7 incomplete transaction -> -EBUSY", ret == -EBUSY);
		ck("S7 refusal named", log_has("handover refused: incomplete transaction"));
		ck("S7 retained flag set", w.retained);
		ck("S7 BME cleared on the way out",
		   (fix_config()[PCI_COMMAND >> 2] & PCI_COMMAND_MASTER) == 0);
		ck("S7 DMA buffers retained (never freed mid-flight)", dma_live == 1);
	}

	/* ---- S7b: quiesced unwind frees and restores (reverse pair) ---- */
	claim_ready(&w);
	{
		dma_addr_t dma;
		void *cpu = dma_alloc_coherent(&fx_pdev.dev, 4096, &dma, 0);

		w.firmware_started = true;
		w.state = GU_QUIESCED;
		w.cmd_valid = true;
		w.original_cmd = 0x0002;
		w.boot.cpu = cpu;
		w.boot.dma = dma;
		w.boot.size = 4096;
		fix_config()[PCI_COMMAND >> 2] = 0x0002;
		ret = unlock_transaction_unwind(&w);
		ck("S7b quiesced unwind -> 0", ret == 0);
		ck("S7b coherent buffer freed", dma_live == 0 && !w.boot.cpu);
		ck("S7b not retained", !w.retained);
		ck("S7b no handover-refused line", !log_has("handover refused"));
	}

	/* ---- S9: entry guard — no recipe -> -ENODEV before any work ---- */
	fix_reset();
	pdev_reset();
	{
		struct gpu_unlock_610_shared shared = { };
		struct gu_device dev = { .pdev = &fx_pdev, .recipe = NULL };

		ret = gpu_unlock_610_unlock(&dev, &shared, false);
		ck("S9 missing recipe -> -ENODEV", ret == -ENODEV);
	}

	/* ---- S10: allocation failure is contained at entry ---- */
	{
		struct gpu_unlock_610_shared shared = { };
		struct gu_device dev = { .pdev = &fx_pdev, .recipe = &fx_card };

		k_fail_alloc_at = 0;
		ret = gpu_unlock_610_unlock(&dev, &shared, false);
		ck("S10 kzalloc failure -> -ENOMEM, nothing else touched",
		   ret == -ENOMEM && dma_live == 0);
		k_fail_alloc_at = -1;
	}

	printf(fails ? "%d FAILURES\n" : "ALL-PASS\n", fails);
	return fails != 0;
}
