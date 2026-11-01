# 615-era experimental patches — NOT built by any profile

These patch series were written against the **615.78.08** source tree during
the 615 port/investigation (2026-10-31 → 2026-11-01) and are kept as evidence.
They are **not referenced** by `build.sh` (product pin = **610.43.03**, see
`driver-pin.env` and the closure `docs/CMP50HX-615-UNLOCK-INVESTIGATION.md` —
"stay on 610").

| file | what it was |
|---|---|
| `04-cmp50-pcie-gen2-rebased-on-cmp90hx.patch` | both-profile Gen2 rebase for the 615 tree (610-era both uses `cmp50hx/04` directly) |
| `09-lsvar-615-experiment.patch` | lsvar probe rc2 |
| `10-efionly-skip-stockflow.patch` · `11-efionly-stock-boot.patch` | EFI-only 615 interim mode (rc3) |
| `12-frame-variant-matrix.patch` · `13-v4-record-trust.patch` · `14-v7-shape-control.patch` | frame-matrix probes that produced the mechanism attribution (V1–V7, ticket 10–12 of 615-gen2-h2) |

Before any future driver bump, run the **six-step re-derivation checklist** in
`docs/CMP50HX-615-UNLOCK-INVESTIGATION.md` — this class of breakage lives
inside signed firmware and is invisible to normal porting. These files become
relevant again only as archaeological input for that bump.
