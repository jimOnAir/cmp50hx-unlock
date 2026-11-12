#!/usr/bin/env bash
# flr-craft-selftest.sh — offline gate for the FLR craft (gtuu-mining t18,
# row B2-P13) + the ko D0-force value helper (row P32a).
# Extracts do_flr VERBATIM (between FLR-CRAFT markers) and the two pure
# gfw_eval helpers VERBATIM — drift-proof, same rule as the other selftests.
#
#   usage: bash efi-unlock/tools/flr-craft-selftest.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${HERE}/../unlock50x_v1.c"
GFW="${HERE}/../../claim-90hx/gfw_eval.c"
OUT="$(mktemp -d)/flr_harness.c"

python3 - "$SRC" "$GFW" "$OUT" <<'PYEOF'
import sys
src = open(sys.argv[1]).read()
start = src.index("static EFI_STATUS\ndo_flr(void)")
end = src.index("/* FLR-CRAFT-END */")
body = src[start:end].replace('L"', '"')
gfw = open(sys.argv[2]).read()
_a = gfw.index("bool gpu_unlock_pmcsr_d0(u16 pmcsr)")
_b = gfw.index("\n}", gfw.index("gpu_unlock_pm_force_d0_value")) + 2
helper = gfw[_a:_b]
harness = '''#include <stdio.h>
#include <string.h>
#include <stdarg.h>
#include <stdbool.h>
typedef unsigned char UINT8; typedef unsigned short UINT16;
typedef unsigned int UINT32; typedef unsigned long long UINT64;
typedef unsigned long UINTN; typedef char CHAR16;
typedef int BOOLEAN; typedef int INTN; typedef INTN EFI_STATUS;
typedef UINT16 u16;
#define TRUE 1
#define FALSE 0
#define EFI_SUCCESS 0
#define EFI_NOT_FOUND 2
#define EFI_TIMEOUT 7
static unsigned long stub_stall(unsigned long us);
typedef struct { unsigned long (*Stall)(unsigned long); } BSS;
static BSS bs = { stub_stall };
static BSS *BS = &bs;
#define uefi_call_wrapper(f, n, ...) (bs.Stall(__VA_ARGS__))

/* ---- fixture config space + width-aware access recorder ---- */
static UINT8 cfg[256];
static int flr_issued;                    /* armed by ANY 16-bit write w/ bit15 */
static UINT32 vendev_post = 0xFFFFFFFFu;  /* identity after FLR per fixture */
struct rec { int width; unsigned off; unsigned val; } w[64];
static int wn;
static unsigned long vms;
static char logs[8][256]; static int ln;

static unsigned rd(int off, int bytes) {
    unsigned v = 0;
    if (off == 0 && bytes == 4 && flr_issued) return vendev_post;
    for (int i = bytes - 1; i >= 0; i--) v = (v << 8) | cfg[off + i];
    return v;
}
static UINT32 cfg_read32(UINTN o) { return (UINT32)rd((int)o, 4); }
static UINT16 cfg_read16(UINTN o) { return (UINT16)rd((int)o, 2); }
static void cfg_write16(UINTN o, UINT16 v) {
    if (v & 0x8000u) flr_issued = 1;
    if (wn < 64) { w[wn].width = 16; w[wn].off = (unsigned)o; w[wn].val = v; wn++; }
    cfg[o] = (UINT8)v; cfg[o + 1] = (UINT8)(v >> 8);
}
static void cfg_write32(UINTN o, UINT32 v) {
    if (wn < 64) { w[wn].width = 32; w[wn].off = (unsigned)o; w[wn].val = v; wn++; }
    for (int i = 0; i < 4; i++) cfg[o + i] = (UINT8)(v >> (8 * i));
}
static unsigned long stub_stall(unsigned long us) { vms += us / 1000; return 0; }
static int Print(const CHAR16 *fmt, ...) {
    if (ln < 8) { snprintf(logs[ln], 256, "%s", fmt); ln++; }
    return 0;
}
static int saw(const char *frag) {
    for (int i = 0; i < ln; i++) if (strstr(logs[i], frag)) return 1;
    return 0;
}
static UINTN g_pf_pm_cap, g_pf_pcie_cap; static BOOLEAN g_pf_flr_plus;

/* ================= do_flr: VERBATIM from unlock50x_v1.c ================= */
''' + body + '''
/* ============ ko pure helpers: VERBATIM from gfw_eval.c ================= */
#define GU_PCI_PM_CTRL_STATE_MASK 0x3u
#define GU_PCI_PM_STATE_D0 0u
''' + helper + '''
/* ------------------------------ fixtures ------------------------------- */
static int fails;
static void fx(void) {
    memset(cfg, 0, sizeof cfg); wn = 0; vms = 0; flr_issued = 0; ln = 0;
    vendev_post = 0x10DE1E09u;
    cfg[0] = 0x09; cfg[1] = 0x1E; cfg[2] = 0xDE; cfg[3] = 0x10;   /* vendev */
}
static void ck(const char *nm, int cond) {
    if (!cond) { printf("FAIL %s\\n", nm); fails++; } else printf("PASS %s\\n", nm);
}
static int wr_count(int width, unsigned off) {
    int n = 0; for (int i = 0; i < wn; i++)
        if (w[i].width == width && w[i].off == off) n++;
    return n;
}
static int wr_idx(int width, unsigned off, int nth) {
    for (int i = 0; i < wn; i++)
        if (w[i].width == width && w[i].off == off && nth-- == 0) return i;
    return -1;
}
int main(void) {
    EFI_STATUS r; unsigned v; int i16, i32;

    /* F1 happy path, pm=0 (D0 path skipped), walker-provided cap 0x50 */
    fx(); g_pf_pm_cap = 0; g_pf_pcie_cap = 0x50; g_pf_flr_plus = 1;
    cfg[0x58] = 0x1F; cfg[0x59] = 0x2A;                          /* devctl 0x2A1F */
    r = do_flr();
    ck("F1 success", r == EFI_SUCCESS);
    i16 = wr_idx(16, 0x58, 0);
    ck("F1 devctl WORD RMW sets bit15 preserves rest", i16 == 0 && w[i16].val == 0xAA1Fu);
    ck("F1 NO dword write to the devctl/status dword", wr_count(32, 0x58) == 0);
    ck("F1 COMMAND never touched", wr_count(16, 0x04) == 0 && wr_count(32, 0x04) == 0);
    ck("F1 identity-return immediate, 200ms kept", vms == 200);
    ck("F1 verified line logged", saw("issued+verified"));

    /* F2 D3 entry: PMCSR force-D0 FIRST at pm=0x40 (PMCSR@0x44) */
    fx(); g_pf_pm_cap = 0x40; g_pf_pcie_cap = 0x50;
    cfg[0x44] = 0x03; cfg[0x45] = 0x01;                          /* PMCSR 0x0103 D3hot */
    r = do_flr();
    ck("F2 success", r == EFI_SUCCESS);
    i16 = wr_idx(16, 0x44, 0); i32 = wr_idx(16, 0x58, 0);
    ck("F2 D0 force is the FIRST write (precedes FLR)", i16 == 0 && i32 == 1 && w[i16].val == 0x0100u);
    ck("F2 post-FLR second PMCSR write: upper restored, D0 pinned",
       wr_count(16, 0x44) == 2 && w[wr_idx(16, 0x44, 1)].val == 0x0100u);
    ck("F2 pre-FLR line named", saw("D0 forced pre-FLR"));

    /* F3 TP stuck: advisory, still proceeds, full 1 s drain observed */
    fx(); g_pf_pm_cap = 0; g_pf_pcie_cap = 0x50;
    cfg[0x06] = 0x10;                                            /* STATUS bit4 set forever */
    r = do_flr();
    ck("F3 proceeds on TP-stuck", r == EFI_SUCCESS);
    ck("F3 [TP] advisory named", saw("[TP]"));
    ck("F3 full drain 1000ms + silence 200ms", vms >= 1200);

    /* F4 identity never returns */
    fx(); g_pf_pm_cap = 0; g_pf_pcie_cap = 0x50;
    vendev_post = 0xFFFFFFFFu;
    r = do_flr();
    ck("F4 EFI_TIMEOUT", r == EFI_TIMEOUT);
    ck("F4 [IDENTITY] named", saw("[IDENTITY]"));

    /* F5 no PCIe capability at all */
    fx(); g_pf_pm_cap = 0; g_pf_pcie_cap = 0; cfg[0x34] = 0;
    r = do_flr();
    ck("F5 NOT_FOUND named", r == EFI_NOT_FOUND && saw("capability not found"));

    /* F6 garbage saved cap -> fallback walk finds 0x48 */
    fx(); g_pf_pm_cap = 0; g_pf_pcie_cap = 0xFFF;
    cfg[0x34] = 0x40; cfg[0x40] = 0x01; cfg[0x41] = 0x48;        /* PM -> 0x48 */
    cfg[0x48] = 0x10;                                            /* PCIe @0x48 */
    cfg[0x50] = 0x1F;
    r = do_flr();
    i16 = wr_idx(16, 0x50, 0);
    ck("F6 fallback walk finds cap 0x48, devctl@0x50", r == EFI_SUCCESS && i16 == 0 && w[i16].val == 0x801Fu);

    /* ko pure helper fixtures */
    {
        UINT16 nxt;
        ck("ko already-D0 -> no write", gpu_unlock_pm_force_d0_value(0x0100, &nxt) == 0 && nxt == 0x0100u);
        ck("ko D3hot 0x0103 -> 0x0100 needs-write", gpu_unlock_pm_force_d0_value(0x0103, &nxt) == 1 && nxt == 0x0100u);
        ck("ko 0x0002 -> 0x0000 needs-write", gpu_unlock_pm_force_d0_value(0x0002, &nxt) == 1 && nxt == 0x0000u);
        ck("ko pmcsr_d0 truth table", gpu_unlock_pmcsr_d0(0x0100) == TRUE && gpu_unlock_pmcsr_d0(0x0103) == FALSE);
    }
    printf(fails ? "%d FAILURES\\n" : "ALL-PASS\\n", fails);
    return fails != 0;
}
'''
open(sys.argv[3], "w").write(harness)
PYEOF

gcc -O1 -Wall -Wno-unused-function -Wno-unused-variable -o "$OUT.bin" "$OUT"
"$OUT.bin"
echo "flr-craft-selftest: craft + D0-force gate (extracted verbatim)"
