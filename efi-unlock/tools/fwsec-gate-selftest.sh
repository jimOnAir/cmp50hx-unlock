#!/usr/bin/env bash
# fwsec-gate-selftest.sh — host-side logic gate for the FWSEC completion gate
# (gtuu-mining ticket 14, row B2-P1). Extracts fwsec_boot_gsp_50hx VERBATIM
# from unlock50x_v1.c (zero drift by construction, same pattern as
# preflight-selftest.sh), plus every #define it references — pulled by name
# closure from the live source and ../common/cmp50hx_regs.h so the harness
# can never test against stale addresses. Stubs: mmio_read32/mmio_write32
# over a virtual-clock register model, Print swallowed but format strings
# captured (the named gate lines are asserted by tag), BS->Stall advances a
# virtual-ms clock (the function's own loop counters ARE milliseconds),
# falcon_wait_* and the BL bindata are inert stubs. wbinvd asm is dropped
# (host cache flush is a no-op; no control flow touched).
#
#   usage: bash efi-unlock/tools/fwsec-gate-selftest.sh
#
# Fixture edits in one place: fx_reset() + the check() list below.
#
# Semantics asserted (ticket 14 AC):
#   accept requires ALL FOUR: exact WPR2 lo+hi, GSP CPUCTL HALT,
#   scratch0e[31:16]==0, non-poisoned mailbox; every reject names its
#   condition ([WPR2]/[HALT]/[GSP-RELOCK]/[SCRATCH0E]/[MAILBOX]).
#   "slow HALT" proves the gate WAITS (returns TRUE only after the
#   virtual clock reached the halt time), never assumes it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${HERE}/../unlock50x_v1.c"
HDR="${HERE}/../../common/cmp50hx_regs.h"
OUT="$(mktemp -d)/fwsec_gate_harness.c"

python3 - "$SRC" "$HDR" "$OUT" <<'PYEOF'
import re, sys
src_path, hdr_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(src_path).read()
hdr = open(hdr_path).read()

# 1. the function VERBATIM
start = src.index("static BOOLEAN\nfwsec_boot_gsp_50hx")
end = src.index("\n}\n", start) + 3
body = src[start:end].replace('L"', '"')
body = body.replace('__asm__ volatile("wbinvd" ::: "memory");', '(void)0;')
assert 'wbinvd' not in body and '__asm__' not in body, "unstubbed asm in body"

# 2. the four WPR2-geometry globals the function reads VERBATIM
gstart = src.index("static UINT64 g_frtsOffset")
gend = src.index("\n", src.index("static UINT32 g_wpr2HiUp")) + 1
globals_block = src[gstart:gend]
assert 'static UINT64 g_fbSize' not in globals_block  # unused, must stay out

# 3. every #define the above references, by name closure (drift-proof)
defines = {}  # name -> line
def find_define(name):
    for text in (src, hdr):
        m = re.search(r'^#define[ \t]+' + re.escape(name) + r'\b.*$',
                      text, re.MULTILINE)
        if m:
            return m.group(0)
    return None

tokens = set(re.findall(r'\b[A-Z][A-Z0-9_]{2,}\b', body + globals_block))
frontier = sorted(tokens)
while frontier:
    name = frontier.pop()
    if name in defines:
        continue
    line = find_define(name)
    if line is None:
        continue  # comment prose or harness-provided type/macro
    defines[name] = line
    # a define's replacement text may itself reference macros (comment
    # text stripped first: /* ... */ tails never expand)
    rhs = re.sub(r'/\*.*\*/', '', line)
    rhs = rhs[len('#define'):].split(None, 1)[1] if len(rhs.split(None, 1)) > 1 else ''
    for dep in re.findall(r'\b[A-Z][A-Z0-9_]{2,}\b', rhs):
        if dep not in defines:
            frontier.append(dep)

# emit in dependency order (GSP_BASE -> CMP50_REG_GSP_BASE -> literal)
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
#include <string.h>
typedef unsigned char UINT8; typedef unsigned short UINT16;
typedef unsigned int UINT32; typedef unsigned long long UINT64;
typedef unsigned long UINTN; typedef long INTN; typedef int INT32;
typedef char CHAR16; typedef int BOOLEAN;
#define TRUE 1
#define FALSE 0
typedef INTN EFI_STATUS;
#define EFI_SUCCESS 0

