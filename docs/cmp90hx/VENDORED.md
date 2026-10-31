# cmp90hx-unlock (GA102 / CMP 90HX) — vendored material

> **Rebased for 615.78.08 (2026-10-31, 615-port ticket 05).** The
> `0014-6104303-*` … `0018-6104303-*` filenames are kept deliberately: the
> `6104303` stamp identifies WildFlash1st's upstream **series lineage**
> (which base they were authored against), not what they apply to here.
> The file **contents** are regenerated tree-diffs against NVIDIA
> `615.78.08`, zero-fuzz: the rejoin14 scrubber intercept re-anchors onto
> `kgspPrepareScrubberImageIfNeeded_TU102` (615 moved it out of
> `kernel_gsp.c` and dispatches it for GA102 too), the WPR2 already-up gate
> re-anchors around upstream's new `kbifCheckResetStatus_HAL` block, and the
> renamed `KernelGsp` members (`pWprMetaV1`, `pWprMetaV1Descriptor`) are
> applied to all added lines. `patches/both/01` and the new
> `patches/both/04-…-rebased-on-cmp90hx.patch` carry the mixed-fleet merge
> (including the ISSUE-15 FWSEC re-arm). Re-verify against
> `docs/cmp90hx/success-recipe.md` constants per the 615 re-baseline tickets.

Source: https://github.com/WildFlash1st/cmp90hx-unlock, commit
`76940ae583281daa2b883518a2e89b56c11d3a46` (2026-08-22), license GPL-2.0.

What was vendored and why:

| Here | Upstream | Note |
|---|---|---|
| `patches/cmp90hx/0014-*.patch` | `driver/patches/cmp90-rejoin15/` | CMP 90HX GSP stockflow, 610.43.03, targets `10de:220d/1555` directly (no PCI-ID sed adaptation needed — that hack is only for the `cmp90` profile's `0x20B0` base) |
| `patches/cmp90hx/0015-*.patch` | same | serialized-start + multigpu-state follow-up |
| `docs/cmp90hx/rejoin15-README.md` | same dir README | profile notes |

Not vendored (kept upstream): `cmp170hx/` + `cmp90/` profiles (other
driver versions/cards), `driver/build.sh` (superseded by this repo's
`build.sh --card cmp90hx`), `analysis/`, RPC traces, install/remove scripts.

Upstream also documents a conftest workaround (force `<linux/stdarg.h>`) in
their build.sh — not needed on our kernel/toolchain so far; if the combined
build hits stdarg conftest failures, port that sed block.
