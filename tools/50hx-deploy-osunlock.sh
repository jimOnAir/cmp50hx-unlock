#!/usr/bin/env bash
# Deploy the OS-side unlocker (the merged cmp50hx binary + bench-only unit +
# blobs) to llm2. osunlock stays a separate INVOCATION of cmp50hx: it must
# run with nvidia.ko absent, and its blobs are not redistributable, so it is
# not part of the .deb. The unit ships DISABLED by design: a failed booter
# attempt wedges the card (requires-reset). Enable only after ticket 12
# acceptance on a real lost-warm boot.
set -euo pipefail
B="${BENCH:-dmitry@192.168.3.58}"
D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

scp -q -r "$D/native" "$D/common" "$B:debug/50hx/"
scp -q "$D/tools/50hx-osunlock.conf" "$D/tools/50hx-osunlock.service" \
      "$D/tools/50hx-gate.sh" "$D/tools/50hx-gate.conf" "$B:debug/50hx/"
ssh "$B" 'set -e
cd ~/debug/50hx
make -C native
sudo install -m 0755 native/cmp50hx /usr/local/bin/cmp50hx
sudo mkdir -p /usr/local/share/50hx
for b in booter_ucode_prod.bin fwsec_50hx_prod.bin bl_gsp_tu102.bin; do
  [ -f /usr/local/share/50hx/$b ] || sudo cp ~/cmp50hx-orig/efi-unlock/blobs/$b /usr/local/share/50hx/
done
sudo cp ~/debug/50hx/50hx-osunlock.conf /etc/modprobe.d/
sudo cp ~/debug/50hx/50hx-osunlock.service /etc/systemd/system/
sudo install -m 0755 ~/debug/50hx/50hx-gate.sh /usr/local/sbin/50hx-gate
sudo cp ~/debug/50hx/50hx-gate.conf /etc/modprobe.d/
echo 5 | sudo tee /proc/sys/vm/nr_hugepages >/dev/null
grep -q nr_hugepages /etc/sysctl.d/99-50hx.conf 2>/dev/null || echo vm.nr_hugepages=5 | sudo tee /etc/sysctl.d/99-50hx.conf >/dev/null
sudo systemctl daemon-reload
# NOTE: deliberately NOT enabled — see header.
ls -la /usr/local/share/50hx/
/usr/local/bin/cmp50hx osunlock --help 2>/dev/null || true
echo OSUNLOCK_DEPLOYED'
