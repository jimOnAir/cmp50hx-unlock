// SPDX-License-Identifier: GPL-2.0-only
/*
 * gpu_peek — read-only pre-driver BAR0 sampler for the fleet CMP cards
 * (map gtuu-mining ticket 10).
 *
 * Answers "what state is this card in *before* the display driver touches
 * it" from a headless session: loads against an UNBOUND 10de:1e09 (CMP 50HX,
 * TU102) or 10de:220d (CMP 90HX, GA102), single 32-bit BAR0 loads only,
 * prints PMC_BOOT_0, the permission PLMs, the SS0/SS1 speed-select words,
 * the decoded FEAT readout cluster, and a plain-English verdict
 * (LOCKED / UNLOCKED / PARTIAL / COLD-ALLFF), then leaves the card
 * untouched.
 *
 * Provenance: ported from the unaudited third-party GTUU-sweep clone
 * diagnostics/peek/gpu_peek.c (evaluated commit 1d6a508, GPL-2.0, row T2),
 * port + audit, not vendored. Local changes against the reference: the
 * reference's scan-all-NVIDIA-GPUs mode and its leaked final pci_dev
 * reference are gone (a required single targets=<BDF> parameter took their
 * place); a bound-driver refusal was added (the reference sampled bound
 * cards); a PMC_BOOT_0 chip trust gate was added before any verdict is
 * derived; the AD102/GFW/falcon/fuse-block extras outside the ticket's read
 * set were dropped; offsets and names now come from our registers.h mirror.
 * Authority for register names/offsets: claim-90hx/registers.h. Authority
 * for the readout field order: docs/CMP50HX.md (proved TU102 readback
 * table) and the post-driver verifier native/verify.c. Authority for the
 * chip gate and its all-FF rule: claim-90hx/cmp90hx-claim.sh
 * bar0_reads_trustworthy (row U4) and claim-90hx/unlock_610.c.
 *
 * READ-ONLY BY CONSTRUCTION — hard acceptance criterion, audit evidence in
 * README.md:
 *   - Every device-memory access is a single 32-bit load through
 *     peek_read() -> ioread32(); this file contains no write primitive.
 *   - The only config-space access is pci_read_config_word(PCI_COMMAND), a
 *     read, for cold-vs-wedge context. No config writes.
 *   - No pci_enable_device*, no pci_set_master: Bus Master / MEM-space
 *     enables are never changed. A cold card (decode off) is reported
 *     COLD-ALLFF, not enabled.
 *   - No resets of any kind: no FLR, no bus reset, no engine reset, no
 *     firmware launch.
 *   - A card with a bound driver is refused under pci_dev_lock, the same
 *     guard posture as claim-90hx/main.c unlock_one.
 *
 * Shipped modprobe-blacklisted; only /usr/local/sbin/cmp-peek (or an
 * operator) insmods it, and nothing in the boot flow may ever load it.
 *
 * Usage:
 *   insmod gpu_peek.ko targets=0000:03:00.0   # one unbound CMP card
 *   dmesg | grep gpu_peek
 *   rmmod gpu_peek                            # always clean
 */
#include <linux/io.h>
#include <linux/module.h>
#include <linux/pci.h>

#include "peek_registers.h"

static char *targets;
module_param(targets, charp, 0444);
MODULE_PARM_DESC(targets, "PCI address of the card to sample, e.g. 0000:03:00.0 (required; one card per invocation)");

/* One fleet CMP family: its PMC_BOOT_0 chip field and FEAT aperture. */
struct peek_chip {
	u16 device;
	u32 chip;
	const char *name;
	u32 feat_plm, feat_readout, ss0, ss1;
};

static const struct peek_chip peek_chips[] = {
	{ GPU_PEEK_DEV_CMP50HX, GPU_PEEK_TU102_CHIP_ID, "TU102 (CMP 50HX)",
	  GU_TU102_FEAT_PLM_OFFSET, GU_TU102_FEAT_READOUT_OFFSET,
	  GU_TU102_FEAT_SS0_OFFSET, GU_TU102_FEAT_SS1_OFFSET },
	{ GPU_PEEK_DEV_CMP90HX, GPU_PEEK_GA102_CHIP_ID, "GA102 (CMP 90HX)",
	  GU_FEAT_PLM_OFFSET, GU_FEAT_READOUT_1_OFFSET,
	  GU_FEAT_SS0_OFFSET, GU_FEAT_SS1_OFFSET },
};

/* The nine 3-bit per-unit speed fields inside FEAT_READOUT, field i at
 * bits 3i+2:3i. Order proved by docs/CMP50HX.md (TU102 readback table:
 * IMLA0 2:0 ... IMLA4 24:22) and shared with the post-driver verifier
 * (native/verify.c v1 names). 0 = full rate, 1..6 = 1/2..1/64; the DP unit
 * only distinguishes full vs reduced (verify.c speed_name). */
