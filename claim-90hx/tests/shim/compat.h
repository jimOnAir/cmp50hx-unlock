/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Host-side kernel-API shim for the claim-module failure-injection harness
 * (gtuu-mining ticket 11). Ported from GPU-Tensor-Unlock-Universal
 * @ ab7bfc0 tests/unlock_shim/compat.h, extended for this fork
 * (dev_dbg, pci_name, PM/FLR-force fixture knobs the shim impl provides).
 * The REAL module sources are compiled against this — no forked copies.
 */
#ifndef UNLOCK_TRANSACTION_SHIM_H
#define UNLOCK_TRANSACTION_SHIM_H
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stddef.h>
#include <string.h>
#include <stdio.h>
#include <asm-generic/errno.h>
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int32_t s32;
typedef uint64_t dma_addr_t;
typedef uint64_t resource_size_t;
typedef uint64_t ktime_t;
typedef unsigned int uint;	/* kernel types.h surface used by x2 params */
typedef unsigned int gfp_t;
#define __iomem
#define GFP_KERNEL 0
#define GFP_ATOMIC 1
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define min_t(t,a,b) ((t)(a)<(t)(b)?(t)(a):(t)(b))
#define lower_32_bits(v) ((u32)(v))
#define upper_32_bits(v) ((u32)((u64)(v)>>32))
#define DMA_BIT_MASK(n) ((n)>=64?~0ull:((1ull<<(n))-1))
#define MODULE_FIRMWARE(x)
#define MODULE_PARM_DESC(x, y)
#define module_param(name, type, perm)
#define THIS_MODULE NULL
#define LINUX_VERSION_CODE 0x060800 /* only used by nothing after t06's feature-detect */
struct list_head { unsigned int count; };
struct device;                 /* forward for the log prototype below */
void test_device_log(const struct device *dev, const char *, ...) __attribute__((format(printf, 2, 3)));
/* dev_err carries a "[E] " tag into the log ring: reverse (must-NOT-happen)
 * assertions (B2-P23) then have one precise needle, not a word guess. */
