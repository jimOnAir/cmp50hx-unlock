#!/usr/bin/env bash
# reset-canary-selftest.sh — host-side logic gate for the reset-scratch
# canary (gtuu-mining ticket 16, row B2-P3). Three parts:
#
#  1. C  extraction: the u40x_canary_* block VERBATIM from
#     unlock50x_v1.c + define name-closure from the live source and
#     ../common/cmp50hx_regs.h (same zero-drift pattern as
#     fwsec-gate-selftest.sh), stub mmio model + Print capture. Runs the
#     classification matrix (PBUS dead/alive × AON dead/alive → power-
#     cycle / flr-sbr / relock-suspect / no-event, plus partial-SS,
#     third-value and poison classes), the gate-invariance proof (the
#     verdict never consults PLM — B2-P33: relocked gate + intact SS is
#     NOT a loss), read-only-by-construction (classify performs zero
#     writes), and arm writes OUR slot only, never the claim slot.
#  2. Bash extraction: the CANARY-BEGIN/END block of cmp90hx-claim.sh
#     VERBATIM, sourced with stubs (fixture bar0_read, captured say,
#     stub setpci, bar0_write overridden AFTER the source so the real
#     python mmap twin cannot leak in), driven through the same matrix —
#     proves the claim journal's verdict strings byte-for-byte.
#  2b. collect extraction: the CANARY-COLLECT block of cmp50hx-collect.sh
#     VERBATIM against fixture ESP logs + stubbed journalctl — proves the
#     efi=/claim= composition, stale-log quarantine, last-line-wins, and
#     the EMPTY pre-feature column.
#  3. Call-site structure (textual, all three files): arm ONLY on the
#     success paths, NEVER on the ALREADY_MODIFIED refusal path, the
#     classify read happens BEFORE the first unlock write in the flow,
#     each actor owns exactly its own slot (EFI never writes 0x1484,
#     claim never writes 0x1480), and collect's CSV gains the canary
#     column without reordering the existing ones.
#
#   usage: bash efi-unlock/tools/reset-canary-selftest.sh
#
# Fixture edits in one place: cell() lists (C) + cell calls (bash).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${HERE}/../unlock50x_v1.c"
HDR="${HERE}/../../common/cmp50hx_regs.h"
CLAIM="${HERE}/../../claim-90hx/cmp90hx-claim.sh"
COLLECT="${HERE}/../../cmp50hx/cmp50hx-collect.sh"
TMP="$(mktemp -d)"
OUT="${TMP}/canary_harness.c"

fails=0
fail() { printf 'FAIL %s\n' "$*"; fails=$((fails+1)); }
pass() { printf 'PASS %s\n' "$*"; }

# ==================== 1. C extraction harness ====================
python3 - "$SRC" "$HDR" "$OUT" <<'PYEOF'
import re, sys
src_path, hdr_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(src_path).read()
hdr = open(hdr_path).read()

# 1. the canary function block VERBATIM
start = src.index("static BOOLEAN\nu40x_canary_poison")
end = src.index("/* ==== Pre-flight config-space validation")
body = src[start:end].replace('L"', '"')
assert "u40x_canary_arm" in body       # arm must be inside the block
assert "u40x_canary_classify" in body  # and so the classifier

# 2. every #define the block references, by name closure (drift-proof:
#    addresses and magics can never move away from the live source)
defines = {}
def find_define(name):
    for text in (src, hdr):
        m = re.search(r'^#define[ \t]+' + re.escape(name) + r'\b.*$',
                      text, re.MULTILINE)
        if m:
            return m.group(0)
    return None

tokens = set(re.findall(r'\b[A-Z][A-Z0-9_]{2,}\b', body))
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
for must in ("CANARY_REG_EFI", "CANARY_REG_CLAIM",
             "CANARY_MAGIC_EFI",
             "VAL_SS0_UNLOCKED", "VAL_SS1_UNLOCKED"):
    assert must in ordered, f"define {must} not captured by name closure"
# the claim magic is documentation-only in the EFI (its OWNER is the
# claim script) — assert its value straight off the live source
assert re.search(r'^#define[ \t]+CANARY_MAGIC_CLAIM[ \t]+0x0165CAFEu\b',
                 src, re.MULTILINE), "CANARY_MAGIC_CLAIM drifted"
