/* gen2.c — PCIe Gen2 unlock + auto-retrain (deterministic policy method).
 *
 * C port of cmp50hx-gen2.sh (merged 2026-10-28; register map now in
 * common/cmp50hx_regs.h, shared with the EFI unlocker and kernel patches).
 *
 * The card's PCIe target-speed registers are GSP-clobbered ~100 ms after
 * the driver's boot-window policy runs, so waiting for a "self-unlock" is
 * unreliable (observed on kernel 6.8.0-139: no flip for 12+ minutes, because
 * the driver's retrain gate then always skips). Instead we apply the unlock
 * policy ourselves through BAR0 — the same register set patch 01 writes —
 * and kick LTSSM, which makes the card adopt the unlocked capability set at
 * once (adoption is one-shot per power cycle, so this must run before
 * anything else adopts the locked set; the boot order guarantees that). Then
 * we mirror the card's target onto the upstream port and fire Retrain Link
 * until the link reaches the card's target generation. Retrain Link is safe
 * under load and harmless to repeat.
 */
#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>

#include "../common/cmp50hx_regs.h"

#define TIMEOUT_MIN 20      /* give up after this many minutes */
#define POLL_SEC 15         /* how often to retry (gate opens ~5 s after boot) */
#define RETRAIN_WAIT_SEC 3  /* how long to wait for the link to come back up */
#define GATE_GIVEUP_SEC 90  /* per-card terminal grace: healthy gates open
                             * ~5-15 s after the driver loads (module autoloads
                             * by PCI alias on stock installs; on bench the
                             * boot runner's collect phase loads it ~0.3 s in).
                             * A gate still closed after this grace is either a
                             * compute-locked card (opens only after a power
                             * cycle — waiting is pointless) or a host that
                             * deliberately blacklists nvidia and starts every
                             * consumer after cmp50hx-boot: in both cases do
                             * NOT hold the Before=docker transaction hostage.
                             * Run 'cmp50hx gen2' manually after the driver is
                             * up on such hosts. */

#define PCI_CAP_ID_EXP 0x10
#define PCI_CAP_LIST  0x34   /* first capability pointer */
#define PCI_EXP_LNKCAP 0x0c  /* Link Capabilities (32-bit): low nibble = max speed */
#define PCI_EXP_LNKCTL 0x10  /* Link Control (16-bit): bit 5 = Retrain Link */
#define PCI_EXP_LNKCTL2 0x30 /* Link Control 2 (16-bit): low nibble = target speed */

static void log_msg(const char *fmt, ...) {
    va_list ap;
    printf("cmp50hx-gen2: ");
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    printf("\n");
    fflush(stdout);
}

static int read_sysfs_str(const char *path, char *buf, size_t len) {
    FILE *f = fopen(path, "r");
    if (f == NULL) {
        return -1;
    }
    if (fgets(buf, (int)len, f) == NULL) {
        fclose(f);
        return -1;
    }
    fclose(f);
    buf[strcspn(buf, "\n")] = '\0';
    return 0;
}

/* Link speed "5.0 GT/s PCIe" -> generation 1..5, 0 unknown */
static int link_gen(const char *bdf) {
    char path[PATH_MAX];
    char text[128];
    snprintf(path, sizeof path, "/sys/bus/pci/devices/%s/current_link_speed",
             bdf);
    if (read_sysfs_str(path, text, sizeof text) != 0) {
        return 0;
    }
    if (strstr(text, "2.5") != NULL)  return 1;
    if (strstr(text, "5.0") != NULL)  return 2;
    if (strstr(text, "8.0") != NULL)  return 3;
    if (strstr(text, "16.0") != NULL) return 4;
    if (strstr(text, "32.0") != NULL) return 5;
    return 0;
}

static int config_open(const char *bdf) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "/sys/bus/pci/devices/%s/config", bdf);
    return open(path, O_RDWR);
}

static int cfg_read(int cf, off_t off, void *buf, size_t len) {
    return pread(cf, buf, len, off) == (ssize_t)len ? 0 : -1;
}

static int cfg_write(int cf, off_t off, const void *buf, size_t len) {
    return pwrite(cf, buf, len, off) == (ssize_t)len ? 0 : -1;
}

/* offset of the PCI Express capability, or -1 */
static int cap_exp(int cf) {
    unsigned char ptr = 0;
    if (cfg_read(cf, PCI_CAP_LIST, &ptr, 1) != 0) {
        return -1;
    }
    for (int hops = 0; hops < 48 && ptr >= 0x40; ++hops) {
        unsigned char id = 0, next = 0;
        if (cfg_read(cf, ptr, &id, 1) != 0 ||
            cfg_read(cf, (off_t)ptr + 1, &next, 1) != 0) {
            return -1;
        }
        if (id == PCI_CAP_ID_EXP) {
            return ptr;
        }
        ptr = next;
    }
    return -1;
}

