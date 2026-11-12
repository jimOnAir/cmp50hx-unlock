/* booter_mailbox.h — SEC2 booter mailbox0/EXCI decode dictionary v3
 * (gtuu-mining ticket 17, row B2-P4).
 *
 * ONE shared header: included by the EFI unlocker
 * (efi-unlock/unlock50x_v1.c, `#include "../common/booter_mailbox.h"`)
 * and by the claim ko (claim-90hx/booter_diag.c — in-tree via the Kbuild
 * -I$(src)/../common flag, in the standalone DKMS tree via the byte
 * copy staged by tools/build-deb.sh next to the module sources). The
 * decoded names printed in failure dumps exist nowhere else, so EFI and
 * ko halt diagnostics cannot drift apart.
 *
 * Dictionary v3 sources (read-only reference sweep, nvuu-sweep):
 *   - loader/src/tx_booter.rs:782-840 — post-halt mailbox0 dictionary v3
 *     (mailbox0_verdict) and the EXCAUSE names (exci_cause_name);
 *   - docs/tu10x-booter-nsstub-disasm.md:62-75 — the NS-stub disassembly:
 *     the stub writes 0x31 right before its single `lcall 0x100` into the
 *     secure entry; §C3.3 the authoritative EXCI bitfields;
 *   - docs/tu10x-round3-conclusions.md:15 — the v3 semantic corrections:
 *     0x91 = WPR-window geometry check (descriptor-vs-live WPR2 regs
 *     0x1fa824/28, 64-bit delta must be EXACTLY 1 MiB — the race-fix
 *     mechanism), 0x89 = meta magic second compare, 0x8a = descriptor
 *     field (D[+0xac]) compare, 0x0b = PSS final-hash error code (dual
 *     GetParam id), 0x11 = GetParam expected-value table id.
 *
 * EXCI register provenance (offset AND bit layout, mirrored — not vibes):
 *   - vendored open-gpu-kernel-modules
 *     src/common/inc/swref/published/nvswitch/lr10/dev_soe_ip.h:318-338:
 *     NV_SOE_FALCON_EXCI 0x00d0, .EXPC 19:0, .EXCAUSE 24:20 with the
 *     NV_SOE_FALCON_EXCI_EXCAUSE_* constants whose names this table
 *     mirrors (Falcon IP common — same block on SEC2's Turing falcon);
 *   - live-silicon cross-check of the offset: B2 loader/src/tx.rs:308
 *     authority scan ("EXCI", 0x0d0) at SEC2 0x00840000 and
 *     loader/src/tx_booter.rs:581 halt forensics (SEC2 + 0x0d0).
 *     Consumers use the same window: the ko reads
 *     GU_SEC2_BASE + GU_FALCON_EXCI_OFFSET (claim-90hx/registers.h), the
 *     EFI reads SEC2_EXCI (NV_PSEC_BASE + 0x0d0) — bases already agreed
 *     in common/cmp50hx_regs.h lineage.
 *
 * TWO TRAPS encoded here as rules AND behavior (verbatim intent):
 *  (1) Turing `sec` readback is ALWAYS scrub-poisoned — the ns/dmem rows
 *      are the verdict. Nothing in this header consumes a secure-port
 *      readback value and no caller may print a sec-derived verdict;
 *      poisoned REGISTERS are caught by booter_reg_poisoned() and print
 *      no name.
 *  (2) `0x00900100` (INV_INS@0x100) appears in SUCCESSFUL runs too — the
 *      secure stage's terminal self-kill residue. booter_exci_info_class()
 *      labels it `info`; a line carrying it is never a verdict.
 *
 * Contract: every decoder returns a static string for KNOWN codes and
 * NULL for unknown ones — callers then print `raw=0x%08x undecoded`.
 * Never guess: a decoder that invents a meaning misdiagnoses the halt.
 * Inline-only, ASCII, no includes: safe for -ffreestanding EFI, kernel
 * and host-harness builds alike.
 */
#ifndef BOOTER_MAILBOX_H
#define BOOTER_MAILBOX_H

/* Poisoned readback: bus-gated all-ones or the gated-domain 0xBADF
 * prefix — the same predicate the FWSEC gate (ticket 14) and the ko's
 * inaccessible() apply. Trap (1) in code: a poisoned value is never
 * fed to a decoder, it prints as raw poison and stays non-verdict. */
static inline int booter_reg_poisoned(unsigned int v)
{
    return v == 0xFFFFFFFFu || (v & 0xFFFF0000u) == 0xBADF0000u;
}

/* Post-halt mailbox0 dictionary v3 (SEC2 falcon, MAILBOX0 = base+0x40).
 * Only codes with a source-pinned meaning are named; anything else —
 * including the input-carrier meta address the loader stores pre-start —
 * returns NULL so the caller prints the raw value, undecoded. */
