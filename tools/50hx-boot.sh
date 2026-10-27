#!/bin/bash
# 50hx-boot — single boot-flow unit (ticket 04 mechanism, merged 2026-10-27):
#   phase 1: archive ESP unlocker log + write ledger row (best-effort)
#   phase 2: health verdict + warm re-roll policy
# Merging fixed the old race where boothealth rebooted 20 s in before
# After=multi-user collect could ever run, losing re-roll-boot evidence.
# No PDU hardware (user decision): power-cycle cure for locked cards is manual.
set -u

# phase 1 — never let archival block or veto the health decision
timeout 30 /usr/local/bin/50hx-collect.sh >/run/50hx-boot-collect.log 2>&1 \
    || logger -t 50hx-boot -- "collect phase rc=$? (continuing)"

# phase 2 — exec so systemd sees the health exit status
exec /usr/local/sbin/50hx-boothealth "$@"
