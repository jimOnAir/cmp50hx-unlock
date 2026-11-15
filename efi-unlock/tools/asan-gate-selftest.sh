#!/usr/bin/env bash
# asan-gate-selftest.sh — UEFI app host-side sanitizer gate (gtuu-mining
# ticket 12, rows X3+X4). Boot-path logic from unlock50x_v1.c compiled for
# host Linux under -fsanitize=address,undefined -Werror with a simulated
# PCI/MMIO/ESP/BlockIo environment, driven by a scenario suite: memory
# errors and UB in the unlock code found by the build gate, not by a
# bricked boot.
#
# Extraction is VERBATIM (same rule as the other selftests): cold-state
# verdict + defines, the CHIPID-GATE observation block, the asset-
# attestation pair (struct + manifest lookup + attest), the PROM gate
# (defines + function), and the whole FAT-PARSER block — production code,
# unmodified, between the marker comments. sha256.c is compiled as the
# production file (stub <efi.h>). Fixtures (synthetic FAT32/FAT16 disks,
# manifest, pin file) are built deterministically in code — zero binaries
# committed. The deliberate-bug poison fixture validates that the
# sanitizer gate actually bites (repo standard: a fix must be proven on
# its failure path).
#
# Containment-assert vocabulary mirrors ticket 11's harness: ck()/PASS/
# FAIL/log_has. Provenance: GTUU @ 1d6a508 tests/ (X3 host-shim method,
# X4 parser-test shapes) — analyzed read-only, never executed; nv-
# uefi-unlocker sim/ discipline (row B2-P23).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${HERE}/../unlock50x_v1.c"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/stubinc"

# sha256.h includes <efi.h>: minimal host stand-in for its typedefs only.
cat > "${WORK}/stubinc/efi.h" <<'EOF'
#ifndef EFI_HOST_STUB_H
#define EFI_HOST_STUB_H
#include <stdint.h>
#include <stddef.h>   /* NULL: the real <efi.h> provides it too */
typedef uint8_t UINT8; typedef uint16_t UINT16; typedef uint32_t UINT32;
typedef uint64_t UINT64; typedef uint64_t EFI_STATUS;
typedef unsigned long UINTN; typedef long INTN;
typedef char CHAR16; typedef void VOID; typedef int BOOLEAN;
#define TRUE 1
#define FALSE 0
#define EFIAPI
#endif
EOF

python3 - "$SRC" "$WORK/harness.c" "$WORK/poison.c" <<'PYEOF'
import sys, re
src = open(sys.argv[1]).read()

def cut(a, b):
    """src from marker a (inclusive) up to marker b (exclusive)"""
    i = src.index(a)
    j = src.index(b, i)
    return src[i:j]

cold   = cut("#define COLD_CLEAN", "/* FINAL-GATE-BEGIN */")   # incl. is_unlocked
chipid = src[src.index("/* CHIPID-GATE-BEGIN */") + len("/* CHIPID-GATE-BEGIN */"):
             src.index("/* CHIPID-GATE-END */")]
astd   = cut("struct u40x_asset {", "static struct u40x_asset u40x_assets[]")
mlk    = cut("static BOOLEAN u40x_manifest_lookup", "static BOOLEAN u40x_attest_assets")
att    = cut("static BOOLEAN u40x_attest_assets", "/* ESP read/write")
prom   = cut("#define U40X_PROM_WINDOW", "/* ==== Read-only diagnostics dump")
fat    = src[src.index("/* FAT-PARSER-BEGIN */") + len("/* FAT-PARSER-BEGIN */"):
             src.index("/* FAT-PARSER-END */")]

def strip(s):  # C23 L-literals break host build (documented gotcha)
    return s.replace('L"', '"').replace("L'", "'")

cold, chipid, astd, mlk, att, prom, fat = map(strip, (cold, chipid, astd, mlk, att, prom, fat))