/* card's target speed from LNKCTL2, or -1 */
static int gpu_tls(const char *bdf) {
    int cf = config_open(bdf);
    unsigned short ctl2 = 0;
    int off, tls;
    if (cf < 0) {
        return -1;
    }
    off = cap_exp(cf);
    if (off < 0 || cfg_read(cf, off + PCI_EXP_LNKCTL2, &ctl2, 2) != 0) {
        close(cf);
        return -1;
    }
    close(cf);
    tls = ctl2 & 0xf;
    return tls;
}

/* max link speed from LNKCAP, or -1 */
static int gpu_max_speed(const char *bdf) {
    int cf = config_open(bdf);
    unsigned int cap = 0;
    int off, spd;
    if (cf < 0) {
        return -1;
    }
    off = cap_exp(cf);
    if (off < 0 || cfg_read(cf, off + PCI_EXP_LNKCAP, &cap, 4) != 0) {
        close(cf);
        return -1;
    }
    close(cf);
    spd = (int)(cap & 0xf);
    return spd;
}

typedef enum { POLICY_GATE_CLOSED, POLICY_ALREADY, POLICY_ADOPTED,
               POLICY_FAILED } policy_result_t;

/* Apply the Gen2 policy + LTSSM kick via BAR0 (same register set as the
 * driver's boot-window policy; VAL3/OVR3 deliberately omitted — proven
 * unnecessary on 2026-09-13). */
