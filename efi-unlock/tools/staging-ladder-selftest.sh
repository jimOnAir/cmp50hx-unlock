#!/usr/bin/env bash
# staging-ladder-selftest.sh — host-side logic gate for the staging-band
# fallback ladder (gtuu-mining ticket 15, row B2-P2). Extraction pattern +
# define name-closure copied from fwsec-gate-selftest.sh: the band
# vocabulary block, GspFwWprMeta typedef, build_wpr_meta,
# u40x_build_radix_band and staging_band_fallback are pulled VERBATIM from
# unlock50x_v1.c, every referenced #define by name closure from the live
# source and ../common/cmp50hx_regs.h (addresses can't drift), wbinvd asm
# the only inertization.
#
# Stubs: alloc_fwsec_buffer/alloc_below_4g over two mmap pools with ASSERTED
# band invariants (pool >=4GiB vs MAP_FIXED at 0x50000000 — the fixtures
# assert bands by address arithmetic, so a silent pool misplacement must
# abort the harness, never pass a fixture); do_flr/enable_mem_decode/
# fwsec_boot_gsp_50hx/booter_load_tu102_direct record a call-order event
# string + counters (the B2 1e93 lesson: command-reg re-arm STRICTLY before
# FWSEC re-ignition is asserted); Print swallows output but keeps format
# strings for tag assertions; mmio over knobs.
#
#   usage: bash efi-unlock/tools/staging-ladder-selftest.sh
#
# Semantics asserted (ticket 15 AC):
#   - success-high: ladder never arms (no FLR, no fire);
#   - 0x89 + host magic intact + all-HIGH staging: exactly ONE LOW retry,
#     vehicle order flr -> bme -> fwsec -> booter, booter sees a <4GiB meta;
#   - LOW retry success: verified line + buffers rebound below 4GiB;
#   - 0x89 + CORRUPT magic: no retry, meta corruption named;
#   - second 0x89: final refusal, exactly one retry (no loop), band history
#     [BAND-HIGH] + [BAND-LOW] in the log;
#   - zero-DMA fingerprint (cpuctl==0 && IMEM[0]==0xffffffff) prints the
#     named 'check BIOS VT-d/intel-IOMMU' advisory — and only then;
#   - mirror class 0x91 and already-LOW staging (the alloc-time silent
#     fallback class) never arm the ladder;
#   - FWSEC re-ignition failure: refusal without ever firing the booter.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${HERE}/../unlock50x_v1.c"
HDR="${HERE}/../../common/cmp50hx_regs.h"
OUT="$(mktemp -d)/ladder_harness.c"

python3 - "$SRC" "$HDR" "$OUT" <<'PYEOF'
import re, sys
src_path, hdr_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(src_path).read()
hdr = open(hdr_path).read()

def extract(start_marker, end_from=None):
    """verbatim slice from start_marker to the first column-0 '}\n' after it"""
    start = src.index(start_marker)
    end = src.index("\n}\n", end_from or start) + 3
    return src[start:end]

blocks = []
# 1. band vocabulary: defines, U40X_STAGE, band helpers, alloc_stage,
#    all-high guard, zero-DMA fingerprint helper — contiguous, VERBATIM
blocks.append(extract("#define STAGE_BAND_HIGH",
                      src.index("static void\nu40x_zero_dma_note")))
# 2. the meta struct VERBATIM
tstart = src.index("typedef struct {\n    UINT64 magic;")
blocks.append(src[tstart:src.index("} GspFwWprMeta;", tstart) + len("} GspFwWprMeta;\n")])
# 3. the two globals the extracted functions read, VERBATIM
for marker in ("static UINT64 g_fbSize     = 0x280000000ULL;",
               "static UINTN cmp90_stockSig = 0;"):
    m = src.index(marker)
    blocks.append(src[m:m + len(marker) + 1])
# 4. the functions under test VERBATIM
blocks.append(extract("static void\nbuild_wpr_meta"))
blocks.append(extract("static EFI_STATUS u40x_build_radix_band"))
blocks.append(extract("static BOOLEAN\nstaging_band_fallback"))

