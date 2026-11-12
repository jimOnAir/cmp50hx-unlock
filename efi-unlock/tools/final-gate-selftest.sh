#!/usr/bin/env bash
# final-gate-selftest.sh — offline gate for the fresh-MMIO final gate
# (gtuu-mining t19, row B2-P36-C4). Extracts the FINAL-GATE block
# VERBATIM; structural asserts pin placement/arming. Drift-proof.
#   usage: bash efi-unlock/tools/final-gate-selftest.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${HERE}/../unlock50x_v1.c"
OUT="$(mktemp -d)/fg_harness.c"

python3 - "$SRC" "$OUT" <<'PYEOF'
import sys
src = open(sys.argv[1]).read()
body = src[src.index("static BOOLEAN g_fg_armed = FALSE;"):
           src.index("/* FINAL-GATE-END */")].replace('L"', '"')
harness = '''#include <stdio.h>
#include <string.h>
typedef unsigned char UINT8; typedef unsigned short UINT16;
typedef unsigned int UINT32; typedef unsigned long UINTN;
typedef char CHAR16; typedef int BOOLEAN;
#define TRUE 1
#define FALSE 0
#define REG_FEAT_OVR_PLM      0x409650u
#define REG_FEAT_OVR_SM_SPD   0x409664u
#define REG_FEAT_OVR_SM_SPD_1 0x40966cu
#define VAL_PLM_OPEN          0xFFFFFFFFu
#define VAL_SS0_UNLOCKED      0x88888888u
#define VAL_SS1_UNLOCKED      0x00000008u
static UINT32 f_plm, f_ss0, f_ss1;
static UINT32 mmio_read32(UINTN off) {
    switch ((unsigned)off) {
    case REG_FEAT_OVR_PLM: return f_plm;
    case REG_FEAT_OVR_SM_SPD: return f_ss0;
    default: return f_ss1;
    }
}
static char logs[4][256]; static int ln;
static int Print(const CHAR16 *fmt, ...) {
    if (ln < 4) { snprintf(logs[ln], 256, "%s", fmt); ln++; }
    return 0;
}
static int saw(const char *f) { for (int i = 0; i < ln; i++) if (strstr(logs[i], f)) return 1; return 0; }
''' + body + '''
static int fails;
static void ck(const char *n, int c) { if (!c) { printf("FAIL %s\\n", n); fails++; } else printf("PASS %s\\n", n); }
static void fx(UINT32 p, UINT32 a, UINT32 b) { f_plm = p; f_ss0 = a; f_ss1 = b; ln = 0; }
int main(void) {
    BOOLEAN r;
    fx(0xFFFFFFFFu, 0x88888888u, 0x00000008u);
    r = u40x_final_gate();
    ck("all-true PASS + ok line", r == TRUE && saw("FINAL-GATE ok: plm=OPEN"));

    fx(0xFFFFFF8Fu, 0x88888888u, 0x00000008u);
    r = u40x_final_gate();
    ck("P33 relocked-gate + SS intact = ok RELOCKED-GATE", r == TRUE && saw("ok RELOCKED-GATE") && !saw("REFUSED"));

    fx(0xFFFFFFFFu, 0x88888888u, 0x00000001u);
    r = u40x_final_gate();
    ck("SS0-only named PARTIAL", r == FALSE && saw("REFUSED-STATE PARTIAL"));
    fx(0xFFFFFFFFu, 0x00000001u, 0x00000008u);
    r = u40x_final_gate();
    ck("SS1-only named PARTIAL", r == FALSE && saw("REFUSED-STATE PARTIAL"));

    fx(0xFFFFFFFFu, 0x5112071u, 0x00000001u);
    r = u40x_final_gate();
    ck("both-locked named LOST", r == FALSE && saw("REFUSED-STATE LOST"));

    fx(0xBADF5040u, 0x88888888u, 0x8u);
    r = u40x_final_gate();
    ck("badf-plm UNTRUSTED (never ok)", r == FALSE && saw("FINAL-GATE UNTRUSTED") && !saw("FINAL-GATE ok"));
    fx(0xFFFFFFFFu, 0xBADF1100u, 0x8u);
    r = u40x_final_gate();
    ck("badf-ss UNTRUSTED", r == FALSE && saw("FINAL-GATE UNTRUSTED"));
    /* all-ones (wedge) reads: PLM==OPEN-value collision must NOT pass —
       SS reads 0xFFFFFFFF => both-locked branch (not ok) */
    fx(0xFFFFFFFFu, 0xFFFFFFFFu, 0xFFFFFFFFu);
    r = u40x_final_gate();
    ck("wedge all-FF cannot pass the gate", r == FALSE && !saw("FINAL-GATE ok"));
    printf(fails ? "%d FAILURES\\n" : "ALL-PASS\\n", fails);
    return fails != 0;
}
'''
open(sys.argv[2], "w").write(harness)
PYEOF
gcc -O1 -Wall -Wno-unused-function -Wno-unused-variable -o "$OUT.bin" "$OUT"
"$OUT.bin"

# structural: placement last-before-StartImage + exactly 3 arm sites + no
# allocation/print-free violations claimed inside the gate (reads + Print
# AFTER decisions only, per design note)
python3 - "$SRC" <<'PYEOF'
import sys
src = open(sys.argv[1]).read()
fn = src[src.index("static EFI_STATUS chainload_preloaded"):src.index("\n}\n", src.index("static EFI_STATUS chainload_preloaded"))]
i_gate = fn.index("(void)u40x_final_gate();")
i_start = fn.index("BS->StartImage")
assert i_gate < i_start, "gate must precede StartImage"
assert src.count("g_fg_armed = TRUE;") == 3, "exactly three claim sites arm"
gate = src[src.index("static BOOLEAN g_fg_armed"):src.index("/* FINAL-GATE-END */")]
assert "AllocatePool" not in gate and "FreePool" not in gate, "gate stays alloc-free"
assert "mmio_write32" not in gate, "gate is read-only"
print("PASS structural: gate precedes StartImage; 3 arm sites; alloc-free; read-only")
PYEOF
echo "final-gate-selftest green (extracted verbatim)"
