# 19 — Fresh-MMIO final gate before chainload handoff

Type: build (EFI)
Status: resolved (code+LIVE llm2 2026-11-13)
Blocked by: 18 (handoff-path serialization)
Source row: B2-P36-C4 (peer-pitfall-audit-ada §C4)

## What to build

The last thing the EFI does before StartImage/chainload must be a FRESH
read of the silicon state it claims to have established: FEAT PLM open,
SS0/SS1 at unlocked values, readout cluster agreeing. Not-as-true ⇒
refuse the handoff with a named line (chainload anyway WITHOUT claiming
success? — decision recorded in the ticket: default = chainload anyway,
log REFUSED-STATE loudly, since a locked boot must still boot; the gate
kills silent false-success, never availability). No log-callback or
allocation work on this path (their audit's companion finding: the gate
must be the last MMIO-touching code).

## Acceptance criteria

- [ ] Gate runs after sanitize, immediately pre-chainload; its reads use
      the existing sentinel-guarded primitive; zero allocations/prints on
      the MMIO path itself (log after).
- [ ] Harness: all-true pass; each field failing alone produces the exact
      named line; badf reads classify as UNTRUSTED, not as fail-open.
- [ ] Collect gains a final-gate column; one guinea-pig boot row in
      findings.md; byte-identical happy path otherwise.