extracted = "\n".join(blocks).replace('L"', '"')
extracted = extracted.replace('__asm__ volatile("wbinvd" ::: "memory");', '(void)0;')
assert 'wbinvd' not in extracted and '__asm__' not in extracted, "unstubbed asm in body"

# every #define the above references, by name closure (drift-proof),
# skipping names already defined inside the extracted VERBATIM blocks
defines = {}
pre_defs = set(re.findall(r'#define[ \t]+(\w+)', extracted))
def find_define(name):
    for text in (src, hdr):
        m = re.search(r'^#define[ \t]+' + re.escape(name) + r'\b.*$',
                      text, re.MULTILINE)
        if m:
            return m.group(0)
    return None

tokens = set(re.findall(r'\b[A-Z][A-Z0-9_]{2,}\b', extracted)) - pre_defs
frontier = sorted(tokens)
while frontier:
    name = frontier.pop()
    if name in defines:
        continue
    line = find_define(name)
    if line is None:
        continue  # comment prose or harness-provided type/macro
    defines[name] = line
    rhs = re.sub(r'/\*.*\*/', '', line)
    rhs = rhs[len('#define'):].split(None, 1)[1] if len(rhs.split(None, 1)) > 1 else ''
    for dep in re.findall(r'\b[A-Z][A-Z0-9_]{2,}\b', rhs):
        if dep not in defines:
            frontier.append(dep)

ordered, pending = [], dict(defines)
while pending:
    progressed = False
    for name in sorted(pending):
        rhs = re.sub(r'/\*.*\*/', '', pending[name])
        rhs = rhs[len('#define'):].split(None, 1)[1] if len(rhs.split(None, 1)) > 1 else ''
        if all(dep in ordered for dep in re.findall(r'\b[A-Z][A-Z0-9_]{2,}\b', rhs)):
            ordered.append(name)
            del pending[name]
            progressed = True
            break
    assert progressed, f"define dependency cycle: {sorted(pending)}"
defines_block = "\n".join(defines[n] for n in ordered)

