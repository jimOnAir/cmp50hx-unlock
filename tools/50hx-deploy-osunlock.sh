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
[ -f /usr/local/share/50hx/booter_ucode_prod.bin ] || sudo cp ~/cmp50hx-orig/efi-unlock/blobs/booter_ucode_prod.bin /usr/local/share/50hx/
sudo cp ~/debug/50hx/50hx-osunlock /usr/local/bin/
sudo cp ~/debug/50hx/50hx-osunlock.conf /etc/modprobe.d/
sudo cp ~/debug/50hx/50hx-osunlock.service /etc/systemd/system/
echo 4 | sudo tee /proc/sys/vm/nr_hugepages >/dev/null
echo "4" | sudo tee -a /etc/sysctl.d/99-50hx.conf >/dev/null 2>&1 || true
sudo systemctl daemon-reload
sudo systemctl enable 50hx-osunlock.service
ls -la /etc/modprobe.d/50hx-osunlock.conf /usr/local/bin/50hx-osunlock /usr/local/share/50hx/booter_ucode_prod.bin
echo OSUNLOCK_DEPLOYED'
