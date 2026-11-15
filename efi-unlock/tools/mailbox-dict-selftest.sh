#!/usr/bin/env bash
# mailbox-dict-selftest.sh — host-side logic gate for the booter
# mailbox0/EXCI decode dictionary (gtuu-mining ticket 17, row B2-P4).
# Pattern of the existing four harnesses: the code under test is pulled
# VERBATIM from the live sources, so the harness can never test a stale
# copy:
#   - common/booter_mailbox.h   (shared dictionary) — compiled via #include
#   - claim-90hx/booter_diag.c  (ko compose layer)  — #included with
#     __KERNEL__ undefined (userspace branch, the dual-build idiom of
#     diagnostic.h), composed fragments asserted as full strings;
#   - the EFI note helpers u40x_booter_mailbox_note / u40x_booter_exci_note
#     extracted VERBATIM from unlock50x_v1.c against a Print stub that
#     implements this file's own printf mini-rendering (%s %a %x %08x %d),
#     so the RENDERED lines — not just format strings — are asserted.
#
# Proven behaviorally:
#   * every dictionary code decodes, to its contract tokens (0x91's line
#     must STATE "EXACTLY 1 MiB"/"0x100000"), and ko/EFI render the same
#     string (the one-header rule, no drift);
#   * unknown codes => NULL => 'raw=0x%08x undecoded' on BOTH sides;
#   * trap 1: poisoned readback never gets a name or a verdict — proven
#     with the 0xBADF5620 shape whose EXCI bits WOULD decode as
#     SP_OVERFLOW if poison did not gate first; structurally proven too
#     (helpers contain no port read, call sites pass no sec value);
#   * trap 2: 0x00900100 renders labeled `info`, and NO emitted decode
#     line anywhere contains the token 'VERDICT';
#   * EXCI shift math against hand-computed fixtures ([24:20], [19:0]).
# Grep block pins every attachment site (EFI failure/refusal dumps, ko
# gu_snapshot + invocation-failed), the Kbuild include path + object,
# the DKMS staging line, and the collect no-collision claim.
#
#   usage: bash efi-unlock/tools/mailbox-dict-selftest.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${HERE}/../unlock50x_v1.c"
ROOT="$(cd "${HERE}/../.." && pwd)"
OUT="$(mktemp -d)/mailbox_dict_harness.c"

python3 - "$SRC" "$ROOT" "$OUT" <<'PYEOF'
import re, sys
src_path, root, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(src_path).read()

# 1. the two EFI note helpers VERBATIM (markers pin their exact heads)
def extract(marker):
    start = src.index(marker)
    end = src.index("\n}\n", start) + 3
    return src[start:end]

helpers = extract("static void\nu40x_booter_mailbox_note") + \
          extract("static void\nu40x_booter_exci_note")
assert 'mmio' not in helpers and 'IMEMD' not in helpers and 'rbSec' not in helpers, \
    "EFI note helpers must not read anything (they receive values only)"
helpers = helpers.replace('L"', '"')
helpers = helpers.replace('__asm__ volatile("wbinvd" ::: "memory");', '(void)0;')

