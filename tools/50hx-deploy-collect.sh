#!/usr/bin/env bash
# 50hx-deploy-collect.sh — install the per-boot collector on the bench
# and run it once against the CURRENT boot (validates logic without a
# reboot; the unit itself fires on the next boot).
set -euo pipefail
BENCH="${BENCH:-dmitry@192.168.3.58}"
SRC="$(cd "$(dirname "$0")" && pwd)"

rsync -a "$SRC/50hx-collect.sh" "$SRC/50hx-collect.service" "${BENCH}:/tmp/"
ssh "$BENCH" bash -s <<'EOF'
set -euo pipefail
sudo cp -f /tmp/50hx-collect.sh /usr/local/bin/50hx-collect.sh
sudo chmod 755 /usr/local/bin/50hx-collect.sh
sudo cp -f /tmp/50hx-collect.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable 50hx-collect.service
echo UNIT_ENABLED
EOF

# stage the FMA bench source permanently (tmpfs /tmp is empty after reboot;
# the collector rebuilds+runs it per boot)
ssh "$BENCH" 'mkdir -p ~/debug/50hx'
rsync -a "$SRC/fma_bench.c" "${BENCH}:debug/50hx/fma_bench.c"

echo "==> run collector against the current boot"
ssh "$BENCH" 'sudo HOME=/home/dmitry /usr/local/bin/50hx-collect.sh'
ssh "$BENCH" 'tail -3 ~/debug/50hx/ledger.csv'
