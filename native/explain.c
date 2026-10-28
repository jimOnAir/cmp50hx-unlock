/* explain.c — human-readable decoder for the CMP 50HX unlock logs.
 *
 * The pre-OS unlocker writes hex verdict lines to the ESP (its only channel
 * into the OS) and the driver logs signature memdescs; neither reads like
 * English. This subcommand translates what happened on THIS machine into a
 * verdict + a cure. Machine-parseable log formats are NOT changed — this is
 * pure interpretation.
 *
 *   cmp50hx explain          all sections
 *   cmp50hx explain efi      the ESP unlocker logs per boot-module
 *   cmp50hx explain cards    per-1e09 health: PCI, driver, NVML, link speed
 *   cmp50hx explain dmesg    annotated NVRM / CMP50 unlock lines
 */
#define _GNU_SOURCE

#include <ctype.h>
#include <dirent.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* ESP logs count toward THIS boot only inside the collect.sh freshness
 * window: [boot_epoch - 300 s, boot_epoch + 120 s] (the unlocker writes
 * pre-OS, so its FAT mtime lands before the kernel clock starts). */
#define FRESH_BEFORE 300
#define FRESH_AFTER 120

static time_t boot_epoch(void) {
    FILE *f = fopen("/proc/uptime", "r");
    double up = 0;
    if (f == NULL) {
        return 0;
    }
    if (fscanf(f, "%lf", &up) != 1) {
        up = 0;
    }
    fclose(f);
    if (up <= 0) {
        return 0;
    }
    return time(NULL) - (time_t)up;
}

static int log_fresh(time_t mtime, time_t bepoch) {
    if (bepoch == 0) {
        return -1;   /* unknown */
    }
    return (mtime >= bepoch - FRESH_BEFORE && mtime <= bepoch + FRESH_AFTER);
}

/* --- value translators ----------------------------------------------------- */

static void print_ss0(unsigned long v) {
    switch (v) {
    case 0x88888888UL:
        printf("    SS0 = 0x88888888  -> compute features UNLOCKED\n");
        printf("                         (full-speed feature mask applied)\n");
        break;
    case 0:
        printf("    SS0 = 0x00000000  -> still LOCKED\n");
        printf("                         the pre-OS booter unlock never landed\n");
        printf("                         on the card this module drove\n");
        break;
    default:
        printf("    SS0 = 0x%08lx  -> unexpected partial value\n", v);
        break;
    }
}

static void print_plm(unsigned long v) {
    if (v == 0xFFFFFFFFUL) {
        printf("    PLM = 0xffffffff  -> privilege gate fully OPEN (normal\n");
        printf("                         after a successful booter run)\n");
    } else {
        printf("    PLM = 0x%08lx  -> privilege gate still partly held\n", v);
        printf("                         the booter window was missed this boot\n");
    }
}

static void print_wpr2(unsigned long hi, unsigned long lo) {
    if (hi == 0x027FEE00UL && lo == 0x027FE000UL) {
        printf("    WPR2 = up (0x%08lx:0x%08lx)  -> GSP secure memory region\n",
               hi, lo);
        printf("                         established (needed for GSP, but the\n");
        printf("                         feature mask above still says locked)\n");
    } else if (hi == 0 && lo == 0x1FFFFE00UL) {
        printf("    WPR2 = DOWN (0x%08lx:0x%08lx)  -> the locked SKU's VBIOS\n",
               hi, lo);
        printf("                         never raised it; GSP will fail to load\n");
        printf("                         and RmInitAdapter will fail (card\n");
        printf("                         bound to nvidia but invisible to NVML)\n");
    } else {
        printf("    WPR2 = 0x%08lx:0x%08lx  (unexpected geometry)\n", hi, lo);
    }
}

/* --- helpers --------------------------------------------------------------- */

static int hex_at(const char *line, const char *key, unsigned long *out) {
    const char *p = strstr(line, key);
    if (p == NULL) {
        return 0;
    }
    p += strlen(key);
    char *end = NULL;
    unsigned long v = strtoul(p, &end, 16);
    if (end == p) {
        return 0;
    }
    *out = v;
    return 1;
}

static int read_file_head(const char *path, char *buf, size_t len) {
    FILE *f = fopen(path, "r");
    size_t got;
    if (f == NULL) {
        return -1;
    }
    got = fread(buf, 1, len - 1, f);
    buf[got] = '\0';
    fclose(f);
    /* EFI writes CRLF */
    for (size_t i = 0; i < got; ++i) {
        if (buf[i] == '\r') {
            buf[i] = '\n';
        }
    }
    return 0;
}

/* --- explain efi ----------------------------------------------------------- */

