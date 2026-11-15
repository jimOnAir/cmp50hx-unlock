/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Fixture model for the claim-module host harness (gtuu-mining t11).
 * 16 MiB MMIO array + faked 256 B config space + named fault knobs
 * (B2-P23 discipline: named axes, live-buffer counters, reverse
 * assertions). Ported/adapted from GTUU @ ab7bfc0 tests/unlock_shim.
 */
#include "compat.h"
#include <assert.h>
#include <stdarg.h>

#define FIX_BAR_SIZE (16u << 20)
static u8 fix_bar[FIX_BAR_SIZE];
static u32 fix_cfg[64];
static const char fix_name[] = "pci:0000:01:00.0";

/* ---- named fault knobs (each documents ONE platform behavior) ---- */
int k_fail_alloc_at = -1;          /* fail the Nth kzalloc, counting from 0 */
int k_alloc_calls;
int k_pmcsr_stuck;                 /* PMCSR writes do not take effect */
int k_flr_ret;                     /* pcie_flr() return value */
int k_flr_identity_gone;           /* config identity absent after FLR */
int k_flr_wedge;                   /* config wedges all-FF *across* FLR */
int k_cmd_allf;                    /* wedge: every config read is 0xffff */
int k_fw_name_fail = 1;            /* request_firmware fails until fed */
int k_bme_stuck_off;               /* pci_set_master does not stick */
u64 fix_rebar_sizes;               /* possible-sizes bitmap offered to X2 */
int k_x2_req_busy;                 /* request_selected_regions returns -EBUSY */
int k_x2_resize_fail;              /* pci_resize_resource fails */
int fix_aperture_rm_n;             /* legacy removal call counter (reverse asserts) */
char fix_seq[64][12];              /* ordered stub-call codes for sequencing pins */
int fix_seq_n;

unsigned long vms;                 /* virtual ms clock */
unsigned dma_live;                 /* outstanding dma_alloc_coherent blocks */
int log_n;
char log_ring[128][256];

void test_device_log(const struct device *dev, const char *fmt, ...)
{
	(void)dev;
	if (log_n < 128) {
		va_list ap;
		va_start(ap, fmt);
		vsnprintf(log_ring[log_n], sizeof(log_ring[0]), fmt, ap);
		va_end(ap);
		log_n++;
	}
}
int log_has(const char *frag)
{
	for (int i = 0; i < log_n; i++) {
		if (strstr(log_ring[i], frag))
			return 1;
	}
	return 0;
}
void log_clear(void) { log_n = 0; }

const char *pci_name(const struct pci_dev *pdev) { (void)pdev; return fix_name; }
void usleep_range(unsigned long lo, unsigned long hi) { vms += (hi + lo) / 2000 + 1; }
unsigned long simple_strtoul(const char *cp, char **endp, unsigned int base)
{ return strtoul(cp, endp, base); }
int kstrtoul(const char *s, unsigned int base, unsigned long *res)
{
	char *end;
	unsigned long v;

	if (!s || !*s)
		return -EINVAL;
	v = strtoul(s, &end, base);
	if (*end != '\0')
		return -EINVAL;
	*res = v;
	return 0;
}
ktime_t ktime_get(void) { return vms * 1000ull; }
void dma_wmb(void) {}

u32 readl(const void __iomem *p)
{
	unsigned long off = (unsigned long)((const u8 *)p - fix_bar);
	assert(off + 4 <= FIX_BAR_SIZE);
	u32 v;
	memcpy(&v, fix_bar + off, 4);
	return v;
}
void writel(u32 val, void __iomem *p)
{
	unsigned long off = (unsigned long)((u8 *)p - fix_bar);
	assert(off + 4 <= FIX_BAR_SIZE);
	memcpy(fix_bar + off, &val, 4);
}

void *kzalloc(size_t n, int flags)
{
	(void)flags;
	if (k_fail_alloc_at >= 0 && k_alloc_calls++ == k_fail_alloc_at)
		return NULL;
	k_alloc_calls++;
	return calloc(1, n);
}

void *dma_alloc_coherent(struct device *d, size_t n, dma_addr_t *dma, int f)
{
	void *p = NULL;
	(void)d; (void)f;
	/* The kernel's coherent allocator is page-aligned; production's radix
	 * table builder validates that (GU_RADIX_PAGE mask), so the fixture
	 * must match the contract, not calloc's 16-byte alignment. */
	if (posix_memalign(&p, 4096, (n + 4095) & ~(size_t)4095) == 0) {
		memset(p, 0, n);
		*dma = (dma_addr_t)(uintptr_t)p;
		dma_live++;
	} else {
		p = NULL;
	}
	return p;
}
void dma_free_coherent(struct device *d, size_t n, void *p, dma_addr_t a)
{
	(void)d; (void)n; (void)a;
	if (p) { free(p); dma_live--; }
}
int dma_set_mask(struct device *d, u64 m) { d->dma_mask = &d->coherent_dma_mask; d->coherent_dma_mask = m; return 0; }
int dma_set_coherent_mask(struct device *d, u64 m) { d->coherent_dma_mask = m; return 0; }

