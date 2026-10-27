#!/usr/bin/env bash
# who-is-where.sh — bench card identity: bus ↔ sticker ↔ UUID.
# Run on the bench (ticket 02). Locked/uninitialised cards have no NVML
# UUID by definition: they show as bus+sticker with uuid=locked?. Never
# guess a UUID; the sticker is the truth when the card is dark.
# Usage: who-is-where.sh  (or piped over ssh)
set -uo pipefail

echo "bus      uuid         nvidia-smi name        note"
declare -A UUID_OF=() NAME_OF=()
while read -r line; do
    # "GPU-xxxx, NAME, 00000000:01:00.0"
    u=$(echo "$line" | cut -d, -f1 | sed 's/GPU-//;s/ //g')
    n=$(echo "$line" | cut -d, -f2 | xargs)
    busid=$(echo "$line" | cut -d, -f3 | tr -d ' ')
    bus10=${busid#00000000:}; bus10=${bus10%:00.0}
    [ -n "$u" ] && UUID_OF[$bus10]="${u:0:8}" && NAME_OF[$bus10]="$n"
done < <(nvidia-smi --query-gpu=uuid,name,pci.bus_id --format=csv,noheader 2>/dev/null)
for d in $(lspci -Dn -d 10de: | awk '{print $1}'); do
    b=${d#0000:}
    b=${b%:00.0}
    dev_id=$(lspci -n -s "$d" | awk '{print $3}' | cut -d: -f2)
    uuid="${UUID_OF[$b]:-locked?}"
    name="${NAME_OF[$b]:-1e09 locked/unknown}"
    note=""
    [ "$dev_id" = "220d" ] && note="GA102 (90HX class: unlocker ignores)"
    printf '%-8s %-12s %-20s %s\n' "$b" "$uuid" "$name" "$note"
done
echo
echo "console FACT (DRM card0): $(udevadm info -q property -n /dev/dri/card0 2>/dev/null | sed -n 's/^ID_PATH=pci-//p' | sed 's/\.0$//')"
echo "sticker check: match uuid prefixes against the labels on the cards (last 8 hex)."
