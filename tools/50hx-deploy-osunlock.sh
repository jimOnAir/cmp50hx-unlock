#!/usr/bin/env bash
# deploy the OS-side unlocker stack to llm2
set -euo pipefail
B=dmitry@192.168.3.58
D=/home/dmitry/github/cmp50hx-unlock/tools
scp -q "$D/50hx-osunlock.c" "$B:debug/50hx/"
ssh "$B" 'cd ~/debug/50hx && gcc -O2 -Wall -o 50hx-osunlock 50hx-osunlock.c 2>&1 | grep -v unused-result | grep -v pread | grep -v pwrite | grep -v "^\s*[0-9]* |" | grep -v warning || true'
scp -q "$D/50hx-osunlock.conf" "$D/50hx-osunlock.service" "$B:debug/50hx/"
ssh "$B" 'set -e
sudo mkdir -p /usr/local/share/50hx
for b in booter_ucode_prod.bin fwsec_50hx_prod.bin bl_gsp_tu102.bin; do
  [ -f /usr/local/share/50hx/$b ] || sudo cp ~/cmp50hx-orig/efi-unlock/blobs/$b /usr/local/share/50hx/
done
sudo cp ~/debug/50hx/50hx-osunlock /usr/local/bin/
sudo cp ~/debug/50hx/50hx-osunlock.conf /etc/modprobe.d/
sudo cp ~/debug/50hx/50hx-osunlock.service /etc/systemd/system/
echo 5 | sudo tee /proc/sys/vm/nr_hugepages >/dev/null
grep -q nr_hugepages /etc/sysctl.d/99-50hx.conf 2>/dev/null || echo vm.nr_hugepages=5 | sudo tee /etc/sysctl.d/99-50hx.conf >/dev/null
sudo systemctl daemon-reload
# NOTE: deliberately NOT enabled — a failed booter attempt wedges the card
# (requires-reset) and would take llama down. Enable only after ticket 12
# acceptance on a real lost-warm boot.
ls -la /usr/local/share/50hx/
echo OSUNLOCK_DEPLOYED'
