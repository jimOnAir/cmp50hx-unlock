# 06 — Aperture-API feature detection instead of kernel-version gate

Type: build (claim-90hx)
Status: in-progress (code landed + gates; guinea-pig warm boot proof pending)
Blocked by: — (can start immediately)
Source row: K17

## What to build

The claim module's aperture-removal call site currently selects the API
shape by `LINUX_VERSION_CODE`. Replace that with `__has_include` feature
detection (probe for the header the modern call lives in, fall back to the
name-only compat form), so the module keeps building correctly on any
kernel in the fleet's actual range (5.15 through 7.2+) without another
version-threshold edit when a new kernel reorders symbols. The failure
mode this prevents: a version gate that's right today compiles the wrong
branch tomorrow with no build error until someone boots it.

## Acceptance criteria

- [x] Compiles clean, zero warnings, on two kernel generations natively
      (7.2.9-1-MANJARO + 6.18.55-1-MANJARO trees; noble container leg rides
      the next deb build).
- [x] Both branches proven: real builds resolve `U aperture_remove_conflicting_pci_devices`
      (nm) with zero `remove_conflicting_pci_framebuffers` refs; the #else
      branch compiles + runs against stub drm headers passing the
      "gpu_unlock" requester label through.
- [ ] Live proof: one warm boot on the guinea-pig host, claim-ok line green
      exactly as before (no behavior change — pure build-robustness port).
- [ ] findings.md line; commit message notes the source row (K17) and the
      provenance header added to any new compat file.

## Notes

Ported compat shim lands as a separate GPL-2.0-only file with the standard
provenance header (upstream URL @ 1d6a508 + row K17); the existing call
site itself stays GPL-2.0-only as it already is.