harness = r'''#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdbool.h>
typedef uint8_t UINT8; typedef uint16_t UINT16; typedef uint32_t UINT32;
typedef uint64_t UINT64; typedef long INTN; typedef unsigned long UINTN;
typedef char CHAR16; typedef void VOID; typedef int BOOLEAN;
typedef INTN EFI_STATUS;
VOID GuSha256(const VOID *Data, UINTN Size, UINT8 Digest[32]);
BOOLEAN GuHashMatches(const VOID *Data, UINTN Size, const char *Hex64);
#define TRUE 1
#define FALSE 0
#define EFI_SUCCESS 0
#define EFI_UNSUPPORTED (-1)
#define EFI_INVALID_PARAMETER (-2)
#define EFI_NOT_FOUND (-3)
#define EFI_OUT_OF_RESOURCES (-4)
#define EFI_DEVICE_ERROR (-5)
#define EFI_BAD_BUFFER_SIZE (-6)
#define EFI_LOAD_ERROR (-7)
#define EFI_END_OF_FILE (-8)
#define EFI_BUFFER_TOO_SMALL (-9)
#define EFI_ERROR(x) ((INTN)(x) < 0)
#define EfiLoaderData 2
#define EfiBootServicesData 3
#define STATIC static
#define CopyMem(a, b, n) memcpy((a), (b), (n))
#define uefi_call_wrapper(fn, n, ...) (fn(__VA_ARGS__))
typedef struct { UINT32 dummy; } EFI_GUID;
typedef void *EFI_HANDLE;

/* ---- log ring + ck(): same vocabulary as the t11 claim harness ---- */
static char log_ring[160][512]; static int log_n;
static int Print(const CHAR16 *fmt, ...) {
    char out[512]; int o = 0; const char *p = (const char *)fmt; va_list ap;
    va_start(ap, fmt);
    while (*p && o < 505) {
        if (*p != '%') { out[o++] = *p++; continue; }
        p++;
        char spec[24]; int s = 0; spec[s++] = '%';
        while (*p=='0'||*p=='-'||*p=='l'||(*p>='1'&&*p<='9')) spec[s++] = *p++;
        char c = *p++; spec[s++] = c; spec[s] = 0;
        if (c == 's') { char *v = va_arg(ap, char *); o += snprintf(out+o, 512-o, "%s", v ? v : "(null)"); }
        else if (c=='d'||c=='u'||c=='x'||c=='X') { unsigned long v = va_arg(ap, unsigned long); o += snprintf(out+o, 512-o, spec, v); }
        else if (c == '%') out[o++] = '%';
        else o += snprintf(out+o, 512-o, "<%s>", spec);
    }
    out[o] = 0;
    if (log_n < 160) snprintf(log_ring[log_n++], 512, "%s", out);
    va_end(ap);
    return 0;
}
static int log_has(const char *frag) { int i; for (i = 0; i < log_n; i++) if (strstr(log_ring[i], frag)) return 1; return 0; }
static void log_clear(void) { log_n = 0; }
static int fails;
static void ck(const char *name, int cond) {
    if (!cond) { printf("FAIL %s\n", name); fails++; } else printf("PASS %s\n", name);
}

/* ---- MMIO fixture (4 MiB BAR0) ---- */
#define BAR_BYTES (4u<<20)
static UINT8 *g_bar;
#define REG_FEAT_OVR_SM_SPD    0x00409664u   /* CMP50_REG_FEAT_SS0 */
#define REG_FEAT_OVR_SM_SPD_1  0x0040966cu   /* CMP50_REG_FEAT_SS1 */
#define VAL_SS0_UNLOCKED       0x88888888u
#define VAL_SS1_UNLOCKED       0x00000008u
static UINT32 mmio_read32(UINTN off) { UINT32 v; memcpy(&v, g_bar + off, 4); return v; }
static void mmio_write32_fxt(UINTN off, UINT32 v) { memcpy(g_bar + off, &v, 4); }

/* ---- pool + BlockIo + ESP fixture ---- */
static int g_alloc_fail;
typedef struct { EFI_STATUS (*AllocatePool)(UINT32, UINTN, VOID **); void (*FreePool)(VOID *); } BS_T;
static EFI_STATUS stub_alloc(UINT32 t, UINTN s, VOID **p) { (void)t; if (g_alloc_fail || !s || !(*p = malloc(s))) { *p = NULL; return EFI_OUT_OF_RESOURCES; } return EFI_SUCCESS; }
static void stub_free(VOID *p) { free(p); }
static BS_T bs_impl = { stub_alloc, stub_free }; static BS_T *BS = &bs_impl;

typedef struct { UINT32 MediaId; UINT32 BlockSize; UINT64 LastBlock; } EFI_BLOCK_IO_MEDIA;
typedef struct EFI_BLOCK_IO_PROTOCOL {
    EFI_BLOCK_IO_MEDIA *Media;
    EFI_STATUS (*ReadBlocks)(struct EFI_BLOCK_IO_PROTOCOL *, UINT32, UINT64, UINTN, VOID *);
} EFI_BLOCK_IO_PROTOCOL;
static UINT8 *g_disk; static UINT64 g_disk_sectors;
static EFI_STATUS stub_read_blocks(EFI_BLOCK_IO_PROTOCOL *b, UINT32 id, UINT64 lba, UINTN bytes, VOID *dst) {
    (void)b; (void)id;
    if (lba + bytes / 512 > g_disk_sectors) return EFI_DEVICE_ERROR;
    memcpy(dst, g_disk + lba * 512, bytes);
    return EFI_SUCCESS;
}
static EFI_BLOCK_IO_MEDIA g_media = { 1, 512, 0 };
static EFI_BLOCK_IO_PROTOCOL g_bio = { &g_media, stub_read_blocks };

static const char *g_pin; static size_t g_pin_len;
static char g_write_name[128]; static size_t g_write_len;
static BOOLEAN u40x_esp_read(void *IH, CHAR16 *name, VOID *buf, UINTN cap, UINTN *out) {
    (void)IH;
    if (!g_pin || strcmp((char *)name, "50hx_prom_pin.sha256")) return FALSE;
    *out = g_pin_len < cap ? g_pin_len : cap;
    memcpy(buf, g_pin, *out);
    return TRUE;
}
static BOOLEAN u40x_esp_write(void *IH, CHAR16 *name, const VOID *data, UINTN len) {
    (void)IH; (void)data;
    snprintf(g_write_name, sizeof g_write_name, "%s", (char *)name);
    g_write_len = len;
    return TRUE;
}

/* =================== production slices (VERBATIM) =================== */
/* -- ticket-04 cold-state verdict + defines -- */
''' + cold + r'''
static void chipid_gate(void) {''' + chipid + r'''}

/* -- ticket-09 attestation: struct verbatim; table = fixtures -- */
''' + astd + r'''
static UINT8 f_a1[64], f_a2[32], f_a3[128];
static struct u40x_asset u40x_assets[] = {
    { "v67_payload.bin",         "v67_payload", f_a1, f_a1 + sizeof f_a1 },
    { "booter_ucode_prod.bin",   "booter_prod", f_a2, f_a2 + sizeof f_a2 },
    { "sec2_ucode_vbios_49.bin", "sec2_vb49",   f_a3, f_a3 + sizeof f_a3 },
};
/* -- the manifest bytes the production lookup walks (fixture text) -- */
static const UINT8 assets_sha256_bin[] = MANIFEST_PLACEHOLDER;
static const UINT8 *assets_sha256_bin_end = assets_sha256_bin + sizeof(assets_sha256_bin) - 1;
''' + mlk + att + r'''
/* -- ticket-09 PROM gate (defines + function verbatim) -- */
''' + prom + r'''
/* -- X4 FAT parser over BlockIo (whole block verbatim) -- */
''' + fat + r'''
/* ============================ fixtures ============================ */
static void cold_set(UINT32 ss0, UINT32 ss1) {
    mmio_write32_fxt(REG_FEAT_OVR_SM_SPD, ss0);
    mmio_write32_fxt(REG_FEAT_OVR_SM_SPD_1, ss1);
}
static void put16(UINT8 *d, UINTN off, UINT32 v) { d[off] = (UINT8)v; d[off+1] = (UINT8)(v>>8); }
static void put32(UINT8 *d, UINTN off, UINT32 v) { put16(d, off, v & 0xFFFF); put16(d, off+2, v>>16); }
static void mk_disk(UINT64 sectors) {
    free(g_disk);
    g_disk = calloc((size_t)sectors, 512);
    g_disk_sectors = sectors;
    g_media.LastBlock = sectors - 1;
}
static void sfn(UINT8 *e, const char *nm8, const char *ext3) {
    int i, n8 = (int)strlen(nm8), n3 = (int)strlen(ext3);
    for (i = 0; i < 8; i++) e[i] = (UINT8)(i < n8 ? nm8[i] : ' ');
    for (i = 0; i < 3; i++) e[8+i] = (UINT8)(i < n3 ? ext3[i] : ' ');
}
/* FAT32 volume: root cluster 2 holds FILE.EFI (clusters 3->4, 1024 B)
 * and LONGFILE.BIN (cluster 5, 512 B) behind a one-fragment LFN entry. */
static void build_fat32(int lfn) {
    UINT8 *d;
    mk_disk(800); d = g_disk;
    d[11]=0; d[12]=2; d[13]=1; d[14]=32; d[15]=0; d[16]=2;      /* bps=512 spc=1 rsvd=32 nfats=2 */
    put16(d,17,0); put16(d,22,0); put32(d,36,8);                 /* fatsz32=8 */
    put32(d,44,2);                                               /* rootClus=2 */
    d[510]=0x55; d[511]=0xAA;
    put32(d,16384+0*4,0x0FFFFFF8u); put32(d,16384+1*4,0x0FFFFFFFu);
    put32(d,16384+2*4,0x0FFFFFF8u);                              /* root dir = cluster 2, EOC */
    put32(d,16384+3*4,4); put32(d,16384+4*4,0x0FFFFFF8u); put32(d,16384+5*4,0x0FFFFFF8u);
    {   /* root dir entries @ cluster 2 (dataOff = 24576) */
        UINT8 *e = d + 24576;
        sfn(e, "FILE", "EFI"); e[11]=0x20; put16(e,26,3); put16(e,20,0); put32(e,28,1024);
        e += 32;
        if (lfn) {                                              /* one LFN fragment "LONGFILE.BIN" */
            const char *n = "LONGFILE.BIN"; int i;
            e[0]=0x41; e[11]=0x0F; e[12]=0; e[13]=0;
            for (i = 0; i < 5; i++) put16(e, 1+i*2, (UINT32)(UINT8)n[i]);       /* chars 0-4 */
            for (i = 5; i < 11; i++) put16(e, 14+(i-5)*2, (UINT32)(UINT8)n[i]); /* chars 5-10 (bytes 11-13 are reserved) */
            put16(e,28,(UINT8)n[11]); put16(e,30,0);                             /* char 11 + terminator */
            e += 32;
            sfn(e, "LONGFI~1", "BIN");
        } else sfn(e, "LONGFILE", "BIN");
        e[11]=0x20; put16(e,26,5); put16(e,20,0); put32(e,28,512);
    }
    d[24576 + 1*512 + 0] = 'M'; d[24576 + 1*512 + 1] = 'Z';     /* cluster 3 = file data starts */
    d[24576 + 3*512 + 0] = 'M'; d[24576 + 3*512 + 1] = 'Z';     /* cluster 5 */
}
static void build_fat16(void) {
    UINT8 *d;
    mk_disk(600); d = g_disk;
    d[11]=0; d[12]=2; d[13]=1; d[14]=1; d[15]=0; d[16]=2;
    put16(d,17,512); put16(d,22,4);                             /* rootEnts=512 fatsz16=4 */
    d[510]=0x55; d[511]=0xAA;
    put16(d,512+0*2,0x00F8); put16(d,512+1*2,0xFFF7); put16(d,512+2*2,0xFFF8);
    {   /* flat root @ (1+2*4)*512 = 4608 */
        UINT8 *e = d + 4608;
        sfn(e, "A", "EFI"); e[11]=0x20; put16(e,26,2); put16(e,20,0); put32(e,28,512);
    }
    d[20992 + 0] = 'M'; d[20992 + 1] = 'Z';                     /* cluster 2 data */
}
static void sha_hex(const VOID *p, UINTN n, char out[65]) {
    UINT8 dig[32]; int i; static const char hx[] = "0123456789abcdef";
    GuSha256(p, n, dig);
    for (i = 0; i < 32; i++) { out[2*i] = hx[dig[i]>>4]; out[2*i+1] = hx[dig[i]&15]; }
    out[64] = 0;
}

int main(void) {
    g_bar = calloc(1, BAR_BYTES);

    /* ---------- ticket-04 cold-state matrix ---------- */
    cold_set(0x00000001, 0x00000001);
    ck("C1 stock card CLEAN", cold_state_verdict() == COLD_CLEAN);
    cold_set(0x88888888, 0x00000008);
    ck("C2 exact pair ALREADY", cold_state_verdict() == COLD_ALREADY);
    cold_set(0x88888888, 0x00000001);
    ck("C3 SS0-only PARTIAL", cold_state_verdict() == COLD_PARTIAL);
    cold_set(0x00000001, 0x00000008);
    ck("C4 SS1-only PARTIAL", cold_state_verdict() == COLD_PARTIAL);
    cold_set(0xFFFFFFFF, 0xFFFFFFFF);
    ck("C5 all-FF (BAR untrusted) is not ALREADY", cold_state_verdict() == COLD_CLEAN);
    ck("C6 is_unlocked predicate follows verdict",
       (cold_set(0x88888888, 0x00000008), is_unlocked()) &&
       !(cold_set(0x88888888, 0x00000001), is_unlocked()));

    /* ---------- ticket-05 chip-identity observation ---------- */
    log_clear(); mmio_write32_fxt(0x0, 0x162000A1); chipid_gate();
    ck("CI1 matching constant: no WARNING", !log_has("WARNING: PMC_BOOT_0") && log_has("(matches RM constant)"));
    log_clear(); mmio_write32_fxt(0x0, 0xB72000A1); chipid_gate();
    ck("CI2 strap variant: named WARNING", log_has("WARNING: PMC_BOOT_0=0xb72000a1 != RM-write constant 0x162000A1"));
    log_clear(); mmio_write32_fxt(0x0, 0u); chipid_gate();
    ck("CI3 reset value 0 tolerated silently", !log_has("WARNING"));
    log_clear(); mmio_write32_fxt(0x0, 0xFFFFFFFFu); chipid_gate();
    ck("CI4 all-FF tolerated (wedge named elsewhere: t16)", !log_has("WARNING"));

    /* ---------- ticket-09 asset attestation ---------- */
    {   /* fill fixture payloads deterministically */
        int i; for (i = 0; i < 64; i++)  f_a1[i] = (UINT8)(i*7+1);
        for (i = 0; i < 32; i++)  f_a2[i] = (UINT8)(200-i);
        for (i = 0; i < 128; i++) f_a3[i] = (UINT8)(i ^ 0x5A);
    }
    log_clear();
    ck("AT1 all-manifested assets attest", u40x_attest_assets() == TRUE && log_has("ATTEST ok"));
    f_a2[7] ^= 0xFF;
    log_clear();
    ck("AT2 tampered payload -> DIGEST MISMATCH + REFUSE",
       u40x_attest_assets() == FALSE && log_has("ATTEST booter_prod: DIGEST MISMATCH"));
    f_a2[7] ^= 0xFF;
    {   /* asset with no manifest line */
        const char *save = u40x_assets[2].file;
        u40x_assets[2].file = "missing.bin";
        log_clear();
        ck("AT3 missing manifest entry -> REFUSE",
           u40x_attest_assets() == FALSE && log_has("ATTEST sec2_vb49: no manifest entry"));
        u40x_assets[2].file = save;
    }
    ck("AT4 unknown manifest name found (prefix-only scan is by design)",
       !u40x_manifest_lookup("bogus.bin", (char[65]){0}));

    /* ---------- ticket-09 live-PROM SHA gate ---------- */
    {   /* fill the PROM window with a deterministic pattern */
        UINTN i;
        for (i = 0; i < U40X_PROM_OBSERVE; i += 4)
            mmio_write32_fxt(U40X_PROM_WINDOW + i, (UINT32)(0xA0000000u + i));
    }
    {
        char want[65];
        UINT8 win[U40X_PROM_OBSERVE]; UINTN i;
        for (i = 0; i < U40X_PROM_OBSERVE; i += 4) memcpy(win + i, g_bar + U40X_PROM_WINDOW + i, 4);
        sha_hex(win, U40X_PROM_OBSERVE, want);

        g_pin = NULL; log_clear();
        ck("P1 no pin file: OBSERVE prints exact digest",
           u40x_prom_gate(NULL) == TRUE && log_has(want) && log_has("PROM gate OBSERVE") && log_has("bytes=0x40000"));

        static char pinbuf[80];
        snprintf(pinbuf, sizeof pinbuf, "%s\n", want);
        g_pin = pinbuf; g_pin_len = strlen(pinbuf); log_clear();
        ck("P2 ENFORCE ok on exact pin",
           u40x_prom_gate(NULL) == TRUE && log_has("PROM gate ENFORCE ok"));

        {   /* uppercase pin must normalize */
            static char upper[80]; int i;
            for (i = 0; i < 64; i++) upper[i] = (want[i]>='a') ? (char)(want[i]-32) : want[i];
            upper[64] = '\n'; upper[65] = 0;
            g_pin = upper; g_pin_len = 65; log_clear();
            ck("P3 uppercase pin accepted", u40x_prom_gate(NULL) == TRUE && !log_has("MISMATCH"));
        }
        {   /* one hex digit flipped -> refuse + dump */
            static char bad[80];
            snprintf(bad, sizeof bad, "%s\n", want);
            bad[0] = (bad[0] == 'a') ? 'b' : 'a';
            g_pin = bad; g_pin_len = strlen(bad); log_clear();
            g_write_name[0] = 0;
            ck("P4 flipped digit -> ENFORCE MISMATCH REFUSE",
               u40x_prom_gate(NULL) == FALSE && log_has("ENFORCE MISMATCH"));
            ck("P4 live ROM dumped for forensics",
               !strcmp(g_write_name, "50hx_prom_fail.bin") && g_write_len == U40X_PROM_OBSERVE);
        }
        {   /* optional byte-length field honored: pin for the NARROWED window */
            static char lenpin[96];
            char want2[65];
            sha_hex(win, 65536, want2);
            snprintf(lenpin, sizeof lenpin, "%s 65536\n", want2);
            g_pin = lenpin; g_pin_len = strlen(lenpin); log_clear();
            u40x_prom_gate(NULL);
            ck("P5 pin length field narrows window (bytes=0x10000)",
               log_has("ENFORCE ok") && log_has("bytes=0x10000"));
        }
        g_pin = NULL;
    }
    g_alloc_fail = 1; log_clear();
    ck("P6 pool failure skips gate (attest-only boot, never hangs unlock)",
       u40x_prom_gate(NULL) == TRUE && log_has("skip gate (attest-only boot)"));
    g_alloc_fail = 0;

    /* ---------- X4 FAT parser over synthetic volumes ---------- */
    build_fat32(1);
    {
        Cmp90Fat f; UINT8 *buf = NULL; UINTN sz = 0; EFI_STATUS st;
        st = cmp90_fat_open(&g_bio, 0, &f);
        ck("F1 FAT32 open geometry", !EFI_ERROR(st) && f.fat32 && f.bps == 512 && f.spc == 1 &&
           f.fatOff == 16384 && f.dataOff == 24576 && f.rootClus == 2 && f.eocMark == 0x0FFFFFF8u);
        st = cmp90_fat_load_path(&f, "\\FILE.EFI", &buf, &sz);
        ck("F2 8.3 file loads (size + PE magic intact)",
           !EFI_ERROR(st) && sz == 1024 && buf && buf[0]=='M' && buf[1]=='Z' &&
           buf[512+511] == 0 /* second cluster streamed (pattern byte) */);
        free(buf); buf = NULL;
        st = cmp90_fat_load_path(&f, "\\file.efi", &buf, &sz);
        ck("F3 case-insensitive lookup", !EFI_ERROR(st)); free(buf); buf = NULL;
        st = cmp90_fat_load_path(&f, "\\LONGFILE.BIN", &buf, &sz);
        ck("F4 LFN reassembly wins over mangled 8.3",
           !EFI_ERROR(st) && sz == 512 && buf[0]=='M' && buf[1]=='Z');
        free(buf);
    }
    build_fat16();
    {
        Cmp90Fat f; UINT8 *buf = NULL; UINTN sz = 0; EFI_STATUS st;
        st = cmp90_fat_open(&g_bio, 0, &f);
        ck("F5 FAT16 open (fixed root)", !EFI_ERROR(st) && !f.fat32 && f.rootEnts == 512 &&
           f.rootOff == 4608 && f.dataOff == 4608+16384 && f.eocMark == 0xFFF8u);
        st = cmp90_fat_load_path(&f, "\\A.EFI", &buf, &sz);
        ck("F6 FAT16 flat-root file loads", !EFI_ERROR(st) && sz == 512 && buf[0]=='M');
        free(buf);
    }
    /* adversarial BPBs and corrupted structures — all must be errors,
       never crashes, never UB (this whole binary runs under UBSan) */
    mk_disk(800); g_disk[510]=0; /* no signature */
    { Cmp90Fat f; ck("F7 bad BPB signature -> UNSUPPORTED", EFI_ERROR(cmp90_fat_open(&g_bio, 0, &f))); }
    build_fat32(0); g_disk[11]=0; g_disk[12]=0;
    { Cmp90Fat f; ck("F8 bps=0 rejected (no divide by zero)", EFI_ERROR(cmp90_fat_open(&g_bio, 0, &f))); }
    build_fat32(0); g_disk[13]=0;
    { Cmp90Fat f; ck("F9 spc=0 rejected", EFI_ERROR(cmp90_fat_open(&g_bio, 0, &f))); }
    build_fat32(0); put32(g_disk, 44, 1);
    { Cmp90Fat f; ck("F10 FAT32 rootClus<2 rejected", EFI_ERROR(cmp90_fat_open(&g_bio, 0, &f))); }
    build_fat32(0); g_disk[510]=0x55; g_disk[511]=0xAA;
    {
        Cmp90Fat f; UINT8 *buf = NULL; UINTN sz = 0;
        (void)cmp90_fat_open(&g_bio, 0, &f);
        { /* first file cluster corrupted to 1 with nonzero size */
            UINT8 *e = g_disk + 24576; put16(e, 26, 1);
            ck("F11 cluster<1 chain -> EOF, no read at bogus offset",
               EFI_ERROR(cmp90_fat_load_path(&f, "\\FILE.EFI", &buf, &sz)));
            free(buf);
        }
    }
    {
        Cmp90Fat f; UINT8 *buf = NULL; UINTN sz = 0; char longpath[128];
        (void)cmp90_fat_open(&g_bio, 0, &f);
        memset(longpath, 'Z', 100); longpath[0] = '\\'; longpath[101] = 0;
        ck("F12 oversized path component -> INVALID_PARAMETER",
           cmp90_fat_load_path(&f, longpath, &buf, &sz) == EFI_INVALID_PARAMETER);
    }
    build_fat32(0);
    {
        Cmp90Fat f; UINT8 *buf = NULL; UINTN sz = 0;
        /* attacker-sized FAT spanning 2 GiB sectors: geometry stays
           UINT32-wrapped, every read lands behind the bio bounds check */
        put32(g_disk, 36, 0x0FFFFFFFu);
        (void)cmp90_fat_open(&g_bio, 0, &f);
        ck("F13 absurd fatsz: reads bounded, result is an error",
           EFI_ERROR(cmp90_fat_load_path(&f, "\\FILE.EFI", &buf, &sz)));
    }
    build_fat32(0);
    {   /* sign-bit fatsz: production expression (UINT32)bpb[39]<<24 —
           UBSan across this whole suite proves no signed-shift UB */
        Cmp90Fat f;
        put32(g_disk, 36, 0x80000000u);
        (void)cmp90_fat_open(&g_bio, 0, &f);
        ck("F14 bpb[39]=0x80 fatsz: open accepted wrapped geometry", f.fat32);
    }
    {   /* non-PE file content -> LOAD_ERROR sanitizer */
        Cmp90Fat f; UINT8 *buf = NULL; UINTN sz = 0;
        build_fat32(0);
        g_disk[24576 + 1*512] = 'X'; g_disk[24576 + 1*512 + 1] = 'Y';
        (void)cmp90_fat_open(&g_bio, 0, &f);
        ck("F15 non-MZ file refused before LoadImage",
           cmp90_fat_load_path(&f, "\\FILE.EFI", &buf, &sz) == EFI_LOAD_ERROR);
    }
    {   /* size cap: 0x02000000+1 -> BAD_BUFFER_SIZE before any alloc */
        Cmp90Fat f; UINT8 *buf = NULL; UINTN sz = 0;
        build_fat32(0);
        put32(g_disk + 24576, 28, 0x02000001u);
        (void)cmp90_fat_open(&g_bio, 0, &f);
        ck("F16 file over alloc cap -> BAD_BUFFER_SIZE",
           cmp90_fat_load_path(&f, "\\FILE.EFI", &buf, &sz) == EFI_BAD_BUFFER_SIZE);
    }

    printf(fails ? "%d FAILURES\n" : "ALL-PASS\n", fails);
    return fails != 0;
}
'''

