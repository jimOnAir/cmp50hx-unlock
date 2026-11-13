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
#include <stdlib.h>
#include "../device.h"
#include "../unlock_610.c"	/* production file, verbatim */

/* ---- fixture surface (tests/shim/shim_impl.c) ---- */
void fix_reset(void);
u8 *fix_mmio(void);
u32 *fix_config(void);
int log_has(const char *frag);
void log_clear(void);
extern int k_pmcsr_stuck, k_cmd_allf, k_fail_alloc_at;
extern int k_flr_ret, k_flr_identity_gone, k_flr_wedge;
extern int k_fw_name_fail, k_bme_stuck_off;
extern char fix_fw_dir[512];
extern unsigned long vms;
extern unsigned dma_live;
extern u64 fix_rebar_sizes;
extern int k_x2_req_busy, k_x2_resize_fail, fix_aperture_rm_n, fix_seq_n;
extern char fix_seq[64][12];
int fix_seq_has(const char *code);
extern int log_n;
extern char log_ring[128][256];
static void dump_ring(const char *why)
{
	printf("RING-DUMP (%s):\n", why);
	for (int i = 0; i < log_n; i++)
		printf("  [%02d] %s\n", i, log_ring[i]);
}

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
	/* The kernel PCI core seeds dev.dma_mask at enumeration; production's
	 * dma phase refuses a NULL one (mirror that state honestly). */
	fx_pdev.dev.dma_mask = &fx_pdev.dev.coherent_dma_mask;
	fx_pdev.dev.coherent_dma_mask = 0xffffffffull;
	/* resource[] backs the shim pci_resource_* accessors (kernel shape:
	 * the resources live in the pci_dev). BAR0 = 16 MiB window claimed
	 * by the module (BUSY), BAR1 = firmware-default 16 MiB, free. */
	fx_pdev.resource[0] = (struct resource){ 0, (16u << 20) - 1,
		IORESOURCE_MEM | IORESOURCE_BUSY, NULL };
	fx_pdev.resource[1] = (struct resource){ 0x40000000ull,
		0x40000000ull + (16u << 20) - 1,
		IORESOURCE_MEM | IORESOURCE_MEM_64 | IORESOURCE_PREFETCH, NULL };
}