assert re.search(r'^#define[ \t]+CANARY_REG_CLAIM[ \t]+0x00001484UL\b',
                 src, re.MULTILINE), "CANARY_REG_CLAIM drifted"
defines_block = "\n".join(defines[n] for n in ordered)

harness = '''#include <stdio.h>
#include <string.h>
#include <stdarg.h>
typedef unsigned char UINT8; typedef unsigned short UINT16;
typedef unsigned int UINT32; typedef unsigned long long UINT64;
typedef unsigned long UINTN; typedef char CHAR16;
typedef int BOOLEAN;
#define TRUE 1
#define FALSE 0

/* ---- constants extracted VERBATIM from the live source ---- */
''' + defines_block + '''
/* ---- fixture register model (keyed by the EXTRACTED macros) ---- */
static UINT32 f_efi, f_claim, f_ss0, f_ss1, f_plm;
static int g_arm_writable = 1;          /* models an unwritable block */
static UINT32 g_wlog[64]; static const CHAR16 *g_wlog_name[64];
static int g_wn;                        /* mmio_write32 call log */

static UINT32 mmio_read32(UINTN off) {
    if (off == CANARY_REG_EFI)     return f_efi;
    if (off == CANARY_REG_CLAIM)   return f_claim;
    if (off == REG_FEAT_OVR_SM_SPD)    return f_ss0;
    if (off == REG_FEAT_OVR_SM_SPD_1)  return f_ss1;
    if (off == REG_FEAT_OVR_PLM)       return f_plm;
    return 0;
}
static void mmio_write32(UINTN off, UINT32 v) {
    if (g_wn < 64) { g_wlog[g_wn] = v;
        g_wlog_name[g_wn] = (off == CANARY_REG_EFI)   ? "EFI-slot"
                            : (off == CANARY_REG_CLAIM) ? "CLAIM-slot"
                            : "other";
        g_wn++; }
    if (g_arm_writable) {               /* else the readback stays stale */
        if (off == CANARY_REG_EFI)  f_efi = v;
        if (off == CANARY_REG_CLAIM) f_claim = v;
    }
}

/* ---- Print capture: the [CANARY] classify line carries the assertions
 * (three %s up front: AON, PBUS, verdict). Format strings are kept for
 * the SET-line tags. ---- */
static const CHAR16 *g_last_fmt;
static const char *g_last_s1, *g_last_s2, *g_last_s3;
static int Print(const CHAR16 *f, ...) {
    va_list ap;
    g_last_fmt = f;
    g_last_s1 = g_last_s2 = g_last_s3 = 0;
    if (strstr(f, "AON=%s PBUS=%s verdict=%s")) {
        va_start(ap, f);
        g_last_s1 = va_arg(ap, const char *);
        g_last_s2 = va_arg(ap, const char *);
        g_last_s3 = va_arg(ap, const char *);
        va_end(ap);
    }
    return 0;
}

/* ---- the functions under test, extracted VERBATIM ---- */
''' + body + '''
static int fails;
static void fx_reset(void) {
    f_efi = 0; f_claim = 0;
    f_ss0 = 0x5112071u; f_ss1 = 0x3u;   /* a stock-ish selector pair */
    f_plm = 0xffffff8fu;                 /* gate closed */
    g_wn = 0;
    g_arm_writable = 1;
}
/* A matrix cell: after classify, the emitted line must carry exactly
 * want_aon / want_pbus / want_verdict, and the pass performed ZERO
 * writes (the read path must stay clean up to the arm point). */
static void cell(const char *name, UINT32 efi, UINT32 ss0, UINT32 ss1,
                 const char *wa, const char *wp, const char *wv) {
    fx_reset(); f_efi = efi; f_ss0 = ss0; f_ss1 = ss1;
    u40x_canary_classify();
    if (g_wn != 0 || !g_last_s1 || strcmp(g_last_s1, wa) ||
        strcmp(g_last_s2, wp) || strcmp(g_last_s3, wv)) {
        printf("FAIL %s want=%s/%s/%s got=%s/%s/%s (writes=%d)\\n", name,
               wa, wp, wv, g_last_s1 ? g_last_s1 : "-",
               g_last_s2 ? g_last_s2 : "-", g_last_s3 ? g_last_s3 : "-", g_wn);
        fails++;
    } else printf("PASS %s\\n", name);
}
/* gate-invariance: the SAME slot/SS state with the gate relocked, open,
 * or garbage must produce the SAME verdict — PLM is never consulted
 * (B2-P33: relocked gate + intact SS = still unlocked). */
static void inv(void) {
    const CHAR16 *a, *b;
    fx_reset(); f_efi = CANARY_MAGIC_EFI;
    f_ss0 = VAL_SS0_UNLOCKED; f_ss1 = VAL_SS1_UNLOCKED; f_plm = 0x0u;
    a = u40x_canary_verdict(f_efi, CANARY_MAGIC_EFI, f_ss0, f_ss1);
    f_plm = 0xffffffefu;
    b = u40x_canary_verdict(f_efi, CANARY_MAGIC_EFI, f_ss0, f_ss1);
    if (strcmp(a, "no-event") || strcmp(a, b)) {
        printf("FAIL gate-invariance got=%s/%s\\n", a, b); fails++;
    } else printf("PASS gate-invariance (verdict never reads PLM — P33 rule)\\n");
}
int main(void) {
    /* the extracted constants can never silently drift: assert values
     * (CANARY_MAGIC_CLAIM value is asserted in python — its owner is the
     * claim script, the EFI only defines it as documentation) */
    if (CANARY_REG_EFI != 0x00001480UL || CANARY_REG_CLAIM != 0x00001484UL ||
        CANARY_MAGIC_EFI != 0x0164C0DEu) {
        printf("FAIL extracted offsets/magics drifted from B2\\n"); return 1;
    }
    printf("PASS offsets+magics adopted from B2 verbatim "
           "(0x1480/0x1484, 0164c0de/0165cafe)\\n");

    /* ---- classification matrix (PBUS × AON), ticket 16 AC ---- */
    cell("PBUS dead + AON dead -> power-cycle (rail-off / S5; EXPECTED)",
         0u, 0x5112071u, 0x3u, "dead", "cleared", "power-cycle");
    cell("PBUS dead + AON alive -> flr-sbr (reset, AON survived it)",
         0u, VAL_SS0_UNLOCKED, VAL_SS1_UNLOCKED, "alive", "cleared", "flr-sbr");
    cell("PBUS alive + AON dead -> relock-suspect (a WRITE, no reset)",
         CANARY_MAGIC_EFI, 0x5112071u, 0x3u, "dead", "intact", "relock-suspect");
    cell("PBUS alive + AON alive -> no-event (nothing between boots)",
         CANARY_MAGIC_EFI, VAL_SS0_UNLOCKED, VAL_SS1_UNLOCKED,
         "alive", "intact", "no-event");
    /* half-latched selectors (ticket-04 class) never read as alive */
    cell("SS0-only alive + PBUS dead -> power-cycle (partial is not alive)",
         0u, VAL_SS0_UNLOCKED, 0x3u, "partial", "cleared", "power-cycle");
    cell("SS1-only alive + PBUS alive -> relock-suspect (partial)",
         CANARY_MAGIC_EFI, 0x5112071u, VAL_SS1_UNLOCKED,
         "partial", "intact", "relock-suspect");
    /* third value: a devinit/BIOS pass ran over the cell (B2 `other`) */
    cell("third value in slot + AON alive -> rewritten",
         0xdeadbeefu, VAL_SS0_UNLOCKED, VAL_SS1_UNLOCKED,
         "alive", "rewritten", "rewritten");
    /* poison reads are NEVER a canary death (B2's inaccessible) */
    cell("slot 0xffffffff -> unreadable (no decode — not judged)",
         0xFFFFFFFFu, 0x5112071u, 0x3u, "dead", "unreadable", "unreadable");
    cell("slot 0xBADF5040 -> unreadable (gated domain — not judged)",
         0xBADF5040u, VAL_SS0_UNLOCKED, VAL_SS1_UNLOCKED,
         "alive", "unreadable", "unreadable");
    inv();

    /* ---- arm: the success path writes ONLY the EFI slot ---- */
    fx_reset();
    u40x_canary_arm();
    if (g_wn != 1 || strcmp(g_wlog_name[0], "EFI-slot") ||
        g_wlog[0] != (UINT32)CANARY_MAGIC_EFI || f_efi != (UINT32)CANARY_MAGIC_EFI) {
        printf("FAIL arm writes EFI-slot only (n=%d)\\n", g_wn); fails++;
    } else printf("PASS arm writes EFI slot 0x1480 with 0x0164c0de, never the claim slot\\n");
    fx_reset();
    u40x_canary_arm();
    if (!strstr(g_last_fmt, "readback ok")) {
        printf("FAIL arm readback-ok line\\n"); fails++;
    } else printf("PASS arm readback verified (B2 CANARY-SET pattern)\\n");
    fx_reset(); g_arm_writable = 0;
    u40x_canary_arm();
    if (!strstr(g_last_fmt, "readback FAILED")) {
        printf("FAIL arm readback-FAILED line on unwritable block\\n"); fails++;
    } else printf("PASS unwritable block named as such (readback FAILED), chain proceeds\\n");

    printf(fails ? "%d FAILURES\\n" : "ALL-PASS\\n", fails);
    return fails != 0;
}
'''
open(out_path, "w").write(harness)
PYEOF

