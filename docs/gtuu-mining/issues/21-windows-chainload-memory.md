# 21 — Free staging pool before Windows bootmgr chainload (conditional)

Type: build (EFI) — conditional
Status: wontfix (2026-11-13 — owner: "windows is not needed"; the pool-free fix
is NOT ported. Carve-out from this very ticket implemented instead: the
largest-free-block line ships pre-chainload — u40x_log_memmap_stats +
pure walker u40x_memmap_stats, harness memmap-selftest.sh 7/7 under
ASan+UBSan, placed deliberately AFTER the ticket-19 final gate so the
gate stays the last MMIO-touching code.)
Blocked by: — (can start immediately)
Source rows: B2-P16 (docs/handoff-lowmem.en.md:9-70; chainload.rs:105-116)

## Question gating this ticket

Does ANY real deployment chainload Windows bootmgr through this EFI?
The fleet is Linux; the code path exists. B2 proved (issue #146) that a
resident >80 MB LOADER_DATA pool starves winload's single-descriptor boot
reservation into 0xc000009A, and fixed it by freeing the pool pre-chain
+ logging the largest free block. If the answer is yes, do it; if no,
close wontfix-with-note (keep the largest-block LOG line either way —
free evidence).

## Acceptance criteria (if activated)

- [N/A] (wontfix per owner answer — no Windows deployment exists).
- [x] Largest-free-block line logged pre-chain on every handoff
      (implemented + harness-gated 2026-11-13; live line arrives with the
      next EFI promotion).