static int load_prom_fixture(const char *path)
{
	FILE *f = fopen(path, "rb");
	size_t n;

	if (!f)
		return -1;
	n = fread(fix_mmio() + GU_PROM_DATA_OFFSET, 1,
		  (size_t)(16u << 20) - GU_PROM_DATA_OFFSET, f);
	fclose(f);
	return n >= (1u << 20) ? 0 : -1;
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

/* Seed the fixture for a full unlock_transaction_reset gauntlet run
 * (S19+): success up to the post-FLR checks, x2 left at the caller's
 * discretion. */
static void reset_seeded(void)
{
	struct unlock_transaction_work w;

	claim_ready(&w);
	bar_w32(GU_FEAT_SS0_OFFSET, GU_SS0_UNLOCK);
	bar_w32(GU_FEAT_SS1_OFFSET, GU_SS1_UNLOCK);
	bar_w32(GU_PMC_BOOT_0_OFFSET, fx_card.chip);
	bar_w32(GU_GFW_PLM_OFFSET, 0x1);
	bar_w32(GU_GFW_BOOT_OFFSET, 0xff);
	bar_w32(GU_GFW_CPUCTL_OFFSET, GU_GFW_CPUCTL_HALTED);
	fix_config()[PCI_COMMAND >> 2] = 0x0006;	/* MSE+BME; prod clears BME */
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

	/* ================= X2 aperture claim (t11 phase-2) =================
	 * Direct calls into the production statics (same TU): the claim
	 * function is the unit; sequence pins via the shim call log prove
	 * the release -> resize -> request contract and the rollback. */

	/* ---- S11: pure size picker ---- */
	{
		int idx = -1;

		ck("S11a x2_pick wants 256 from {4,16,64,256}=0x55 -> idx6 (2^(20+28)B)",
		   x2_pick_size(0x55, 256, &idx) == 0 && idx == 6);
		idx = -1;
		ck("S11b non-pow2 want 50 picks largest <= -> idx2 (16M, 64>50)",
		   x2_pick_size(0x15, 50, &idx) == 0 && idx == 2);
		ck("S11c want below 4 MiB floor -> -EINVAL",
		   x2_pick_size(0x15, 2, &idx) == -EINVAL);
		ck("S11d capability offers nothing <= want -> -EOPNOTSUPP",
		   x2_pick_size(0xf0, 8, &idx) == -EOPNOTSUPP);
	}

	/* ---- S12: claim happy path, exact contract sequence ---- */
	claim_ready(&w);
	x2_aperture = true; x2_size_mb = 256;
	ret = gpu_unlock_x2_claim(&w);
	ck("S12a claim returns 0", ret == 0 && w.x2_claimed);
	ck("S12b sequence rel -> rsz1:6 -> req",
	   fix_seq_n == 3 && !strcmp(fix_seq[0], "rel") &&
	   !strcmp(fix_seq[1], "rsz1:6") && !strcmp(fix_seq[2], "req"));
	ck("S12c BAR1 now 256 MiB and busy",
	   pci_resource_len(&fx_pdev, 1) == 256u << 20 &&
	   (fx_pdev.resource[1].flags & IORESOURCE_BUSY));
	ck("S12d named claim line logged", log_has("x2: BAR1 claimed 256 MiB"));

	/* ---- S13: window busy elsewhere -> resize rolled back ---- */
	claim_ready(&w);
	k_x2_req_busy = 1;
	ret = gpu_unlock_x2_claim(&w);
	ck("S13a refused with -EBUSY, not claimed", ret == -EBUSY && !w.x2_claimed);
	ck("S13b rollback sequence rel,rsz1:6,req,rsz1:2",
	   fix_seq_n == 4 && !strcmp(fix_seq[3], "rsz1:2"));
	ck("S13c BAR1 back to 16 MiB after rollback",
	   pci_resource_len(&fx_pdev, 1) == 16u << 20);
	ck("S13d refusal named in log", log_has("x2: BAR1 window claim refused"));
	k_x2_req_busy = 0;

	/* ---- S14: BAR1 not 64-bit prefetchable -> untouched refusal ---- */
	claim_ready(&w);
	fx_pdev.resource[1].flags = IORESOURCE_MEM | IORESOURCE_PREFETCH;
	ret = gpu_unlock_x2_claim(&w);
	ck("S14a -EOPNOTSUPP, zero kernel calls",
	   ret == -EOPNOTSUPP && fix_seq_n == 0 && !w.x2_claimed);
	ck("S14b named skip", log_has("not 64-bit prefetchable"));

	/* ---- S15: carried state (resume / re-run) -> no re-do ---- */
	claim_ready(&w);
	fx_pdev.resource[1].end = 0x40000000ull + (256ull << 20) - 1;
	fx_pdev.resource[1].flags |= IORESOURCE_BUSY;
	ret = gpu_unlock_x2_claim(&w);
	ck("S15a carried at size+busy -> success with zero calls",
	   ret == 0 && w.x2_claimed && fix_seq_n == 0);
	ck("S15b named carry line", log_has("x2: BAR1 carried at 256 MiB"));

	/* ---- S16: capability tops out below want -> largest <=, no refusal ---- */
	claim_ready(&w);
	fix_rebar_sizes = 0x05;                    /* 4 MiB and 16 MiB only */
	ret = gpu_unlock_x2_claim(&w);
	ck("S16a claims at 16 MiB (idx2) instead of refusing",
	   ret == 0 && fix_seq_n == 3 && !strcmp(fix_seq[1], "rsz1:2") &&
	   pci_resource_len(&fx_pdev, 1) == 16u << 20);
	fix_rebar_sizes = 0x15;

	/* ---- S17: resize failure leaves the BAR as it was ---- */
	claim_ready(&w);
	k_x2_resize_fail = 1;
	ret = gpu_unlock_x2_claim(&w);
	ck("S17a -EIO, no request attempted",
	   ret == -EIO && fix_seq_n == 2 && !strcmp(fix_seq[1], "rsz1:6") &&
	   !(fx_pdev.resource[1].flags & IORESOURCE_BUSY));
	ck("S17b named skip", log_has("resize to 256 MiB failed"));
	k_x2_resize_fail = 0;

	/* ---- S18: integration ordering — reset refuses at the selector
	 * gate long before any aperture work: legacy removal AND x2 both
	 * untouched (the transaction gate keeps priority). */
	claim_ready(&w);
	{
		struct unlock_transaction_work rw = w;
		rw.bar = (void __iomem *)fix_mmio();
		rw.bar_len = 16u << 20;
		ret = unlock_transaction_reset(&rw);
		ck("S18a refusal is pre-aperture", ret != 0);
		ck("S18b neither aperture path ran",
		   fix_aperture_rm_n == 0 && fix_seq_n == 0);
	}

	/* ---- S19: integration — full reset gauntlet reaches X2 after
	 * the post-FLR BAR verify, legacy removal ran first ---- */
	claim_ready(&w);
	{
		struct unlock_transaction_work rw = w;

		rw.state = GU_STOCK;	/* the transaction phase reset expects */
		rw.bar = (void __iomem *)fix_mmio();
		rw.bar_len = 16u << 20;
		bar_w32(GU_FEAT_SS0_OFFSET, GU_SS0_UNLOCK);
		bar_w32(GU_FEAT_SS1_OFFSET, GU_SS1_UNLOCK);
		bar_w32(GU_PMC_BOOT_0_OFFSET, fx_card.chip);
		bar_w32(GU_GFW_PLM_OFFSET, 0x1);
		bar_w32(GU_GFW_BOOT_OFFSET, 0xff);
		bar_w32(GU_GFW_CPUCTL_OFFSET, GU_GFW_CPUCTL_HALTED);
		fix_config()[PCI_COMMAND >> 2] = 0x0006;	/* MSE+BME; prod clears BME */
		x2_aperture = true; x2_size_mb = 256;
		ret = unlock_transaction_reset(&rw);
		ck("S19a X2 ran inside the transaction",
		   fix_seq_n >= 3 && !strcmp(fix_seq[fix_seq_n - 3], "rel"));
		ck("S19b legacy removal preceded X2", fix_aperture_rm_n == 1 &&
		   log_has("x2: BAR1 claimed 256 MiB"));
		ck("S19c X2 refused nothing on the happy path",
		   !log_has("claim refused") && !log_has("claim skipped"));
		(void)ret;	/* later gauntlet stages may legitimately stop the flow */
	}
	x2_aperture = false;

	/* ---- S20: FLR itself fails (k_flr_ret) -> transaction dies at the
	 * FLR call: legacy removal already ran (it precedes FLR), X2 must
	 * NOT (it lives strictly after the post-FLR verify). ---- */
	reset_seeded();
	{
		struct unlock_transaction_work rw = w;

		rw.state = GU_STOCK;
		rw.bar = (void __iomem *)fix_mmio();
		rw.bar_len = 16u << 20;
		k_flr_ret = -EOPNOTSUPP;
		x2_aperture = true;
		ret = unlock_transaction_reset(&rw);
		k_flr_ret = 0;
		ck("S20 FLR -EOPNOTSUPP propagates", ret == -EOPNOTSUPP);
		ck("S20 removal ran, X2 did not",
		   fix_aperture_rm_n == 1 && fix_seq_n == 0 && !rw.x2_claimed);
		x2_aperture = false;
	}

	/* ---- S21: card dies across FLR (identity all-FF after) -> named
	 * post-FLR -ENODEV; X2 stays off a dead card. ---- */
	reset_seeded();
	{
		struct unlock_transaction_work rw = w;

		rw.state = GU_STOCK;
		rw.bar = (void __iomem *)fix_mmio();
		rw.bar_len = 16u << 20;
		k_flr_identity_gone = 1;
		x2_aperture = true;
		ret = unlock_transaction_reset(&rw);
		k_flr_identity_gone = 0;
		ck("S21 identity loss -> -ENODEV", ret == -ENODEV);
		ck("S21 dead card never sees X2 or a claim",
		   fix_seq_n == 0 && !rw.x2_claimed);
		ck("S21 refusal snapshotted",
		   log_has("failure unlock_transaction_reset"));
		x2_aperture = false;
	}

	/* ---- S22: config wedges all-FF ACROSS the FLR window
	 * (k_flr_wedge — the pre-FLR reads stay clean) -> post-FLR
	 * identity check refuses -ENODEV; X2 still untouched. ---- */
	reset_seeded();
	{
		struct unlock_transaction_work rw = w;

		rw.state = GU_STOCK;
		rw.bar = (void __iomem *)fix_mmio();
		rw.bar_len = 16u << 20;
		x2_aperture = true;
		k_flr_wedge = 1;
		ret = unlock_transaction_reset(&rw);
		k_flr_wedge = 0; k_cmd_allf = 0;
		ck("S22 wedge across FLR -> post-FLR -ENODEV", ret == -ENODEV);
		ck("S22 X2 did not run", fix_seq_n == 0 && !rw.x2_claimed);
		x2_aperture = false;
	}

	/* ---- S23 (reverse pair of S19): same gauntlet WITHOUT x2 (fleet
	 * default) — transaction behaves exactly as before phase-2: no
	 * rebar/resize/request calls at all, legacy removal only. ---- */
	reset_seeded();
	{
		struct unlock_transaction_work rw = w;

		rw.state = GU_STOCK;
		rw.bar = (void __iomem *)fix_mmio();
		rw.bar_len = 16u << 20;
		x2_aperture = false;
		ret = unlock_transaction_reset(&rw);
		ck("S23 default-off: legacy removal only, zero X2 calls",
		   fix_aperture_rm_n == 1 && fix_seq_n == 0 && !rw.x2_claimed);
		ck("S23 no x2 log lines at all", !log_has("x2:"));
	}


	/* ---- S24/S25: deep-phase feed — the orchestrator with REAL 610
	 * firmware (extract.sh, manifest-gated) and the REAL captured 90HX
	 * board PROM, production recipe from gu_card_find(0x220d).
	 * Provisioned via CLAIM_FW_FIXTURE / CLAIM_PROM_FIXTURE (the runner
	 * sets them from the repo cache when possible). No fixture => loud
	 * SKIP, never a silent pass. */
	{
		const char *fixdir = getenv("CLAIM_FW_FIXTURE");
		const char *promp = getenv("CLAIM_PROM_FIXTURE");

		if (!fixdir || !*fixdir || !promp || !*promp) {
			printf("SKIP S24/S25 (deep-phase fixtures not provisioned)\n");
		} else {
			const struct gu_card *rec = gu_card_find(0x220d);
			struct gpu_unlock_610_shared sh = { };
			struct gu_device gd;

			ck("S24a production CMP90HX recipe resolves",
			   rec && rec->family && rec->family->booter);
			snprintf(fix_fw_dir, sizeof fix_fw_dir, "%s", fixdir);

			/* fixture mirror: firmware names carry "gpu-unlock/610.43.03/..."
			 * subdirs; the runner staged files flat, so map via symlink dirs */
			fix_reset();
			pdev_reset();
			fx_pdev.device = 0x1e09;	/* vendor/device only gates claim bookkeeping */
			{
				char pp[768];
				snprintf(pp, sizeof pp, "%s/gpu-unlock/610.43.03", fixdir);
				(void)pp; /* layout verified by production error naming below */
			}
			ck("S24b real PROM opens", load_prom_fixture(promp) == 0);
			ck("S24c real PROM >=1 MiB lands inside fixture BAR",
			   GU_PROM_DATA_OFFSET + (1u << 20) <= (size_t)(16u << 20));
			/* cold-board seeds at the REAL family offsets */
			bar_w32(rec->family->feat_plm, 0xffffffef);	/* closed, not open */
			bar_w32(rec->family->feat_ss0, GU_SS0_UNLOCK);
			bar_w32(rec->family->feat_ss1, GU_SS1_UNLOCK);
			bar_w32(GU_GFW_PLM_OFFSET, 0x1);	/* LEVEL0 for the assessor */
			bar_w32(GU_GFW_BOOT_OFFSET, 0xff);
			bar_w32(GU_GFW_CPUCTL_OFFSET, GU_GFW_CPUCTL_HALTED);
			bar_w32(GU_PMC_BOOT_0_OFFSET,
				((rec->chip & 0x1ff) << 20) | 0xa1u);
			bar_w32(GU_GFW_FB_SIZE_OFFSET, 4096);		/* 4 GiB window */
			bar_w32(GU_MMU_LOCK_CFG_PLM_OFFSET, 1);
			bar_w32(PCI_COMMAND, 0); /* no-op guard, keeps indexes honest */
			fix_config()[PCI_COMMAND >> 2] = 0x0006;
			k_fw_name_fail = 0;
			gd.pdev = &fx_pdev;
			gd.recipe = rec;
			log_clear();
			ret = gpu_unlock_610_load_shared(&gd, &sh);
			ck("S24d production load_shared accepts the real assets",
			   ret == 0);
			if (ret)
				dump_ring("S24d load_shared failed");
			log_clear();
			ret = gpu_unlock_610_unlock(&gd, &sh, false);
			ck("S24e flow ran (positive needle: recipe selection line)",
			   log_has("recipe selection:"));
			if (!log_has("FWSEC: reading PROM"))
				dump_ring("S24f never reached fwsec");
			ck("S24f real PROM yields the FWSEC-FRTS (no named refusal)",
			   !log_has("FWSEC-FRTS not found") &&
			   log_has("FWSEC: reading PROM"));
			if (!log_has("stage=handoff"))
				dump_ring("S24g no handoff line");
			ck("S24g transaction ran to the end (handoff line)",
			   log_has("stage=handoff"));
			ck("S24h BME succeeded, launch failed -> retained",
			   ret != 0 && log_has("firmware did not stop") &&
			   dma_live >= 1);
			log_clear();

			/* S25: same everything, but pci_set_master does not stick:
			 * refuse BEFORE the firmware_started boundary -> FULL clean */
			fix_reset();
			pdev_reset();
			bar_w32(rec->family->feat_plm, 0xffffffef);
			bar_w32(rec->family->feat_ss0, GU_SS0_UNLOCK);
			bar_w32(rec->family->feat_ss1, GU_SS1_UNLOCK);
			bar_w32(GU_GFW_PLM_OFFSET, 0x1);
			bar_w32(GU_GFW_BOOT_OFFSET, 0xff);
			bar_w32(GU_GFW_CPUCTL_OFFSET, GU_GFW_CPUCTL_HALTED);
			bar_w32(GU_PMC_BOOT_0_OFFSET, ((rec->chip & 0x1ff) << 20) | 0xa1u);
			bar_w32(GU_GFW_FB_SIZE_OFFSET, 4096);
			bar_w32(GU_MMU_LOCK_CFG_PLM_OFFSET, 1);
			fix_config()[PCI_COMMAND >> 2] = 0x0006;
			ck("S25d PROM reloaded after fix_reset", load_prom_fixture(promp) == 0);
			k_bme_stuck_off = 1;
			ret = gpu_unlock_610_unlock(&gd, &sh, false);
			k_bme_stuck_off = 0;
			ck("S25a stuck BME -> refused transaction", ret != 0);
			ck("S25b refused BEFORE the started boundary: no retention",
			   !log_has("firmware did not stop") &&
			   !log_has("handover refused") && dma_live == 0);
			if (!log_has("FWSEC: reading PROM"))
				dump_ring("S25c never reached fwsec");
			ck("S25c still reached FWSEC (assets/PROM good)",
			   log_has("recipe selection:") &&
			   log_has("FWSEC: reading PROM") &&
			   !log_has("FWSEC-FRTS not found"));
			k_fw_name_fail = 1;
			fix_fw_dir[0] = '\0';
		}
	}
	printf(fails ? "%d FAILURES\n" : "ALL-PASS\n", fails);
	return fails != 0;
}