if gcc -O1 -Wall -o "$OUT.bin" "$OUT" 2>"$OUT.gcc"; then
    if "$OUT.bin"; then pass "C harness: matrix green"; else fail "C harness matrix"; fi
else
    sed 's/^/  [c-gcc] /' "$OUT.gcc"; fail "C harness does not compile"
fi

# ==================== 2. bash claim-script harness ====================
BLK="${TMP}/claim_canary_block.sh"
awk '/^# CANARY-BEGIN/{f=1} f{print} /^# CANARY-END/{f=0}' "$CLAIM" > "$BLK"
grep -q "canary_read_classify" "$BLK" || fail "claim CANARY block not extractable"

cat > "${TMP}/claim_canary_test.sh" <<'EOF'
#!/usr/bin/env bash
# Fixture-driven offline run of the claim script's canary functions:
# sourced VERBATIM with stubs. bar0_write is overridden AFTER sourcing
# (the block defines its real python-mmap twin; the stub must win).
set -u
BDF="0000:03:00.0"
declare -A F
SAY=()
WLOG=()
NOWRITE=""
SETPCI_FAIL=""
say() { SAY+=("$*"); }
bar0_read() { local v="${F[$1]:-}"; [ -n "$v" ] && printf '%s' "$v"; }
setpci()  { # stub: COMMAND read -> "0006"; COMMAND=<val> write -> silent ok
    local a
    for a in "$@"; do [[ "$a" == COMMAND=* ]] && return 0; done
    [[ -n "$SETPCI_FAIL" ]] || echo 0006
}
source "$1"
bar0_write() { [[ -n "$NOWRITE" ]] || F[$1]="$2"; WLOG+=("$1 $2"); }