/* ---- virtual clock: the gate's loops are 1 iteration per 1 ms stall ---- */
static UINT64 g_vms;
static EFI_STATUS stub_stall(UINTN us) { g_vms += us / 1000; return EFI_SUCCESS; }
typedef struct { EFI_STATUS (*Stall)(UINTN); } BS_STUB;
static BS_STUB bsobj = { stub_stall };
static BS_STUB *BS = &bsobj;
#define uefi_call_wrapper(f, n, ...) ((f)(__VA_ARGS__))

/* ---- Print: swallow output but keep format strings for tag assertions ---- */
static const CHAR16 *g_log[4096];
static int g_logn;
static int Print(const CHAR16 *f, ...) {
    if (g_logn < (int)(sizeof g_log / sizeof g_log[0])) g_log[g_logn++] = f;
    return 0;
}

/* ---- constants extracted VERBATIM from the live source ---- */
''' + defines_block + '''
''' + globals_block + '''

/* ---- fixture knobs (register model over a virtual clock) ---- */
static UINT32 f_wpr_lo, f_wpr_hi, f_wpr_lo_pre, f_wpr_hi_pre;
static UINT64 f_wpr_up_at;
static UINT32 f_cpuctl;
static UINT64 f_halt_at, f_badf_at;
static UINT32 f_mb0, f_mb1, f_scratch;
static UINT32 g_writes;

static UINT32 mmio_read32(UINTN off) {
    if (off == GSP_CPUCTL) {
        if (g_vms >= f_badf_at)  return f_cpuctl | 0xBADF0000u;
        if (g_vms >= f_halt_at)  return f_cpuctl | NV_PFALCON_FALCON_CPUCTL_HALTED_TRUE;
        return f_cpuctl;
    }
    if (off == REG_PFB_MMU_WPR2_LO) return g_vms >= f_wpr_up_at ? f_wpr_lo : f_wpr_lo_pre;
    if (off == REG_PFB_MMU_WPR2_HI) return g_vms >= f_wpr_up_at ? f_wpr_hi : f_wpr_hi_pre;
    if (off == GSP_MAILBOX0) return f_mb0;
    if (off == GSP_MAILBOX1) return f_mb1;
    if (off == 0x001438)     return f_scratch;   /* FWSECLIC scratch0e */
    return 0;
}
static void mmio_write32(UINTN off, UINT32 v) { (void)off; (void)v; g_writes++; }

/* ---- inert helpers (not the logic under test) ---- */
static void falcon_wait_reset_ready(UINT32 r) { (void)r; }
static BOOLEAN falcon_wait_scrub_done(UINT32 a, UINT32 b, const CHAR16 *t) {
    (void)a; (void)b; (void)t; return TRUE;
}
/* ticket 15 wiring: the [WPR2]-reject branch now consults the zero-DMA
 * fingerprint helper (VERBATIM call is part of the extracted function).
 * Inertized here — the fingerprint itself is gated by its own harness in
 * staging-ladder-selftest.sh (fixtures 6a/6b/6c). */
static int g_zerodma_calls;
static void u40x_zero_dma_note(const CHAR16 *who, UINT32 c, UINT32 m) {
    (void)who; (void)c; (void)m; g_zerodma_calls++;
}
static const UINT8 gsp_bl_tu102[0x400];
static UINT8 g_blob[0x10000];   /* stands in for the physical FWSEC blob */