harness = '''#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
typedef unsigned char UINT8; typedef unsigned short UINT16;
typedef unsigned int UINT32; typedef unsigned long long UINT64;
typedef unsigned long UINTN; typedef long INTN; typedef int INT32;
typedef char CHAR16; typedef int BOOLEAN; typedef void VOID;
#define TRUE 1
#define FALSE 0
typedef INTN EFI_STATUS;
typedef UINT64 EFI_PHYSICAL_ADDRESS;
#define EFI_SUCCESS 0
#define EFI_DEVICE_ERROR 1
#define EFI_ERROR(s) ((s) != EFI_SUCCESS)

/* ---- Print: swallow output but keep format strings for tag assertions ---- */
static const CHAR16 *g_log[4096];
static int g_logn;
static int Print(const CHAR16 *f, ...) {
    if (g_logn < (int)(sizeof g_log / sizeof g_log[0])) g_log[g_logn++] = f;
    return 0;
}
static int saw(const char *tag) {
    int j;
    for (j = 0; j < g_logn; j++) if (strstr(g_log[j], tag)) return 1;
    return 0;
}
#define saw_not(tag) (!saw(tag))

/* ---- constants extracted VERBATIM from the live source ---- */
''' + defines_block + '''

/* ---- fake "physical memory": two pools with ASSERTED band invariants.
 * The fixtures read/write the meta magic through the returned addresses,
 * so a dereferenceable-but-wrong-band pool would silently poison the
 * all-high guard test — hence hard aborts. ---- */
#define POOL_SZ (8u << 20)
static UINT8 *pool_hi, *pool_lo;
static UINTN hi_off, lo_off;
static int g_alloc_hi, g_alloc_lo;
static int f_alloc_lo_fail, f_flr_fail, f_fwsec_ok, f_booter_ok, f_retry_exit;
static int g_flr, g_bme, g_fwsec, g_booter, g_last_band;
static UINT64 g_last_meta_arg;
static char g_events[128];
static char g_bands[32];

static void pools_init(void) {
    pool_hi = mmap(NULL, POOL_SZ, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    pool_lo = mmap((void *)(UINTN)0x50000000UL, POOL_SZ, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    if (pool_hi == MAP_FAILED || pool_lo == MAP_FAILED) {
        perror("mmap pool"); exit(2);
    }
    if ((UINTN)pool_hi < 0x100000000ULL || (UINTN)pool_lo >= 0x100000000ULL) {
        fprintf(stderr, "HARNESS BUG: pool bands wrong (hi=%p lo=%p)\\n",
                (void *)pool_hi, (void *)pool_lo);
        exit(2);
    }
}
static EFI_STATUS alloc_fwsec_buffer(UINTN Pages, EFI_PHYSICAL_ADDRESS *Phys) {
    UINTN sz = Pages << 12;
    if (hi_off + sz > POOL_SZ) return EFI_DEVICE_ERROR;
    *Phys = (EFI_PHYSICAL_ADDRESS)(UINTN)(pool_hi + hi_off);
    hi_off += sz; g_alloc_hi++;
    if (*Phys < 0x100000000ULL) { fprintf(stderr, "HARNESS BUG: hi pool page below 4G\\n"); exit(2); }
    memset((void *)(UINTN)*Phys, 0, sz);
    return EFI_SUCCESS;
}
static EFI_STATUS alloc_below_4g(UINTN Pages, EFI_PHYSICAL_ADDRESS *Phys) {
    UINTN sz = Pages << 12;
    if (f_alloc_lo_fail || lo_off + sz > POOL_SZ) return EFI_DEVICE_ERROR;
    *Phys = (EFI_PHYSICAL_ADDRESS)(UINTN)(pool_lo + lo_off);
    lo_off += sz; g_alloc_lo++;
    if (*Phys >= 0x100000000ULL) { fprintf(stderr, "HARNESS BUG: lo pool page >=4G\\n"); exit(2); }
    memset((void *)(UINTN)*Phys, 0, sz);
    return EFI_SUCCESS;
}

/* ---- vehicle stubs: counters + strict call-order event string ---- */
static void evt(const char *e) {
    if (g_events[0] && strlen(g_events) + 1 < sizeof g_events)
        strcat(g_events, ",");
    if (strlen(g_events) + strlen(e) < sizeof g_events - 1)
        strcat(g_events, e);
}
static EFI_STATUS do_flr(void) { g_flr++; evt("flr");
    return f_flr_fail ? EFI_DEVICE_ERROR : EFI_SUCCESS; }
static void enable_mem_decode(void) { g_bme++; evt("bme"); }
static BOOLEAN fwsec_boot_gsp_50hx(UINT64 p) { (void)p; g_fwsec++;
    evt("fwsec"); return f_fwsec_ok ? TRUE : FALSE; }
static EFI_STATUS booter_load_tu102_direct(UINT64 meta, UINT64 ucode,
                                           UINT32 band, UINT32 *exitp) {
    (void)ucode;
    /* mirrors the real function's band-tagged entry line so fixtures that
     * simulate the first attempt read their band history off the captured
     * Print log (band==1 is STAGE_BAND_LOW, spelled out to keep the stub
     * below the extracted defines without a forward reference) */
    Print("%s tu102: booter transaction begins (meta@0x%lx)\\n",
          band == 1u ? "[BAND-LOW]" : "[BAND-HIGH]", meta);
    /* band history as an ordered string: saw() only captures format
     * strings, and the band name is a %s ARGUMENT — fixtures asserting
     * per-attempt band history read this instead of log-grepping */
    if (strlen(g_bands) < sizeof g_bands - 2)
        strcat(g_bands, band == 1u ? "L" : "H");
    g_booter++; evt("booter"); g_last_band = (int)band;
    g_last_meta_arg = meta;
    if (f_booter_ok) { if (exitp) *exitp = 0u; return EFI_SUCCESS; }
    if (exitp) *exitp = (UINT32)f_retry_exit;
    return EFI_DEVICE_ERROR;
}
/* ---- register knobs ---- */
static UINT32 f_wpr2hi, f_wpr2lo, f_sec_cpu, f_sec_imem0;
static UINT32 mmio_read32(UINTN off) {
    if (off == REG_PFB_MMU_WPR2_HI) return f_wpr2hi;
    if (off == REG_PFB_MMU_WPR2_LO) return f_wpr2lo;
    if (off == SEC2_CPUCTL)         return f_sec_cpu;
    if (off == SEC2_IMEMD0)         return f_sec_imem0;
    return 0;
}
static UINT32 g_writes;
static void mmio_write32(UINTN off, UINT32 v) { (void)off; (void)v; g_writes++; }
/* ticket 17 wiring: the refusal lines now attach the shared-dictionary
 * decode note (the VERBATIM call is part of the extracted function).
 * Inertized here — the dictionary itself, both traps and the
 * refusal-site attachment are gated by mailbox-dict-selftest.sh. */
static int g_mailnote_calls;
static void u40x_booter_mailbox_note(const CHAR16 *who, UINT32 m0) {
    (void)who; (void)m0; g_mailnote_calls++;
}
static void CopyMem(VOID *d, const VOID *s, UINTN n) { memcpy(d, s, n); }
static void SetMem(VOID *d, UINTN n, UINT8 v) { memset(d, n, v); }
static UINT8 fwsec_50hx_prod_bin[FW50_BLOB_SIZE];
static UINT8 v67_payload_bin[V67_SIZE];
static UINT8 gsp_rm_boot_dbg[GSP_RM_BOOT_SIZE];

''' + extracted + '''

/* ---- fixtures ---- */
static int fails;
static void fx_reset(void) {
    hi_off = lo_off = g_alloc_hi = g_alloc_lo = 0;
    g_flr = g_bme = g_fwsec = g_booter = g_writes = 0;
    g_last_band = -1; g_last_meta_arg = 0;
    f_alloc_lo_fail = f_flr_fail = 0;
    f_fwsec_ok = f_booter_ok = 1; f_retry_exit = 0;
    f_wpr2hi = f_wpr2lo = 0; f_sec_cpu = 2u; f_sec_imem0 = 0xDEAD5EC1u;
    g_logn = 0; g_events[0] = 0; g_bands[0] = 0;
    g_mailnote_calls = 0;
}
static UINT64 hi_alloc(UINTN pages) {
    EFI_PHYSICAL_ADDRESS p;
    if (EFI_ERROR(alloc_fwsec_buffer(pages, &p))) {
        fprintf(stderr, "fixture hi-alloc overflow\\n"); exit(2);
    }
    return p;
}
static U40X_STAGE fx_stage_high(void) {
    /* mirrors efi_main's [6]/[7]: v67, ucode, bl, meta, radix, dummy-FW
     * source — all HIGH; meta written with the real magic. fwSize kept
     * small (1MB): the radix geometry math is not under test, the band
     * propagation is. */
    U40X_STAGE s;
    s.v67Phys   = hi_alloc((V67_SIZE + 0xFFFu) >> 12);
    s.ucodePhys = hi_alloc(0x10u);
    s.blPhys    = hi_alloc((GSP_RM_BOOT_SIZE + 0xFFFu) >> 12);
    s.metaPhys  = hi_alloc((WPR_META_SIZE + 0xFFFu) >> 12);
    s.radixPhys = hi_alloc(0x100u);
    s.fwPhys    = hi_alloc(0x100u);
    s.fwSize    = 0x100000ULL;
    memset((void *)(UINTN)s.fwPhys, 0xA5, 0x100000u);
    *(volatile UINT64 *)(UINTN)s.metaPhys = GSP_FW_WPR_META_MAGIC;
    return s;
}
static void expect(const char *name, int cond) {
    if (!cond) { printf("FAIL %s\\n", name); fails++; }
    else printf("PASS %s\\n", name);
}
int main(void) {
    U40X_STAGE s; int r; UINT64 meta_before; UINT32 firstExit;

    pools_init();

    /* 1. success-high: booter OK means the ladder is never armed */
    fx_reset(); s = fx_stage_high();
    r = staging_band_fallback(&s, 0x0u);
    expect("1 success-high: no retry (no flr/bme/fwsec/booter, decline named)",
           !r && !g_flr && !g_bme && !g_fwsec && !g_booter &&
           saw("STAGING-FALLBACK: not armed") &&
           g_mailnote_calls == 1 &&   /* ticket 17: the named halt gets its
                                       * dictionary note on the refusal */
           saw_not("exactly ONE retry"));

    /* 2. 0x89 + magic intact + all-HIGH: exactly one LOW retry, vehicle
     *    order flr -> bme(command re-arm) -> fwsec -> booter, booter's
     *    meta argument genuinely below 4GiB (retry fails here: "fires") */
    fx_reset(); s = fx_stage_high(); f_booter_ok = 0; f_retry_exit = 0x89;
    firstExit = 0u;   /* simulate the first (HIGH) attempt through the same
                       * stub so band history + no-loop counting are real */
    (void)booter_load_tu102_direct(s.metaPhys, s.ucodePhys,
                                   STAGE_BAND_HIGH, &firstExit);
    r = staging_band_fallback(&s, firstExit);
    expect("2 0x89+magic-intact: exactly one low retry fired (order booter,flr,bme,fwsec,booter; retry meta<4GiB)",
           !r && firstExit == 0x89u && g_flr == 1 && g_bme == 1 &&
           g_fwsec == 1 && g_booter == 2 &&
           strcmp(g_events, "booter,flr,bme,fwsec,booter") == 0 &&
           g_last_band == (int)STAGE_BAND_LOW &&
           g_last_meta_arg < 0x100000000ULL &&
           saw("booter 0x89 + host magic intact = the >=4GiB staging read never delivered"));

    /* 3. LOW retry success: verified line + buffers rebound below 4GiB
     *    with the rebuilt magic intact */
    fx_reset(); s = fx_stage_high(); meta_before = s.metaPhys;
    r = staging_band_fallback(&s, 0x89u);
    expect("3 low-retry-success: logged verified + rebound low + repacked magic intact",
           r && strcmp(g_bands, "L") == 0 &&
           s.metaPhys != meta_before &&
           s.metaPhys < 0x100000000ULL && s.v67Phys < 0x100000000ULL &&
           s.blPhys < 0x100000000ULL && s.radixPhys < 0x100000000ULL &&
           g_alloc_lo >= 4 &&
           *(volatile UINT64 *)(UINTN)s.metaPhys == GSP_FW_WPR_META_MAGIC &&
           saw("LOW-band retry VERIFIED") && saw("[BAND-LOW]"));

    /* 4. 0x89 + CORRUPT magic: no retry, meta corruption named */
    fx_reset(); s = fx_stage_high();
    *(volatile UINT64 *)(UINTN)s.metaPhys = 0xDEADBEEF00000000ULL;
    r = staging_band_fallback(&s, 0x89u);
    expect("4 0x89+magic-corrupt: NO retry, corruption named",
           !r && !g_booter && !g_flr && !g_fwsec &&
           saw("host meta page magic CORRUPT") &&
           g_mailnote_calls == 0 &&   /* host-side verdict, not a halt-code dump */
           saw_not("exactly ONE retry"));

    /* 5. second 0x89 (retry fails identically): final refusal, still
     *    exactly ONE retry (no loop), band history in the log */
    fx_reset(); s = fx_stage_high(); f_booter_ok = 0; f_retry_exit = 0x89;
    firstExit = 0u;
    (void)booter_load_tu102_direct(s.metaPhys, s.ucodePhys,
                                   STAGE_BAND_HIGH, &firstExit);
    r = staging_band_fallback(&s, firstExit);
    expect("5 second 0x89: final refusal, exactly one retry (no loop), band history HIGH+LOW",
           !r && g_booter == 2 &&
           saw("LOW-band retry also failed") &&
           g_mailnote_calls == 1 &&   /* ticket 17: retry-fail halt decoded once */
           saw("exactly ONE retry") &&
           strcmp(g_bands, "HL") == 0);   /* HIGH attempt, then the ONE
                                           * LOW retry — band history, and
                                           * g_booter==2 proves no loop */

    /* 6. zero-DMA fingerprint pair: fires ONLY on cpuctl==0&&IMEM[0]==all-ones */
    fx_reset();
    u40x_zero_dma_note("fx", 0x00000000u, 0xFFFFFFFFu);
    expect("6a zero-DMA fingerprint fires on the (0, 0xffffffff) pair",
           saw("ZERO-DMA FINGERPRINT") && saw("check BIOS VT-d/intel-IOMMU"));
    fx_reset();
    u40x_zero_dma_note("fx", 0x00000002u, 0xFFFFFFFFu);
    u40x_zero_dma_note("fx", 0x00000000u, 0x00123456u);
    expect("6b zero-DMA fingerprint silent on near-miss pairs",
           saw_not("ZERO-DMA"));

    /* 6c. retry failure in the zero-DMA shape: the advisory rides the
     *     ladder's own refusal line (live register read) */
    fx_reset(); s = fx_stage_high();
    f_booter_ok = 0; f_retry_exit = 0x0B; f_sec_cpu = 0u; f_sec_imem0 = 0xFFFFFFFFu;
    r = staging_band_fallback(&s, 0x89u);
    expect("6c retry-fail with zero-DMA shape: VT-d advisory printed",
           !r && g_booter == 1 && saw("check BIOS VT-d/intel-IOMMU"));

    /* 7. mirror class 0x91 (sub-4GiB read lock): never arms — a LOW retry
     *    re-fails by design */
    fx_reset(); s = fx_stage_high();
    r = staging_band_fallback(&s, 0x91u);
    expect("7 0x91 mirror class: never armed",
           !r && !g_booter && !g_flr &&
           saw("mirror sub-4GiB read-lock") &&
           g_mailnote_calls == 1 &&   /* ticket 17: 0x91 refusal gets the
                                       * dictionary line stating the
                                       * EXACTLY-1MiB contract */
           saw_not("exactly ONE retry"));

    /* 8. already-LOW staging (the alloc_fwsec_buffer allocation-time
     *     fallback class): guard names it, nothing to descend */
    fx_reset(); s = fx_stage_high();
    if (EFI_ERROR(alloc_below_4g((GSP_RM_BOOT_SIZE + 0xFFFu) >> 12, &s.blPhys))) {
        fprintf(stderr, "fixture lo-alloc failed\\n"); return 2;
    }
    r = staging_band_fallback(&s, 0x89u);
    expect("8 already-LOW staging (silent alloc fallback): NOT armed",
           !r && !g_booter && !g_flr &&
           saw("allocation-time fallback already tried LOW") &&
           saw_not("exactly ONE retry"));

    /* 9. FWSEC re-ignition failure: refusal WITHOUT ever firing the
     *    booter (FLR+BME happened first — vehicle order preserved) */
    fx_reset(); s = fx_stage_high(); f_fwsec_ok = 0;
    r = staging_band_fallback(&s, 0x89u);
    expect("9 FWSEC re-ignition fail: no fire, refusal named",
           !r && g_flr == 1 && g_bme == 1 && g_fwsec == 1 && g_booter == 0 &&
           saw("FWSEC re-ignition failed"));

    /* 10. alloc band plumbing: HIGH path goes through alloc_fwsec_buffer,
     *     the LOW wrapper through alloc_below_4g (alloc_stage VERBATIM) */
    fx_reset(); {
        EFI_PHYSICAL_ADDRESS p;
        (void)alloc_stage(1, &p, STAGE_BAND_HIGH);
        (void)alloc_stage(1, &p, STAGE_BAND_LOW);
        expect("10 alloc_stage band routing (high->alloc_fwsec_buffer, low->alloc_below_4g)",
               g_alloc_hi == 1 && g_alloc_lo == 1);
    }

    printf(fails ? "%d FAILURES\\n" : "ALL-PASS\\n", fails);
    return fails != 0;
}
'''
open(out_path, "w").write(harness)
PYEOF

gcc -O1 -Wall -Wno-unused-function -o "$OUT.bin" "$OUT"
"$OUT.bin"
echo "staging-ladder-selftest: band ladder green (extracted from $(basename "$SRC"))"
