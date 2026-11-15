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

# Default slot 03:00.0 is the ORIGINAL bench slot; the card physically
# moved to 01:00.0 (live 2026-11-15: silent no-op until CMP90_BDF override).
# Set CMP90_BDF (env or systemd drop-in) whenever the bench topology changes.
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

claim_module_opts() {
    # Space-separated extra insmod params from boot.conf (default: none).
    # The only knob today is x2_aperture=1 (+ x2_size_mb=N) for the
    # gtuu-mining ticket-11 phase-2 window claim; default-off semantics
    # live in the module. Unquoted expansion on the insmod line below is
    # deliberate (word-splitting into params); values are operator-set,
    # not user input.
    local conf=/etc/cmp50hx/boot.conf v
    [[ -f "$conf" ]] || return 0
    v="$(sed -n 's/^CLAIM_90HX_OPTS=\(.*\)/\1/p' "$conf" | tail -1)"
    printf '%s' "${v%\"}" | tr -d '\"'
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

bar0_reads_trustworthy() { # wedge guard: after a reboot the card's memory
    # decode is off and EVERY BAR0 offset reads 0xffffffff — indistinguishable
    # from "open" (success-recipe §0 lesson). PMC_BOOT_0 is a constant; if it
    # reads correctly, other readbacks mean what they say.
    # GTUU row U4 (@1d6a508): compare the chip-identity field (bits 28:20 =
    # 0x172 GA102), NOT a full literal — foundry strap bits 31:29 make
    # 0xb72000a1 and 0x172000a1 the same silicon (llm2's card is the strap
    # form; a bare-field part used to fail this guard and silently lose the
    # Gen2 claim).
    local v
    v=$(bar0_read 0x0)
    [[ "$v" =~ ^0x[0-9a-fA-F]{8}$ ]] || return 1
    [[ "$v" == "0x00000000" || "$v" == "0xffffffff" ]] && return 1
    (( (( 16#${v#0x} >> 20 ) & 0x1ff) == 0x172 ))
}

# ==== Reset-scratch canary (gtuu-mining ticket 16, row B2-P3) ====
# Name the culprit that wipes the unlock between boots. Mechanism ported
# READ-ONLY from nv-uefi-unlocker @bbcb92f (loader/src/tx.rs:84-132,
# docs/diag-2.1.11-diag1-protocol.md §3 table, tools/diag-unlock.py:98-117):
# PBUS software-scratch words (NV_PBUS_SW_SCRATCH(i) = 0x1400+i*4, verified
# against work/upstream/bendy2-cmp90hx/.../swref/published/ampere/ga100/
# dev_bus.h — 64 RW-4A slots, INIT 0) die to FLR/SBR/rail-off; the AON
# island (where the SS overrides live) resets only on power loss. Pairing
# the two gives the culprit class:
#   slot cleared + SS gone   -> rail-off / S5 power removal wiped the
#                               volatile unlock (EXPECTED — log as such)
#   slot cleared + SS alive  -> an FLR/SBR-class reset between boots that
#                               the AON survived — not a power cycle,
#                               noteworthy when unexpected
#   slot intact + SS gone    -> no reset: something RE-WROTE the selectors
#                               while scratch survived (driver-init relock
#                               or a manual write — cross-check the SS
#                               values on the line and the ticket-04/
#                               source-eval B2-P33 taxonomy: a relocked
#                               gate (PLM 0xffffffef/8f) with intact SS is
#                               STILL unlocked — the gate never enters the
#                               classification, it is printed only)
#   slot intact + SS alive   -> nothing happened between boots.
# AON-side register — DOCUMENTED LIMITATION (same as the EFI twin in
# efi-unlock/unlock50x_v1.c): B2's protocol doc §3 names NO separate AON
# scratch — their design uses the FEAT/override values themselves as the
# AON witness; no general-purpose writable AON scratch exists in the open
# headers, and we do not guess hardware offsets. A zero slot cannot
# distinguish "cleared by reset" from "never armed" (scratch INIT is 0);
# the verdict follows the reference doctrine (cleared says a reset
# happened, not who did it) and pre-feature boots stay distinguishable in
# collect's CSV by the empty canary column.
#
# SLOT CONVENTION (coupled with the EFI, documented in BOTH files):
#   index 0x20 (BAR0 0x1480, magic 0x0164c0de) = EFI's slot — armed by
#       the EFI unlocker only, after a successful unlock transaction;
#   index 0x21 (BAR0 0x1484, magic 0x0165cafe) = claim's slot — armed by
#       this script only, after claim-ok. The coordination needs no
#       runtime handshake: each actor owns exactly ONE slot and writes
#       only it, so the claim arm can never overwrite evidence the EFI
#       left in 0x1480 (nor vice versa); each slot dates the gap since
#       ITS OWN last arm.
# This script READS both slots (the EFI's value corroborates the wider
# window) but takes the verdict from ITS OWN slot 0x1484 — on the 90HX
# the EFI unlocker never runs its arm, so 0x1480 there would forever
# read zero and tell nothing.
# CANARY-BEGIN — efi-unlock/tools/reset-canary-selftest.sh extracts the
# functions below VERBATIM (fixture-driven verdict matrix, stubs below).
CANARY_EFI_SLOT=0x1480;   CANARY_EFI_MAGIC=0x0164c0de
CANARY_CLAIM_SLOT=0x1484; CANARY_CLAIM_MAGIC=0x0165cafe
CANARY_SS0=0x82381c;      CANARY_SS1=0x823820      # GA102 SS pair (registers.h)
CANARY_SS0_UNLOCKED=0x88888888; CANARY_SS1_UNLOCKED=0x00000008
CANARY_GATE=0x823804                               # GA102 FEAT PLM (printed only)

canary_poison() { # <val> -> 0 if the read says nothing: all-ones, 0xBADF****,
    # or empty (bar0_read failed). B2's inaccessible() + the empty case the
    # python reader produces when the mmap itself cannot open.
    local x
    [[ "$1" =~ ^0x[0-9a-fA-F]{8}$ ]] || return 0
    x=$(( 16#${1#0x} ))
    (( x == 16#ffffffff )) && return 0
    (( (x >> 16 & 0xffff) == 16#badf )) && return 0
    return 1
}

canary_slot_state() { # <val> <magic> -> intact|cleared|rewritten|unreadable
    if canary_poison "$1"; then echo "unreadable"; return; fi
    [[ "$1" == "$2" ]]                 && { echo "intact"; return; }
    [[ "$1" == "0x00000000" ]]         && { echo "cleared"; return; }
    echo "rewritten"
}

canary_aon_state() { # <ss0> <ss1> -> alive|partial|dead
    # The SS pair is the authority; the gate (PLM) is NEVER consulted —
    # B2-P33: relocked gate + intact SS = still unlocked.
    local a=0 b=0
    [[ "$1" == "$CANARY_SS0_UNLOCKED" ]] && a=1
    [[ "$2" == "$CANARY_SS1_UNLOCKED" ]] && b=1
    if   (( a && b )); then echo "alive"
    elif (( a !=  b )); then echo "partial"   # ticket-04 half-latch class
    else                    echo "dead"; fi
}

canary_verdict() { # <slot-state> <aon-state> -> verdict string
    # NB: ':' delimiter, NOT '|' — pipe is the case-pattern OR operator.
    case "$1:$2" in
        unreadable:*) echo "unreadable" ;;   # not judged
        intact:alive) echo "no-event" ;;
        intact:*)     echo "relock-suspect" ;;
        cleared:alive) echo "flr-sbr" ;;
        cleared:*)    echo "power-cycle" ;;
        *)            echo "rewritten" ;;    # third value: devinit/BIOS
    esac
}

canary_read_classify() { # read-only; journal line BEFORE any claim work
    local e c s0 s1 gate pb aon vd
    e=$(bar0_read "$CANARY_EFI_SLOT");   c=$(bar0_read "$CANARY_CLAIM_SLOT")
    s0=$(bar0_read "$CANARY_SS0");       s1=$(bar0_read "$CANARY_SS1")
    gate=$(bar0_read "$CANARY_GATE")
    pb=$(canary_slot_state "${c:-}" "$CANARY_CLAIM_MAGIC")   # our slot = primary
    aon=$(canary_aon_state "${s0:-}" "${s1:-}")
    vd=$(canary_verdict "$pb" "$aon")
    say "gen2-claim: canary AON=$aon PBUS=$pb verdict=$vd efi@${CANARY_EFI_SLOT}=${e:-none} slot@${CANARY_CLAIM_SLOT}=${c:-none} ss0=${s0:-none} ss1=${s1:-none} gate=${gate:-none}"
}

canary_arm() { # success path ONLY (call site below): write our magic to
    # our slot 0x1484 and prove it (B2 CANARY-SET pattern). The ko restores
    # the command register at claim end (boot-2 lesson: BAR0 reads all-FF
    # from here), so MEM decode is re-enabled around the poke and restored
    # to whatever it was — the same transient enable the EFI performs every
    # boot (u40x_enable_bar). Never touches the EFI's slot 0x1480.
    local cmd rb
    cmd=$(setpci -s "$BDF" COMMAND 2>/dev/null)
    if [[ -z "$cmd" ]]; then
        say "gen2-claim: canary ARM skipped (config COMMAND unreadable)"
        return 0
    fi
    setpci -s "$BDF" COMMAND=$(printf '%04x' $(( 16#$cmd | 2 ))) 2>/dev/null \
        || { say "gen2-claim: canary ARM skipped (COMMAND write failed)"; return 0; }
    bar0_write "$CANARY_CLAIM_SLOT" "$CANARY_CLAIM_MAGIC"
    rb=$(bar0_read "$CANARY_CLAIM_SLOT")
    setpci -s "$BDF" COMMAND="$cmd" 2>/dev/null || true
    if [[ "$rb" == "$CANARY_CLAIM_MAGIC" ]]; then
        say "gen2-claim: canary SET slot@${CANARY_CLAIM_SLOT}=$rb readback ok (armed after claim-ok, claim slot per convention)"
    else
        say "gen2-claim: canary SET readback FAILED got=${rb:-none} — treats the block as not writable on this card"
    fi
}

bar0_write() { # <addr-hex> <value-hex> — the RW twin of bar0_read; only
    # ever called by canary_arm, on an UNBOUND device (this script's whole
    # window runs before cmp50hx-boot.service binds nvidia).
    python3 - "$BDF" "$1" "$2" << 'PY' 2>/dev/null || true
import mmap, os, struct, sys
bdf, addr, val = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3], 16)
res = f"/sys/bus/pci/devices/{bdf}/resource0"
try:
    fd = os.open(res, os.O_RDWR); m = mmap.mmap(fd, 0x1000000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
    m.seek(addr); m.write(struct.pack("<I", val)); m.flush(); m.close()
except Exception:
    pass
PY
}
# CANARY-END

claim_done() { # masks the config pass needs are already open (idempotency guard)
    bar0_reads_trustworthy \
        && [[ "$(bar0_read 0x823800)" == "0xffffffff" && "$(bar0_read 0x88fe8)" == "0xffffffff" ]]
}

if disabled; then say "gen2-claim: disabled (boot.conf GEN2_90HX=disabled)"; exit 0; fi
if ! lspci -Dn -s "$BDF" 2>/dev/null | grep -q "10de:220d"; then exit 0; fi   # no 90HX: no-op
if [[ ! -d "/sys/bus/pci/devices/$BDF" ]]; then say "gen2-claim: gen1-fallback device absent"; exit 0; fi

# Canary classification BEFORE any claim work (ticket 16): the verdict
# describes the inter-boot event, not this boot's claim — so it runs even
# on the already-open idempotent skip below (that skip is itself an
# interesting boot for the fleet story). Read-only; never arms.
canary_read_classify

if claim_done; then say "gen2-claim: already-open (idempotent skip)"; exit 0; fi

# Cold-state verdict (GTUU row U3 port, informational on the 90HX: the
# Gen2 claim does not write SS0/SS1, but the fleet should name this state
# from journal alone). Offsets: GA102 SS0/SS1 per claim-90hx/registers.h.
_ss0=$(bar0_read 0x82381c); _ss1=$(bar0_read 0x823820)
if [[ "$_ss0" == "0x88888888" && "$_ss1" == "0x00000008" ]]; then
    say "gen2-claim: cold-state ALREADY_MODIFIED ss0=$_ss0 ss1=$_ss1"
elif [[ "$_ss0" == "0x88888888" || "$_ss1" == "0x00000008" ]]; then
    say "gen2-claim: cold-state PARTIALLY_MODIFIED ss0=$_ss0 ss1=$_ss1 (half-unlocked tensor state — investigate; Gen2 claim unaffected)"
else
    say "gen2-claim: cold-state CLEAN"
fi

mkdir -p "$STATE"
claim_ok=0
if insmod "$KO" targets="$BDF" resume=0 $(claim_module_opts) 2>/tmp/cmp90hx-claim.insmod; then
    # The ko synchronously verifies every write (pass=… ret=0) and prints
    # "unlocked" before handoff — that IS the authoritative verdict: the ko
    # restores the command register afterwards, so a BAR0 re-read from here
    # would hit the all-FF-unreadable pattern (boot 2 lesson, 2026-11-01).
    landed="$(dmesg | grep -ac 'gpu_unlock: pass=.*ret=0' || true)"
    if dmesg | grep -aq 'gpu_unlock: unlocked' && [ "${landed:-0}" -ge 6 ]; then
        say "gen2-claim: claim-ok ${landed}/6 landed (link truth: boot digest cmp90hx-gen2 line)"
        claim_ok=1
    else
        say "gen2-claim: gen1-fallback claim incomplete ${landed:-0}/6 landed (see dmesg + /tmp/cmp90hx-claim.insmod)"
    fi
else
    say "gen2-claim: gen1-fallback insmod failed: $(tail -1 /tmp/cmp90hx-claim.insmod 2>/dev/null)"
fi
rmmod gpu_unlock 2>/dev/null || true
# ARM ONLY ON SUCCESS (ticket 16; mirrors the EFI's [10c] rule): the two
# gen1-fallback paths above must not overwrite the previous boot's claim
# evidence. Runs after rmmod — the module has fully released the card,
# canary_arm re-enables MEM decode around its single scratch write and
# restores the command register itself.
if (( claim_ok )); then canary_arm; fi
exit 0