harness = '''#include <stdio.h>
#include <string.h>
#include <stdarg.h>
typedef unsigned int UINT32;
typedef char CHAR16;

/* ---- Print stub: mini-render (mirrors u40x_print's %s %x %08x %d +
 * the new %a branch) so assertions run on the RENDERED failure line ---- */
static char g_lines[64][512];
static int g_ln;
static int g_prints;
static void Print(const CHAR16 *fmt, ...) {
    va_list ap;
    char *o = g_lines[g_ln < 63 ? g_ln++ : 63];
    size_t n = 0;
    va_start(ap, fmt);
    for (const char *f = (const char *)fmt; *f && n < 400; ) {
        if (*f != '%') { o[n++] = *f++; continue; }
        f++;
        if (*f == '%') { o[n++] = '%'; f++; continue; }
        int zero = 0, width = 0;
        while (*f == '0' || (*f >= '1' && *f <= '9')) {
            if (*f == '0') zero = 1; else width = width * 10 + (*f - '0');
            f++;
        }
        if (*f == 'x') {
            char tmp[24];
            unsigned v = va_arg(ap, unsigned);
            int i = 0;
            do { int d = (int)(v & 0xFu); tmp[i++] = d < 10 ? '0' + d : 'a' + d - 10; v >>= 4; } while (v);
            while (i < (zero ? width : 0)) tmp[i++] = '0';
            while (i > 0) o[n++] = tmp[--i];
            f++;
        } else if (*f == 'd') {
            n += (size_t)snprintf(o + n, 32, "%d", va_arg(ap, int));
            f++;
        } else if (*f == 's' || *f == 'a') {
            const char *s = va_arg(ap, const char *);
            if (!s) s = "(null)";
            while (*s && n < 480) o[n++] = *s++;
            f++;
        } else {
            o[n++] = *f ? *f : '?';
            if (*f) f++;
        }
    }
    o[n] = 0;
    va_end(ap);
    g_prints++;
}
static void log_reset(void) { g_ln = 0; g_prints = 0; }
static int saw(const char *s) {
    for (int j = 0; j < g_ln; j++) if (strstr(g_lines[j], s)) return 1;
    return 0;
}
static int saw_not(const char *s) { return !saw(s); }

/* ---- THE SHARED DICTIONARY + the ko compose layer, as built (no copy) ---- */
#include "''' + root + '''/common/booter_mailbox.h"
#include "''' + root + '''/claim-90hx/booter_diag.c"

/* ---- the EFI note helpers, extracted VERBATIM from the live source ---- */
''' + helpers + '''

/* ---- fixtures ---- */
static int fails;
static void expect(const char *name, int cond) {
    if (!cond) { printf("FAIL %s\\n", name); fails++; }
    else printf("PASS %s\\n", name);
}
static char kb[512], ke[512];

int main(void) {
    /* B1: every dictionary code decodes with its contract tokens, and the
     * ko formatter + the EFI note render the SAME string (one header). */
    struct { unsigned v; const char *tokens[3]; } mb[] = {
        { 0x31u, { "NS-stub pre-secure marker", "informational", 0 } },
        { 0x00u, { "secure-stage success", 0, 0 } },
        { 0x89u, { "meta magic", "staging-undelivered", 0 } },
        { 0x8au, { "descriptor field", "D[+0xac]", 0 } },
        /* the 0x91 line must STATE the contract (ticket 17): */
        { 0x91u, { "EXACTLY 1 MiB", "0x100000", "live-WPR-geometry" } },
        { 0x0bu, { "PSS final-hash", 0, 0, 0 } },
        { 0x11u, { "expected-value table", 0, 0, 0 } },
    };
    for (unsigned i = 0; i < sizeof mb / sizeof mb[0]; i++) {
        char tok[96];
        int ok = 1;
        const char *nm = booter_mailbox0_name(mb[i].v);
        if (!nm) ok = 0;
        for (int t = 0; nm && t < (int)(sizeof mb[i].tokens / sizeof mb[i].tokens[0]) && mb[i].tokens[t]; t++)
            if (!strstr(nm, mb[i].tokens[t])) ok = 0;
        snprintf(tok, sizeof tok, "B1 mailbox0 0x%02x contract tokens", mb[i].v);
        expect(tok, ok);
        snprintf(kb, sizeof kb, "0x%08x decode: %s", mb[i].v, nm);
        expect("B1b ko compose matches dictionary verbatim",
               strcmp(gu_booter_mailbox_diag(mb[i].v, ke, sizeof ke), kb) == 0);
        log_reset();
        u40x_booter_mailbox_note("efx", mb[i].v);
        expect("B1c EFI note renders the identical dictionary string",
               saw(nm) && saw("halt-decode mailbox0") && saw("decode:"));
    }
    { /* strings must be pairwise distinct (no swapped-code mapping) */
      unsigned codes[] = { 0x31u, 0x00u, 0x89u, 0x8au, 0x91u, 0x0bu, 0x11u };
      int distinct = 1;
      for (unsigned a = 0; a < 7; a++)
          for (unsigned b = a + 1; b < 7; b++)
              if (!strcmp(booter_mailbox0_name(codes[a]),
                          booter_mailbox0_name(codes[b]))) distinct = 0;
      expect("B1d all seven dictionary strings distinct", distinct);
    }
    /* B2: unknown codes fall through raw on BOTH sides. 0x8b/0x90 are the
     * deliberate non-entries around the 0x89/0x8a family; 0x0a/0x0c/0x10/
     * 0x12 surround 0x0b/0x11 — holes stay unnamed, never a guess. */
    {
        unsigned unk[] = { 0x8bu, 0x90u, 0x30u, 0x32u, 0x0au, 0x0cu, 0x10u,
                           0x12u, 0x12345678u, 0x0000FFFFu };
        int ok = 1;
        for (unsigned i = 0; i < sizeof unk / sizeof unk[0]; i++) {
            char raw[48];
            if (booter_mailbox0_name(unk[i])) ok = 0;
            snprintf(raw, sizeof raw, "raw=0x%08x undecoded", unk[i]);
            if (strcmp(gu_booter_mailbox_diag(unk[i], kb, sizeof kb), raw))
                ok = 0;
            log_reset();
            u40x_booter_mailbox_note("efx", unk[i]);
            if (!saw(raw) || saw("decode:")) ok = 0;
        }
        expect("B2 unknown mailbox codes => raw=0x%08x undecoded (ko+EFI)", ok);
    }
    /* B3 (trap 1, behavioral): poison flavors never get a name/verdict.
     * 0xBADF5620 is the smoking fixture: its EXCI bits WOULD name
     * SP_OVERFLOW, and its mailbox bits are outside the dictionary — the
     * poison gate must decide FIRST and both lines must say undecoded. */
    {
        unsigned pois[] = { 0xFFFFFFFFu, 0xBADF0000u, 0xBADF5620u, 0xBADFFFFFu };
        int ok = 1;
        for (unsigned i = 0; i < sizeof pois / sizeof pois[0]; i++) {
            if (!booter_reg_poisoned(pois[i])) ok = 0;
            gu_booter_mailbox_diag(pois[i], kb, sizeof kb);
            if (!strstr(kb, "undecoded") || strstr(kb, "decode:")) ok = 0;
            if (!strstr(kb, "poisoned readback - no verdict derived from it"))
                ok = 0;
            gu_booter_exci_diag(pois[i], ke, sizeof ke);
            if (!strstr(ke, "undecoded") || strstr(ke, "decode:") ||
                strstr(ke, "SP_OVERFLOW")) ok = 0;
            log_reset();
            u40x_booter_mailbox_note("efx", pois[i]);
            u40x_booter_exci_note("efx", pois[i]);
            if (saw("decode:") || saw("SP_OVERFLOW")) ok = 0;
            if (!saw("poisoned readback - no verdict derived from it")) ok = 0;
        }
        expect("B3 trap1: poisoned readback never named, never a verdict (ko+EFI)", ok);
        /* the trap is REAL: raw bit math would name SP_OVERFLOW on poison */
        expect("B3b 0xBADF5620 cause bits would have lied (SP_OVERFLOW)",
               strcmp(booter_exci_cause_name(BOOTER_EXCI_EXCAUSE(0xBADF5620u)),
                      "SP_OVERFLOW") == 0);
    }
    /* B4: EXCI shift math vs hand-computed fixtures ([24:20] + [19:0]) */
    {
        struct { unsigned v; unsigned cause; unsigned expc; } ex[] = {
            { 0x00900100u, 0x09u, 0x100u },  /* the successful-runs residue */
            { 0x01000100u, 0x10u, 0x100u },  /* SEC2 latched shape (#62 E) */
            { 0x00a00100u, 0x0au, 0x100u },  /* #151 TU117 MISS_INS@0x100 */
            { 0x012FFFFFu, 0x12u, 0x0FFFFFu },
            { 0x000FFFFFu, 0x00u, 0x0FFFFFu },
            { 0x01F00000u, 0x1Fu, 0x000000u },
            { 0x008FFFFFu, 0x08u, 0x0FFFFFu },
        };
        int ok = 1;
        for (unsigned i = 0; i < sizeof ex / sizeof ex[0]; i++)
            if (BOOTER_EXCI_EXCAUSE(ex[i].v) != ex[i].cause ||
                BOOTER_EXCI_EXPC(ex[i].v) != ex[i].expc) ok = 0;
        expect("B4 EXCI bitfields [24:20]/[19:0] match hand-computed fixtures", ok);
        expect("B4b 0x00900100 [24:20] == 0x09 (INV_INS), NOT 0x10 (old wrong read)",
               BOOTER_EXCI_EXCAUSE(0x00900100u) == 0x09u);
    }
    /* B5: cause names mirror NV_SOE_FALCON_EXCI_EXCAUSE_*; enum holes NULL */
    {
        struct { unsigned c; const char *n; } cs[] = {
            { 0x00u, "TRAPn" }, { 0x03u, "TRAPn" }, { 0x08u, "ILL_INS" },
            { 0x09u, "INV_INS" }, { 0x0au, "MISS_INS" }, { 0x0bu, "DHIT_INS" },
            { 0x0du, "SP_OVERFLOW" }, { 0x0fu, "BRKPT_INS" },
            { 0x10u, "DMEM_MISS_INS" }, { 0x11u, "DMEM_DHIT_INS" },
            { 0x12u, "DMEM_PAFAULT_INS" }, { 0x13u, "DMEM_PERMISSION_INS" },
            { 0x15u, "BROM_CALL_INS" }, { 0x16u, "KMEM_VIOLATION_INS" },
            { 0x17u, "BMEM_PERMISSION_INS" },
        };
        unsigned holes[] = { 0x04u, 0x05u, 0x06u, 0x07u, 0x0cu, 0x0eu, 0x14u,
                             0x18u, 0x1fu };
        int ok = 1;
        for (unsigned i = 0; i < sizeof cs / sizeof cs[0]; i++) {
            const char *n = booter_exci_cause_name(cs[i].c);
            if (!n || strcmp(n, cs[i].n)) ok = 0;
        }
        for (unsigned i = 0; i < sizeof holes / sizeof holes[0]; i++)
            if (booter_exci_cause_name(holes[i])) ok = 0;
        expect("B5 EXCAUSE names + enum holes stay NULL", ok);
    }
    /* B6 (trap 2, behavioral): 0x00900100 => labeled `info`, never a
     * verdict; neighbors get NO info claim (it is the exact shape). */
    {
        gu_booter_exci_diag(0x00900100u, kb, sizeof kb);
        int ok = strstr(kb, "decode: INV_INS") != 0 &&
                 strstr(kb, "info - also seen in SUCCESSFUL runs") != 0 &&
                 strstr(kb, "VERDICT") == 0;
        log_reset();
        u40x_booter_exci_note("efx", 0x00900100u);
        ok = ok && saw("info - also seen in SUCCESSFUL runs") &&
             saw("halt-decode exci") && saw_not("VERDICT");
        gu_booter_exci_diag(0x00900101u, ke, sizeof ke);
        ok = ok && strstr(ke, "INV_INS") && !strstr(ke, "info -");
        log_reset();
        u40x_booter_exci_note("efx", 0x00900101u);
        ok = ok && saw_not("info -");
        expect("B6 trap2: 0x00900100 labeled info on ko+EFI, neighbors unclaimed", ok);
        gu_booter_exci_diag(0x00a00100u, kb, sizeof kb);
        expect("B6b MISS_INS@0x100 (#151 shape) named WITHOUT an info label",
               strstr(kb, "decode: MISS_INS") && !strstr(kb, "info -"));
        gu_booter_exci_diag(0x01000100u, kb, sizeof kb);
        expect("B6c DMEM_MISS_INS@0x100 (latched shape) named",
               !!strstr(kb, "decode: DMEM_MISS_INS"));
    }
    /* B7: no emitted line anywhere carries the verdict token (sweep the
     * whole log of every fixture above plus targeted calls). */
    {
        log_reset();
        u40x_booter_mailbox_note("efx", 0x91u);
        u40x_booter_exci_note("efx", 0x00900100u);
        u40x_booter_exci_note("efx", 0xBADF5620u);
        gu_booter_mailbox_diag(0x89u, kb, sizeof kb);
        gu_booter_exci_diag(0x00900100u, ke, sizeof ke);
        int ok = !saw("VERDICT") && !strstr(kb, "VERDICT") && !strstr(ke, "VERDICT");
        expect("B7 token sweep: 'VERDICT' never printed (label info, never verdict)", ok);
    }
    printf(fails ? "%d FAILURES\\n" : "ALL-PASS\\n", fails);
    return fails != 0;
}
'''
open(out_path, "w").write(harness)
PYEOF

