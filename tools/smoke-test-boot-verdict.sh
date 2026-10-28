#!/bin/bash
# Boot-flow replay harness — drives the REAL cmp50hx-boot.sh verdict +
# readiness-gate decision path against fixture ESP logs / PCI trees / boot
# epochs via its CMP_TEST_* seams. No root, no reboot, seconds per scenario.
#
# History locked down here: the warm re-roll ladder was retired
# 2026-10-28 (docs/adr/0001) — a boot may not reboot its own host to gamble
# on the booter-window lottery; degraded boots must ACCEPT loudly, and the
# unit must instead PROVE readiness for the cards the pre-OS unlocker
# promised (Gen2 PASS count vs ESP UNLOCKED count), failing red — never
# silently — when a promised card does not initialize.
#
# Fixture logs are modelled on the real bench archives in
# ~/debug/50hx/bootlogs/<bootid>/ (token-identical reject and unlock
# bodies, volatile "canary @ +N s" line included).
#
# Contract asserted:
#   H1 degraded + promised cards PASS  -> advice, READY, exit 0, no reboot
#   H2 promised card never PASSes      -> INIT-INCOMPLETE, exit 1
#   H3 healthy                         -> ALL-UNLOCKED, run flag, READY, 0
#   H4 every card rejected             -> gen2 best-effort (kernel rescue possible), 0
#   H5 no ESP logs at all              -> best-effort gen2, exit 0
#   H6 stale plain log never inflates the verdict (sharp signal)
set -u
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
RUNNER="$here/../cmp50hx/cmp50hx-boot.sh"
[ -f "$RUNNER" ] || { echo "runner not found: $RUNNER"; exit 1; }

fail=0
E0=1793200000
bad()  { echo "  FAIL: $*"; fail=$((fail+1)); }
want() { grep -q "$2" "$1" || { bad "missing pattern [$2] in $1:"; sed 's/^/      | /' "$1"; }; }
wanti(){ grep -q "$2" "$1" && { bad "unexpected pattern [$2] in $1:"; sed 's/^/      | /' "$1"; }; }

# --- fixture log bodies (token-identical to real bench archives) -----------
log_unlock() {
    printf '%s\n' \
"[50HX] 50HX unlock chain starting" \
"[warm] canary @ +${1:-1} s: ACCEPTED (mbox0 was 0x00000000)" \
"tu102: RESULT: PLM=0xffffff8f SS0=0x88888888 SS1=0x00000008" \
"[50HX] booter_load_tu102_direct returned 0" \
"[50HX] RESULT: PLM=0xffffff8f SS0=0x88888888 SS1=0x00000008" \
"[50HX] *** UNLOCKED (SS0=0x88888888 SS1=0x8) ***" \
"[50HX] returning to GRUB; it may now start the OS loader"
}
log_reject() {
    printf '%s\n' \
"[50HX] 50HX unlock chain starting" \
"tu102: read#4 mbox..." \
"tu102: RESULT: PLM=0xfffffe8e SS0=0x00000000 SS1=0x00000000" \
"tu102: attempt 1 not-OK (m0=0x91 halted=1)" \
"[warm] canary @ +${1:-1} s: ACCEPTED (mbox0 was 0x00000000)" \
"[50HX] booter_load_tu102_direct returned 8000000000000007" \
"[warm] canary closed after try - stop (rb=0x00000091)" \
"[50HX] RESULT: PLM=0xfffffe8e SS0=0x00000000 SS1=0x00000000" \
"[50HX] PLM closed  no booter effect observed" \
"[50HX] returning to GRUB; it may now start the OS loader"
}

# new_scenario <cards>   (cards = 1e09 PCI devices to fake)
new_scenario() {
    local ncards=${1:-3} bdf
    TMP=$(mktemp -d /tmp/bootv-sXXXXXX)
    esp=$TMP/esp; pcir=$TMP/pci; bin=$TMP/bin
    mkdir -p "$esp" "$pcir/devices" "$bin"
    # gen2 stub: prints $CMP_TEST_PASS_N real-format PASS lines, records runs
    cat > "$bin/cmp50hx" <<'EOF'
#!/bin/sh
[ "$1" = gen2 ] || exit 0
echo gen2-invoked >> "$CMP_TEST_TMP/invocations"
i=0
while [ "$i" -lt "${CMP_TEST_PASS_N:-0}" ]; do
    i=$((i+1))
    printf 'cmp50hx-gen2: 0000:0%d:00.0: PASS, link at 5.0 GT/s PCIe\n' "$((i*2-1))"
done
exit 0
EOF
    chmod +x "$bin/cmp50hx"
    printf 'CMP_BOOT_COLLECT=0\nCMP_BOOT_PROFILE=\n' > "$TMP/boot.conf"
    export CMP_TEST_TMP=$TMP
    local i=1
    for bdf in 0000:01:00.0 0000:03:00.0 0000:04:00.0; do
        [ "$i" -le "$ncards" ] || break
        mkdir -p "$pcir/devices/$bdf"
        echo 0x10de > "$pcir/devices/$bdf/vendor"
        echo 0x1e09 > "$pcir/devices/$bdf/device"
        i=$((i+1))
    done
    # stale plain log from an old single-module deployment (contains UNLOCKED)
    log_unlock 5 > "$esp/50hx_log.txt"
    touch -d "@$((E0 - 7200))" "$esp/50hx_log.txt"
}

