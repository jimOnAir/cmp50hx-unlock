#!/usr/bin/env bash
# cmp50hx-collect.sh — ONE BOOT -> ONE LEDGER ROW + archived ESP unlocker log.
# Bench-only phase of cmp50hx-boot.sh, run only with CMP_BOOT_COLLECT=1 in
# /etc/cmp50hx/boot.conf (the ledger paths below are bench paths).
# Best-effort by design: it must never break a boot.
#
# Ledger (CSV, header created on first run):
#   boot_utc          UTC boot wall-clock (uptime -s)
#   collect_utc       when this row was written
#   boot_id           kernel boot_id (join key for bootlogs/)
#   stamp             [build] git-stamp from the unlocker log (empty=stock/unknown)
#   efi_ran           yes|no|stale-log (was the ESP log written THIS boot?)
#   layout            per 10de card: bus:uuid-or-shelf
#   preflight         skip decisions from the log (console-gop / console-assumed)
#   verdicts          [multi] card N result summary (or single-card RESULT)
#   ss0               last SS0= seen per card (cur:SS0)
#   drm_minor0        PCI bdf backing /dev/dri/card0 (console FACT vs decision)
#   nvml_count        GPUs NVML can see
#   tflops            per-GPU FMA bench (skipped:busy when compute apps hold GPUs)
#   dmesg_wpr2        count of WPR2/RmInitAdapter hits
#   log_path          archived ESP log location
set -uo pipefail

BENCHDIR="/home/dmitry/debug/50hx"   # absolute: systemd User=root has HOME=/root (bit us 2026-10-26)
# primary = newest of the per-module ESP logs (U1/U4 chain builds)
 LOGSRC=$(ls -t /boot/efi/50hx_log_u1.txt /boot/efi/50hx_log_u3.txt /boot/efi/50hx_log_u4.txt /boot/efi/50hx_log.txt 2>/dev/null | head -1)