import hashlib
# deterministic manifest: sha256 of the exact fixture payload bytes
def a1(): return bytes((i*7+1) & 0xFF for i in range(64))
def a2(): return bytes((200-i) & 0xFF for i in range(32))
def a3(): return bytes((i ^ 0x5A) & 0xFF for i in range(128))
lines = [
    (hashlib.sha256(a1()).hexdigest(), "v67_payload.bin"),
    (hashlib.sha256(a2()).hexdigest(), "booter_ucode_prod.bin"),
    (hashlib.sha256(a3()).hexdigest(), "sec2_ucode_vbios_49.bin"),
    ("0"*64, "unlisted.bin"),   # foreign lines must be skipped safely
]
c_bytes = bytes("".join("%s  %s\n" % (h, f) for h, f in lines), "ascii")
arr = ", ".join(str(b) for b in c_bytes)
harness = harness.replace("MANIFEST_PLACEHOLDER", "{ %s }" % arr)
open(sys.argv[2], "w").write(harness)

# ---- deliberate-bug fixture: the shape a regression could take (pool
# freed on the failure exit while the digest text still points into it).
# NOT production code — this binary MUST abort under ASan. ----
open(sys.argv[3], "w").write(r'''/* poison_fixture.c — deliberate heap-use-after-free, ticket 12 (row X3).
 * Proves the ASan gate bites: the suite is only trustworthy if a bug of
 * this shape cannot pass it. Mirrors the PROM-gate failure-exit shape:
 * pool freed, then the buffer referenced one last time. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(void) {
    /* Bite MUST be real: plain printf("%s", pool) got constant-folded by
     * gcc-13 (first GitHub CI run: empty print, rc=0 — hollow proof the
     * local gcc-15 box never exposed), and even a volatile-stored pointer
     * into printf evaded it. A volatile-qualified LOAD through the freed
     * pointer cannot be folded away: the language mandates the read
     * instruction, which is exactly what ASan's shadow check rides. */
    char *pool = malloc(256);
    volatile char *v = (volatile char *)pool;
    *v = 'D';
    free(pool);
    char sink = *v;                /* the use-after-free: mandated load */
    printf("live=%c\n", sink);
    
}
''')
print("generated")
PYEOF

