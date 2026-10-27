# cmp90hx-unlock (GA102 / CMP 90HX) — vendored material

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
