#!/usr/bin/env bash
# memmap-selftest.sh — offline gate for the ticket-21 carve-out walker
# (u40x_memmap_stats), extracted VERBATIM between the MEMMAP-STATS
# markers (same rule as every other selftest here). The ticket itself
# closed wontfix (no Windows deployment); the largest-free-block log line
# stays as free handoff evidence, and its walker gets a real fixture
# suite so "largest block" can never lie.
#   usage: bash efi-unlock/tools/memmap-selftest.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${HERE}/../unlock50x_v1.c"
OUT="$(mktemp -d)/mm_harness.c"

python3 - "$SRC" "$OUT" <<'PYEOF'
import sys
src = open(sys.argv[1]).read()
body = src[src.index("static void\nu40x_memmap_stats"):src.index("static void u40x_log_memmap_stats")]
harness = '''#include <stdio.h>
#include <string.h>
typedef unsigned char UINT8; typedef unsigned int UINT32;
typedef unsigned long long UINT64; typedef unsigned long UINTN;
typedef int BOOLEAN;
#define EfiConventionalMemory 0
#define EfiPersistentMemory 7
#define EFI_MEMORY_DESCRIPTOR EFI_MEMORY_DESCRIPTOR_
typedef struct {
    UINT32 Type; UINT64 PhysicalStart; UINT64 VirtualStart;
    UINT64 NumberOfPages; UINT64 Attribute;
} EFI_MEMORY_DESCRIPTOR_;
''' + body + '''
#define KB4 (4096ULL/4096ULL)
static int fails;
static void ck(const char *n, int c) { if (!c) { printf("FAIL %s\\n", n); fails++; } else printf("PASS %s\\n", n); }
static void add(UINT8 *buf, UINTN *off, UINT32 type, UINT64 pages) {
    EFI_MEMORY_DESCRIPTOR d; memset(&d, 0, sizeof d);
    d.Type = type; d.NumberOfPages = pages;
    memcpy(buf + *off, &d, sizeof d); *off += sizeof d;
}
int main(void) {
    UINT8 buf[64 * 32]; UINTN off = 0;
    UINT64 L; UINTN B;
    /* M1: mixed map, largest in the middle (pages x 4096: 256 pages = 1 MiB) */
    add(buf, &off, EfiConventionalMemory, 16 * 256);          /* 16 MiB */
    add(buf, &off, 3 /*BootServicesCode*/, 100);
    add(buf, &off, EfiConventionalMemory, 64 * 256);          /* 64 MiB = largest */
    add(buf, &off, 5 /*RuntimeServicesData*/, 50);
    add(buf, &off, EfiConventionalMemory, 32 * 256);          /* 32 MiB */
    u40x_memmap_stats((void *)buf, off, sizeof(EFI_MEMORY_DESCRIPTOR), &L, &B);
    ck("M1 largest = 64MB middle-position", L == 64ULL * 1024 * 1024 && B == 3);
    /* M2: empty map */
    u40x_memmap_stats((void *)buf, 0, sizeof(EFI_MEMORY_DESCRIPTOR), &L, &B);
    ck("M2 empty -> 0/0", L == 0 && B == 0);
    /* M3: dsz=0 guard (no infinite loop possible) */
    u40x_memmap_stats((void *)buf, off, 0, &L, &B);
    ck("M3 dsz=0 rejected", L == 0 && B == 0);
    /* M4: dsz below struct size rejected */
    u40x_memmap_stats((void *)buf, off, sizeof(EFI_MEMORY_DESCRIPTOR) - 1, &L, &B);
    ck("M4 undersized dsz rejected", L == 0 && B == 0);
    /* M5: truncated trailing descriptor ignored */
    /* M5: truncated trailing descriptor ignored — the cut 32 MiB conv entry
       must vanish from BOTH counters (proves the i+dsz<=sz bound) */
    u40x_memmap_stats((void *)buf, off - 5, sizeof(EFI_MEMORY_DESCRIPTOR), &L, &B);
    ck("M5 partial tail descriptor ignored", L == 64ULL * 1024 * 1024 && B == 2);
    /* M6: zero-page conventional descriptors do not count */
    off = 0;
    add(buf, &off, EfiConventionalMemory, 0);
    add(buf, &off, EfiConventionalMemory, 1);
    u40x_memmap_stats((void *)buf, off, sizeof(EFI_MEMORY_DESCRIPTOR), &L, &B);
    ck("M6 zero-page skipped, 4096 B counted", L == 4096ULL && B == 1);
    /* M7: NULL map guard */
    u40x_memmap_stats(NULL, 1000, sizeof(EFI_MEMORY_DESCRIPTOR), &L, &B);
    ck("M7 NULL map -> 0/0", L == 0 && B == 0);
    printf(fails ? "%d FAILURES\\n" : "ALL-PASS\\n", fails);
    return fails != 0;
}
'''
open(sys.argv[2], "w").write(harness)
PYEOF

gcc -O1 -Wall -Wextra -Wno-unused-parameter -fsanitize=address,undefined \
    -fno-sanitize-recover=all -o "$OUT.bin" "$OUT"
"$OUT.bin"
echo "memmap-selftest: largest-free walker green (extracted verbatim)"