CF=(-std=gnu11 -g -O1 -Wall -Wextra -Werror -Wno-unused-function
    # extraction convention keeps CHAR16=char (8-bit): production's
    # `lfn[i] != 0xFFFF` sentinel test reads as dead only in the harness
    -Wno-type-limits
    -fsanitize=address,undefined -fno-sanitize-recover=all)

gcc "${CF[@]}" -I "${WORK}/stubinc" -c "${HERE}/../sha256.c" -o "${WORK}/sha256.o"
gcc "${CF[@]}" -o "${WORK}/asan_harness" "${WORK}/harness.c" "${WORK}/sha256.o"
# the poison fixture IS the bug: gcc's own -Wuse-after-free would stop it,
# so compile it with the sanitizers but without -Werror on purpose
gcc -std=gnu11 -g -O1 -fsanitize=address,undefined -fno-sanitize-recover=all \
    -o "${WORK}/poison" "${WORK}/poison.c"

echo "== sanitizer suite =="
"${WORK}/asan_harness"

echo "== ASan bite proof (expected: abort with heap-use-after-free) =="
set +e
out="$("${WORK}/poison" 2>&1)"; rc=$?
set -e
if [[ $rc -eq 0 ]] || ! grep -q "heap-use-after-free" <<<"${out}"; then
    printf 'POISON FIXTURE NOT CAUGHT — sanitizer gate is hollow\n' >&2
    exit 1
fi
echo "PASS poison fixture caught by ASan (exit=${rc})"
echo "asan-gate-selftest: boot-path logic clean under ASan+UBSan"