static policy_result_t apply_policy(const char *bdf) {
    char path[PATH_MAX];
    policy_result_t result = POLICY_FAILED;
    int fd;
    void *map;
    volatile uint32_t *bar;
    uint32_t misc1, cya0, cfg0, pl_rate;

    snprintf(path, sizeof path, "/sys/bus/pci/devices/%s/resource0", bdf);
    fd = open(path, O_RDWR | O_SYNC);
    if (fd < 0) {
        return POLICY_FAILED;
    }
    map = mmap(NULL, 0x90000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (map == MAP_FAILED) {
        return POLICY_FAILED;
    }
    bar = (volatile uint32_t *)map;

    if (bar[CMP50_REG_PCIE_XP3G_PLM0 / 4] != 0xFFFFFFFFu) {
        result = POLICY_GATE_CLOSED;   /* driver still booting; gate opens ~5 s in */
        goto out;
    }
    if (gpu_max_speed(bdf) >= 2) {
        result = POLICY_ALREADY;
        goto out;
    }
    misc1 = bar[CMP50_REG_PCIE_MISC1 / 4];
    bar[CMP50_REG_PCIE_MISC1 / 4] =
        (misc1 | ((1u << 11) | (1u << 13))) & ~((1u << 12) | (1u << 14));
    bar[CMP50_REG_PCIE_XP3G_VAL0 / 4] = 0;
    bar[CMP50_REG_PCIE_XP3G_OVR0 / 4] = 1;
    cya0 = bar[CMP50_REG_PCIE_CYA0 / 4];
    bar[CMP50_REG_PCIE_CYA0 / 4] = cya0 & ~(1u << 2);
    cfg0 = bar[CMP50_REG_PCIE_CFG0 / 4];
    bar[CMP50_REG_PCIE_CFG0 / 4] = (cfg0 & ~0x000C0000u) | (2u << 18);
    pl_rate = bar[CMP50_REG_PCIE_PL_RATE / 4];
    bar[CMP50_REG_PCIE_PL_RATE / 4] = (pl_rate & ~0x00060000u) | 0x00040000u;
    bar[CMP50_REG_PCIE_LTSSM / 4] = 6;   /* kick: one-shot adoption */
    result = POLICY_ADOPTED;
out:
    munmap(map, 0x90000);
    return result;
}

/* upstream bridge BDF of a device: the sysfs symlink points at
 * /sys/devices/pci0000:00/<rootport>/<bdf>; the parent dir is the rootport */
static int upstream_of(const char *bdf, char *out, size_t out_len) {
    char link[PATH_MAX];
    char resolved[PATH_MAX];
    char *slash;
    snprintf(link, sizeof link, "/sys/bus/pci/devices/%s", bdf);
    if (realpath(link, resolved) == NULL) {
        return -1;
    }
    slash = strrchr(resolved, '/');
    if (slash == NULL || slash == resolved) {
        return -1;
    }
    *slash = '\0';
    slash = strrchr(resolved, '/');
    if (slash == NULL) {
        return -1;
    }
    snprintf(out, out_len, "%s", slash + 1);
    return 0;
}

static void retrain(const char *upstream, int target) {
    int cf = config_open(upstream);
    unsigned short ctl2 = 0, ctl = 0;
    int off;
    if (cf < 0) {
        return;
    }
    off = cap_exp(cf);
    if (off >= 0) {
        if (cfg_read(cf, off + PCI_EXP_LNKCTL2, &ctl2, 2) == 0) {
            ctl2 = (unsigned short)((ctl2 & ~0xfu) | (unsigned)target);
            cfg_write(cf, off + PCI_EXP_LNKCTL2, &ctl2, 2);
        }
        if (cfg_read(cf, off + PCI_EXP_LNKCTL, &ctl, 2) == 0) {
            ctl = (unsigned short)(ctl | 0x20u);   /* Retrain Link */
            cfg_write(cf, off + PCI_EXP_LNKCTL, &ctl, 2);
        }
    }
    close(cf);
}

static int collect_cards(char names[][13], int max) {
    static const char dir[] = "/sys/bus/pci/devices";
    DIR *d = opendir(dir);
    char path[PATH_MAX], value[16];
    int count = 0;
    struct dirent *ent;
    if (d == NULL) {
        return 0;
    }
    while ((ent = readdir(d)) != NULL && count < max) {
        snprintf(path, sizeof path, "%s/%s/vendor", dir, ent->d_name);
        if (read_sysfs_str(path, value, sizeof value) != 0 ||
            strcmp(value, "0x10de") != 0) {
            continue;
        }
        snprintf(path, sizeof path, "%s/%s/device", dir, ent->d_name);
        if (read_sysfs_str(path, value, sizeof value) != 0 ||
            strcmp(value, "0x1e09") != 0) {
            continue;
        }
        size_t name_len = strlen(ent->d_name);
        if (name_len == 0 || name_len >= 13) {
            continue;   /* not a PCI BDF directory name */
        }
        memcpy(names[count], ent->d_name, name_len + 1);
        ++count;
    }
    closedir(d);
    return count;
}

int gen2_main(int argc, char **argv) {
    char bdfs[8][13];
    time_t first_closed[8] = {0};
    int terminal[8] = {0};
    int n, i;
    time_t deadline;
    (void)argc; (void)argv;

    n = collect_cards(bdfs, 8);
    if (n == 0) {
        log_msg("no CMP 50HX (10de:1e09) found; nothing to do");
        return 0;
    }

    deadline = time(NULL) + (time_t)TIMEOUT_MIN * 60;
    for (;;) {
        int all_fast = 1;
        for (i = 0; i < n; ++i) {
            const char *bdf = bdfs[i];
            int t = gpu_tls(bdf);
            int cur = link_gen(bdf);
            char upstream[13];
            if (t >= 2 && cur >= t) {
                continue;
            }
            if (terminal[i]) {
                continue;   /* given up on this card: not fast, but not waited on */
            }
            all_fast = 0;
            if (t < 2) {
                switch (apply_policy(bdf)) {
                case POLICY_GATE_CLOSED:
                    if (first_closed[i] == 0) {
                        first_closed[i] = time(NULL);
                    }
                    if (time(NULL) - first_closed[i] >= GATE_GIVEUP_SEC) {
                        terminal[i] = 1;
                        log_msg("%s: GATE-GIVEUP after %ds closed — compute-locked (gate opens only after a power cycle) or driver never loaded; not waiting further",
                                bdf, GATE_GIVEUP_SEC);
                    } else {
                        log_msg("%s: PCIe policy gate closed (driver still booting, or this card is compute-locked and will never open it); retrying", bdf);
                    }
                    break;
                case POLICY_ALREADY:
                    log_msg("%s: ALREADY cap>=2 (target %d)", bdf,
                            gpu_max_speed(bdf));
                    break;
                case POLICY_ADOPTED:
                    log_msg("%s: ADOPTED (target %d cap %d)", bdf, gpu_tls(bdf),
                            gpu_max_speed(bdf));
                    break;
                default:
                    log_msg("%s: policy apply failed (need root for BAR0/PCIe config access?); retrying", bdf);
                    break;
                }
                t = gpu_tls(bdf);
                if (t < 2) {
                    continue;
                }
            }
            if (upstream_of(bdf, upstream, sizeof upstream) != 0) {
                log_msg("%s: no upstream bridge found; skipping retrain", bdf);
                continue;
            }
            log_msg("%s: card unlocked (TLS=%d), firing retrain via %s "
                    "(link now Gen%d)", bdf, t, upstream, cur);
            retrain(upstream, t);
            for (int tenth = 0; tenth < RETRAIN_WAIT_SEC * 10; ++tenth) {
                if (link_gen(bdf) >= t) {
                    break;
                }
                usleep(100000);
            }
            cur = link_gen(bdf);
            if (cur >= t) {
                char speed[64] = "?";
                char path[PATH_MAX];
                snprintf(path, sizeof path,
                         "/sys/bus/pci/devices/%s/current_link_speed", bdf);
                read_sysfs_str(path, speed, sizeof speed);
                log_msg("%s: PASS, link at %s", bdf, speed);
            } else {
                log_msg("%s: retrain fired, link still at Gen%d < Gen%d "
                        "(will retry)", bdf, cur, t);
            }
        }
        if (all_fast) {
            int nterm = 0;
            for (i = 0; i < n; ++i) {
                nterm += terminal[i];
            }
            if (nterm > 0) {
                log_msg("DONE with %d/%d cards terminal (GATE-GIVEUP; power cycle is the cure)",
                        nterm, n);
                return 1;
            }
            log_msg("all CMP 50HX cards at their target generation");
            return 0;
        }
        if (time(NULL) >= deadline) {
            log_msg("TIMEOUT after %d min; some card(s) below target",
                    TIMEOUT_MIN);
            return 1;
        }
        sleep(POLL_SEC);
    }
}
