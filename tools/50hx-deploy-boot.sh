#!/usr/bin/env bash
# Deploy the merged boot stack (collect + boothealth + 50hx-boot unit) to llm2
# and retire the per-function units + zombie services. Ticket 04/13, 2026-10-27.
set -euo pipefail
B="${BENCH:-dmitry@192.168.3.58}"
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

scp -q "$D/50hx-boot.sh" "$D/50hx-boot.service" \
      "$D/50hx-boothealth.sh" "$D/50hx-collect.sh" "$B:debug/50hx/"
ssh "$B" 'set -e
sudo install -m 0755 ~/debug/50hx/50hx-boot.sh /usr/local/sbin/50hx-boot
sudo install -m 0755 ~/debug/50hx/50hx-boothealth.sh /usr/local/sbin/50hx-boothealth
sudo install -m 0755 ~/debug/50hx/50hx-collect.sh /usr/local/bin/50hx-collect.sh
sudo cp ~/debug/50hx/50hx-boot.service /etc/systemd/system/
# retire per-function units and zombies (keep cmp50hx-gen2 unit + gputempd)
sudo systemctl disable --now 50hx-collect.service 50hx-boothealth.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/50hx-collect.service /etc/systemd/system/50hx-boothealth.service
sudo systemctl disable --now 50hx-osunlock.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/50hx-osunlock.service
systemctl is-enabled gpu-unwedge >/dev/null 2>&1 && { sudo systemctl disable gpu-unwedge 2>/dev/null || true; }
sudo rm -f /etc/systemd/system/gpu-unwedge.service
sudo systemctl daemon-reload
sudo systemctl enable 50hx-boot.service
systemctl list-unit-files --no-pager | grep -E "50hx|gpu-unwedge|cmp50hx-gen2" || true
echo BOOT_STACK_DEPLOYED'