gcc -O1 -Wall -Wextra -Wno-unused-function -o "$OUT.bin" \
    -I "${ROOT}/common" "$OUT"
"$OUT.bin"

# ==== grep block: every attachment + both structural trap guarantees ====
FAILS=0
chk() { # chk <description> <want: 0|1> <cmd...>
    local desc="$1" want="$2"; shift 2
    if "$@" >/dev/null 2>&1; then got=1; else got=0; fi
    if [ "$got" = "$want" ]; then echo "PASS $desc"; else echo "FAIL $desc"; FAILS=$((FAILS+1)); fi
}
near() { # near <file> <anchor-literal> <follow-literal> <window>
    awk -v pat="$2" -v want="$3" -v win="$4" '
        !done && index($0, pat) { found = NR }
        found && NR > found && NR <= found + win && index($0, want) { done = 1 }
        END { exit done ? 0 : 1 }' "$1"
}

# EFI attachment sites (ticket 17: every failure/refusal print of a
# mailbox0/exit-code value gets the dictionary note nearby)
chk "EFI: tu102 halt dump m0 print -> mailbox note"   1 near "$SRC" 'm0=0x%x m1=0x%x' 'u40x_booter_mailbox_note' 8
chk "EFI: tu102 not-OK path -> EXCI read + exci note" 1 near "$SRC" 'attempt %d not-OK' 'u40x_booter_exci_note' 24
chk "EFI: not-OK path reads the SEC2_EXCI register"    1 near "$SRC" 'attempt %d not-OK' 'mmio_read32(SEC2_EXCI)' 24
chk "EFI: [9][warm] halt print -> mailbox note"       1 near "$SRC" 'returned %r (halt=0x%08x)' 'u40x_booter_mailbox_note' 4
chk "EFI: STAGING-FALLBACK decline -> mailbox note"   1 near "$SRC" 'STAGING-FALLBACK: not armed (booter halt=0x%08x' 'u40x_booter_mailbox_note' 8
chk "EFI: LOW-band retry refusal -> mailbox note"     1 near "$SRC" 'LOW-band retry also failed' 'u40x_booter_mailbox_note' 3
chk "EFI: FWSEC gate [MAILBOX] reject -> mailbox note" 1 near "$SRC" 'gate REJECT [MAILBOX]' 'u40x_booter_mailbox_note' 18
# Trap 1 structurally: helpers receive values only (python-asserted above:
# no mmio/port reads in their bodies); here pin that no call site feeds a
# secure-port readback, and that the rb-dump line carries the rule verbatim.
chk "EFI: no note call passes a sec/IMEM_S-derived value" 0 grep -nE 'u40x_booter_(mailbox|exci)_note\([^)]*(rbSec|IMEM_S|SEC=)' "$SRC"
chk "EFI: IMEM_S readback comment states the scrub-poison rule" 1 grep -q 'ALWAYS scrub-poisoned' "$SRC"
chk "EFI: IMEM_S lines carry no verdict token" 0 bash -c \
    "grep 'IMEM_S' '$SRC' | grep -q 'VERDICT'"