static void explain_one_log(const char *path, time_t bepoch) {
    static char text[256u * 1024u];
    struct stat st;
    char line[256];
    int unlocked = 0, saw_result = 0;
    unsigned long plm = 0, ss0 = 0, ss1 = 0, wpr_hi = 0, wpr_lo = 0;
    int have_wpr = 0;

    if (stat(path, &st) != 0) {
        return;
    }
    printf("  %s", path);
    int fresh = log_fresh(st.st_mtime, bepoch);
    printf("   [%s%s]\n", fresh == 1 ? "written THIS boot" :
           fresh == 0 ? "STALE — not this boot, ignored" : "age unknown",
           "");
    if (fresh != 1) {
        return;
    }
    if (read_file_head(path, text, sizeof text) != 0) {
        printf("    (unreadable — run with sudo)\n");
        return;
    }

    const char *build = strstr(text, "[build]");
    if (build != NULL) {
        const char *eol = strchr(build, '\n');
        printf("    unlocker build: %.*s\n",
               (int)(eol != NULL ? eol - build : (long)strlen(build)), build);
    }

    /* scan lines: remember the LAST verdict evidence */
    const char *p = text;
    while (*p != '\0') {
        const char *eol = strchr(p, '\n');
        size_t len = eol != NULL ? (size_t)(eol - p) : strlen(p);
        if (len >= sizeof line) {
            len = sizeof line - 1;
        }
        memcpy(line, p, len);
        line[len] = '\0';

        if (strstr(line, "UNLOCKED (SS0") != NULL) {
            unlocked = 1;
        }
        if (strstr(line, "RESULT: PLM=") != NULL) {
            unsigned long t_plm = 0, t_ss0 = 0, t_ss1 = 0;
            if (hex_at(line, "PLM=0x", &t_plm) &&
                hex_at(line, "SS0=0x", &t_ss0)) {
                (void)hex_at(line, "SS1=0x", &t_ss1);
                plm = t_plm;
                ss0 = t_ss0;
                ss1 = t_ss1;
                saw_result = 1;
            }
        }
        {
            const char *w = strstr(line, "WPR2=0x");
            if (w != NULL && saw_result) {
                unsigned long a = 0, b = 0;
                if (sscanf(w + 5, "%lx:%lx", &a, &b) == 2) {
                    wpr_hi = a;
                    wpr_lo = b;
                    have_wpr = 1;
                }
            }
        }
        if (eol == NULL) {
            break;
        }
        p = eol + 1;
    }

    if (unlocked) {
        printf("    VERDICT: UNLOCKED — the booter won this card this boot\n");
    } else if (saw_result) {
        printf("    VERDICT: LOCKED — the booter missed this card this boot\n");
        print_plm(plm);
        print_ss0(ss0);
        printf("    SS1 = 0x%08lx  -> %s\n", ss1,
               ss1 == 0x8UL ? "open" : "still locked");
        if (have_wpr) {
            print_wpr2(wpr_hi, wpr_lo);
        }
    } else {
        printf("    (no RESULT line found — did the module reach the GPU?)\n");
    }
}

static void explain_efi(void) {
    static const char *const logs[] = {
        "/boot/efi/50hx_log_u1.txt", "/boot/efi/50hx_log_u3.txt",
        "/boot/efi/50hx_log_u4.txt", "/boot/efi/50hx_log.txt", NULL};
    time_t bepoch = boot_epoch();
    int won = 0, seen = 0;
    printf("== Pre-OS unlocker logs (ESP, written every boot BEFORE the OS)\n");
    for (int i = 0; logs[i] != NULL; ++i) {
        struct stat st;
        if (stat(logs[i], &st) != 0) {
            continue;
        }
        ++seen;
        explain_one_log(logs[i], bepoch);
        /* count wins like cmp50hx-boot.sh does (fresh files only) */
        if (log_fresh(st.st_mtime, bepoch) == 1) {
            static char text[256u * 1024u];
            if (read_file_head(logs[i], text, sizeof text) == 0 &&
                strstr(text, "UNLOCKED (SS0") != NULL) {
                ++won;
            }
        }
    }
    if (seen == 0) {
        printf("  (no ESP unlocker logs found — UEFI unlock not deployed?)\n");
    } else {
        printf("  => this boot: %d unlocker module log(s) report UNLOCKED\n",
               won);
    }
}

/* --- explain cards --------------------------------------------------------- */

static int read_small(const char *path, char *buf, size_t len) {
    FILE *f = fopen(path, "r");
    if (f == NULL) {
        buf[0] = '\0';
        return -1;
    }
    if (fgets(buf, (int)len, f) == NULL) {
        buf[0] = '\0';
    }
    fclose(f);
    buf[strcspn(buf, "\n")] = '\0';
    return 0;
}