#define dev_err(dev, ...)  test_device_log(dev, "[E] " __VA_ARGS__)
#define dev_info(dev, ...) test_device_log(dev, __VA_ARGS__)
#define dev_dbg(dev, ...)  test_device_log(dev, __VA_ARGS__)
#define dev_warn(dev, ...) test_device_log(dev, "[E] " __VA_ARGS__)
#define PCI_D0 0
#define PCI_D3hot 3
#define PCI_D3cold 4
#define PCI_UNKNOWN 5
#define PCI_DEV_FLAGS_NO_FLR_RESET (1u << 10)
#define PCI_VENDOR_ID 0x00
#define PCI_DEVICE_ID 0x02
#define PCI_COMMAND 0x04
#define PCI_COMMAND_MEMORY 2
#define PCI_COMMAND_MASTER 4
#define PCI_STATUS 0x06
#define PCI_CAPABILITY_LIST 0x34
#define PCI_CAP_ID_PM 0x01
#define PCI_CAP_ID_EXP 0x10
#define PCI_PM_CTRL 0x04
#define PCI_PM_CTRL_STATE_MASK 3
#define PCI_EXP_FLAGS 0x02
#define PCI_EXP_DEVCAP 0x04
#define PCI_EXP_DEVCAP_FLR (1u<<28)
#define PCI_EXP_DEVCTL 0x08
#define PCI_EXP_DEVSTA 0x0a
#define PCI_EXP_DEVSTA_TRPND 32
#define PCI_BASE_ADDRESS_0 0x10
#define IORESOURCE_MEM 0x200
#define IORESOURCE_PREFETCH 0x2000
#define IORESOURCE_MEM_64 0x100000
#define IORESOURCE_BUSY 0x80000000
#define BIT(n) (1UL << (n))
#define SZ_1M 0x00100000UL
#define SZ_4M 0x00400000UL
#define ilog2(n) __ilog2(n)
static inline int __ilog2(u64 n) { int r = -1; while (n) { n >>= 1; r++; } return r; }
struct resource { resource_size_t start, end; unsigned long flags; const char *name; };
static inline bool list_empty(const struct list_head *h) { return !h->count; }
#define spin_lock_irqsave(lock, flags) do { (void)(lock); (flags)=0; } while (0)
#define spin_unlock_irqrestore(lock, flags) do { (void)(lock); (void)(flags); } while (0)
struct device { u64 *dma_mask; u64 coherent_dma_mask; struct list_head devres_head; int devres_lock; };
void *devres_open_group(struct device *, void *, int);
int devres_release_group(struct device *, void *);
struct pci_dev { struct device dev; unsigned short vendor, device; int current_state, pm_cap, refs; unsigned int dev_flags; struct resource resource[6]; };
struct firmware { size_t size; const u8 *data; };
void usleep_range(unsigned long, unsigned long);
unsigned long simple_strtoul(const char *cp, char **endp, unsigned int base);
int kstrtoul(const char *s, unsigned int base, unsigned long *res);
ktime_t ktime_get(void);
static inline ktime_t ktime_add_us(ktime_t t, unsigned long u) { return t + u * 1000ull; }
static inline int ktime_compare(ktime_t a, ktime_t b) { return a > b ? 1 : a < b ? -1 : 0; }
const char *pci_name(const struct pci_dev *pdev);
u32 readl(const void __iomem *);
void writel(u32, void __iomem *);
#define memcpy_fromio memcpy
void *dma_alloc_coherent(struct device *, size_t, dma_addr_t *, int);
void dma_free_coherent(struct device *, size_t, void *, dma_addr_t);
int dma_set_mask(struct device *, u64);
int dma_set_coherent_mask(struct device *, u64);
void dma_wmb(void);
void *kzalloc(size_t n, int flags);
static inline void *kvcalloc(size_t n, size_t s, int flags) { return calloc(n, s); }
static inline void *kvmalloc(size_t n, int flags) { return malloc(n); }
#define kfree free
#define kvfree free
int request_firmware(const struct firmware **, const char *, struct device *);
void release_firmware(const struct firmware *);
void __module_get(void *);
int pci_read_config_word(const struct pci_dev *, int, u16 *);
int pci_read_config_dword(const struct pci_dev *, int, u32 *);
int pci_write_config_word(struct pci_dev *, int, u16);
int pcie_capability_read_word(struct pci_dev *, int, u16 *);
int pcie_capability_read_dword(struct pci_dev *, int, u32 *);
int pci_is_pcie(struct pci_dev *);
int pci_select_bars(struct pci_dev *, unsigned long);
int pci_request_region(struct pci_dev *, int, const char *);
void pci_release_region(struct pci_dev *, int);
int aperture_remove_conflicting_pci_devices(struct pci_dev *, const char *);
int pci_enable_device_mem(struct pci_dev *);
void pci_disable_device(struct pci_dev *);
resource_size_t pci_resource_len(struct pci_dev *, int);
resource_size_t pci_resource_start(struct pci_dev *, int);
u64 pci_rebar_get_possible_sizes(struct pci_dev *, int);
int pci_resize_resource(struct pci_dev *, int, int, int);
int pci_request_selected_regions(struct pci_dev *, int, const char *);
void pci_release_selected_regions(struct pci_dev *, int);
void __iomem *pci_iomap(struct pci_dev *, int, unsigned long);
void pci_iounmap(struct pci_dev *, void __iomem *);
void *pci_map_rom(struct pci_dev *, size_t *);
void pci_unmap_rom(struct pci_dev *, void *);
int pci_save_state(struct pci_dev *);
void pci_restore_state(struct pci_dev *);
void pci_set_master(struct pci_dev *);
void pci_clear_master(struct pci_dev *);
int pcie_flr(struct pci_dev *);
struct pci_dev *pci_dev_get(struct pci_dev *);
void pci_dev_put(struct pci_dev *);
#endif
