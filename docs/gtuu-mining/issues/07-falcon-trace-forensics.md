# 07 — Falcon failure forensics: RISC-V trace-PC / priv_err / hub_err dump

Type: build (claim-90hx)
Status: in-progress (code landed + compile gate; live negative proof + findings row pending)
Blocked by: — (can start immediately)
Source row: K15

## What to build

When the booter/Falcon chain halts on a stuck or trapping Falcon, the
claim module's existing snapshot-on-failure gains the fields that name the
fault: the RISC-V trace PC and its upper-word companion, and the
`riscv` / `rpc` / `priv_err` (+ faulting address) / `hub_err` register set.
The point: a T09-chain halt on a headless fleet host becomes diagnosable
from dmesg alone — the faulting address appears in the log, no bench visit,
no card swap.

## Critical gotcha to port verbatim (from the sweep)

The RISC-V debug block lives in the **falcon2 window**, not at
`base+0x388` — the naive offset reads garbage and looks like dead hardware.
Read only through the falcon2 aperture offsets proven upstream.

## Acceptance criteria

- [x] Failure path emits one new riscv dev_err line in gu_snapshot (the
      established snapshot-line idiom; read_bar reads only, snapshot runs
      only on first error — happy path untouched by construction).
- [x] Reads go through read_bar (records last read; failure flips ok=0 in
      the adjacent boot line; raw values printed as-is incl. sentinels).
- [x] Compile gate 7.2.9-1-MANJARO: rc=0, zero warnings (pending: the
      byte-identical happy-path dmesg check rides the guinea-pig boot).
- [ ] Guinea-pig warm boot: happy-path dmesg byte-identical to the pre-change rev.
- [ ] Negative proof: on the next real or injected halt (bench or shim
      once ticket 11 lands), the dump shows a sane trace PC; if no halt is
      available before close, a ctypes/BAR-stand replay of the read helpers
      against the fixture values is recorded instead.
- [ ] findings.md line; provenance header on any new file (row K15).
