#!/usr/bin/env bash
# preflight-selftest.sh — host-side logic gate for the config-space walker
# (gtuu-mining ticket 08, row U2). Extracts the walker VERBATIM from
# unlock50x_v1.c (zero drift by construction), wraps it in a stub harness
# (cfg_read32 over a synthetic 256 B config, Print swallowed), and runs
# the fixture matrix: one valid TU102-like chain must accept, and each
# hostile layout class must reject.
#
#   usage: bash efi-unlock/tools/preflight-selftest.sh
#
# Fixture edits in one place: good_chain() + the check() list below.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${HERE}/../unlock50x_v1.c"
OUT="$(mktemp -d)/pf_harness.c"

python3 - "$SRC" "$OUT" <<'PYEOF'
import sys
src = open(sys.argv[1]).read()
start = src.index("static UINT8 cfg8_at")
end = src.index("return TRUE;", src.index("u40x_preflight_config(void)"))
end2 = src.index("\n}\n", end) + 3
body = src[start:end2].replace('L"', '"')
harness = '''#include <stdio.h>
#include <string.h>
typedef unsigned char UINT8; typedef unsigned short UINT16;
typedef unsigned int UINT32; typedef unsigned long long UINT64;
typedef unsigned long UINTN; typedef char CHAR16;
typedef int BOOLEAN;
#define TRUE 1
#define FALSE 0
#define PF_CFG_DWORDS 64
static UINT32 g_cfg[PF_CFG_DWORDS];
static UINTN g_pf_pm_cap, g_pf_pcie_cap; static int g_pf_flr_plus;
static UINT32 cfg_read32(UINTN off) { return g_cfg[off / 4]; }
static int Print(const CHAR16 *f, ...) { (void)f; return 0; }
''' + body + '''
static void base(void) {
    memset(g_cfg, 0, sizeof g_cfg);
    g_cfg[1] = (g_cfg[1] & ~0xFFFF0000u) | 0x0010u << 16;  /* STATUS cap-list */
    g_cfg[1] = (g_cfg[1] & ~0xFFFFu) | 0x0002u;            /* COMMAND mem en */
}
static void setcap(UINTN off, UINT8 id, UINT8 next, UINT16 ctrl) {
    g_cfg[off/4] = (g_cfg[off/4] & ~0xFFFFu) | id | ((UINT32)next << 8);
    g_cfg[(off+2)/4] = (g_cfg[(off+2)/4] & ~0xFFFF0000u) | ((UINT32)ctrl << 16);
}
static int fails = 0;
static void check(const char *name, int want) {
    int got = u40x_preflight_config();
    if (got != want) { printf("FAIL %s want=%d got=%d\\n", name, want, got); fails++; }
    else printf("PASS %s\\n", name);
}
static void good_chain(void) {
    base();
    g_cfg[0x34/4] |= 0x40;
    setcap(0x40, 0x01, 0x48, 0x0003);            /* PM ver3, CSR D0 */
    setcap(0x48, 0x03, 0x50, 0x0000);            /* VPD */
    setcap(0x50, 0x05, 0x70, 0x0065);            /* MSI 64b+mask */
    setcap(0x70, 0x09, 0x90, 0x0018);            /* VENDOR len 0x18 */
    setcap(0x90, 0x10, 0xCC, 0x0002);            /* PCIe v2 */
    g_cfg[(0x90+4)/4] |= (1u << 28);             /* DEVCAP FLReset+ */
    setcap(0xCC, 0x11, 0x00, 0x0000);            /* MSI-X end */
}
int main(void) {
    good_chain();                                    check("valid TU102-like chain", 1);
    good_chain(); g_cfg[0x34/4] = (g_cfg[0x34/4] & ~0xFFu) | 0x41; check("unaligned cap ptr", 0);
    good_chain(); setcap(0x40, 0x01, 0x40, 0x0003);  check("cycle: PM next=self", 0);
    good_chain(); setcap(0x48, 0x42, 0x50, 0);       check("unknown cap id 0x42", 0);
    good_chain(); g_cfg[0x44/4] |= 3u;               check("PM non-D0", 0);
    good_chain(); g_cfg[(0x90+4)/4] &= ~(1u<<28);    check("DEVCAP no FLReset+", 0);
    good_chain(); setcap(0x40, 0x01, 0x48, 0x0000);  check("PM ver 0 invalid", 0);
    good_chain(); setcap(0x48, 0x01, 0x50, 0x0003);  check("PM duplicate", 0);
    good_chain(); g_cfg[0x30/4] |= 1u;               check("option ROM enabled", 0);
    good_chain(); g_cfg[1] &= ~0xFFFFu;              check("MEM space off", 0);
    good_chain(); setcap(0x50, 0x05, 0x54, 0x0065);  check("MSI overrun into next", 0);
    good_chain(); setcap(0x40, 0x01, 0x08, 0x0003);  check("cap ptr below 0x40", 0);
    good_chain(); { int i; for(i=0;i<45;i++) setcap(0x40+i*4, 0x03, (UINT8)(0x44+i*4), 0); } check("step limit", 0);
    printf(fails ? "%d FAILURES\\n" : "ALL-PASS\\n", fails);
    return fails != 0;
}
'''
open(sys.argv[2], "w").write(harness)
PYEOF

gcc -O1 -Wall -Wno-unused-function -o "$OUT.bin" "$OUT"
"$OUT.bin"
echo "preflight-selftest: walker gate green (extracted from $(basename "$SRC"))"