char fix_fw_dir[512];                /* fixture /lib/firmware mirror; empty = no feed */
int request_firmware(const struct firmware **fw, const char *name, struct device *d)
{
	char path[1024];
	FILE *f;
	long n;
	void *buf;
	struct firmware *fk;

	(void)d;
	*fw = NULL;
	if (k_fw_name_fail)
		return -ENOENT;
	if (!*fix_fw_dir)
		return -ENOENT;       /* no feed configured: same class as absent */
	snprintf(path, sizeof path, "%s/%s", fix_fw_dir, name);
	f = fopen(path, "rb");
	if (!f)
		return -ENOENT;       /* production prints the named refusal itself */
	if (fseek(f, 0, SEEK_END) || (n = ftell(f)) <= 0 ||
	    fseek(f, 0, SEEK_SET) || !(buf = malloc((size_t)n)) ||
	    fread(buf, 1, (size_t)n, f) != (size_t)n) {
		fclose(f);
		free(buf);
		return -EIO;
	}
	fclose(f);
	fk = calloc(1, sizeof *fk);
	if (!fk) {
		free(buf);
		return -ENOMEM;
	}
	fk->data = buf;
	fk->size = (size_t)n;
	*fw = fk;
	return 0;
}
void release_firmware(const struct firmware *fw)
{
	if (fw) {
		free((void *)fw->data);
		free((void *)fw);
	}
}
void __module_get(void *m) { (void)m; }
void *devres_open_group(struct device *d, void *o, int f) { (void)d; (void)o; (void)f; return (void *)1; }
int devres_release_group(struct device *d, void *o) { (void)d; (void)o; return 0; }

/* ---- config space access, honoring the wedge knob ---- */
static int cfg_ok(void) { return !k_cmd_allf; }
int pci_read_config_word(const struct pci_dev *p, int off, u16 *v)
{
	(void)p;
	*v = cfg_ok() ? (u16)(fix_cfg[off >> 2] >> ((off & 2) * 8)) : 0xffffu;
	return 0;
}
int pci_read_config_dword(const struct pci_dev *p, int off, u32 *v)
{
	(void)p;
	*v = cfg_ok() ? fix_cfg[off >> 2] : 0xffffffffu;
	return 0;
}
int pci_write_config_word(struct pci_dev *p, int off, u16 v)
{
	(void)p;
	if (off == p->pm_cap + PCI_PM_CTRL && k_pmcsr_stuck)
		return 0;                       /* D3cold-deaf card: write lands nowhere */
	fix_cfg[off >> 2] = (fix_cfg[off >> 2] & ~(0xffffu << ((off & 2) * 8))) | ((u32)v << ((off & 2) * 8));
	return 0;
}
int pcie_capability_read_word(struct pci_dev *p, int pos, u16 *v) { return pci_read_config_word(p, 0x50 + pos, v); }
int pcie_capability_read_dword(struct pci_dev *p, int pos, u32 *v)
{
	(void)p;
	*v = cfg_ok() ? (pos == PCI_EXP_DEVCAP ? fix_cfg[(0x50 + 4) >> 2] : 0) : 0xffffffffu;
	return 0;
}
int pci_is_pcie(struct pci_dev *p) { (void)p; return 1; }
int pci_select_bars(struct pci_dev *p, unsigned long f) { (void)p; (void)f; return 1; }
int pci_request_region(struct pci_dev *p, int bar, const char *n) { (void)p; (void)bar; (void)n; return 0; }
void pci_release_region(struct pci_dev *p, int bar) { (void)p; (void)bar; }
int aperture_remove_conflicting_pci_devices(struct pci_dev *p, const char *n) { (void)p; (void)n; fix_aperture_rm_n++; return 0; }
int pci_enable_device_mem(struct pci_dev *p) { (void)p; return 0; }
void pci_disable_device(struct pci_dev *p) { (void)p; }
resource_size_t pci_resource_len(struct pci_dev *p, int bar) { return p->resource[bar].end - p->resource[bar].start + 1; }
resource_size_t pci_resource_start(struct pci_dev *p, int bar) { return p->resource[bar].start; }

/* ---- X2 aperture fixtures: fake Resizable BAR core + call sequence
 * (globals declared with the fault knobs above; the aperture stub already
 * uses the counter) ---- */
