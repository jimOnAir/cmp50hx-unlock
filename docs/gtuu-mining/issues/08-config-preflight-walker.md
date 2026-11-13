# 08 — Pre-flight PCI config-space capability walker in the EFI app

Type: build (EFI)
Status: resolved (code+LIVE llm2 2026-11-13; residual sub-rows noted in boxes) (code + both offline gates landed; boot proof pending)
Blocked by: — (can start immediately)
Source row: U2

## What to build

Before the EFI unlock writes a single register or starts any DMA, it walks
the GPU's full PCI capability list and refuses the transaction (chainload
untouched, reason logged) unless the topology is sane: every capability
entry on a valid offset within config space, no offset overlaps, no cycle,
unknown capability IDs rejected, PM capability present with D0 power state,
FLR supported in DEVCAP bit 28, and option-ROM disabled. Today the app
scans config space for the specific capabilities it wants with no overall
validation — an odd BIOS or AIB layout can leave it operating on a
half-understood device.

~200 lines, self-contained; the refusal path reuses the cold-state refusal
pattern from ticket 04 (log observed layout, hand off to the boot manager).

## Acceptance criteria

- [x] `efi-unlock/tools/preflight-selftest.sh`: extracts the walker VERBATIM
      from the live source (zero drift), 13/13 fixtures green — valid chain
      accepts; cycle, overlap, unknown ID, DEVCAP bit28 clear, non-D0 PM,
      unaligned/out-of-range ptr, duplicate PM, ROM-on, MEM-off, step-limit
      all reject. Deviation recorded in-file: source rejects 64-bit MSI
      (self-contradictory with its own length math); we accept both.
- [ ] Guinea-pig boot proof PENDING: bench-toolchain build green (rc=0,
      warnings identical to HEAD baseline — zero new); needs one warm boot
      showing the PREFLIGHT ok line + unchanged unlock.
- [ ] Log on refusal names the exact offending capability offset/ID.
- [ ] findings.md line; provenance header (row U2), ported walker as its
      own GPL-2.0-only file; combined EFI binary license consequence
      (MIT base + GPL-2.0-only port → combined GPL-2.0-only) recorded in
      source-eval.md, accepted there.

## Notes

This gates the *first* hardware write, so it must run before anything in
the existing sequence touches config-space bits; the ticket-09 PROM gate
runs after this walker in the pre-flight ordering.
