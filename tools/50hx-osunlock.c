/* 50hx-osunlock.c — OS-side CMP 50HX (TU102) SEC2 booter unlock, pre-driver.
 *
 * Replicates the winning EFI sequence (booter_load_tu102_direct attempt A,
 * no engine reset, no DMA transfer) against /sys BAR0 MMIO. Runs BEFORE
 * nvidia.ko probes: POST-GSP mutex flapping is over by then (ticket 09).
 *
 * usage: 50hx-osunlock [--bdf 0000:04:00.0] [--wait 60] [--meta-zero]
 *          --bdf    only this device (repeatable not needed: default = all)
 *          --wait   seconds to wait for canary acceptance per card
 *          --blob   path to booter_ucode_prod.bin (default /usr/local/share/50hx/)
 *
 * Safety: no engine resets ever. Only writes: COMMAND cmd bits, SEC2 falcon
 * regs, PLM-agnostic. Already-unlocked cards are skipped.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/stat.h>

#define DEV_MATCH_VENDOR 0x10de
#define DEV_MATCH_DEVICE 0x1e09

/* BAR0 offsets (from unlock50x_v1.c; NV_PSEC_BASE=0x840000) */
#define SEC2_IRQSCLR      0x840004
#define SEC2_IRQSTAT      0x840008
#define SEC2_MAILBOX0     0x840040
#define SEC2_MAILBOX1     0x840044
#define SEC2_DEBUGINFO    0x840094
#define SEC2_CPUCTL       0x840100
#define SEC2_BOOTVEC      0x840104
#define SEC2_DMACTL       0x84010C
#define SEC2_FBIF_CTL     0x840190
#define SEC2_IMEMC0       0x840180
#define SEC2_IMEMD0       0x840184
#define SEC2_IMEMT0       0x840188
#define SEC2_DMEMC0       0x8401C0
#define SEC2_DMEMD0       0x8401C4
#define SEC2_RESET_PLM    0x8403C4

#define REG_FEAT_OVR_PLM  0x00409650
#define REG_SS0           0x00409664
#define REG_SS1           0x0040966C

#define UCODE_SIZE        0xE700
#define SIG_PATCH_OFF     0x8700   /* DMEM+0x200 */
#define STARTCPU          0x2u
#define HALTED            0x10u

static volatile uint32_t *g_bar;
static uint64_t g_meta_phys;
static uint64_t g_ucode_phys;
static inline uint32_t rd(uint32_t off) { return g_bar[off / 4]; }
static inline void wr(uint32_t off, uint32_t v) { g_bar[off / 4] = v; }

static void imem_write(uint32_t dst, int sec, const uint32_t *src,
                       uint32_t bytes, uint32_t virt)
{
    uint32_t words = bytes >> 2, tag = virt >> 8, i;
    wr(SEC2_IMEMC0, (dst & 0xFFFFFCu) | (1u << 24) | (sec ? (1u << 28) : 0u));
    for (i = 0; i < words; i++) {
        if ((i & 63u) == 0u) { wr(SEC2_IMEMT0, tag & 0xFFFFu); tag++; }
        wr(SEC2_IMEMD0, src[i]);
    }
}

static void dmem_write(uint32_t dst, const uint32_t *src, uint32_t bytes)
{
    uint32_t words = bytes >> 2, i;
    wr(SEC2_DMEMC0, (dst & 0xFFFFFCu) | (1u << 24));
    for (i = 0; i < words; i++)
        wr(SEC2_DMEMD0, src[i]);
}

/* hugepage-backed buffer + its physical address (root, lockdown none) */
static int meta_phys(void **out_virt, uint64_t *out_phys)
{
    size_t len = 2u << 20;
    void *p = mmap(NULL, len, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB, -1, 0);
    if (p == MAP_FAILED) {
        fprintf(stderr, "hugetlb mmap failed: %s (nr_hugepages?)\n",
                strerror(errno));
        return -1;
    }
    memset(p, 0, len);           /* touch + pin */
    int fd = open("/proc/self/pagemap", O_RDONLY);
    if (fd < 0) { munmap(p, len); return -1; }
    uint64_t e = 0;
    off_t off = ((uintptr_t)p / 4096u) * 8;
    if (pread(fd, &e, 8, off) != 8 || !(e >> 63)) {
        close(fd); munmap(p, len);
        fprintf(stderr, "pagemap: PFN not present/allowed\n");
        return -1;
    }
    close(fd);
    *out_virt = p;
    *out_phys = (e & ((1ULL << 55) - 1)) << 12;
    return 0;
}