fails=0
last() { printf '%s' "${SAY[-1]:-}"; }
chk() { # chk <name> <want-substring> — last say line must contain it
    local got; got=$(last)
    if [[ "$got" != *"$2"* ]]; then printf 'FAIL %s want~=%s got=%s\n' "$1" "$2" "$got"; fails=$((fails+1));
    else printf 'PASS %s\n' "$1"; fi
}
cell() { # cell <name> <own-slot> <ss0> <ss1> <gate> <want "AON=.. PBUS=.. verdict=..">
    SAY=(); F=(); F[0x1480]=0x0164c0de   # EFI slot armed (corroboration)
    F[0x1484]=$2; F[0x82381c]=$3; F[0x823820]=$4; F[0x823804]=$5
    canary_read_classify
    chk "$1" "canary $6"
}
# --- classification matrix (same cells as the C harness) ---
cell "claim PBUS dead + AON dead -> power-cycle" \
     0x00000000 0x05112071 0x00000003 0xffffff8f "AON=dead PBUS=cleared verdict=power-cycle"
cell "claim PBUS dead + AON alive -> flr-sbr" \
     0x00000000 0x88888888 0x00000008 0xffffff8f "AON=alive PBUS=cleared verdict=flr-sbr"
cell "claim PBUS alive + AON dead -> relock-suspect" \
     0x0165cafe 0x05112071 0x00000003 0xffffff8f "AON=dead PBUS=intact verdict=relock-suspect"
cell "claim PBUS alive + AON alive -> no-event" \
     0x0165cafe 0x88888888 0x00000008 0xffffffef "AON=alive PBUS=intact verdict=no-event"
cell "claim half-SS + PBUS alive -> relock-suspect (partial)" \
     0x0165cafe 0x88888888 0x00000003 0xffffffff "AON=partial PBUS=intact verdict=relock-suspect"
cell "claim third value -> rewritten" \
     0xdeadbeef 0x88888888 0x00000008 0xffffffff "AON=alive PBUS=rewritten verdict=rewritten"