static const char *const speed_fields[9] = {
	"IMLA0", "FMLA16", "DP", "FMLA32", "FFMA",
	"IMLA1", "IMLA2", "IMLA3", "IMLA4",
};
static const char *const speed_names[] = {
	"full", "1/2", "1/4", "1/8", "1/16", "1/32", "1/64", "unknown",
};

/* The module's ONLY device-memory primitive: one bounds-prechecked 32-bit
 * load. Keeping every read behind it makes the zero-write audit a grep. */
static u32 peek_read(const void __iomem *bar, u32 offset)
{
	return ioread32(bar + offset);
}

/* Bar0 reads mean nothing unless the chip identity decodes: zero and all-FF
 * are unreadable (memory decode off on a cold card, or a wedge), and bits
 * 28:20 must match the family — foundry strap bits 31:29 make 0xb72000a1
 * and 0x172000a1 the same silicon. Mirrors bar0_reads_trustworthy
 * (claim-90hx/cmp90hx-claim.sh, row U4). */
static bool bar0_reads_trustworthy(u32 boot0, u32 chip)
{
	return boot0 != 0 && boot0 != ~0u && ((boot0 >> 20) & 0x1ff) == chip;
}

/* Ratio name for one 3-bit unit, matching the post-driver verifier
 * (native/verify.c speed_name): the DP unit only distinguishes full from
 * reduced. */
static const char *speed_name(unsigned int unit, unsigned int value)
{
	if (unit == 2)
		return value == 0 ? "full" : (value == 1 ? "reduced" : "unknown");
	return speed_names[value];
}

static void peek_decode_readout(struct pci_dev *pdev, u32 readout)
{
	char units[192];
	unsigned int i;
	int n = 0;

	for (i = 0; i < ARRAY_SIZE(speed_fields); i++)
		n += scnprintf(units + n, sizeof(units) - n, " %s=%s",
			       speed_fields[i],
			       speed_name(i, (readout >> (3 * i)) & 7u));
	pci_info(pdev, "gpu_peek: FEAT_READOUT units (3-bit, 0=full):%s\n", units);
}

static void peek_decode_selectors(struct pci_dev *pdev, u32 ss0, u32 ss1)
{
	char nibbles[8 * 5];
	unsigned int i;
	int n = 0;

	/* SS0 carries eight 4-bit override fields, SS1 one (registers.h:
	 * value 8 selects full rate). Positions are printed, not unit names:
	 * the nibble-to-unit map is not proved in this repo. */
	for (i = 0; i < 8; i++)
		n += scnprintf(nibbles + n, sizeof(nibbles) - n, " %x",
			       (ss0 >> (4 * i)) & 0xfu);
	pci_info(pdev, "gpu_peek: SS0 nibbles n0..n7:%s SS1 n0:%x (8=full)\n",
		 nibbles, ss1 & 0xfu);
}

static const char *peek_verdict(u32 ss0, u32 ss1)
{
	bool full0 = ss0 == GU_SS0_UNLOCK, full1 = ss1 == GU_SS1_UNLOCK;

	if (full0 && full1)
		return "UNLOCKED — both speed-select words show the full-rate pattern";
	if (full0 != full1)
		return "PARTIAL — exactly one speed-select word landed (ticket 04 PARTIALLY_MODIFIED; treat as unknown state)";
	return "LOCKED — neither speed-select word shows the full-rate pattern";
}