static void upper_copy(char *dst, const char *src, size_t len) {
    size_t i = 0;
    for (; src[i] != '\0' && i + 1 < len; ++i) {
        dst[i] = (char)toupper((unsigned char)src[i]);
    }
    dst[i] = '\0';
}

static void collect_nvml_buses(char buses[][16], int max) {
    FILE *f = popen("nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader "
                    "2>/dev/null", "r");
    char line[64];
    int n = 0;
    if (f == NULL) {
        return;
    }
    while (n < max && fgets(line, sizeof line, f) != NULL) {
        char up[32];
        upper_copy(up, line, sizeof up);
        /* nvidia-smi prints 00000000:03:00.0 -> keep "03:00.0" */
        char *colon = strchr(up, ':');
        if (colon != NULL && n < max) {
            snprintf(buses[n], 16, "%s", colon + 1);
            buses[n][strcspn(buses[n], "\r\n")] = '\0';
            ++n;
        }
    }
    pclose(f);
}

static void explain_cards(void) {
    static const char dir[] = "/sys/bus/pci/devices";
    DIR *d = opendir(dir);
    struct dirent *ent;
    char nvml_buses[8][16];
    int bad = 0;
    int found = 0;

    printf("== Cards on the PCI bus (10de:1e09 = CMP 50HX)\n");
    collect_nvml_buses(nvml_buses, 8);
    if (d == NULL) {
        printf("  (cannot read /sys/bus/pci/devices)\n");
        return;
    }
    while ((ent = readdir(d)) != NULL) {
        char path[512], value[64];
        snprintf(path, sizeof path, "%s/%s/vendor", dir, ent->d_name);
        if (read_small(path, value, sizeof value) != 0 ||
            strcmp(value, "0x10de") != 0) {
            continue;
        }
        snprintf(path, sizeof path, "%s/%s/device", dir, ent->d_name);
        if (read_small(path, value, sizeof value) != 0 ||
            strcmp(value, "0x1e09") != 0) {
            continue;
        }
        /* found a CMP 50HX: driver? NVML-visible? link speed? */
        char drv[64] = "none";
        snprintf(path, sizeof path, "%s/%s/driver", dir, ent->d_name);
        {
            char resolved[512];
            if (realpath(path, resolved) != NULL) {
                char *slash = strrchr(resolved, '/');
                snprintf(drv, sizeof drv, "%s",
                         slash != NULL ? slash + 1 : "?");
            }
        }
        int visible = 0;
        const char *tail = ent->d_name + strlen(ent->d_name) - 7; /* 03:00.0 */
        for (int i = 0; i < 8; ++i) {
            if (nvml_buses[i][0] != '\0' && strstr(nvml_buses[i], tail) != NULL) {
                visible = 1;
            }
        }
        char speed[64] = "?";
        snprintf(path, sizeof path, "%s/%s/current_link_speed", dir,
                 ent->d_name);
        read_small(path, speed, sizeof speed);

        ++found;
        printf("  %s  driver=%s  NVML=%s  PCIe=%s\n", ent->d_name, drv,
               visible ? "visible" : "ABSENT", speed);
        if (visible) {
            if (strstr(speed, "5.0") == NULL) {
                printf("      -> working, but PCIe link is below Gen2; the boot\n");
                printf("         flow should retrain it (journalctl -u cmp50hx-boot)\n");
                ++bad;
            } else {
                printf("      -> healthy: compute-unlocked, driver up, Gen2\n");
            }
        } else {
            ++bad;
            if (strcmp(drv, "nvidia") == 0) {
                printf("      -> bound to the driver but NOT initialized: the\n");
                printf("         pre-OS unlock missed this card and the driver's\n");
                printf("         in-kernel fallback commit was REJECTED, so GSP\n");
                printf("         never came up (see: explain dmesg).\n");
                printf("         The card is unusable until a FULL power cycle.\n");
            } else {
                printf("      -> no driver bound; modprobe nvidia or check\n");
                printf("         journalctl -k for the reason\n");
            }
        }
    }
    closedir(d);
    if (found == 0) {
        printf("  (no CMP 50HX (10de:1e09) on this PCI bus)\n");
    }
    if (bad > 0) {
        printf("  => %d card(s) degraded. Warm reboots only re-roll the\n", bad);
        printf("     unlocker's probability; the deterministic cure (no PDU)\n");
        printf("     is: power the machine OFF for ~10 s, then back on.\n");
    }
}

/* --- explain dmesg --------------------------------------------------------- */