static inline const char *booter_mailbox0_name(unsigned int v)
{
    switch (v) {
    case 0x31u:
        return "NS-stub pre-secure marker (informational, entry-level): the NS stub wrote it before `lcall 0x100` and the secure entry never executed - placement/entry failure, NOT a secure-stage rejection";
    case 0x00u:
        return "secure-stage success status (replay chains also end here)";
    case 0x89u:
        return "meta magic second compare failed on the live-WPR2 rebuild (0x89/0x8a meta-validation family) - the staging-undelivered class: the card-side DMA read of an intact host meta page never delivered (the ticket-15 ladder trigger, BOOTER_EXIT_STAGING_UNDELIVERED)";
    case 0x8au:
        return "meta descriptor field check failed (descriptor D[+0xac] vs the live WPR2/MMU state) - 0x89/0x8a meta-validation family";
    case 0x91u:
        return "live-WPR-geometry check failed - the meta-descriptor-vs-live-WPR2 (0x1fa824/0x1fa828) 64-bit delta must be EXACTLY 1 MiB (0x100000): the secure code RAN and rejected; our sub-4GiB read-lock class lands here (BOOTER_EXIT_SUB4G_READLOCK)";
    case 0x0bu:
        return "PSS final-hash stage: RSASSA-PSS final-hash mismatch (the GA booter also uses 0x0b as a GetParam id) - meta/WPR2 checks PASSED, the death is in the signature-verify domain";
    case 0x11u:
        return "GetParam expected-value table id (signature-struct parameter domain) - meta/WPR2 checks PASSED, the death is at/after signature verification";
    default:
        return 0; /* unknown - caller prints raw=0x%08x undecoded */
    }
}

/* NV_SOE_FALCON_EXCI field accessors (dev_soe_ip.h: EXPC 19:0,
 * EXCAUSE 24:20). The 2024-era annotation "EXCAUSE=0x10 for
 * 0x00900100" was WRONG: [24:20] of 0x00900100 is 0x09 (INV_INS). */
#define BOOTER_EXCI_EXPC_MASK  0x000FFFFFu
#define BOOTER_EXCI_EXCAUSE_SHL 20u
#define BOOTER_EXCI_EXCAUSE_MASK 0x1Fu
#define BOOTER_EXCI_EXPC(v)    ((v) & BOOTER_EXCI_EXPC_MASK)
#define BOOTER_EXCI_EXCAUSE(v) \
    (((v) >> BOOTER_EXCI_EXCAUSE_SHL) & BOOTER_EXCI_EXCAUSE_MASK)

/* EXCAUSE[24:20] names (NV_SOE_FALCON_EXCI_EXCAUSE_*, Falcon IP common).
 * NULL for unlisted causes - the cause enum has holes (0x4-0x7, 0xc,
 * 0xe, 0x14, 0x18-0x1f) and a decoder naming a hole would be guessing. */
static inline const char *booter_exci_cause_name(unsigned int cause)
{
    switch (cause) {
    case 0x00u: case 0x01u: case 0x02u: case 0x03u: return "TRAPn";
    case 0x08u: return "ILL_INS";
    case 0x09u: return "INV_INS";
    case 0x0au: return "MISS_INS";
    case 0x0bu: return "DHIT_INS";
    case 0x0du: return "SP_OVERFLOW";
    case 0x0fu: return "BRKPT_INS";
    case 0x10u: return "DMEM_MISS_INS";
    case 0x11u: return "DMEM_DHIT_INS";
    case 0x12u: return "DMEM_PAFAULT_INS";
    case 0x13u: return "DMEM_PERMISSION_INS";
    case 0x15u: return "BROM_CALL_INS";
    case 0x16u: return "KMEM_VIOLATION_INS";
    case 0x17u: return "BMEM_PERMISSION_INS";
    default:
        return 0; /* unknown - caller prints raw=0x%08x undecoded */
    }
}

/* Trap (2), as a function: the exact 0x00900100 shape (INV_INS at
 * EXPC 0x100, the secure entry) is the secure stage's terminal self-kill
 * residue — B2's guarded evidence pack shows it in fully SUCCESSFUL
 * runs. Non-NULL return means: this line is labeled `info`, it is never
 * a verdict by itself. Every other value returns NULL (no class claim). */
static inline const char *booter_exci_info_class(unsigned int exci)
{
    if (exci == 0x00900100u)
        return "info - also seen in SUCCESSFUL runs, not a verdict by itself (secure-stage terminal self-kill residue)";
    return 0;
}

#endif /* BOOTER_MAILBOX_H */