# boot <out> <boot-n> <u1-fn> <u3-fn> <u4-fn>   (fn: unlock|reject|skip)
boot() {
    local out=$1 n=$2 tgt i=0 fn
    local rc=$TMP/rc
    local epoch=$((E0 + n * 90)) m=$((E0 + n * 90 - 20))
    rm -f "$esp"/50hx_log_u*.txt "$TMP/invocations"
    shift 2
    for fn in "$@"; do
        i=$((i+1))
        case $i in 1) tgt=u1;; 2) tgt=u3;; 3) tgt=u4;; esac
        [ "$fn" = skip ] && continue
        "log_$fn" "$n" > "$esp/50hx_log_$tgt.txt"; touch -d "@$m" "$esp/50hx_log_$tgt.txt"
    done
    CMP_TEST_CONF=$TMP/boot.conf CMP_TEST_ESP_DIR=$esp CMP_TEST_PCI_DIR=$pcir \
    CMP_TEST_BOOT_EPOCH=$epoch CMP_TEST_RUN_FLAG=$TMP/runflag CMP_TEST_BIN=$bin/cmp50hx \
    bash "$RUNNER" > "$out" 2>&1
    echo $? > "$rc"
}
invoked() { [ -e "$TMP/invocations" ]; }
rcv()     { cat "$TMP/rc"; }
O=/tmp/bootv-out-$$

echo "== H1 degraded + promised PASS: advice, READY, exit 0, no reboot =="
new_scenario
export CMP_TEST_PASS_N=2
boot "$O" 1 reject unlock unlock
want "$O" "DEGRADED win=2/3"; want "$O" "will NOT reboot itself"
want "$O" "READY: 2/2 promised GPUs initialized"
[ "$(rcv)" = 0 ] || bad "H1 exit rc=$(rcv), want 0"
invoked || bad "H1: gen2 gate must run for promised cards"
[ ! -e "$TMP/runflag" ] || bad "H1 degraded: no unlocked run-flag"

echo "== H2 promised card never PASSes: INIT-INCOMPLETE, exit 1 =="
new_scenario
export CMP_TEST_PASS_N=1          # promised=2, only one PASS -> driver flake
boot "$O" 1 reject unlock unlock
want "$O" "INIT-INCOMPLETE: only 1/2"
want "$O" "power cycle"
[ "$(rcv)" = 1 ] || bad "H2 exit rc=$(rcv), want 1 (Q11: fail loudly)"

echo "== H3 healthy: ALL-UNLOCKED + run flag + READY =="
new_scenario
export CMP_TEST_PASS_N=3
boot "$O" 1 unlock unlock unlock
want "$O" "ALL-UNLOCKED win=3/3"; want "$O" "READY: 3/3"
want "$O" "stale ESP log"          # plain log excluded
[ "$(rcv)" = 0 ] || bad "H3 exit rc=$(rcv)"
[ -e "$TMP/runflag" ] || bad "H3: run flag must be touched"

echo "== H4 all rejected: gen2 best-effort (kernel rescue exists), exit 0 =="
new_scenario
export CMP_TEST_PASS_N=0
boot "$O" 1 reject reject reject
want "$O" "DEGRADED win=0/3"
want "$O" "gen2 best-effort"
wanti "$O" "INIT-INCOMPLETE"
invoked || bad "H4: gen2 must run best-effort — kernel V551 may have rescued armed cards"
[ "$(rcv)" = 0 ] || bad "H4 exit rc=$(rcv), want 0"

echo "== H5 no ESP logs: NO_EFI_VERDICT best-effort, exit 0 =="
new_scenario
export CMP_TEST_PASS_N=3
rm -f "$esp/50hx_log.txt"          # nothing fresh OR stale
boot "$O" 1 skip skip skip
want "$O" "NO_EFI_VERDICT"
want "$O" "gen2 best-effort done"
invoked || bad "H5: gen2 still runs best-effort"
[ "$(rcv)" = 0 ] || bad "H5 exit rc=$(rcv), want 0"

echo "== H6 stale plain log cannot inflate a degraded verdict =="
new_scenario 2                        # only cards 01 + 03 installed
export CMP_TEST_PASS_N=1
# fresh u1 unlock + fresh u3 REJECT + stale plain UNLOCKED:
# win must be 1/2 (DEGRADED); if stale counted, it would read ALL-UNLOCKED.
log_unlock 1 > "$esp/50hx_log_u1.txt"; touch -d "@$((E0 + 90 - 20))" "$esp/50hx_log_u1.txt"
log_reject 1 > "$esp/50hx_log_u3.txt"; touch -d "@$((E0 + 90 - 20))" "$esp/50hx_log_u3.txt"
CMP_TEST_CONF=$TMP/boot.conf CMP_TEST_ESP_DIR=$esp CMP_TEST_PCI_DIR=$pcir \
CMP_TEST_BOOT_EPOCH=$((E0 + 90)) CMP_TEST_RUN_FLAG=$TMP/runflag CMP_TEST_BIN=$bin/cmp50hx \
CMP_TEST_PASS_N=1 bash "$RUNNER" > "$O" 2>&1; echo $? > "$TMP/rc"
want "$O" "DEGRADED win=1/2"
want "$O" "stale ESP log"
wanti "$O" "ALL-UNLOCKED"

rm -f "$O"
echo
if [ "$fail" = 0 ]; then echo "PASS_CMP_BOOT_VERDICT_SMOKE"; exit 0
else echo "FAIL_CMP_BOOT_VERDICT_SMOKE ($fail)"; exit 1; fi