LOGSRC=${LOGSRC:-/boot/efi/50hx_log.txt}
LEDGER="$BENCHDIR/ledger.csv"
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '-')
ARCH="$BENCHDIR/bootlogs/$BOOT_ID"
BOOT_UTC=$(date -u -d "$(uptime -s)" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
BOOT_EPOCH=$(date -u -d "$(uptime -s)" +%s 2>/dev/null || echo 0)
mkdir -p "$ARCH"
# archive fresh secondary module logs alongside (chain builds write per-target files)
for ex in /boot/efi/50hx_log_u1.txt /boot/efi/50hx_log_u3.txt /boot/efi/50hx_log_u4.txt /boot/efi/50hx_log.txt; do
    [ "$ex" = "$LOGSRC" ] && continue
    [ -f "$ex" ] || continue
    Mx=$(stat -c %Y "$ex" 2>/dev/null || echo 0)
    BE=$(date -u -d "$(uptime -s)" +%s 2>/dev/null || echo 0)
    if [ "$BE" -gt 0 ] && [ "$Mx" -ge $((BE-300)) ] && [ "$Mx" -le $((BE+120)) ]; then
        tr -d '\r' < "$ex" > "$ARCH/$(basename "$ex")" 2>/dev/null
    fi
done

# ---- archive ESP log, detect "unlocker ran THIS boot" ------------------
# The unlocker writes the log PRE-OS, so its FAT mtime lands BEFORE the
# kernel boot epoch (by the POST duration) — `mtime >= boot` was always
# false (bit us 2026-10-26). Rule: fresh iff mtime in
# [boot_epoch - 300s, boot_epoch + 120s] (tolerates POST time + RTC skew).
RAN="no-log"; STAMP=""; PREFLIGHT=""; VERDICTS=""; SS0=""
CLEAN="$ARCH/50hx_log.txt"
if [ -f "$LOGSRC" ]; then
    tr -d '\r' < "$LOGSRC" > "$CLEAN.tmp" 2>/dev/null
    M=$(stat -c %Y "$LOGSRC" 2>/dev/null || echo 0)
    if [ "$BOOT_EPOCH" -gt 0 ] && [ "$M" -ge $((BOOT_EPOCH - 300)) ] && [ "$M" -le $((BOOT_EPOCH + 120)) ]; then
        RAN="yes"
    elif [ "$BOOT_EPOCH" -eq 0 ]; then
        RAN="unknown"
    else
        RAN="stale-log"
    fi
    mv -f "$CLEAN.tmp" "$CLEAN" 2>/dev/null
    STAMP=$(grep -m1 '^\[build\]' "$CLEAN" | sed 's/^\[build\] //')
    PREFLIGHT=$(awk '/skipped: CONSOLE \(conout-gop\)/{printf "%s:console-gop;", $3}' "$CLEAN" | sed 's/card//')
    PA=$(awk '/skipped: CONSOLE \(lowest-bus-assumption\)/{printf "%s:console-assumed;", $3}' "$CLEAN" | sed 's/card//')
    PREFLIGHT="${PREFLIGHT}${PA}"
    VERDICTS=$(grep -oE 'card [0-9]+ result: [A-Za-z ()-]+' "$CLEAN" | sed 's/result: //;s/ /_/g;s/_$//g' | paste -sd';' -)
    [ -z "$VERDICTS" ] && VERDICTS=$(grep -oE '\*\*\* UNLOCKED|RESULT: PLM=0x[0-9a-f]+ SS0=0x[0-9a-f]+' "$CLEAN" | tail -2 | paste -sd';' - | tr ' ' '_')
    SS0=$(awk '/=== card/{c=$4} /RESULT:.*SS0=/{sub(/.*SS0=/,"",$0);sub(/[ ).].*/,"",$0);printf "%s:%s;", c, $0}' "$CLEAN")
fi

# ---- hardware layout: bus:uuid (locked/uninit card => uuid unknown) ----
LAYOUT=""
declare -A UUID_OF=()
while read -r line; do
    # "GPU-xxxx, 00000000:01:00.0"
    u=$(echo "$line" | cut -d, -f1 | sed 's/GPU-//;s/ .*//')
    b=$(echo "$line" | cut -d, -f2 | tr -d ' ' | sed 's/00000000://;s/:00\.0//')
    [ -n "$b" ] && [ -n "$u" ] && UUID_OF[$b]=$u
done < <(nvidia-smi --query-gpu=uuid,pci.bus_id --format=csv,noheader 2>/dev/null)
for d in $(lspci -Dn -d 10de: 2>/dev/null | awk '{print $1}'); do
    b=${d#0000:}; b=${b%:00.0}
    uuid="${UUID_OF[$b]:-unknown}"
    LAYOUT="${LAYOUT}${b}:${uuid:0:8};"
done

# ---- console FACT: DRM card0 -> PCI bdf --------------------------------
DRM0="none"
if [ -e /dev/dri/card0 ]; then
    IDP=$(udevadm info -q property -n /dev/dri/card0 2>/dev/null | sed -n 's/^ID_PATH=pci-//p')
    if [ -n "$IDP" ]; then
        DRM0=$(echo "$IDP" | sed 's/\.0$//')
    else
        bdf=$(readlink -f /dev/dri/card0/device 2>/dev/null | sed 's|.*/||;s/\.0$//')
        [ -n "$bdf" ] && DRM0="$bdf"
    fi
fi

# ---- NVML + TFLOPS (skip bench when someone is using the GPUs) ---------
# NB: capture app list in a variable first — `grep -q` exiting early under
# pipefail turns nvidia-smi's SIGPIPE into a false branch (bit us 2026-10-26).
NVML=$(nvidia-smi --query-gpu=count --format=csv,noheader 2>/dev/null | head -1)
case "$NVML" in ''|*[!0-9]*) NVML=err;; esac
APPS=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null)
TF="skipped:no-nvml"
if [ "$NVML" != err ] && [ -n "${APPS//[[:space:]]/}" ]; then
    TF="skipped:busy"
elif [ "$NVML" != err ] && [ -f "$BENCHDIR/fma_bench.c" ] && command -v gcc >/dev/null; then
    cp -f "$BENCHDIR/fma_bench.c" /tmp/fma_bench.c
    if gcc -O2 -DCL_TARGET_OPENCL_VERSION=300 /tmp/fma_bench.c -lOpenCL -o /tmp/fma_bench 2>/dev/null; then
        TF=""
        for i in $(seq 0 $((NVML - 1))); do
            v=$(/tmp/fma_bench $i 2>/dev/null | grep -oE '[0-9.]+ TFLOP' | tail -1 | cut -d' ' -f1)
            TF="${TF}${v:-err};"
        done
    else
        TF="skipped:build-fail"
    fi
fi

WPR=$(dmesg 2>/dev/null | grep -ciE 'WPR2|RmInitAdapter')
WPR=${WPR:-0}

# ---- append CSV ---------------------------------------------------------
NEW=0; [ ! -f "$LEDGER" ] && NEW=1
{
[ "$NEW" = 1 ] && echo 'boot_utc,collect_utc,boot_id,stamp,efi_ran,layout,preflight,verdicts,ss0,drm_minor0,nvml_count,tflops,dmesg_wpr2,log_path'
printf '%s,%s,%s,"%s",%s,"%s","%s","%s","%s",%s,%s,"%s",%s,%s\n' \
    "$BOOT_UTC" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BOOT_ID" "$STAMP" "$RAN" \
    "$LAYOUT" "$PREFLIGHT" "$VERDICTS" "$SS0" "$DRM0" "$NVML" "$TF" "$WPR" "$ARCH/50hx_log.txt"
} >> "$LEDGER"

chown -R dmitry:dmitry "$BENCHDIR" 2>/dev/null
echo "collected boot $BOOT_ID (efi_ran=$RAN)"