/* ---- the function under test, extracted VERBATIM ---- */
''' + body + '''
/* ---- fixtures + matrix ---- */
static int fails;
static void fx_reset(void) {
    g_vms = 0; g_logn = 0; g_writes = 0; g_zerodma_calls = 0;
    memset(g_blob, 0, sizeof g_blob);
    f_wpr_lo = g_wpr2LoUp;  f_wpr_hi = g_wpr2HiUp;   /* exact expected window */
    f_wpr_lo_pre = 0;       f_wpr_hi_pre = 0;        /* down before FRTS */
    f_wpr_up_at = 0;
    f_cpuctl = 0x2;                                   /* STARTCPU sticky, no HALT */
    f_halt_at = 0;                                    /* halted from t=0 */
    f_badf_at = ~(UINT64)0;                           /* never re-gated */
    f_mb0 = 0x11982C00u; f_mb1 = 1u;                  /* benign read-back */
    f_scratch = 0x00000002u;                          /* hi16 (FRTS_ERR) == 0 */
}
static int saw(const char *tag) {
    int j;
    for (j = 0; j < g_logn; j++) if (strstr(g_log[j], tag)) return 1;
    return 0;
}
static void check(const char *name, int want, const char *tag, UINT64 min_vms) {
    int got = fwsec_boot_gsp_50hx((UINT64)(UINTN)g_blob);
    /* zero-DMA consult: required on the WPR2-reject dump, forbidden
     * everywhere else (the hook is read-only advice on the failure path) */
    int zdma_ok = (tag && strcmp(tag, "[WPR2]") == 0)
                  ? g_zerodma_calls == 1 : g_zerodma_calls == 0;
    if (got != want || (tag && !saw(tag)) || g_vms < min_vms || !zdma_ok) {
        printf("FAIL %s want=%d/%s/>=%llums got=%d/%llums\\n",
               name, want, tag ? tag : "-", (unsigned long long)min_vms,
               got, (unsigned long long)g_vms);
        fails++;
    } else printf("PASS %s\\n", name);
}
int main(void) {
    /* accept: all four conditions hold */
    fx_reset();                                       check("all-true accept", 1, "FWSEC gate PASS", 0);
    /* condition 1: WPR2 must match EXACTLY (lo AND hi of the window) */
    fx_reset(); f_wpr_lo = g_wpr2LoUp ^ 0x10u;        check("WPR2 lo mismatch reject", 0, "[WPR2]", 0);
    fx_reset(); f_wpr_hi = 0;                         check("WPR2 hi zero (legacy lo-only accept class) reject", 0, "[WPR2]", 0);
    fx_reset(); f_wpr_up_at = ~(UINT64)0;             check("WPR2 never up reject (+zero-DMA hook consulted on the dump)", 0, "[WPR2]", 0);
    /* proven predicate keeps its nibble-mask: flag bits tolerated */
    fx_reset(); f_wpr_lo |= 5u; f_wpr_hi |= 1u;       check("WPR2 low-nibble flags tolerated", 1, "FWSEC gate PASS", 0);
    /* condition 2: GSP falcon must be OBSERVED halted (bounded 10s) */
    fx_reset(); f_halt_at = ~(UINT64)0;               check("CPUCTL never halts reject (10s budget spent)", 0, "[HALT]", 9999);
    fx_reset(); f_halt_at = ~(UINT64)0; f_badf_at = 200; check("GSP re-lock (0xBADF sentinel) reject", 0, "[GSP-RELOCK]", 200);
    /* condition 3: scratch0e[31:16] FRTS_ERR_CODE == 0 */
    fx_reset(); f_scratch = 0x00AB0000u;              check("scratch0e hi16 nonzero reject", 0, "[SCRATCH0E]", 0);
    /* condition 4: mailbox read-back not poisoned */
    fx_reset(); f_mb0 = 0xFFFFFFFFu;                  check("mailbox0 all-ones poison reject", 0, "[MAILBOX]", 0);
    fx_reset(); f_mb1 = 0xBADF5620u;                  check("mailbox1 gated-domain poison reject", 0, "[MAILBOX]", 0);
    fx_reset(); f_mb0 = 0; f_mb1 = 0;                 check("mailbox zeros NOT poison (reference parity)", 1, "FWSEC gate PASS", 0);
    /* the gate WAITS, it does not assume: #62's measured tail — WPR2-up at
     * 3ms, HALT at 156ms — must still be accepted, at/after 156 virtual ms */
    fx_reset(); f_wpr_up_at = 53; f_halt_at = 156;    check("slow HALT then accept (waits, not assumes)", 1, "FWSEC gate PASS", 156);
    printf(fails ? "%d FAILURES\\n" : "ALL-PASS\\n", fails);
    return fails != 0;
}
'''
open(out_path, "w").write(harness)
PYEOF

gcc -O1 -Wall -Wno-unused-function -o "$OUT.bin" "$OUT"
"$OUT.bin"
echo "fwsec-gate-selftest: four-condition gate green (extracted from $(basename "$SRC"))"