cell "claim poison slot 0xffffffff -> unreadable" \
     0xffffffff 0x00000000 0x00000000 0xffffffff "AON=dead PBUS=unreadable verdict=unreadable"
cell "claim poison slot 0xBADF5040 -> unreadable" \
     0xbadf5040 0x88888888 0x00000008 0xffffff8f "AON=alive PBUS=unreadable verdict=unreadable"
# unreadable also when the reader returns nothing at all (mmap cannot open)
SAY=(); F=(); canary_read_classify
chk "claim empty reads -> unreadable line" "verdict=unreadable"

# --- gate-invariance: the printed gate value never moves the verdict ---
SAY=(); F=(); F[0x1484]=0x0165cafe; F[0x82381c]=0x88888888; F[0x823820]=0x00000008
F[0x823804]=0x00000000; canary_read_classify; g1=$(last); g1="${g1%% gate=*}"
SAY=(); F[0x823804]=0xffffffff; canary_read_classify; g2=$(last); g2="${g2%% gate=*}"
if [[ "$g1" == "$g2" && "$g1" == *"verdict=no-event"* ]]; then
    echo "PASS claim gate-invariance (PLM printed, never consulted)"
else echo "FAIL claim gate-invariance: $g1 | $g2"; fails=$((fails+1)); fi

