#!/usr/bin/env bash
# cmp90hx-claim.sh — once-per-boot Gen2 mask claim for the CMP 90HX.
# Map 90hx-gen2-610 ticket 05 design record v1 / ticket 06.
#
# Runs BEFORE cmp50hx-boot.service binds nvidia (unit ordering). Claims the
# T09 gate-first window via the blacklisted gpu-unlock-claim module, verifies
# the two masks the in-module Gen2 speed path requires (0x823800 config gate +
# 0x88fe8 XVE), rmmods, and ALWAYS exits 0: every failure mode degrades to
# Gen1 (the module's config pass keeps skipping on its own gate), never blocks
# boot, never retries across boots (ADR-0001).
set -u

BDF="${CMP90_BDF:-0000:03:00.0}"
KO="$(modprobe -R gpu_unlock 2>/dev/null || true)"
if [[ -z "$KO" || ! -f "$KO" ]]; then
    KO="$(find "/lib/modules/$(uname -r)/updates/dkms" -maxdepth 1 -name 'gpu_unlock.ko*' 2>/dev/null | head -1)"
fi
STATE=/var/lib/cmpunlocker-rs
JOURNAL_TAG=cmp90hx-claim
HEALTH_URL="${LLM_HEALTH_URL:-http://127.0.0.1:8080/health}"

say() { logger -t "$JOURNAL_TAG" -- "$*" 2>/dev/null; printf '%s\n' "$*"; }

disabled() {
    local conf=/etc/cmp50hx/boot.conf v
    [[ -f "$conf" ]] || return 1
    v="$(sed -n 's/^GEN2_90HX=\(.*\)/\1/p' "$conf" | tail -1)"
    [[ "$v" == "disabled" ]]
}

bar0_read() { # <addr-hex> -> value or empty; wedge-safe (mmap RO like maskread)
    python3 - "$BDF" "$1" << 'PY' 2>/dev/null || true
import mmap, os, struct, sys
bdf, addr = sys.argv[1], int(sys.argv[2], 16)
res = f"/sys/bus/pci/devices/{bdf}/resource0"
try:
    fd = os.open(res, os.O_RDONLY); m = mmap.mmap(fd, 0x1000000, mmap.MAP_SHARED, mmap.PROT_READ)
    m.seek(addr); v = struct.unpack("<I", m.read(4))[0]
    print(f"0x{v:08x}")
except Exception:
    pass
PY
}

claim_done() { # masks the config pass needs are already open (idempotency guard)
    [[ "$(bar0_read 0x823800)" == "0xffffffff" && "$(bar0_read 0x88fe8)" == "0xffffffff" ]]
}

if disabled; then say "gen2-claim: disabled (boot.conf GEN2_90HX=disabled)"; exit 0; fi
if ! lspci -Dn -s "$BDF" 2>/dev/null | grep -q "10de:220d"; then exit 0; fi   # no 90HX: no-op
if [[ ! -d "/sys/bus/pci/devices/$BDF" ]]; then say "gen2-claim: gen1-fallback device absent"; exit 0; fi
if claim_done; then say "gen2-claim: already-open (idempotent skip)"; exit 0; fi

mkdir -p "$STATE"
if insmod "$KO" targets="$BDF" resume=0 2>/tmp/cmp90hx-claim.insmod; then
    # ko logs pass= lines + stage=handoff; verify the two decisive masks
    if claim_done; then
        say "gen2-claim: landed bdf=$BDF"
    else
        say "gen2-claim: gen1-fallback claim ran but readback not open (see insmod log + dmesg)"
    fi
else
    say "gen2-claim: gen1-fallback insmod failed: $(tail -1 /tmp/cmp90hx-claim.insmod 2>/dev/null)"
fi
rmmod gpu_unlock 2>/dev/null || true
exit 0