static int peek_one(struct pci_dev *pdev, const struct peek_chip *card)
{
	u32 boot0, wpr_cfg, wpr, fbpa, feat_plm, ss0, ss1, readout;
	void __iomem *bar;
	u16 command = 0xffff;
	int ret;

	if (!(pci_resource_flags(pdev, 0) & IORESOURCE_MEM)) {
		pci_warn(pdev, "gpu_peek: BAR0 is not a memory region, refusing\n");
		return -ENODEV;
	}
	if (!pci_resource_start(pdev, 0) ||
	    pci_resource_len(pdev, 0) < GPU_PEEK_WINDOW_END) {
		pci_warn(pdev, "gpu_peek: BAR0 missing or shorter than the read window, refusing\n");
		return -ENODEV;
	}

	/* Guard + sample under the device lock: the same posture as
	 * gpu_unlock's unlock_one (claim-90hx/main.c). A bound card is
	 * refused — these numbers are only meaningful pre-driver. */
	pci_dev_lock(pdev);
	if (pdev->driver) {
		pci_warn(pdev, "gpu_peek: card is bound to %s, refusing to sample (unbind first)\n",
			 pdev->driver->name);
		ret = -EBUSY;
		goto out;
	}
	bar = pci_iomap(pdev, 0, 0);
	if (!bar) {
		pci_warn(pdev, "gpu_peek: BAR0 map failed, refusing\n");
		ret = -EIO;
		goto out;
	}

	boot0 = peek_read(bar, GU_PMC_BOOT_0_OFFSET);
	wpr_cfg = peek_read(bar, GU_WPR_CFG_PLM_OFFSET);
	wpr = peek_read(bar, GU_WPR_PLM_OFFSET);
	fbpa = peek_read(bar, GU_FBPA_PLM_OFFSET);
	feat_plm = peek_read(bar, card->feat_plm);
	ss0 = peek_read(bar, card->ss0);
	ss1 = peek_read(bar, card->ss1);
	readout = peek_read(bar, card->feat_readout) & GU_SPEED_READOUT_MASK;
	pci_read_config_word(pdev, PCI_COMMAND, &command);

	pci_info(pdev, "gpu_peek: chip=%s boot0=%#010x command=%#04x (MEM=%u MASTER=%u)\n",
		 card->name, boot0, command,
		 !!(command & PCI_COMMAND_MEMORY), !!(command & PCI_COMMAND_MASTER));
	pci_info(pdev, "gpu_peek: %#010x WPR_CFG_PLM = %#010x\n", GU_WPR_CFG_PLM_OFFSET, wpr_cfg);
	pci_info(pdev, "gpu_peek: %#010x WPR_PLM     = %#010x\n", GU_WPR_PLM_OFFSET, wpr);
	pci_info(pdev, "gpu_peek: %#010x FBPA_PLM    = %#010x\n", GU_FBPA_PLM_OFFSET, fbpa);
	pci_info(pdev, "gpu_peek: %#010x FEAT_PLM    = %#010x\n", card->feat_plm, feat_plm);
	pci_info(pdev, "gpu_peek: %#010x SS0         = %#010x\n", card->ss0, ss0);
	pci_info(pdev, "gpu_peek: %#010x SS1         = %#010x\n", card->ss1, ss1);
	pci_info(pdev, "gpu_peek: %#010x FEAT_READOUT= %#010x\n", card->feat_readout, readout);

	if (!bar0_reads_trustworthy(boot0, card->chip)) {
		/* All-FF/unreadable: cold (decode off after a reboot) or
		 * wedged — a state this repo refuses to decode registers in.
		 * The MEM enable bit splits the two cases. */
		pci_info(pdev, "gpu_peek: %s\n",
			 command & PCI_COMMAND_MEMORY ?
			 "COLD-ALLFF - VERDICT WITHHELD: BAR0 reads are untrusted with decode ON (wedge or reset in flight); power-cycle the card before trusting anything here" :
			 "COLD-ALLFF - VERDICT WITHHELD: BAR0 reads are untrusted and MEM decode is OFF: card is cold since its last reset; this is the expected cold state, not a fault");
	} else {
		peek_decode_readout(pdev, readout);
		peek_decode_selectors(pdev, ss0, ss1);
		pci_info(pdev, "gpu_peek: %s\n", peek_verdict(ss0, ss1));
	}
	pci_iounmap(pdev, bar);
	ret = 0;
out:
	pci_dev_unlock(pdev);
	return ret;
}

static int __init gpu_peek_init(void)
{
	unsigned int domain, bus, slot, func;
	const struct peek_chip *card = NULL;
	struct pci_dev *pdev;
	size_t i;
	int ret;

	/* Operator-triggered diagnostic: exactly one card per invocation,
	 * no default scan (unlike the reference port). */
	if (!targets || !*targets ||
	    sscanf(targets, "%x:%x:%x.%x", &domain, &bus, &slot, &func) != 4 ||
	    slot > 0x1f || func > 7) {
		pr_err("gpu_peek: targets=<domain:bus:slot.function> required (one card per invocation), got \"%s\"\n",
		       targets ?: "");
		return -EINVAL;
	}
	pdev = pci_get_domain_bus_and_slot(domain, bus, PCI_DEVFN(slot, func));
	if (!pdev) {
		pr_err("gpu_peek: no device at \"%s\"\n", targets);
		return -ENODEV;
	}
	for (i = 0; i < ARRAY_SIZE(peek_chips); i++)
		if (pdev->vendor == PCI_VENDOR_ID_NVIDIA &&
		    pdev->device == peek_chips[i].device) {
			card = &peek_chips[i];
			break;
		}
	if (!card) {
		pci_info(pdev, "gpu_peek: %04x:%04x is not a fleet CMP card (need 10de:%04x or 10de:%04x), refusing\n",
			 pdev->vendor, pdev->device, GPU_PEEK_DEV_CMP50HX,
			 GPU_PEEK_DEV_CMP90HX);
		pci_dev_put(pdev);
		return -ENODEV;
	}
	ret = peek_one(pdev, card);
	pci_dev_put(pdev);
	return ret;
}

/* All sampling finished when init returns; nothing to tear down, rmmod is
 * always clean (no references, no notifiers, no state held). */
static void __exit gpu_peek_exit(void) { }

module_init(gpu_peek_init);
module_exit(gpu_peek_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Read-only pre-driver BAR0 sampler for fleet CMP triage");
MODULE_VERSION("1.0");