# --- arm: own slot only, readback proven, failure modes named ---
SAY=(); F=(); WLOG=(); canary_arm
chk "claim arm SET line (readback ok)" "canary SET slot@0x1484=0x0165cafe readback ok"
if [[ ${#WLOG[@]} -eq 1 && "${WLOG[0]}" == "0x1484 0x0165cafe" ]]; then
    echo "PASS claim arm writes ONLY slot 0x1484 with 0x0165cafe (never 0x1480)"
else echo "FAIL claim arm slot discipline: ${WLOG[*]:-none}"; fails=$((fails+1)); fi
SAY=(); F=(); F[0x1484]=0x00000000; WLOG=(); NOWRITE=1; canary_arm; NOWRITE=""
chk "claim arm readback FAILED named on unwritable block" "canary SET readback FAILED got=0x00000000"
SAY=(); F=(); SETPCI_FAIL=1; canary_arm; SETPCI_FAIL=""
chk "claim arm skips cleanly when COMMAND is unreadable" "canary ARM skipped"

exit $fails
EOF
rc=0
bash "${TMP}/claim_canary_test.sh" "$BLK" | sed 's/^/  [sh] /' || rc=$?
[ "$rc" -eq 0 ] && pass "bash harness: matrix green" || fail "bash claim harness matrix (rc=$rc)"

# ==================== 2b. collect canary-column harness =================
# The CANARY-COLLECT-BEGIN/END block of cmp50hx-collect.sh, sourced
# VERBATIM against fixture ESP logs + a stubbed journalctl: proves the
# efi=…/claim=… composition, the stale-log quarantine, and that a
# pre-feature boot renders the column EMPTY.
CBLK="${TMP}/collect_canary_block.sh"
awk '/^# CANARY-COLLECT-BEGIN/{f=1} f{print} /^# CANARY-COLLECT-END/{f=0}' "$COLLECT" > "$CBLK"
grep -q 'CANARY="efi=\$CE"' "$CBLK" || fail "collect CANARY block not extractable"

cat > "${TMP}/collect_canary_test.sh" <<'EOF'
#!/usr/bin/env bash
set -u
CBLK="$1"
JOURNAL=""
CLEAN=""
RAN="yes"
CANARY=""
journalctl() { [ -n "$JOURNAL" ] && printf '%s\n' "$JOURNAL"; }
fails=0
run() { # run — source the extracted block fresh each fixture
    ( source "$1"; printf '%s' "$CANARY" )
}
expect() { # expect <name> <want> <got>
    if [[ "$2" == "$3" ]]; then printf 'PASS %s\n' "$1"
    else printf 'FAIL %s want=[%s] got=[%s]\n' "$1" "$2" "$3"; fails=$((fails+1)); fi
}
# fixture ESP log with a fresh EFI canary line
printf '=== CMP50HX ===\n[CANARY] AON=dead PBUS=cleared verdict=power-cycle efi@0x1480=0x00000000 claim@0x1484=0x00000000 ss0=0x00000000 ss1=0x00000000 gate=0xffffff8f\n[50HX] done\n' > "${TMP}/esp.log"
CLEAN="${TMP}/esp.log"; RAN="yes"; JOURNAL=""
expect "collect: fresh log -> efi=verdict" "efi=power-cycle" "$(run "$CBLK")"
JOURNAL="Nov 12 07:00 host cmp90hx-claim: gen2-claim: canary AON=alive PBUS=intact verdict=no-event efi@0x1480=0x0164c0de slot@0x1484=0x0165cafe ss0=0x88888888 ss1=0x00000008 gate=0xffffffff"
expect "collect: log+journal -> joined efi;claim" "efi=power-cycle;claim=no-event" "$(run "$CBLK")"
RAN="stale-log"
expect "collect: stale log quarantined (journal only)" "claim=no-event" "$(run "$CBLK")"
RAN="yes"; CLEAN="${TMP}/missing.log"; JOURNAL=""
expect "collect: no log + no journal -> EMPTY (pre-feature)" "" "$(run "$CBLK")"
printf '[CANARY] AON=alive PBUS=intact verdict=no-event efi@0x1480=0x0164c0de claim@0x1484=0x00000000 ss0=0x88888888 ss1=0x00000008 gate=0xffffffff\n[CANARY] AON=alive PBUS=intact verdict=rewritten efi@0x1480=0xdeadbeef claim@0x1484=0x00000000 ss0=0x88888888 ss1=0x00000008 gate=0xffffffff\n' > "${TMP}/esp2.log"
CLEAN="${TMP}/esp2.log"
expect "collect: repeated lines -> LAST one wins" "efi=rewritten" "$(run "$CBLK")"
exit $fails
EOF
rc=0
TMP="$TMP" bash "${TMP}/collect_canary_test.sh" "$CBLK" | sed 's/^/  [csv] /' || rc=$?
[ "$rc" -eq 0 ] && pass "collect canary-column harness green" || fail "collect canary-column harness (rc=$rc)"

# ==================== 3. call-site structure ====================
if python3 - "$SRC" "$CLAIM" "$COLLECT" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
claim = open(sys.argv[2]).read()
collect = open(sys.argv[3]).read()
fails = 0
def chk(name, cond):
    global fails
    if cond: print("PASS " + name)
    else: print("FAIL " + name); fails += 1

# ---- EFI: main-flow arm/classify placement ----
mstart = src.index("EFI_STATUS\nefi_main(")
main = src[mstart:]

cls = main.index("u40x_canary_classify();")
arms = [m.start() for m in re.finditer(r"u40x_canary_arm\(\);", main)]
arm1 = main.index("if (direct_write_probe()) {")
arm2 = main.index("if (is_unlocked())\n        u40x_canary_arm();")

chk("EFI: classify called exactly once, before the [2b] pre-flight gate",
    main.count("u40x_canary_classify();") == 1
    and cls < main.index("u40x_preflight_config()"))
# "before any write anywhere": between efi_main entry and the classify
# call, main() itself must not call any write primitive nor any function
# of the unlock flow that writes. (The command-register MEM-enable in
# u40x_enable_bar is config space and is WHAT makes the BAR0 read
# meaningful — B2's CANARY-PRE runs under the same condition.)
pre = main[:cls]
chk("EFI: no write primitive call between efi_main entry and [2a]",
    "mmio_write32(" not in pre and "cfg_write32(" not in pre
    and "u40x_pci_wbdf(" not in pre)
for bad in ("direct_write_probe", "gsp_engine_reset", "fwsec_boot_gsp",
            "booter_load_tu102_direct"):
    chk(f"EFI: [2a] precedes the first writing flow step ({bad})", bad not in pre)

chk("EFI: exactly two arm call sites", len(arms) == 2)
chk("EFI: arm #1 is inside the direct-write success branch",
    arm1 < arms[0] < main.index("goto done;", arm1))
chk("EFI: arm #2 gated by is_unlocked() and after the sanitize tail",
    arm2 < arms[1] < arm2 + 200 and "sanitize" in main[max(0, arm2 - 3000):arm2])

# ALREADY_MODIFIED classifies (at [2a]) but NEVER arms; PARTIALLY likewise;
# refusal paths likewise.
cold = main.index("if (cs == COLD_ALREADY) {")
cold_end = main.index("goto done;", cold)
chk("EFI: ALREADY_MODIFIED branch reaches no arm call (skip precedes both)",
    "u40x_canary_arm" not in main[cold:cold_end] and cold_end < min(arms))
part = main.index("if (cs == COLD_PARTIAL) {")
part_end = main.index("goto done;", part)
chk("EFI: PARTIALLY_MODIFIED refusal reaches no arm call",
    "u40x_canary_arm" not in main[part:part_end])
pre_ok = main[main.index("PREFLIGHT config-space validation FAILED"):main.index("detect_fb_size(ImageHandle);")]
chk("EFI: PREFLIGHT refusal reaches no arm call", "u40x_canary_arm" not in pre_ok)

# each actor owns its slot
arm = src[src.index("static void\nu40x_canary_arm"):src.index("/* ==== Pre-flight config-space validation")]
chk("EFI: arm body writes only CANARY_REG_EFI; nothing ever writes the claim slot",
    arm.count("mmio_write32(") == 1 and "CANARY_REG_EFI" in arm
    and "mmio_write32(CANARY_REG_CLAIM" not in src)

# ---- claim script ----
chk("claim: classify called exactly once, before the insmod claim work",
    claim.count("\ncanary_read_classify\n") == 1
    and claim.index("\ncanary_read_classify\n") < claim.index('insmod "$KO"'))
chk("claim: classify runs after the disabled/device-absent guards "
    "(non-90HX hosts emit nothing)",
    claim.index("10de:220d") < claim.index("\ncanary_read_classify\n")
    and claim.index("device absent") < claim.index("\ncanary_read_classify\n"))
armc = claim.index("if (( claim_ok )); then canary_arm; fi")
ins = claim.index("rmmod gpu_unlock")
chk("claim: arm is success-only (claim_ok set ONLY in the claim-ok branch)",
    claim.count("claim_ok=1") == 1
    and claim.index("claim-ok ${landed}/6") < claim.index("claim_ok=1") < armc)
chk("claim: arm lands after rmmod — module fully released the card", armc > ins)
chk("claim: both gen1-fallback paths leave claim_ok=0 (no arm)",
    claim.count("gen1-fallback") >= 2
    and len(re.findall(r"canary_arm[;(]", claim)) == 2)  # def + the 1 call
blk = claim[claim.index("# CANARY-BEGIN"):claim.index("# CANARY-END")]
chk("claim: only the CLAIM slot is ever written here; EFI slot read-only",
    blk.count("bar0_write ") == 1
    and "$CANARY_CLAIM_SLOT" in blk.split("bar0_write ")[1][:40]
    and 'bar0_write "$CANARY_EFI_SLOT"' not in claim)
chk("claim: slot convention constants match the EFI (0x1480/0x1484, 0164c0de/0165cafe)",
    all(s in blk for s in ("CANARY_EFI_SLOT=0x1480", "CANARY_CLAIM_SLOT=0x1484",
                           "CANARY_EFI_MAGIC=0x0164c0de", "CANARY_CLAIM_MAGIC=0x0165cafe")))

# ---- collect script ----
hdr_old = ("boot_utc,collect_utc,boot_id,stamp,efi_ran,layout,preflight,"
           "verdicts,ss0,drm_minor0,nvml_count,tflops,dmesg_wpr2,log_path")
chk("collect: CSV header gains canary as the LAST column (existing order intact)",
    hdr_old + ",canary" in collect)
chk("collect: verdicts from the ESP [CANARY] line + cmp90hx-claim journal",
    "\\[CANARY\\]" in collect and "journalctl -t cmp90hx-claim" in collect
    and 'CANARY="efi=$CE"' in collect and "claim=$CC" in collect)
chk("collect: empty stays empty (pre-feature boot renders no verdict text)",
    'CANARY=""' in collect)

print("ALL-PASS" if not fails else f"{fails} FAILURES")
sys.exit(1 if fails else 0)
PYEOF
then pass "call-site structure gates"
else fail "call-site structure gates"
fi

# ==================== 4. syntax gates ====================
bash -n "$CLAIM"    && pass "bash -n cmp90hx-claim.sh"
bash -n "$COLLECT"  && pass "bash -n cmp50hx-collect.sh"
bash -n "${BASH_SOURCE[0]}" && pass "bash -n reset-canary-selftest.sh"

if [ "$fails" -gt 0 ]; then echo "reset-canary-selftest: $fails FAILURES"; exit 1; fi
echo "reset-canary-selftest: canary matrix + call-site gates green"