static void seq_push(const char *code)
{
	if (fix_seq_n < 64) {
		snprintf(fix_seq[fix_seq_n], sizeof fix_seq[0], "%s", code);
		fix_seq_n++;
	}
}
int fix_seq_has(const char *code)
{
	for (int i = 0; i < fix_seq_n; i++)
		if (!strcmp(fix_seq[i], code))
			return 1;
	return 0;
}
u64 pci_rebar_get_possible_sizes(struct pci_dev *p, int bar) { (void)p; (void)bar; return fix_rebar_sizes; }
int pci_resize_resource(struct pci_dev *p, int bar, int size)  /* 6.8-era 3-arg */
{
	resource_size_t newlen = (resource_size_t)SZ_4M << size;

	snprintf(fix_seq[fix_seq_n % 64], sizeof fix_seq[0], "rsz%d:%d", bar, size);
	fix_seq_n++;
	if (k_x2_resize_fail)
		return -EIO;
	if (!(fix_rebar_sizes & ((u64)1 << size)))
		return -EINVAL;
	p->resource[bar].end = p->resource[bar].start + newlen - 1;
	return 0;
}
int pci_request_selected_regions(struct pci_dev *p, int bars, const char *name)
{
	(void)name;
	seq_push("req");
	if (k_x2_req_busy)
		return -EBUSY;
	for (int bar = 0; bar < 6; bar++)
		if (bars & BIT(bar))
			p->resource[bar].flags |= IORESOURCE_BUSY;
	return 0;
}
void pci_release_selected_regions(struct pci_dev *p, int bars)
{
	seq_push("rel");
	for (int bar = 0; bar < 6; bar++)
		if (bars & BIT(bar))
			p->resource[bar].flags &= ~IORESOURCE_BUSY;
}
void __iomem *pci_iomap(struct pci_dev *p, int bar, unsigned long f) { (void)p; (void)bar; (void)f; return (void __iomem *)fix_bar; }
void pci_iounmap(struct pci_dev *p, void __iomem *m) { (void)p; (void)m; }
void *pci_map_rom(struct pci_dev *p, size_t *sz) { (void)p; *sz = 0; return NULL; }
void pci_unmap_rom(struct pci_dev *p, void *m) { (void)p; (void)m; }
int pci_save_state(struct pci_dev *p) { (void)p; return 0; }
void pci_restore_state(struct pci_dev *p) { (void)p; }
void pci_set_master(struct pci_dev *p)
{
	if (!k_bme_stuck_off)
		fix_cfg[PCI_COMMAND >> 2] |= PCI_COMMAND_MASTER;
}
void pci_clear_master(struct pci_dev *p) { fix_cfg[PCI_COMMAND >> 2] &= ~PCI_COMMAND_MASTER; }
int pcie_flr(struct pci_dev *p)
{
	(void)p;
	if (k_flr_identity_gone)
		fix_cfg[0] = 0xffffffffu;   /* identity lost after reset */
	if (k_flr_wedge)
		k_cmd_allf = 1;           /* dies during the reset window */
	return k_flr_ret;
}
struct pci_dev *pci_dev_get(struct pci_dev *p) { p->refs++; return p; }
void pci_dev_put(struct pci_dev *p) { p->refs--; }

/* ---- fixture builders for scenarios ---- */
void fix_reset(void)
{
	memset(fix_bar, 0, sizeof fix_bar);
	memset(fix_cfg, 0, sizeof fix_cfg);
	k_fail_alloc_at = -1; k_alloc_calls = 0; k_pmcsr_stuck = 0; k_flr_ret = 0;
	k_flr_identity_gone = 0; k_cmd_allf = 0; k_flr_wedge = 0; k_bme_stuck_off = 0; vms = 0; dma_live = 0;
	k_x2_req_busy = 0; k_x2_resize_fail = 0; fix_aperture_rm_n = 0;
	fix_seq_n = 0;
	fix_rebar_sizes = (1u << 0) | (1u << 2) | (1u << 4) | (1u << 6); /* 4,16,64,256 MiB */
	log_clear();
	fix_cfg[0] = 0x1e0910deu;                    /* vendor/device */
	fix_cfg[PCI_COMMAND >> 2] = 0x0000;          /* MSE off, BME off */
	fix_cfg[PCI_STATUS >> 2] = 0x0010 << 16;     /* cap list present (status word hi) */
	fix_cfg[PCI_CAPABILITY_LIST >> 2] = 0x40;    /* PM @ 0x40 */
	fix_cfg[0x40 >> 2] = 0x00500001u;            /* PM: id 0x01, next 0x50 */
	fix_cfg[0x50 >> 2] = 0x00000010u;            /* PCIe: id 0x10, next 0 */
	fix_cfg[(0x50 + 4) >> 2] = 1u << 28;         /* DEVCAP FLReset+ */
}
u8 *fix_mmio(void) { return fix_bar; }
u32 *fix_config(void) { return fix_cfg; }
