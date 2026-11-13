# docker/ — pre-baked build & smoke images

One-time `apt-get` + a **bind-mounted `cache/`** replace the old ad-hoc
recipe that reinstalled packages and re-downloaded the 440 MB NVIDIA
`.run` inside a fresh container on every build (observed stalling at
100 kB/s; the host cache is sha-verified and already warm).

    docker build -t cmp50hx-build:latest -f docker/Dockerfile.build docker/
    docker build -t cmp50hx-smoke:latest -f docker/Dockerfile.smoke docker/

...or just run the wrapper, it builds them on first use:

    CMP_DEB_REV=20261113.gtuu9 bash tools/docker-deb.sh [--out DIR]

Facts measured 2026-11-13:

- warm run (images built, cache mounted): **~57 s** end to end
  (stage -> EFI -> deb -> 26.04 smoke -> artifacts + sha check), rc 0.
- `cmp50hx-build:latest` = ubuntu:24.04 + build deps (also runs the host
  harness scripts and `efi-unlock/build.sh`); `cmp50hx-smoke:latest` =
  ubuntu:26.04 + dpkg-dev, mirroring the CI matrix.
- Reproducibility: `tools/docker-deb.sh` sets `SOURCE_DATE_EPOCH` (from
  `git log -1`, overridable via env) — with it, two independent
  containers on the same tree produced a **byte-identical .deb**
  (`build-deb.sh` already honored the variable; without it consecutive
  builds differ in ~42 B of timestamps). The embedded EFI has always
  been byte-stable (`8237b24b…` across gtuu7/8).
- Cleanup: containers `chown` their `/src` writes back to the invoking
  uid so the temp build dir is removable without root.