static void annotate_kernel_line(const char *line) {
    char excerpt[161];
    snprintf(excerpt, sizeof excerpt, "%.160s", line);
    printf("    %s\n", excerpt);
    if (strstr(line, "stock-relock") != NULL) {
        unsigned long fecs = 0;
        printf("      -> in-kernel fallback: the driver signed a full-speed\n");
        printf("         relock commit and offered it to this card\n");
        if (hex_at(line, "FECS=0x", &fecs) && fecs != 0) {
            printf("         FECS=0x%08lx = handshake REJECTED the commit\n",
                   fecs);
        }
    } else if (strstr(line, "COMPUTE_UNLOCK_V140") != NULL) {
        printf("      -> fallback step: building fresh WPR metadata so GSP\n");
        printf("         can boot even on a locked card\n");
    } else if (strstr(line, "POST_FWSEC_COMMIT_FAIL") != NULL) {
        unsigned long ss0 = 0, fecs = 0;
        int status = -1;
        const char *st = strstr(line, "status=");
        if (st != NULL) {
            status = (int)strtol(st + 7, NULL, 10);
        }
        printf("      -> fallback step: the signed unlock commit was REJECTED\n");
        printf("         (status=%d) — the card's lock state does not permit it\n",
               status);
        if (hex_at(line, "SS0=", &ss0) && ss0 == 0) {
            printf("         SS0=00000000 confirms: features stay locked\n");
        }
        if (hex_at(line, "FECS=", &fecs) && fecs != 0) {
            printf("         FECS=%08lx = FECS handshake error\n", fecs);
        }
    } else if (strstr(line, "POST_FWSEC_PRE_GSP_ENTRY") != NULL) {
        printf("      -> fallback step: last attempt before entering the GSP\n");
        printf("         driver entry point\n");
    } else if (strstr(line, "final FECS pass") != NULL) {
        printf("      -> fallback step: final FECS retry pass with the WPR\n");
        printf("         privilege gates it managed to open\n");
    } else if (strstr(line, "Cannot initialize GSP firmware RM") != NULL) {
        printf("      -> GSP runtime boot FAILED: without an accepted unlock\n");
        printf("         commit the locked card cannot bring GSP up\n");
    } else if (strstr(line, "RmInitAdapter failed") != NULL) {
        printf("      -> final failure: NVML will not list this card even\n");
        printf("         though the driver owns it on the PCI bus\n");
    } else if (strstr(line, "WPR2") != NULL &&
               strstr(line, "PL=") != NULL) {
        printf("      -> Gen2 policy state at booter window (PL bit 20 = the\n");
        printf("         PCIe slot speed fuse; set the BIOS slot to Gen2)\n");
    }
}

static void explain_dmesg(void) {
    FILE *f = NULL;
    char **lines = NULL;
    size_t kept = 0, cap = 0;
    char line[512];

    printf("== Kernel log lines about the unlock (newest last)\n");
    f = popen("dmesg 2>/dev/null", "r");
    if (f == NULL) {
        printf("  (cannot read the kernel log; try: sudo cmp50hx explain)\n");
        return;
    }
    while (fgets(line, sizeof line, f) != NULL) {
        if (strstr(line, "CMP50_COMPUTE_UNLOCK") == NULL &&
            strstr(line, "RmInitAdapter") == NULL &&
            strstr(line, "GSP firmware RM") == NULL &&
            strstr(line, "CMP50_GEN2") == NULL) {
            continue;
        }
        line[strcspn(line, "\n")] = '\0';
        if (kept == cap) {
            cap = cap == 0 ? 16 : cap * 2;
            lines = realloc(lines, cap * sizeof *lines);
        }
        lines[kept++] = strdup(line);
    }
    pclose(f);
    if (kept == 0) {
        printf("  (nothing found — kernel log restricted? try sudo; or the\n");
        printf("   unlock went cleanly, or no CMP 50HX is present)\n");
        return;
    }
    size_t from = kept > 8 ? kept - 8 : 0;
    for (size_t i = from; i < kept; ++i) {
        annotate_kernel_line(lines[i]);
        free(lines[i]);
    }
    free(lines);
}

/* --- entry point ----------------------------------------------------------- */

int explain_main(int argc, char **argv) {
    const char *what = argc >= 2 ? argv[1] : "all";
    if (strcmp(what, "efi") == 0) {
        explain_efi();
    } else if (strcmp(what, "cards") == 0) {
        explain_cards();
    } else if (strcmp(what, "dmesg") == 0) {
        explain_dmesg();
    } else if (strcmp(what, "all") == 0 || strcmp(what, "-h") == 0 ||
               strcmp(what, "--help") == 0) {
        if (strcmp(what, "all") == 0) {
            explain_efi();
            printf("\n");
            explain_cards();
            printf("\n");
            explain_dmesg();
        } else {
            printf("Usage: cmp50hx explain [efi|cards|dmesg]\n");
        }
    } else {
        fprintf(stderr, "explain: unknown section: %s "
                        "(use efi|cards|dmesg)\n", what);
        return 2;
    }
    return 0;
}