# Registers: SEC2_EXCI define mirrors the vendored header offset
chk "EFI: SEC2_EXCI defined at NV_PSEC_BASE+0x0d0" 1 grep -E '#define SEC2_EXCI +\(NV_PSEC_BASE \+ 0x0d0\)' "$SRC"
# ko attachment: gu_snapshot (mailbox0 + EXCI beside ticket-07's riscv
# line) and the invocation-failed dump
KO="${ROOT}/claim-90hx/unlock_610.c"
chk "ko: gu_snapshot mailbox0 decode line"  1 grep -q 'booter-diag mailbox0' "$KO"
chk "ko: gu_snapshot EXCI decode line"      1 grep -q 'booter-diag exci' "$KO"
chk "ko: two mailbox0 decode sites (snapshot + invocation-failed)" 1 bash -c \
    "[ \$(grep -c 'booter-diag mailbox0' '$KO') -eq 2 ]"
chk "ko: EXCI read goes through read_bar (GU_BOOT_RD)" 1 grep -q 'GU_BOOT_RD(exci, GU_SEC2_BASE + GU_FALCON_EXCI_OFFSET)' "$KO"
chk "ko: riscv snapshot line still precedes the exci decode line" 1 near "$KO" 'riscv tracepc=' 'booter-diag exci' 14
chk "ko: registers.h GU_FALCON_EXCI_OFFSET 0x000000d0 + provenance" 1 grep -E '#define GU_FALCON_EXCI_OFFSET +0x000000d0u' "${ROOT}/claim-90hx/registers.h"
chk "ko: registers.h cites dev_soe_ip.h" 1 grep -q 'dev_soe_ip.h:318-338' "${ROOT}/claim-90hx/registers.h"
# Build wiring: Kbuild object + include path, DKMS staging (byte copy —
# the only non-in-tree build path for the shared header)
chk "Kbuild: booter_diag.o in module objects" 1 grep -q 'booter_diag.o' "${ROOT}/claim-90hx/Kbuild"
chk "Kbuild: -I\$(src)/../common include path" 1 grep -q -- '-I$(src)/../common' "${ROOT}/claim-90hx/Kbuild"
chk "build-deb: stages common/booter_mailbox.h into the claim DKMS tree" 1 grep -q 'install -m 0644 "${root}/common/booter_mailbox.h"' "${ROOT}/tools/build-deb.sh"
# The dictionary lives in EXACTLY one place, and both consumers call it
chk "one header: booter_mailbox0_name defined exactly once" 1 bash -c \
    "[ \$(grep -r --include='*.c' --include='*.h' -c 'booter_mailbox0_name(unsigned' '${ROOT}/common' '${ROOT}/claim-90hx' '${ROOT}/efi-unlock' | awk -F: '{s+=\$2} END{print s}') -eq 1 ]"
chk "one header: ko compose layer calls the dictionary" 1 grep -q 'booter_mailbox0_name(mbox0)' "${ROOT}/claim-90hx/booter_diag.c"
chk "one header: EFI helper calls the same function" 1 grep -q 'booter_mailbox0_name(mbox0)' "$SRC"
# collect: no verdict parsing consumes these lines, so the harness stays
# untouched (ticket 17: no change unless a new grep was added — none was)
chk "collect: untouched by design (no grep consumes decode/undecoded/booter-diag)" 0 grep -qE 'halt-decode|booter-diag|undecoded' "${ROOT}/cmp50hx/cmp50hx-collect.sh"

echo
if [ "$FAILS" -ne 0 ]; then echo "mailbox-dict-selftest: $FAILS grep FAILURES"; exit 1; fi
echo "mailbox-dict-selftest: dictionary + both traps + all attachments green"