static int unlock_one(const char *bdf, const uint8_t *img, int wait_s,
                      uint64_t mphys, int flr)
{
    char path[256];
    uint32_t ss0, ss1, plm, cpu, m0;
    int cf, rc = 1;
    void *bar = MAP_FAILED;
    unsigned cmd;

    snprintf(path, sizeof path,
             "/sys/bus/pci/devices/%s/config", bdf);
    cf = open(path, O_RDWR);
    if (cf < 0) { fprintf(stderr, "%s: config: %s\n", bdf, strerror(errno)); return 1; }

    /* enable memory + bus master */
    pread(cf, &cmd, 2, 0x04);
    cmd |= 0x6;
    pwrite(cf, &cmd, 2, 0x04);
    close(cf);

    snprintf(path, sizeof path,
             "/sys/bus/pci/devices/%s/resource0", bdf);
    int fd = open(path, O_RDWR | O_SYNC);
    if (fd < 0) { fprintf(stderr, "%s: resource0: %s\n", bdf, strerror(errno)); return 1; }
    bar = mmap(NULL, 16u << 20, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (bar == MAP_FAILED) { fprintf(stderr, "%s: mmap: %s\n", bdf, strerror(errno)); return 1; }
    g_bar = bar;

    ss0 = rd(REG_SS0); ss1 = rd(REG_SS1);
    printf("%s: SS0=0x%08x SS1=0x%08x PLM=0x%08x cpu=0x%x mbox0=0x%08x\n",
           bdf, ss0, ss1, rd(REG_FEAT_OVR_PLM), rd(SEC2_CPUCTL), rd(SEC2_MAILBOX0));
    if (ss0 == 0x88888888u && ss1 == 0x8u) {
        printf("%s: already unlocked, skip\n", bdf);
        munmap(bar, 16u << 20);
        return 0;
    }

    if (flr) {   /* fresh POST-like state: clears requires-reset AND
                  * re-runs VBIOS init; pre-driver so nothing else touches
                  * the card; re-mmap after reset */
        char rp[256]; int rfd;
        munmap(bar, 16u << 20); bar = MAP_FAILED;
        snprintf(rp, sizeof rp, "/sys/bus/pci/devices/%s/reset", bdf);
        rfd = open(rp, O_WRONLY);
        if (rfd >= 0) { if (write(rfd, "1\n", 2) < 0) {} close(rfd);
                        printf("%s: FLR issued\n", bdf); }
        else fprintf(stderr, "%s: reset open: %s\n", bdf, strerror(errno));
        fd = open(path, O_RDWR | O_SYNC);
        if (fd < 0 || (bar = mmap(NULL, 16u << 20, PROT_READ | PROT_WRITE,
                                  MAP_SHARED, fd, 0)) == MAP_FAILED) {
            fprintf(stderr, "%s: re-mmap after FLR failed\n", bdf); return 1; }
        close(fd); g_bar = bar;
        {   /* wait for VBIOS re-POST to raise WPR2 (FWSEC/crypto chain) */
            int w;
            for (w = 0; w < 90; w++) {
                sleep(1);
                if (rd(0x001FA828) != 0u) break;
            }
            printf("%s: WPR2 after FLR: 0x%08x:0x%08x (waited %ds)\n",
                   bdf, rd(0x001FA828), rd(0x001FA824), w);
        }
    }

    /* upstream preamble (proven identical in EFI winners):
     * kill POST GFW on GSP engine, RISC-V->Falcon BCR fallback if locked
     * aperture, open SEC2 RESET_PRIV_LEVEL gate, wait for cpuctl=halted. */
    {
        int i;
        uint32_t v;
        wr(0x1103C0, 1u);                       /* GSP_ENGINE reset assert */
        for (i = 0; i < 16; i++) rd(0x1103C0);
        wr(0x1103C0, 0u);
        for (i = 0; i < 16; i++) rd(0x1103C0);
        usleep(200000);
        if ((rd(SEC2_CPUCTL) & 0xBADF0000u) == 0xBADF0000u ||
            (rd(SEC2_FBIF_CTL) & 0xBADF0000u) == 0xBADF0000u) {
            wr(0x841668, 0u);                   /* BCR CORE_SELECT=FALCON */
            for (i = 0; i < 16; i++) rd(0x841668);
            usleep(10000);
            printf("%s: BCR forced FALCON, cpuctl=0x%x\n", bdf, rd(SEC2_CPUCTL));
        }
        wr(SEC2_RESET_PLM, 0xFFu);              /* open reset-priv gate */
        for (i = 0; i < 50; i++) {              /* wait halted=0x10 */
            v = rd(SEC2_CPUCTL);
            if (v == 0x10u) break;
            usleep(100000);
        }
        printf("%s: after GFW-kill: cpuctl=0x%x (exp 0x10) plm_gate=0x%x\n",
               bdf, rd(SEC2_CPUCTL), rd(SEC2_RESET_PLM));
        printf("%s: WPR2=0x%08x:0x%08x (exp up: 027fee00:027fe000)\n", bdf,
               rd(0x001FA828), rd(0x001FA824));
    }

    /* canary gate: wait for SEC2 aperture */
    int t, accepted = 0;
    for (t = 0; t < wait_s * 10 && !accepted; t++) {
        wr(SEC2_MAILBOX0, 0xA5A5C3C3u);
        if (rd(SEC2_MAILBOX0) == 0xA5A5C3C3u) accepted = 1;
        else { struct timespec ts = {0, 100*1000*1000}; nanosleep(&ts, NULL); }
    }
    printf("%s: canary %s after %d.%ds\n", bdf,
           accepted ? "ACCEPTED" : "REFUSED", t / 10, t % 10);
    if (!accepted) goto out;

    /* GPU time must be plausible for cert validation (EFI: set_gpu_time) */
    {
        struct timespec rt;
        uint64_t ns;
        clock_gettime(CLOCK_REALTIME, &rt);
        ns = (uint64_t)rt.tv_sec * 1000000000ULL + (uint64_t)rt.tv_nsec;
        wr(0x00009410, (uint32_t)(ns >> 32));
        wr(0x00009400, (uint32_t)(ns & 0xFFFFFFFFu));
        printf("%s: GPU time set (ns hi=0x%08x)\n", bdf, (uint32_t)(ns >> 32));
    }

    /* the exact attempt-A sequence */
    wr(SEC2_FBIF_CTL, rd(SEC2_FBIF_CTL) | (1u << 7));
    wr(SEC2_DMACTL, 0);
    imem_write(0x000u, 0, (const uint32_t *)img,               0x100u,  0x0u);
    imem_write(0x100u, 1, (const uint32_t *)(img + 0x100u),    0x8400u, 0x100u);
    dmem_write(0x0u,     (const uint32_t *)(img + 0x8500u),    0x6200u);

    wr(SEC2_IMEMC0, 0x0u);
    uint32_t rbNs = rd(SEC2_IMEMD0);
    printf("%s: rb IMEM[0]=0x%08x exp 0x%08x\n", bdf, rbNs, *(uint32_t *)img);

    cpu = rd(SEC2_CPUCTL);
    if (!(cpu & HALTED)) printf("%s: WARN cpuctl=0x%x (not halted)\n", bdf, cpu);

    wr(SEC2_BOOTVEC, 0x0u);
    wr(SEC2_MAILBOX0, (uint32_t)(mphys & 0xFFFFFFFFu));
    wr(SEC2_MAILBOX1, (uint32_t)(mphys >> 32));
    wr(SEC2_CPUCTL, STARTCPU);
    printf("%s: started, holding 3 s...\n", bdf);
    sleep(3);
    m0  = rd(SEC2_MAILBOX0);
    ss0 = rd(REG_SS0); ss1 = rd(REG_SS1); plm = rd(REG_FEAT_OVR_PLM);
    printf("%s: m0=0x%x SS0=0x%08x SS1=0x%08x PLM=0x%08x\n", bdf, m0, ss0, ss1, plm);
    if (ss0 == 0x88888888u && ss1 == 0x8u) {
        printf("%s: *** UNLOCKED (OS-side) ***\n", bdf);
        rc = 0;
    }
out:
    munmap(bar, 16u << 20);
    return rc;
}

int main(int argc, char **argv)
{
    const char *bdf_only = NULL, *blob = "/usr/local/share/50hx/booter_ucode_prod.bin";
    int wait_s = 60, i, rc = 0, do_flr = 0;
    static const uint8_t sig[16] = {
        0x32,0x60,0x43,0x67, 0x98,0x89,0x7b,0x06,
        0xe8,0x5f,0x1a,0xa8, 0x71,0x43,0x5d,0xcb
    };
    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--bdf") && i + 1 < argc) bdf_only = argv[++i];
        else if (!strcmp(argv[i], "--wait") && i + 1 < argc) wait_s = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--blob") && i + 1 < argc) blob = argv[++i];
        else if (!strcmp(argv[i], "--flr")) do_flr = 1;
    }
    if (geteuid()) { fprintf(stderr, "root required\n"); return 2; }

    uint8_t *img = malloc(UCODE_SIZE);
    FILE *f = fopen(blob, "rb");
    if (!f || fread(img, 1, UCODE_SIZE, f) != UCODE_SIZE) {
        fprintf(stderr, "blob %s: short/missing\n", blob);
        return 2;
    }
    fclose(f);
    memcpy(img + SIG_PATCH_OFF, sig, 16);

    void *mvirt; uint64_t mphys;
    uint64_t pBl, pSig, pElf; void *vBl, *vSig, *vElf;
    for (int rtry = 0; rtry < 60; rtry++) {
        if (meta_phys(&mvirt, &mphys)) return 2;
        if (meta_phys(&vBl, &pBl) || meta_phys(&vSig, &pSig) ||
            meta_phys(&vElf, &pElf)) return 2;
        printf("phys[try %d]: meta=0x%llx bl=0x%llx sig=0x%llx elf=0x%llx\n",
               rtry, (unsigned long long)mphys, (unsigned long long)pBl,
               (unsigned long long)pSig, (unsigned long long)pElf);
        if (mphys >= 0x100000000ULL && pBl >= 0x100000000ULL &&
            pSig >= 0x100000000ULL && pElf >= 0x100000000ULL)
            break;
    }
    {   /* load real blobs into their own 2 MB pinned pages */
        size_t got;
        FILE *fb2 = fopen("/usr/local/share/50hx/gsp_rm_boot_dbg.bin", "rb");
        got = fb2 ? fread(vBl, 1, 0x6000, fb2) : 0; if (fb2) fclose(fb2);
        printf("bl blob: %zu bytes\n", got);
        FILE *fs2 = fopen("/usr/local/share/50hx/v67_payload.bin", "rb");
        got = fs2 ? fread(vSig, 1, 0xFA00, fs2) : 0; if (fs2) fclose(fs2);
        printf("sig blob: %zu bytes\n", got);
    }
    {   /* GspFwWprMeta, formulas ported from EFI build_wpr_meta (v62/v73) */
        uint64_t M[256];  /* 2KB at page start; sizeof<=2KB */
        uint64_t fbSize = 0x280000000ULL, MBv = 0x100000ULL;
        uint64_t elfSize = 0x1BFADC8ULL, blSize = 0x6000ULL;
        uint64_t vga, wprEnd, frtsOff, bootBin, gspFwOff, heapSize, heapOff, wprStart, nonWpr;
        memset(M, 0, sizeof M);
        vga      = fbSize - MBv;
        wprEnd   = vga & ~0x1FFFFULL;
        frtsOff  = wprEnd - MBv;
        bootBin  = (frtsOff - blSize) & ~0xFFFULL;
        gspFwOff = (bootBin - elfSize) & ~0xFFFFULL;
        heapSize = 0x7F00000ULL;   /* 10 GiB card */
        heapOff  = (gspFwOff - heapSize) & ~(MBv - 1);
        wprStart = heapOff - MBv;
        nonWpr   = wprStart - MBv;
        M[0] = 0xdc3aae21371a60b3ULL;  /* magic  */
        M[1] = 1;                      /* revision */
        M[2] = pElf;   M[3] = elfSize;
        M[4] = pBl;    M[5] = blSize;
        M[6] = 0x1800; M[7] = 0x800; M[8] = 0x0;      /* BL offsets */
        M[9] = pSig;   M[10] = 0xFA00;                /* sig */
        M[11] = nonWpr;                               /* gspFwRsvdStart */
        M[12] = nonWpr;  M[13] = MBv;                 /* nonWprHeap */
        M[14] = wprStart;
        M[15] = heapOff; M[16] = heapSize;
        M[17] = gspFwOff; M[18] = bootBin;
        M[19] = frtsOff;  M[20] = MBv;
        M[21] = wprEnd;   M[22] = fbSize;
        M[23] = vga;      M[24] = MBv;
        /* bootCount=0 ... */
        ((uint8_t *)M)[241] = 0x1;  /* flags = CLOCK_BOOST */
        memcpy(mvirt, M, sizeof M);
        g_meta_phys = mphys;
        printf("meta built: wprEnd=0x%llx gspFwOff=0x%llx heap=0x%llx+0x%llx\n",
               (unsigned long long)wprEnd, (unsigned long long)gspFwOff,
               (unsigned long long)heapOff, (unsigned long long)heapSize);
    }
    (void)vBl; (void)vSig; (void)vElf;

    for (i = 1; i < argc; i++) {}
    /* enumerate 10de:1e09 */
    FILE *lp = popen("grep -l . /sys/bus/pci/devices/*/device "
                     "2>/dev/null | xargs -I{} sh -c "
                     "'d=${1%/device}; v=$(cat ${d}/vendor); dd=$(cat $d/device); "
                     "[ \"$v\" = 0x10de ] && [ \"$dd\" = 0x1e09 ] && basename $d' _ {}",
                     "r");
    char line[64];
    int found = 0;
    while (lp && fgets(line, sizeof line, lp)) {
        line[strcspn(line, "\n")] = 0;
        if (bdf_only && strcmp(line, bdf_only)) continue;
        found = 1;
        if (unlock_one(line, img, wait_s, mphys, do_flr)) rc = 1;
    }
    if (lp) pclose(lp);
    if (!found) printf("no 10de:1e09 devices matched\n");
    return rc;
}
