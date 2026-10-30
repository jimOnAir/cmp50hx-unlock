#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# CMP90HX Pwner
# Repository: https://github.com/iatethelogs/cmp90hx_pwner
# Copyright (c) iatethelogs
# Credits:
#   pearlfortune/cmpunlocker  - compute unlock, rejoin15, V67 FEAT/PLM 0x823800/0x823804
#   jdowning100/cmpunlocker   - rejoin16 Gen2 path, XVE/LTSSM 0x088fe8
#   Wh1stle05/cmp90hx         - NVIDIA 610.43.03 Linux installer and patch packaging

set -Eeuo pipefail

PROGRAM_NAME="CMP90HX Pwner"
REPO_URL="https://github.com/iatethelogs/cmp90hx_pwner"
DRIVER_VERSION="${DRIVER_VERSION:-610.43.03}"
PROJECT_REPO="${PROJECT_REPO:-https://github.com/Wh1stle05/cmp90hx.git}"
PROJECT_DIR="${PROJECT_DIR:-/usr/local/src/cmp90hx-pwner/cmp90hx}"
PREFIX="${PREFIX:-/opt/cmp90hx-gen2}"
STATE_DIR="${STATE_DIR:-/var/lib/cmp90hx-pwner}"
RUNTIME_STATE_DIR="${RUNTIME_STATE_DIR:-/var/lib/cmpunlocker-rs}"
LOG_DIR="${LOG_DIR:-/var/log}"
LOG="${LOG:-${LOG_DIR}/cmp90hx-pwner-$(date +%Y%m%d-%H%M%S).log}"
SELF_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
AUTO_REBOOT_IF_NOUVEAU="${AUTO_REBOOT_IF_NOUVEAU:-0}"
PURGE_NVIDIA_PACKAGES="${PURGE_NVIDIA_PACKAGES:-1}"
KILL_GPU_PROCS="${KILL_GPU_PROCS:-1}"
SERVICE_NAME="cmp90hx-gen2.service"
COMPUTE_SERVICE="cmp90hx-compute.service"
BOOT_GATE="${PREFIX}/rejoin17-boot-gate.sh"
APPLY_SCRIPT="${PREFIX}/rejoin17-apply-all.sh"
SSH_PROFILE="/etc/profile.d/cmp90hx-pwner-login.sh"
NVIDIA_RUN_URL="https://download.nvidia.com/XFree86/Linux-x86_64/${DRIVER_VERSION}/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run"
NVIDIA_RUN="/var/tmp/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run"

export LC_ALL=C

if [[ "${1:-}" == "--no-tui" ]]; then
    export CMP90HX_NO_TUI=1
    shift
fi

if [[ "$(id -u)" != "0" ]]; then
    exec sudo -E bash "$SELF_PATH" "$@"
fi

mkdir -p "$LOG_DIR" "$STATE_DIR"
chmod 0777 "$STATE_DIR" 2>/dev/null || true

launch_tui() {
    [[ "${CMP90HX_TUI_CHILD:-0}" == "1" ]] && return 0
    [[ "${CMP90HX_NO_TUI:-0}" == "1" || "${NO_TUI:-0}" == "1" ]] && return 0
    [[ -t 0 && -t 1 ]] || return 0
    [[ -n "${TMUX:-}" ]] && return 0

    if ! command -v tmux >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y tmux >/dev/null 2>&1 || true
        fi
    fi
    command -v tmux >/dev/null 2>&1 || return 0

    local session runner tailer a
    session="cmp90hx-pwner-$$"
    runner="/tmp/cmp90hx-pwner-runner-$$.sh"
    tailer="/tmp/cmp90hx-pwner-tailer-$$.sh"

    {
        printf '#!/usr/bin/env bash\n'
        printf 'export CMP90HX_TUI_CHILD=1\n'
        printf 'export FORCE_COLOR=1\n'
        printf 'export LOG=%q\n' "$LOG"
        printf 'args_count=%q\n' "$#"
        printf 'bash %q' "$SELF_PATH"
        for a in "$@"; do printf ' %q' "$a"; done
        printf '\n'
        printf 'rc=$?\n'
        printf 'if (( rc != 0 )); then\n'
        printf '  echo; echo "CMP90HX Pwner command failed with rc=$rc. Returning to main menu. See the right log pane."\n'
        printf '  sleep 2\n'
        printf '  exec bash %q\n' "$SELF_PATH"
        printf 'fi\n'
        printf 'if (( args_count > 0 )); then\n'
        printf '  exec bash %q\n' "$SELF_PATH"
        printf 'fi\n'
        printf 'exit 0\n'
    } > "$runner"

    {
        printf '#!/usr/bin/env bash\n'
        printf 'touch %q\n' "$LOG"
        printf 'printf "DETAILED COMMAND LOG: %s\\n\\n" %q\n' "$LOG" "$LOG"
        printf 'tail -n +1 -F %q\n' "$LOG"
    } > "$tailer"

    chmod +x "$runner" "$tailer"
    tmux new-session -d -s "$session" -n "$PROGRAM_NAME" "bash '$runner'; rc=\$?; sleep 1; exit \"\$rc\""
    tmux split-window -h -l 55% -t "$session:0" "bash '$tailer'"
    tmux select-pane -t "$session:0.0"
    tmux select-layout -t "$session:0" even-horizontal >/dev/null 2>&1 || true
    tmux attach -t "$session"
    local rc=$?
    rm -f "$runner" "$tailer" 2>/dev/null || true
    exit "$rc"
}
launch_tui "$@"

STATUS_FD=1
if [[ "${CMP90HX_TUI_CHILD:-0}" == "1" && -w /dev/tty ]]; then
    exec 3>/dev/tty
    STATUS_FD=3
    exec >>"$LOG" 2>&1
else
    exec > >(tee -a "$LOG") 2>&1
fi

if [[ -n "${NO_COLOR:-}" || "${TERM:-}" == "dumb" ]]; then
    RST=''; BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; ORANGE=''; CYAN=''
else
    RST=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; ORANGE=$'\033[38;5;208m'; CYAN=$'\033[36m'
fi

ui() { printf "$@" >&"$STATUS_FD"; }
cmdlog() { printf '\n[%s] %s\n' "$(date -Is)" "$*"; }
ok() { ui '%b[ OK ]%b %s\n' "${GREEN}${BOLD}" "$RST" "$*"; }
warn() { ui '%b[WARN]%b %s\n' "${YELLOW}${BOLD}" "$RST" "$*"; }
fail() { ui '%b[FAIL]%b %s\n' "${RED}${BOLD}" "$RST" "$*"; }
die() { fail "$*"; ui 'LOG: %s\n' "$LOG"; exit 1; }
clear_left() { [[ -t "$STATUS_FD" ]] && ui '\033[H\033[2J' || true; }

draw_banner() {
    ui '%b' "$ORANGE$BOLD"
    cat >&"$STATUS_FD" <<'EOF_BANNER'

      ____   ___   ______ ______   ______ __  __ ______   __    ____  __________   __ __ __
     /  _/  /   | /_  __// ____/  /_  __// / / // ____/  / /   / __ \/ ____/ ___/  / // // /
     / /   / /| |  / /  / __/      / /  / /_/ // __/    / /   / / / / / __ \__ \  / // // /
   _/ /   / ___ | / /  / /___     / /  / __  // /___   / /___/ /_/ / /_/ /___/ / /_//_//_/
  /___/  /_/  |_|/_/  /_____/    /_/  /_/ /_//_____/  /_____/\____/\____//____/ (_)(_) (_)

EOF_BANNER
    ui '%b' "$RST"
    ui '%b%s%b\n' "$CYAN$BOLD" "$PROGRAM_NAME" "$RST"
    ui '%b%s%b\n' "$DIM" "$REPO_URL" "$RST"
    ui '%bCopyright (c) iatethelogs%b\n\n' "$DIM" "$RST"
    ui '%bUsed work:%b\n' "$BOLD" "$RST"
    ui '  pearlfortune/cmpunlocker  compute unlock, rejoin15, V67 FEAT/PLM 0x823800/0x823804\n'
    ui '  jdowning100/cmpunlocker   rejoin16 Gen2 path, XVE/LTSSM 0x088fe8\n'
    ui '  Wh1stle05/cmp90hx         NVIDIA %s Linux installer and patch packaging\n\n' "$DRIVER_VERSION"
}
banner() {
    draw_banner
}


STEP_NO=0
TOTAL_STEPS=1
spinner_chars=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )

shorten() {
    local text="$1" max="${2:-34}"
    if (( ${#text} > max )); then printf '%s…' "${text:0:$((max-1))}"; else printf '%s' "$text"; fi
}

run_step() {
    local label="$1" clean shown i pid rc elapsed spin
    shift
    STEP_NO=$((STEP_NO + 1))
    clean="$(shorten "$label" 34)"
    shown=$(printf '%02d/%02d  %-34s' "$STEP_NO" "$TOTAL_STEPS" "$clean")
    ui '\n%s ' "$shown"
    cmdlog "START: $label"
    ( "$@" ) >>"$LOG" 2>&1 &
    pid=$!
    i=0
    elapsed=0
    while kill -0 "$pid" 2>/dev/null; do
        spin="${spinner_chars[$((i % ${#spinner_chars[@]}))]}"
        ui '\r\033[K%s %b%s%b %3ss' "$shown" "$ORANGE" "$spin" "$RST" "$elapsed"
        sleep 0.25
        i=$((i + 1))
        (( i % 4 == 0 )) && elapsed=$((elapsed + 1))
    done
    set +e
    wait "$pid"
    rc=$?
    set -e
    if [[ "$rc" == "0" ]]; then
        ui '\r\033[K%s %b[ OK ]%b\n' "$shown" "${GREEN}${BOLD}" "$RST"
        cmdlog "OK: $label"
    else
        ui '\r\033[K%s %b[ FAIL ]%b\n' "$shown" "${RED}${BOLD}" "$RST"
        cmdlog "FAIL: $label rc=$rc"
        return "$rc"
    fi
}

apt_install_base() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl wget git tmux pciutils kmod build-essential dkms linux-headers-"$(uname -r)" python3 python3-minimal initramfs-tools gzip tar make gcc g++
}

install_cuda_toolkit() {
    export DEBIAN_FRONTEND=noninteractive

    local os_id os_ver distro arch keyring_deb keyring_url
    os_id=""
    os_ver=""
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        os_id="${ID:-}"
        os_ver="${VERSION_ID:-}"
    fi

    arch="$(dpkg --print-architecture 2>/dev/null || true)"
    [[ "$arch" == "amd64" ]] || { printf 'unsupported architecture for NVIDIA CUDA repo: %s\n' "$arch"; return 2; }

    case "${os_id}:${os_ver}" in
        ubuntu:20.04) distro="ubuntu2004" ;;
        ubuntu:22.04) distro="ubuntu2204" ;;
        ubuntu:24.04) distro="ubuntu2404" ;;
        debian:11) distro="debian11" ;;
        debian:12) distro="debian12" ;;
        *)
            printf 'unsupported distro for automatic NVIDIA CUDA repo: ID=%s VERSION_ID=%s\n' "$os_id" "$os_ver"
            printf 'supported here: Ubuntu 20.04/22.04/24.04, Debian 11/12\n'
            return 2
            ;;
    esac

    apt-get update
    apt-get install -y ca-certificates curl wget gnupg lsb-release

    keyring_deb="/var/tmp/cuda-keyring_1.1-1_${distro}_all.deb"
    keyring_url="https://developer.download.nvidia.com/compute/cuda/repos/${distro}/x86_64/cuda-keyring_1.1-1_all.deb"

    download_with_retry "$keyring_url" "$keyring_deb"
    dpkg -i "$keyring_deb"

    apt-get update
    apt-get install -y cuda-toolkit

    command -v nvcc >/dev/null 2>&1 && nvcc --version || true
}

find_cmps() {
    for d in /sys/bus/pci/devices/*; do
        [[ -f "$d/vendor" && -f "$d/device" ]] || continue
        if [[ "$(cat "$d/vendor")" == "0x10de" && "$(cat "$d/device")" == "0x220d" ]]; then
            basename "$d"
        fi
    done | sort
}

upstream_of() {
    local bdf="$1"
    basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/$bdf")")"
}

card_is_gen2() {
    local cmp="$1" up speed endpoint upstream
    up="$(upstream_of "$cmp")"
    speed="$(cat "/sys/bus/pci/devices/${cmp}/current_link_speed" 2>/dev/null || true)"
    endpoint="$(lspci -Dvv -s "$cmp" | grep "LnkSta:" | head -1 || true)"
    upstream="$(lspci -Dvv -s "$up" | grep "LnkSta:" | head -1 || true)"
    [[ "$speed" == *"5.0 GT/s"* ]] && [[ "$endpoint" == *"Speed 5GT/s"* ]] && [[ "$upstream" == *"Speed 5GT/s"* ]]
}

verify_links() {
    command -v lspci >/dev/null 2>&1 || { printf 'lspci missing\n'; return 1; }
    local cmps cmp up speed width endpoint upstream total=0 okc=0
    mapfile -t cmps < <(find_cmps)
    (( ${#cmps[@]} > 0 )) || { printf 'no CMP 90HX 10de:220d devices found\n'; return 2; }
    for cmp in "${cmps[@]}"; do
        total=$((total + 1))
        up="$(upstream_of "$cmp")"
        speed="$(cat "/sys/bus/pci/devices/${cmp}/current_link_speed" 2>/dev/null || true)"
        width="$(cat "/sys/bus/pci/devices/${cmp}/current_link_width" 2>/dev/null || true)"
        endpoint="$(lspci -Dvv -s "$cmp" | grep "LnkSta:" | head -1 || true)"
        upstream="$(lspci -Dvv -s "$up" | grep "LnkSta:" | head -1 || true)"
        printf '%s upstream=%s speed=%s width=%s\n' "$cmp" "$up" "$speed" "$width"
        printf '  endpoint %s\n' "$endpoint"
        printf '  upstream %s\n' "$upstream"
        card_is_gen2 "$cmp" && okc=$((okc + 1))
    done
    printf 'GEN2 %s/%s\n' "$okc" "$total"
    [[ "$okc" == "$total" ]]
}

backup_state() {
    local bdir="/root/cmp90hx-pwner-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$bdir"
    {
        date -Is
        uname -a
        lspci -Dnn | grep -Ei '10de|nvidia' || true
        modinfo -F version nvidia 2>/dev/null || true
        modinfo -F srcversion nvidia 2>/dev/null || true
        lsmod | grep -E '^nvidia|^nouveau|^ecc' || true
    } > "$bdir/system.txt"
    cp -a "$PREFIX" "$bdir/opt-cmp90hx-gen2" 2>/dev/null || true
    cp -a /etc/systemd/system/cmp90hx*.service "$bdir/" 2>/dev/null || true
    cp -a /etc/modprobe.d "$bdir/modprobe.d" 2>/dev/null || true
    cp -a /etc/depmod.d "$bdir/depmod.d" 2>/dev/null || true
    printf '%s\n' "$bdir" > "$STATE_DIR/last-backup"
    printf 'backup: %s\n' "$bdir"
}

stop_gpu_users() {
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl stop nvidia-persistenced ollama llama open-webui librechat comfyui 2>/dev/null || true
    if [[ "$KILL_GPU_PROCS" == "1" ]]; then
        pkill -f 'llama-server' 2>/dev/null || true
        pkill -f '/opt/llama.cpp' 2>/dev/null || true
        ls /dev/nvidia* >/dev/null 2>&1 && fuser -k /dev/nvidia* 2>/dev/null || true
    fi
    sleep 1
}

unload_nvidia_modules() {
    modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia_peermem nvidia 2>/dev/null || true
    sleep 1
}

sanitize_depmod() {
    find /etc/depmod.d -type f \( -name '*cmp90hx*' -o -name '*rejoin*' -o -name '*pwner*' \) -print -delete 2>/dev/null || true
}

blacklist_nouveau() {
    mkdir -p /etc/modprobe.d /etc/default/grub.d "$STATE_DIR"
    cat > /etc/modprobe.d/blacklist-nouveau-cmp90hx.conf <<'EOF_NOUVEAU'
blacklist nouveau
options nouveau modeset=0
alias nouveau off
install nouveau /bin/false
EOF_NOUVEAU
    cat > /etc/modprobe.d/nvidia-installer-disable-nouveau.conf <<'EOF_NVIDIA_NOUVEAU'
blacklist nouveau
options nouveau modeset=0
EOF_NVIDIA_NOUVEAU
    cat > /etc/default/grub.d/99-cmp90hx-pwner-nouveau.cfg <<'EOF_GRUB_NOUVEAU'
GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT modprobe.blacklist=nouveau nouveau.modeset=0 rd.driver.blacklist=nouveau"
EOF_GRUB_NOUVEAU
    command -v update-grub >/dev/null 2>&1 && update-grub || true
    command -v grub-mkconfig >/dev/null 2>&1 && [[ -d /boot/grub ]] && grub-mkconfig -o /boot/grub/grub.cfg || true
    command -v update-initramfs >/dev/null 2>&1 && update-initramfs -u -k all || true

    if lsmod | grep -q '^nouveau'; then
        systemctl stop display-manager 2>/dev/null || true
        for dev in /sys/bus/pci/drivers/nouveau/0000:*; do
            [[ -e "$dev" ]] && printf '%s' "${dev##*/}" > /sys/bus/pci/drivers/nouveau/unbind 2>/dev/null || true
        done
        modprobe -r nouveau 2>/dev/null || true
    fi

    if lsmod | grep -q '^nouveau'; then
        local count_file count
        count_file="$STATE_DIR/nouveau-reboot-count"
        count="$(cat "$count_file" 2>/dev/null || echo 0)"
        if [[ "$AUTO_REBOOT_IF_NOUVEAU" == "1" && "$count" == "0" ]]; then
            echo 1 > "$count_file"
            sync
            systemctl reboot
            sleep 60
        fi
        printf 'nouveau is still loaded. Reboot once, then run installer again.\n'
        printf 'cmdline: %s\n' "$(cat /proc/cmdline 2>/dev/null || true)"
        return 50
    fi
    rm -f "$STATE_DIR/nouveau-reboot-count" 2>/dev/null || true
}

remove_bootloader_nouveau_blacklist() {
    rm -f /etc/default/grub.d/99-cmp90hx-pwner-nouveau.cfg /etc/modprobe.d/blacklist-nouveau-cmp90hx.conf /etc/modprobe.d/nvidia-installer-disable-nouveau.conf 2>/dev/null || true
    python3 - <<'PY_REMOVE_GRUB' || true
from pathlib import Path
p = Path('/etc/default/grub')
if p.exists():
    remove = {'modprobe.blacklist=nouveau', 'nouveau.modeset=0', 'rd.driver.blacklist=nouveau'}
    out = []
    for line in p.read_text(errors='replace').splitlines():
        if line.startswith('GRUB_CMDLINE_LINUX_DEFAULT='):
            prefix, value = line.split('=', 1)
            tokens = [t for t in value.strip().strip('"').split() if t not in remove]
            line = prefix + '="' + ' '.join(tokens) + '"'
        out.append(line)
    p.write_text('\n'.join(out) + '\n')
PY_REMOVE_GRUB
    command -v update-grub >/dev/null 2>&1 && update-grub || true
    command -v grub-mkconfig >/dev/null 2>&1 && [[ -d /boot/grub ]] && grub-mkconfig -o /boot/grub/grub.cfg || true
}

purge_old_pwner() {
    systemctl disable --now "$COMPUTE_SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/$COMPUTE_SERVICE" 2>/dev/null || true
    systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable --now cmp90hx-pwner-firstboot-ui.service cmp90hx-pwner-ssh-gate.service 2>/dev/null || true
    systemctl unmask ssh.service sshd.service 2>/dev/null || true
    rm -f "/etc/systemd/system/$SERVICE_NAME" \
          /etc/systemd/system/cmp90hx-pwner-firstboot-ui.service \
          /etc/systemd/system/cmp90hx-pwner-ssh-gate.service 2>/dev/null || true
    rm -f "$SSH_PROFILE" \
          /etc/profile.d/cmp90hx-pwner-firstboot.sh \
          /etc/profile.d/cmp90hx-pwner-login.sh 2>/dev/null || true
    rm -f /etc/update-motd.d/99-cmp90hx-pwner 2>/dev/null || true
    rm -rf "$PREFIX" "$RUNTIME_STATE_DIR" "$STATE_DIR" "$PROJECT_DIR" /usr/local/src/cmp90hx-rejoin17 2>/dev/null || true
    rm -f /etc/depmod.d/cmp90hx-gen2.conf /etc/depmod.d/*cmp90hx* /etc/depmod.d/*rejoin* /etc/depmod.d/*pwner* 2>/dev/null || true
    rm -f /etc/modprobe.d/cmp90hx-gen2-noauto.conf /etc/modprobe.d/*cmp90hx* /etc/modprobe.d/*rejoin* /etc/modprobe.d/*pwner* 2>/dev/null || true
    sanitize_depmod
    systemctl daemon-reload || true
    mkdir -p "$STATE_DIR"
    chmod 0777 "$STATE_DIR" 2>/dev/null || true
}

nvidia_uninstall_best_effort() {
    stop_gpu_users || true
    unload_nvidia_modules || true

    if command -v nvidia-uninstall >/dev/null 2>&1; then
        nvidia-uninstall --silent --no-runlevel-check 2>/dev/null || true
    fi

    if command -v dkms >/dev/null 2>&1; then
        dkms status 2>/dev/null | awk -F, '/nvidia|cmp|rejoin/ {print $1","$2}' | while IFS=, read -r name ver; do
            name="${name// /}"
            ver="${ver// /}"
            [[ -n "$name" && -n "$ver" ]] && dkms remove -m "$name" -v "$ver" --all 2>/dev/null || true
        done
    fi

    if [[ "$PURGE_NVIDIA_PACKAGES" == "1" && -x /usr/bin/apt-get ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get purge -y 'nvidia-*' 'libnvidia-*' 'cuda-drivers*' 'cuda-toolkit-*' 2>/dev/null || true
        apt-get autoremove -y 2>/dev/null || true
    fi

    find /lib/modules /usr/lib/modules -type d \( -name 'cmpunlocker*' -o -name '*cmp90hx*' -o -name '*rejoin*' -o -name '*pwner*' \) -prune -exec rm -rf {} + 2>/dev/null || true
    find /lib/modules /usr/lib/modules -path '*/updates/*' \( -name 'nvidia*.ko' -o -name 'nvidia*.ko.zst' -o -name 'nvidia*.ko.xz' \) -delete 2>/dev/null || true
    find /lib/modules /usr/lib/modules -path '*/extra/*' \( -name 'nvidia*.ko' -o -name 'nvidia*.ko.zst' -o -name 'nvidia*.ko.xz' \) -delete 2>/dev/null || true
    find /lib/modules /usr/lib/modules -path '*/weak-updates/*' \( -name 'nvidia*.ko' -o -name 'nvidia*.ko.zst' -o -name 'nvidia*.ko.xz' \) -delete 2>/dev/null || true

    rm -rf /usr/local/src/cmp90hx-pwner /usr/local/src/cmp90hx-rejoin17 /usr/src/nvidia-* /var/lib/dkms/nvidia 2>/dev/null || true
    rm -f /etc/ld.so.conf.d/nvidia*.conf /etc/OpenCL/vendors/nvidia.icd 2>/dev/null || true
    rm -f /usr/bin/nvidia-smi /usr/bin/nvidia-debugdump /usr/bin/nvidia-persistenced /usr/bin/nvidia-settings /usr/bin/nvidia-uninstall /usr/bin/nvidia-modprobe 2>/dev/null || true
    rm -f /var/tmp/NVIDIA-Linux-x86_64-*.run 2>/dev/null || true

    ldconfig 2>/dev/null || true
    depmod -a || true
    command -v update-initramfs >/dev/null 2>&1 && update-initramfs -u -k all || true
}


download_with_retry() {
    local url="$1" out="$2" tmp attempts delay
    attempts="${DOWNLOAD_ATTEMPTS:-10}"
    delay="${DOWNLOAD_RETRY_DELAY:-8}"
    tmp="${out}.part"
    mkdir -p "$(dirname "$out")"

    for ((i=1; i<=attempts; i++)); do
        printf 'download attempt %s/%s: %s\n' "$i" "$attempts" "$url"
        rm -f "$tmp"
        if command -v curl >/dev/null 2>&1; then
            if curl -fL --connect-timeout 30 --retry 2 --retry-delay 5 --retry-all-errors -o "$tmp" "$url"; then
                mv -f "$tmp" "$out"
                return 0
            fi
        elif command -v wget >/dev/null 2>&1; then
            if wget --tries=3 --waitretry=5 --timeout=30 --read-timeout=60 -O "$tmp" "$url"; then
                mv -f "$tmp" "$out"
                return 0
            fi
        else
            printf 'curl/wget missing\n'
            return 127
        fi
        printf 'download failed, retry in %ss\n' "$delay"
        sleep "$delay"
    done
    rm -f "$tmp"
    return 1
}

git_clone_retry() {
    local repo="$1" dst="$2" attempts delay
    attempts="${GIT_ATTEMPTS:-6}"
    delay="${GIT_RETRY_DELAY:-8}"
    rm -rf "$dst"
    for ((i=1; i<=attempts; i++)); do
        printf 'git clone attempt %s/%s: %s\n' "$i" "$attempts" "$repo"
        if git clone --depth 1 "$repo" "$dst"; then
            return 0
        fi
        rm -rf "$dst"
        printf 'git clone failed, retry in %ss\n' "$delay"
        sleep "$delay"
    done
    return 1
}

install_stock_driver() {
    mkdir -p "$(dirname "$NVIDIA_RUN")"

    if [[ ! -s "$NVIDIA_RUN" ]]; then
        download_with_retry "$NVIDIA_RUN_URL" "$NVIDIA_RUN"
    fi

    chmod +x "$NVIDIA_RUN"
    bash "$NVIDIA_RUN" \
        --silent \
        --accept-license \
        --no-questions \
        --no-cc-version-check \
        --no-nouveau-check

    depmod -a
}

install_patched_driver() {
    mkdir -p "$(dirname "$PROJECT_DIR")"
    git_clone_retry "$PROJECT_REPO" "$PROJECT_DIR"
    cd "$PROJECT_DIR"
    # Do not let the upstream installer enable the combined boot action.
    # Fail if its layout changes instead of guessing which commands to remove.
    grep -qx '# 7. systemd unit' scripts/install.sh || {
        printf 'upstream installer layout changed: boot-service section not found\n'
        return 20
    }
    sed -i '/^# 7. systemd unit$/,$d' scripts/install.sh
    mkdir -p /etc/depmod.d
    bash scripts/install.sh
    depmod -a
}

preserve_rejoin_verifiers() {
    mkdir -p "$PREFIX"
    local bin check copied=0

    bin="$(find_rejoin_verifier_bin || true)"
    if [[ -n "$bin" && -x "$bin" ]]; then
        install -m 0755 "$bin" "$PREFIX/cmpunlocker-rs"
        printf 'saved built-in verifier: %s -> %s\n' "$bin" "$PREFIX/cmpunlocker-rs"
        copied=1
    fi

    check="$(find_rejoin_check_sh || true)"
    if [[ -n "$check" && -f "$check" ]]; then
        install -m 0755 "$check" "$PREFIX/check.sh"
        printf 'saved check.sh: %s -> %s\n' "$check" "$PREFIX/check.sh"
        copied=1
    fi

    if [[ "$copied" != "1" ]]; then
        printf 'warning: no built-in rejoin verifier found during install\n'
        printf 'verify will fail until cmpunlocker-rs or check.sh is available\n'
    fi
}


apply_now() {
    [[ -x "$APPLY_SCRIPT" ]] || return 10
    bash "$APPLY_SCRIPT"
}

bind_cmps_to_nvidia() {
    local cmps cmp dev drv ok=0 total=0
    command -v modprobe >/dev/null 2>&1 || { printf 'modprobe missing\n'; return 30; }
    modprobe nvidia 2>/dev/null || true
    modprobe nvidia_uvm 2>/dev/null || true
    sleep 1

    [[ -d /sys/bus/pci/drivers/nvidia ]] || { printf 'nvidia PCI driver is not registered\n'; return 31; }

    mapfile -t cmps < <(find_cmps)
    (( ${#cmps[@]} > 0 )) || { printf 'no CMP 90HX 10de:220d devices found\n'; return 32; }

    for cmp in "${cmps[@]}"; do
        total=$((total + 1))
        dev="/sys/bus/pci/devices/$cmp"
        drv=""
        if [[ -L "$dev/driver" ]]; then
            drv="$(basename "$(readlink -f "$dev/driver")")"
        fi

        if [[ "$drv" != "nvidia" ]]; then
            printf '%s: binding to nvidia driver\n' "$cmp"
            if [[ -n "$drv" && -e "$dev/driver/unbind" ]]; then
                printf '%s' "$cmp" > "$dev/driver/unbind" 2>/dev/null || true
                sleep 1
            fi
            printf 'nvidia' > "$dev/driver_override" 2>/dev/null || true
            printf '%s' "$cmp" > /sys/bus/pci/drivers_probe 2>/dev/null || true
            if [[ ! -L "$dev/driver" ]]; then
                printf '%s' "$cmp" > /sys/bus/pci/drivers/nvidia/bind 2>/dev/null || true
            fi
            sleep 1
        fi

        drv=""
        if [[ -L "$dev/driver" ]]; then
            drv="$(basename "$(readlink -f "$dev/driver")")"
        fi
        printf '%s driver=%s\n' "$cmp" "${drv:-none}"
        [[ "$drv" == "nvidia" ]] && ok=$((ok + 1))
    done

    printf 'nvidia-bound CMP cards: %s/%s\n' "$ok" "$total"
    [[ "$ok" == "$total" ]]
}

verify_compute_unlock() {
    local ver src cmps cmp drv failed=0
    mapfile -t cmps < <(find_cmps)
    (( ${#cmps[@]} > 0 )) || { printf 'no CMP 90HX 10de:220d devices found\n'; return 10; }

    ver="$(modinfo -F version nvidia 2>/dev/null || true)"
    src="$(modinfo -F srcversion nvidia 2>/dev/null || true)"
    printf 'nvidia module version: %s\n' "${ver:-missing}"
    printf 'nvidia module srcversion: %s\n' "${src:-missing}"

    [[ "$ver" == "$DRIVER_VERSION" ]] || return 11
    [[ -n "$src" ]] || return 12

    bind_cmps_to_nvidia || return 13

    for cmp in "${cmps[@]}"; do
        drv="none"
        [[ -L "/sys/bus/pci/devices/$cmp/driver" ]] && drv="$(basename "$(readlink -f "/sys/bus/pci/devices/$cmp/driver")")"
        if [[ "$drv" != "nvidia" ]]; then
            printf '%s not bound to nvidia driver\n' "$cmp"
            failed=1
        fi
    done
    [[ "$failed" == "0" ]] || return 14

    if [[ -r /proc/driver/nvidia/version ]]; then
        cat /proc/driver/nvidia/version
    fi
    printf 'compute driver layer present\n'
}

find_rejoin_verifier_bin() {
    local p
    for p in \
        "$PREFIX/cmpunlocker-rs" \
        "$PREFIX/bin/cmpunlocker-rs" \
        "$PROJECT_DIR/cmpunlocker-rs" \
        "/usr/local/bin/cmpunlocker-rs" \
        "/usr/bin/cmpunlocker-rs"; do
        [[ -x "$p" ]] && { printf '%s\n' "$p"; return 0; }
    done

    find \
        "$PREFIX" \
        "$PROJECT_DIR" \
        /usr/local/src/cmp90hx-pwner \
        /var/tmp \
        /tmp \
        -maxdepth 8 -type f -name cmpunlocker-rs -perm -111 2>/dev/null | head -1
}

find_rejoin_check_sh() {
    local p
    for p in \
        "$PREFIX/check.sh" \
        "$PROJECT_DIR/check.sh" \
        "/usr/local/src/cmp90hx-pwner/cmp90hx/check.sh"; do
        [[ -f "$p" ]] && { printf '%s\n' "$p"; return 0; }
    done

    find \
        "$PREFIX" \
        "$PROJECT_DIR" \
        /usr/local/src/cmp90hx-pwner \
        /var/tmp \
        /tmp \
        -maxdepth 8 -type f -name check.sh -path '*cmp*' 2>/dev/null | head -1
}

verify_rejoin_compute_full() {
    local bin check rc

    bind_cmps_to_nvidia || return 21

    bin="$(find_rejoin_verifier_bin || true)"
    if [[ -n "$bin" && -x "$bin" ]]; then
        printf 'rejoin verifier: %s\n' "$bin"
        "$bin" compute90hx-v67 verify --all-cmp90hx --expect full
        return $?
    fi

    check="$(find_rejoin_check_sh || true)"
    if [[ -n "$check" && -f "$check" ]]; then
        printf 'rejoin check.sh: %s\n' "$check"
        chmod +x "$check" 2>/dev/null || true
        ( cd "$(dirname "$check")" && bash "./$(basename "$check")" )
        rc=$?
        return "$rc"
    fi

    printf 'no rejoin built-in verifier found\n'
    printf 'expected one of:\n'
    printf '  cmpunlocker-rs compute90hx-v67 verify --all-cmp90hx --expect full\n'
    printf '  check.sh from cmp90hx/cmpunlocker tree\n'
    return 20
}


show_verify() {
    STEP_NO=0
    TOTAL_STEPS=4
    local failed=0
    clear_left
    banner
    if run_step 'compute unlock' verify_compute_unlock; then :; else failed=1; fi
    if run_step 'rejoin compute full' verify_rejoin_compute_full; then :; else failed=1; fi
    if run_step 'P2P runtime status' verify_p2p_runtime_status; then :; else failed=1; fi
    if run_step 'Gen2 link' verify_links; then :; else failed=1; fi
    if [[ "$failed" == "0" ]]; then
        ok 'VERIFY COMPLETE'
    else
        warn 'VERIFY FAILED; details are in the right log pane. Program is still alive.'
    fi
    ui '\nPress Enter to return: '
    [[ -t 0 ]] && read -r _ || true
}

set_cmp_iommu_identity_now() {
    local dev group type_file before after groups=()

    mapfile -t groups < <(
        for dev in $(find_cmps); do
            [[ -e "/sys/bus/pci/devices/$dev/iommu_group" ]] || continue
            basename "$(readlink "/sys/bus/pci/devices/$dev/iommu_group")"
        done | sort -n -u
    )

    [[ "${#groups[@]}" -gt 0 ]] || { printf 'no CMP90HX IOMMU groups found\n'; return 1; }

    for group in "${groups[@]}"; do
        type_file="/sys/kernel/iommu_groups/${group}/type"
        [[ -e "$type_file" ]] || { printf 'group %s has no type file\n' "$group"; continue; }

        before="$(cat "$type_file" 2>/dev/null || true)"
        printf 'IOMMU group %s before=%s\n' "$group" "${before:-unknown}"

        if [[ "$before" != "identity" ]]; then
            echo identity > "$type_file" || {
                printf 'cannot set IOMMU group %s to identity\n' "$group"
                return 1
            }
        fi

        after="$(cat "$type_file" 2>/dev/null || true)"
        printf 'IOMMU group %s after=%s\n' "$group" "${after:-unknown}"
        [[ "$after" == "identity" ]] || return 1
    done
}

disable_acs_redirects_now() {
    local dev old new path
    command -v lspci >/dev/null 2>&1 || return 0
    command -v setpci >/dev/null 2>&1 || return 0

    for path in /sys/bus/pci/devices/*; do
        dev="$(basename "$path")"
        lspci -vv -s "$dev" 2>/dev/null | grep -q ACSCtl || continue

        old="$(setpci -s "$dev" ECAP_ACS+0x6.w 2>/dev/null || true)"
        [[ -z "$old" ]] && continue

        new="$(printf '%04x' $(( 0x$old & ~0x000c )))"
        if [[ "$new" != "$old" ]]; then
            printf '%s ACSCtl old=%s new=%s\n' "$dev" "$old" "$new"
            setpci -s "$dev" ECAP_ACS+0x6.w="$new" 2>/dev/null || true
        fi
    done
}

nvidia_stack_loaded_now() {
    lsmod | awk '{print $1}' | grep -Eq '^nvidia($|_)|^nvidia-vgpu-vfio$|^nvidia_vgpu_vfio$'
}

unload_nvidia_stack_for_p2p() {
    local i loaded

    systemctl stop "$COMPUTE_SERVICE" 2>/dev/null || true
    systemctl stop nvidia-persistenced ollama llama open-webui librechat comfyui docker containerd 2>/dev/null || true

    if ls /dev/nvidia* >/dev/null 2>&1; then
        fuser -k -TERM /dev/nvidia* >/dev/null 2>&1 || true
        sleep 2
        fuser -k -KILL /dev/nvidia* >/dev/null 2>&1 || true
    fi

    for i in 1 2 3 4 5; do
        modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia_peermem nvidia 2>/dev/null || true
        modprobe -r nvidia-vgpu-vfio nvidia_vgpu_vfio nvidia_uvm nvidia_drm nvidia_modeset nvidia_peermem nvidia 2>/dev/null || true
        rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia_peermem nvidia_vgpu_vfio nvidia 2>/dev/null || true
        sleep 2

        if ! nvidia_stack_loaded_now; then
            printf 'nvidia stack unloaded\n'
            return 0
        fi

        loaded="$(lsmod | awk '/^nvidia/ {print $1}' | tr '\n' ' ')"
        printf 'nvidia stack still loaded after pass %s/5: %s\n' "$i" "${loaded:-unknown}"
    done

    printf 'failed to unload nvidia stack\n'
    lsmod | grep '^nvidia' || true
    return 1
}

wait_gpu_for_p2p() {
    local i max="${1:-30}"
    for i in $(seq 1 "$max"); do
        nvidia-smi --query-gpu=name --format=csv,noheader >/dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}

load_patched_driver_once_with_p2p() {
    local krel patched_dir patched_srcv loaded p2p_reg

    krel="$(uname -r)"
    patched_dir="/usr/lib/modules/${krel}/updates/cmpunlocker-90hx-stockflow"
    patched_srcv="$(modinfo -F srcversion "${patched_dir}/nvidia.ko" 2>/dev/null || true)"
    p2p_reg='ForceP2P=0x111;CLForceP2P=0x111;RMForceP2PType=1;RMPcieP2PType=0;RMForceStaticBar1=1;PeerMappingOverride=1;RMDisableFeatureDisablement=1'

    [[ -f "${patched_dir}/nvidia.ko" ]] || { printf 'patched nvidia.ko missing: %s\n' "${patched_dir}/nvidia.ko"; return 1; }
    [[ -n "$patched_srcv" ]] || { printf 'patched nvidia.ko srcversion missing\n'; return 1; }

    if nvidia_stack_loaded_now; then
        printf 'nvidia stack is still loaded before P2P insmod\n'
        lsmod | grep '^nvidia' || true
        return 1
    fi

    printf 'loading patched nvidia.ko once with P2P RegistryDwords\n'

    modprobe ecc 2>/dev/null || true
    modprobe ecdh_generic 2>/dev/null || true

    insmod "${patched_dir}/nvidia.ko" \
        NVreg_EnableResizableBar=1 \
        NVreg_DmaRemapPeerMmio=0 \
        NVreg_RegistryDwords="$p2p_reg" || return 1

    if [[ -f "${patched_dir}/nvidia-uvm.ko" ]]; then
        insmod "${patched_dir}/nvidia-uvm.ko" 2>/dev/null || modprobe nvidia_uvm 2>/dev/null || true
    else
        modprobe nvidia_uvm 2>/dev/null || true
    fi

    loaded="$(cat /sys/module/nvidia/srcversion 2>/dev/null || true)"
    printf 'loaded nvidia srcversion: %s\n' "${loaded:-none}"
    printf 'patched nvidia srcversion: %s\n' "$patched_srcv"

    [[ "$loaded" == "$patched_srcv" ]] || return 1
    wait_gpu_for_p2p 30 || { printf 'GPU did not come up after patched P2P load\n'; return 1; }

    printf 'patched P2P module active\n'
}

verify_p2p_runtime_strict() {
    local d g t modpath bad=0 topo_r topo_w

    modpath="$(modinfo -n nvidia 2>/dev/null || true)"
    printf 'nvidia module path: %s\n' "${modpath:-missing}"

    [[ "$modpath" == *'/updates/cmpunlocker-90hx-stockflow/'* ]] || {
        printf 'nvidia is not resolved from patched cmpunlocker-90hx-stockflow path\n'
        bad=1
    }

    printf '\nNVIDIA params:\n'
    cat /proc/driver/nvidia/params 2>/dev/null | grep -Ei 'RegistryDwords|ForceP2P|CLForceP2P|P2P|BAR|Resizable|Dma|Peer|Static|Iomap|Feature' || true

    printf '\nIOMMU groups:\n'
    for d in $(find_cmps); do
        if [[ -e "/sys/bus/pci/devices/$d/iommu_group" ]]; then
            g="$(basename "$(readlink "/sys/bus/pci/devices/$d/iommu_group")")"
            t="$(cat "/sys/kernel/iommu_groups/$g/type" 2>/dev/null || echo none)"
            printf '  %s group=%s type=%s\n' "$d" "$g" "$t"
            [[ "$t" == "identity" ]] || bad=1
        else
            printf '  %s group=none\n' "$d"
            bad=1
        fi
    done

    printf '\nP2P topo read:\n'
    topo_r="$(nvidia-smi topo -p2p r 2>&1)" || bad=1
    printf '%s\n' "$topo_r"
    printf '%s\n' "$topo_r" | grep -q 'OK' || bad=1

    printf '\nP2P topo write:\n'
    topo_w="$(nvidia-smi topo -p2p w 2>&1)" || bad=1
    printf '%s\n' "$topo_w"
    printf '%s\n' "$topo_w" | grep -q 'OK' || bad=1

    [[ "$bad" == "0" ]]
}

verify_p2p_runtime_status() {
    verify_p2p_runtime_strict || true
    return 0
}

show_p2p_status() {
    verify_p2p_runtime_status
}

show_enable_p2p() {
    STEP_NO=0
    TOTAL_STEPS=5
    local failed=0

    clear_left
    banner

    if [[ "$failed" == "0" ]] && ! run_step 'stop workers and unload nvidia' unload_nvidia_stack_for_p2p; then failed=1; fi
    if [[ "$failed" == "0" ]] && ! run_step 'set IOMMU identity' set_cmp_iommu_identity_now; then failed=1; fi
    if [[ "$failed" == "0" ]] && ! run_step 'disable ACS redirects' disable_acs_redirects_now; then failed=1; fi
    if [[ "$failed" == "0" ]] && ! run_step 'load patched driver with P2P' load_patched_driver_once_with_p2p; then failed=1; fi
    if [[ "$failed" == "0" ]] && ! run_step 'verify P2P runtime' verify_p2p_runtime_strict; then failed=1; fi

    if [[ "$failed" == "0" ]]; then
        ok 'P2P ENABLED FOR CURRENT DRIVER SESSION'
        ui '\nP2P is not written to boot/runtime handoff. Reboot or compute-service restart will return to normal handoff.\n'
    else
        warn 'P2P ENABLE FAILED; details are in the right log pane.'
    fi

    ui '\nPress Enter to return: '
    [[ -t 0 ]] && read -r _ || true
}


show_install_cuda() {
    STEP_NO=0
    TOTAL_STEPS=1
    clear_left
    banner
    run_step 'install CUDA toolkit' install_cuda_toolkit
    ok 'CUDA TOOLKIT INSTALLED'
    ui '\nPress Enter to return: '
    [[ -t 0 ]] && read -r _ || true
}


HELPER_BIN_DIR="${HELPER_BIN_DIR:-/usr/local/bin}"
BOOT_BEEP_SERVICE="${BOOT_BEEP_SERVICE:-boot-beep.service}"

menu() {
    clear_left
    banner 1
    ui '1) COMPUTE UNLOCK\n'
    ui '2) PCIe GEN2\n'
    ui '3) ENABLE P2P\n'
    ui '4) VERIFY\n'
    ui '5) INSTALL CUDA TOOLKIT\n'
    ui '6) INSTALL 4-BEEP AT START\n'
    ui '7) INSTALL FAN/GPU HELPERS\n'
    ui '8) UNINSTALL\n'
    ui '0) EXIT\n\nSelect: '
}

remove_obsolete_boot_hook() {
    systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable --now rejoin17-cmp90hx.service 2>/dev/null || true
    rm -f \
        "/etc/systemd/system/$SERVICE_NAME" \
        "/lib/systemd/system/$SERVICE_NAME" \
        "/usr/lib/systemd/system/$SERVICE_NAME" \
        "/etc/systemd/system/multi-user.target.wants/$SERVICE_NAME" \
        /etc/systemd/system/rejoin17-cmp90hx.service \
        /lib/systemd/system/rejoin17-cmp90hx.service \
        /usr/lib/systemd/system/rejoin17-cmp90hx.service \
        /etc/systemd/system/multi-user.target.wants/rejoin17-cmp90hx.service \
        "$BOOT_GATE" \
        "$SSH_PROFILE" \
        /etc/profile.d/cmp90hx-pwner-firstboot.sh \
        /etc/update-motd.d/99-cmp90hx-pwner \
        2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
}

write_compute_runtime() {
    mkdir -p "$PREFIX"
    cat > "$PREFIX/cmp90hx-gen2-handoff.sh" <<'EOF_COMPUTE_HANDOFF'
#!/usr/bin/env bash
# Make the PATCHED nvidia module the active one, safely.
#
# The patched module must not be the *first* nvidia driver load of a power
# cycle. Its V67 chain replaces the signature memdesc that a plain *stock* GSP
# boot leaves behind, so loading it first fails:
#
#   NVRM: GPU0 nvCheckFailedNoLog: Check failed:
#         s_cmp90PcStockSignatureMemdescByGpu[cmp90GpuSlot] == NULL @ kernel_gsp.c:5986
#   NVRM: GPU 0000:03:00.0: RmInitAdapter failed! (0x62:0x40:2119)
#
# and the half-booted GSP leaves WPR2 up, after which every retry in that same
# boot also fails ("_kgspBootGspRm: unexpected WPR2 already up ... the GPU is
# likely in a bad state and may need to be reset"). Only a reboot clears it,
# so a bad first load costs a reboot and the unlock never happens.
#
# Fix: bring the card up with the stock module first, then hand it over to the
# patched module. Pair with /etc/modprobe.d/cmp90hx-gen2-noauto.conf so udev
# does not auto-load the patched module before this runs.
set -uo pipefail

KREL="$(uname -r)"
PATCHED_DIR="/usr/lib/modules/${KREL}/updates/cmpunlocker-90hx-stockflow"
PATCHED_SRCV="$(modinfo -F srcversion "${PATCHED_DIR}/nvidia.ko" 2>/dev/null || true)"
UNLOAD=(nvidia_drm nvidia_modeset nvidia_uvm nvidia_peermem nvidia)

log() { echo "cmp90hx-handoff: $*"; }
loaded_srcv() { cat /sys/module/nvidia/srcversion 2>/dev/null || true; }
gpu_ok() { nvidia-smi --query-gpu=name --format=csv,noheader >/dev/null 2>&1; }

wait_gpu() {  # <tries> (2 s each)
    local i
    for i in $(seq 1 "${1:-30}"); do gpu_ok && return 0; sleep 2; done
    return 1
}

unload_all() {
    modprobe -r "${UNLOAD[@]}" 2>/dev/null || { sleep 2; modprobe -r "${UNLOAD[@]}" 2>/dev/null; }
}

find_stock() {  # echo path of an unpatched nvidia.ko, if any
    local p
    for p in "/usr/lib/modules/${KREL}/updates/dkms/nvidia.ko" \
             "/lib/modules/${KREL}/updates/dkms/nvidia.ko"; do
        [[ -f "$p" ]] && { echo "$p"; return 0; }
    done
    p="$(find "/lib/modules/${KREL}" -name nvidia.ko 2>/dev/null | grep -v -- "$PATCHED_DIR" | head -1)"
    [[ -n "$p" ]] && echo "$p"
}

[[ -n "$PATCHED_SRCV" ]] || { log "FATAL: patched nvidia.ko missing at $PATCHED_DIR"; exit 1; }
[[ -c /dev/nvidiactl || -d /sys/module/nvidia ]] || true

# Fast path: patched module already active with a live GPU.
if [[ "$(loaded_srcv)" == "$PATCHED_SRCV" ]] && gpu_ok; then
    log "patched module already active (srcversion $PATCHED_SRCV)"
    exit 0
fi

STOCK="$(find_stock)"
if [[ -n "$STOCK" ]]; then
    log "priming GPU with stock module: $STOCK"
    unload_all
    modprobe ecc 2>/dev/null || true
    insmod "$STOCK" 2>/dev/null || log "WARNING: insmod stock module failed"
    if wait_gpu 20; then
        log "stock module brought the GPU up"
    else
        log "WARNING: stock module did not bring the GPU up"
    fi
else
    log "WARNING: no stock nvidia.ko found; patched module may fail as first load"
fi

log "handing over to the patched module"
unload_all
sleep 2
modprobe nvidia || { log "FATAL: modprobe nvidia failed"; exit 1; }
loaded="$(loaded_srcv)"
if [[ "$loaded" != "$PATCHED_SRCV" ]]; then
    log "WARNING: loaded srcversion '${loaded:-none}' != patched '$PATCHED_SRCV'"
fi
if wait_gpu 30; then
    modprobe nvidia_uvm 2>/dev/null || true
    log "patched module active (srcversion ${loaded:-?})"
    exit 0
fi
log "FATAL: GPU did not come up on the patched module"
exit 1
EOF_COMPUTE_HANDOFF
    chmod 0755 "$PREFIX/cmp90hx-gen2-handoff.sh"
    cat > "/etc/systemd/system/$COMPUTE_SERVICE" <<EOF_COMPUTE_UNIT
[Unit]
Description=CMP90HX compute driver initialization
Wants=systemd-udev-settle.service
After=systemd-udev-settle.service local-fs.target systemd-modules-load.service
Before=nvidia-persistenced.service ollama.service llama.service open-webui.service librechat.service comfyui.service
ConditionPathExists=$PREFIX/cmp90hx-gen2-handoff.sh

[Service]
Type=oneshot
# A previous interrupted manual write must not be replayed during compute init.
ExecStartPre=/usr/bin/rm -f /var/lib/cmpunlocker-rs/rejoin16-next-write.bin
ExecStart=/bin/bash $PREFIX/cmp90hx-gen2-handoff.sh
RemainAfterExit=yes
TimeoutStartSec=2000

[Install]
WantedBy=multi-user.target
EOF_COMPUTE_UNIT
    systemctl daemon-reload
    systemctl enable "$COMPUTE_SERVICE"
}

write_gen2_runtime() {
    mkdir -p "$PREFIX" || return $?
    # Retire the previous whole-rig runner; all known-good mask stages are in APPLY_SCRIPT.
    rm -f "$PREFIX/cmp90hx-gen2-minimal.sh" || return $?
    cat > "$PREFIX/rejoin16-cycle.sh" <<'EOF_GEN2_CYCLE'
#!/usr/bin/env bash
# Drive one rejoin16 crafted-Booter write per module reload.
#
# The GA102 V67 chain fires only once per FLR-separated module load, so each
# mask register needs its own unload/reload cycle. The patched module reads
# /var/lib/cmpunlocker-rs/rejoin16-next-write.bin (8 bytes LE: addr, value) in
# the canary-success branch and fires exactly one write.
#
# Usage: ./rejoin16-cycle.sh <addr> <value>
#   env CMP90_BDF  target card (default: first CMP 90HX)
set -uo pipefail

ADDR="$1"
VALUE="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BDF="${CMP90_BDF:-$(lspci -Dnn | awk '/10de:220d/ {print $1; exit}')}"
SPEC=/var/lib/cmpunlocker-rs/rejoin16-next-write.bin
POKE="${CMP90_POKE:-${SCRIPT_DIR}/bar0poke}"

[[ -n "$BDF" ]] || { echo "FATAL: no CMP 90HX (10de:220d) found; set CMP90_BDF"; exit 2; }
[[ -n "$ADDR" && -n "$VALUE" ]] || { echo "usage: $0 <addr> <value>"; exit 2; }

mkdir -p /var/lib/cmpunlocker-rs
python3 - "$ADDR" "$VALUE" "$SPEC" <<'PY'
import struct, sys
addr, val, path = int(sys.argv[1], 0), int(sys.argv[2], 0), sys.argv[3]
with open(path, "wb") as f:
    f.write(struct.pack("<II", addr, val))
PY

# Re-lock the compute selectors BEFORE unloading, while BAR0 is still
# accessible. After `modprobe -r` the device drops into a low-power state
# (BAR0 reads back 0xffffffff, every write REJECTED), so the old order
# (unload first, re-lock after) silently left SS0/SS1 full, the V67 canary
# saw "already present" and skipped the Booter chain entirely
# ("(no REJOIN16 lines!)" + PCIe FAIL every cycle). Root trigger was a
# power-management behavior change after an `apt --fix-broken` pulled in
# libnvidia-compute-580/535 + regenerated initramfs; the kernel module
# itself is still 610.43.03. Verified 2026-09-09 on ubuntu1: pre-unload
# re-lock makes REJOIN16 fire on every cycle.
relock() {  # re-lock SS0/SS1 to 0 with readback check; 0 on success
    local try cur0 cur1 reader="${SCRIPT_DIR}/maskread.py"
    for try in 1 2 3; do
        "$POKE" "$BDF" wr 0x0082381c 0x0 >/dev/null 2>&1
        "$POKE" "$BDF" wr 0x00823820 0x0 >/dev/null 2>&1
        if [[ -f "$reader" ]]; then
            read -r cur0 cur1 <<<"$(python3 "$reader" "$BDF" 0x0082381c 0x00823820 2>/dev/null)"
            [[ "$cur0" == "0x00000000" && "$cur1" == "0x00000000" ]] && return 0
        else
            return 0  # no reader available; assume writes landed (legacy path)
        fi
        sleep 1
    done
    return 1
}

restore_full() {  # best-effort restore of full selectors (compute safety net)
    "$POKE" "$BDF" wr 0x0082381c 0x88888888 >/dev/null 2>&1 || true
    "$POKE" "$BDF" wr 0x00823820 0x00000008 >/dev/null 2>&1 || true
}

relock || { echo "FATAL: cannot re-lock selectors while driver loaded; aborting before unload"; restore_full; exit 1; }

# Unload the whole stack (nvidia_drm/nvidia_modeset may be held by udev).
modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia_peermem nvidia 2>/dev/null || {
    sleep 2
    modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia_peermem nvidia 2>/dev/null
} || {
    # 卸载失败(通常是有进程占着 /dev/nvidia*, 例如 ComfyUI 已初始化 CUDA)。
    # 此时上面的 relock 已经把 SS0/SS1 重置为 0, 若不恢复就会【静默丢失算力解锁】
    # (实测: 服务读到 masks=0xffffff8f, 掩码写不进, PCIe 停在 Gen1)。
    echo "FATAL: cannot unload nvidia stack; restoring full selectors"
    restore_full
    exit 1
}

# Re-lock the compute selectors so the canary path runs on the next load.
# (Done above, before unload — see relock(). Writes after unload are
# REJECTED because BAR0 is inaccessible once the driver is gone.)

dmesg -C 2>/dev/null || true

# modprobe (not insmod) so kernel crypto deps (ecdh/ecc) and DRM resolve
# automatically. The patched build is installed in
# /usr/lib/modules/$(uname -r)/updates/cmpunlocker-90hx-stockflow with a depmod
# override, so this loads the patched nvidia.ko.
modprobe nvidia || { echo "FATAL: modprobe nvidia failed"; exit 1; }
sleep 1
nvidia-smi --query-gpu=name --format=csv,noheader >/dev/null 2>&1   # trigger RM init
sleep 1
modprobe nvidia_uvm 2>/dev/null || true

echo "--- REJOIN16 result ---"
dmesg | grep -E "REJOIN16: (spec|fwsec|write|refill)" || echo "(no REJOIN16 lines!)"
echo "--- readback ---"
"$POKE" "$BDF" wr "$ADDR" "$VALUE" 2>/dev/null | sed 's/^/  (cpu-write probe) /' || true
EOF_GEN2_CYCLE
    cat > "$PREFIX/maskread.py" <<'EOF_GEN2_READER'
import os, mmap, struct, sys
# usage: maskread.py <bdf> <addr> [addr...]
# prints one 0x%08x value per address, space separated
bdf = sys.argv[1]
addrs = [int(a, 0) for a in sys.argv[2:]]
fd = os.open(f"/sys/bus/pci/devices/{bdf}/resource0", os.O_RDONLY)
m = mmap.mmap(fd, 16 << 20, mmap.MAP_SHARED, mmap.PROT_READ)
print(" ".join("0x%08x" % struct.unpack_from("<I", m, a)[0] for a in addrs))
os.close(fd)
EOF_GEN2_READER
    chmod 0755 "$PREFIX/rejoin16-cycle.sh" || return $?
    chmod 0644 "$PREFIX/maskread.py" || return $?
    write_apply_script
}

activate_compute_driver() {
    local handoff="$PREFIX/cmp90hx-gen2-handoff.sh"
    [[ -x "$handoff" ]] || { printf 'missing patched-driver handoff helper: %s\n' "$handoff"; return 20; }
    rm -f /var/lib/cmpunlocker-rs/rejoin16-next-write.bin
    bash "$handoff"
}

write_apply_script() {
    mkdir -p "$PREFIX" || return $?
    cat > "$APPLY_SCRIPT" <<'EOF_APPLY' || return $?
#!/usr/bin/env bash
# CMP90HX PCIe Gen2 known-good apply script.
# This is Gen2 only. It does not install compute unlock, does not create systemd,
# and does not create boot autostart.
#
# Based on the supplied known-good script; stages now target one explicit GPU.
# Reconstructed from the successful session:
#   1) per-card handoff -> embedded adaptive masks, soft tries=13, PCI_RESET=0
#   2) failed card: handoff -> embedded adaptive masks, aggressive tries=13, PCI_RESET=1
#   3) for cards still stuck on FEAT 0x00823800:
#      stop GPU users -> unload nvidia -> target PCI reset -> PCI rescan -> handoff
#      -> repeated visible rejoin16-cycle 0x00823800 0xffffffff with retrain after each try
#   4) final soft pass
#
# Required existing runtime files in /opt/cmp90hx-gen2:
#   cmp90hx-gen2-handoff.sh
#   rejoin16-cycle.sh         # real rejoin16-cycle, not resource0 shim
#   maskread.py
#   bar0poke

set -Eeuo pipefail

PREFIX="${CMP90_PREFIX:-/opt/cmp90hx-gen2}"
HANDOFF="${CMP90_HANDOFF:-$PREFIX/cmp90hx-gen2-handoff.sh}"
CYCLE="${CMP90_CYCLE:-$PREFIX/rejoin16-cycle.sh}"
READER="${CMP90_READER:-$PREFIX/maskread.py}"
BAR0POKE="${CMP90_BAR0POKE:-$PREFIX/bar0poke}"

MASK_FEAT="0x00823800"
MASK_XVE="0x00088fe8"

# Retry limits requested for this integration.
SOFT_MASK_TRIES=13
AGGR_MASK_TRIES=13
HARD_FEAT_TRIES=13
STUCK_REPEAT_LIMIT="${CMP90HX_STUCK_REPEAT_LIMIT:-8}"
TOTAL_TIMEOUT="${CMP90HX_TOTAL_TIMEOUT:-3600}"
START="$(date +%s)"
check_timeout() {
    if (( $(date +%s) - START >= TOTAL_TIMEOUT )); then
        log "FAIL: timeout. Reboot the server and run PCIe GEN2 again; card state varies between boots."
        exit 1
    fi
}

LOG="${CMP90HX_GEN2_LOG:-/root/cmp90hx-gen2-known-good-$(date +%Y%m%d-%H%M%S).log}"

exec > >(tee -a "$LOG") 2>&1

log() { printf '[cmp90hx-known-good] %s\n' "$*"; }

need_runtime() {
    [[ -x "$HANDOFF" ]] || { log "FAIL: missing handoff: $HANDOFF"; exit 11; }
    [[ -x "$CYCLE" ]] || { log "FAIL: missing rejoin16-cycle: $CYCLE"; exit 13; }
    [[ -r "$READER" ]] || { log "FAIL: missing mask reader: $READER"; exit 14; }
    [[ -x "$BAR0POKE" ]] || { log "FAIL: missing bar0poke: $BAR0POKE"; exit 15; }

    if grep -q 'via resource0' "$CYCLE" 2>/dev/null; then
        log "FAIL: bad direct-writer shim detected in $CYCLE"
        log "Restore real rejoin16-cycle.sh before running this script."
        exit 16
    fi
}

find_cmps() {
    for d in /sys/bus/pci/devices/*; do
        [[ -f "$d/vendor" && -f "$d/device" ]] || continue
        [[ "$(cat "$d/vendor")" == "0x10de" && "$(cat "$d/device")" == "0x220d" ]] && basename "$d"
    done | sort
}

upstream_of() {
    basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/$1")")"
}

mask_val() {
    local bdf="$1" addr="$2"
    python3 "$READER" "$bdf" "$addr" 2>/dev/null | awk '{print $1}'
}

card_is_gen2() {
    local bdf="$1" up speed endpoint upstream
    up="$(upstream_of "$bdf")"
    speed="$(cat "/sys/bus/pci/devices/$bdf/current_link_speed" 2>/dev/null || true)"
    endpoint="$(lspci -Dvv -s "$bdf" | grep 'LnkSta:' | head -1 || true)"
    upstream="$(lspci -Dvv -s "$up"  | grep 'LnkSta:' | head -1 || true)"
    [[ "$speed" == *"5.0 GT/s"* ]] && [[ "$endpoint" == *"Speed 5GT/s"* ]] && [[ "$upstream" == *"Speed 5GT/s"* ]]
}

verify_links() {
    local cmps bdf up speed width endpoint upstream total=0 okc=0 failed=()
    cmps=("${BDFS[@]}")
    (( ${#cmps[@]} > 0 )) || { log "FAIL: no CMP 90HX 10de:220d devices found"; return 2; }

    for bdf in "${cmps[@]}"; do
        total=$((total + 1))
        up="$(upstream_of "$bdf")"
        speed="$(cat "/sys/bus/pci/devices/$bdf/current_link_speed" 2>/dev/null || true)"
        width="$(cat "/sys/bus/pci/devices/$bdf/current_link_width" 2>/dev/null || true)"
        endpoint="$(lspci -Dvv -s "$bdf" | grep 'LnkSta:' | head -1 || true)"
        upstream="$(lspci -Dvv -s "$up"  | grep 'LnkSta:' | head -1 || true)"

        log "$bdf upstream=$up speed=$speed width=$width"
        log "  endpoint $endpoint"
        log "  upstream $upstream"

        if card_is_gen2 "$bdf"; then
            okc=$((okc + 1))
        else
            failed+=("$bdf")
        fi
    done

    log "GEN2 $okc/$total"
    if (( ${#failed[@]} > 0 )); then
        log "not Gen2 yet: ${failed[*]}"
    fi

    [[ "$okc" == "$total" ]]
}





handoff() {
    local bdf="$1"
    log "$bdf handoff"
    CMP90_BDF="$bdf" bash "$HANDOFF"
}

# Operations from known-good's adaptive dependency, without its GPU loop.
# Subshell keeps its local retrain timings separate from hard-FEAT recovery.
run_card_masks() (
    local bdf="$1" PCI_RESET="$2" MASK_OPEN_TRIES="$3"
    local RESET_ON_STUCK=1 OPEN_REHANDOFF=1 MASK_FEAT_ECC="$MASK_FEAT"
    local RESET_DONE_DIR=/run/cmp90hx-gen2-reset-done
    local m_feat m_xve spd gen
    [[ "$bdf" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]] || return 2
    log "$bdf masks: pci_reset=$PCI_RESET tries=$MASK_OPEN_TRIES"
mask_val() {  # <bdf> <addr> -> value
    python3 "$READER" "$1" "$2" 2>/dev/null | awk '{print $1}'
}

upstream_of() { # <bdf>
    basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/$1")")"
}

retrain_gen2() {   # <bdf>
    local bdf="$1" up lc nc
    up="$(upstream_of "$bdf")"
    log "  $bdf retrain target Gen2"
    setpci -s "$bdf" CAP_EXP+2c.w=0x0002 2>/dev/null || true
    setpci -s "$up"  CAP_EXP+2c.w=0x0002 2>/dev/null || true
    lc="$(setpci -s "$up" CAP_EXP+10.w 2>/dev/null || true)"
    if [[ -n "$lc" ]]; then
        printf -v nc '0x%x' $(( (16#$lc) | 0x20 ))
        setpci -s "$up" CAP_EXP+10.w="$nc" 2>/dev/null || true
    fi
    sleep 2
}

retrain_gen1_then_gen2() { # <bdf>
    local bdf="$1" up lc nc
    up="$(upstream_of "$bdf")"
    log "  $bdf speed-pulse Gen1 -> Gen2"
    setpci -s "$bdf" CAP_EXP+2c.w=0x0001 2>/dev/null || true
    setpci -s "$up"  CAP_EXP+2c.w=0x0001 2>/dev/null || true
    lc="$(setpci -s "$up" CAP_EXP+10.w 2>/dev/null || true)"
    if [[ -n "$lc" ]]; then
        printf -v nc '0x%x' $(( (16#$lc) | 0x20 ))
        setpci -s "$up" CAP_EXP+10.w="$nc" 2>/dev/null || true
    fi
    sleep 2
    setpci -s "$bdf" CAP_EXP+2c.w=0x0002 2>/dev/null || true
    setpci -s "$up"  CAP_EXP+2c.w=0x0002 2>/dev/null || true
    lc="$(setpci -s "$up" CAP_EXP+10.w 2>/dev/null || true)"
    if [[ -n "$lc" ]]; then
        printf -v nc '0x%x' $(( (16#$lc) | 0x20 ))
        setpci -s "$up" CAP_EXP+10.w="$nc" 2>/dev/null || true
    fi
    sleep 3
}

nvidia_wake() { # <bdf>
    local bdf="$1"
    log "  $bdf nvidia-smi settle"
    nvidia-smi --query-gpu=pci.bus_id,pcie.link.gen.current --format=csv,noheader,nounits >/dev/null 2>&1 || true
    sleep 2
}

soft_rehandoff() { # <bdf>
    local bdf="$1"
    [[ "$OPEN_REHANDOFF" == "1" ]] || return 0
    [[ -x "$HANDOFF" ]] || return 0
    log "  $bdf full handoff refresh"
    CMP90_BDF="$bdf" bash "$HANDOFF" || true
    sleep 4
}

pci_function_reset_once() { # <bdf> <addr>
    local bdf="$1" addr="$2" dev="/sys/bus/pci/devices/$1" key
    [[ "$PCI_RESET" == "1" && "$RESET_ON_STUCK" == "1" ]] || return 0
    [[ -w "$dev/reset" ]] || { log "  $bdf PCI reset unavailable"; return 0; }
    mkdir -p "$RESET_DONE_DIR" 2>/dev/null || true
    key="${bdf//[:.]/_}_${addr}"
    [[ ! -e "$RESET_DONE_DIR/$key" ]] || { log "  $bdf PCI reset already used for $addr in this run"; return 0; }
    : > "$RESET_DONE_DIR/$key" 2>/dev/null || true
    log "  $bdf PCI function reset for stuck $addr"
    echo 1 > "$dev/reset" 2>/dev/null || true
    sleep 8
    retrain_gen2 "$bdf"
    soft_rehandoff "$bdf"
}

settle_for_try() { # <try>
    local t="$1"
    case $(( (t - 1) % 10 )) in
        0) printf '0' ;;
        1) printf '0.25' ;;
        2) printf '0.5' ;;
        3) printf '1' ;;
        4) printf '2' ;;
        5) printf '3' ;;
        6) printf '5' ;;
        7) printf '8' ;;
        8) printf '13' ;;
        *) printf '1' ;;
    esac
}

try_prepare() { # <bdf> <try>
    local bdf="$1" try="$2"
    case $(( try % 18 )) in
        3|11)
            log "  $bdf try $try: pre-retrain"
            retrain_gen2 "$bdf"
            ;;
        5|13)
            log "  $bdf try $try: speed-pulse"
            retrain_gen1_then_gen2 "$bdf"
            ;;
        7)
            log "  $bdf try $try: nvidia settle"
            nvidia_wake "$bdf"
            ;;
        9)
            log "  $bdf try $try: longer quiet settle"
            sleep 10
            ;;
        15)
            log "  $bdf try $try: handoff refresh"
            soft_rehandoff "$bdf"
            ;;
        0)
            log "  $bdf try $try: reset stage if enabled"
            ;;
    esac
}

open_mask() { # <bdf> <addr>
    local bdf="$1" addr="$2" try cur delay old_cur repeat_count=0

    cur="$(mask_val "$bdf" "$addr")"
    [[ "$cur" == "0xffffffff" ]] && { log "  $bdf open $addr already OK"; return 0; }
    old_cur="$cur"

    for try in $(seq 1 "$MASK_OPEN_TRIES"); do
        check_timeout
        try_prepare "$bdf" "$try"

        CMP90_BDF="$bdf" bash "$CYCLE" "$addr" 0xffffffff >/dev/null 2>&1 || true

        cur="$(mask_val "$bdf" "$addr")"
        [[ "$cur" == "0xffffffff" ]] && { log "  $bdf open $addr OK (try $try immediate)"; return 0; }

        sleep 0.25
        cur="$(mask_val "$bdf" "$addr")"
        [[ "$cur" == "0xffffffff" ]] && { log "  $bdf open $addr OK (try $try delayed-250ms)"; return 0; }

        sleep 1
        cur="$(mask_val "$bdf" "$addr")"
        [[ "$cur" == "0xffffffff" ]] && { log "  $bdf open $addr OK (try $try delayed-1s)"; return 0; }

        if [[ "$cur" == "$old_cur" ]]; then
            repeat_count=$((repeat_count + 1))
        else
            repeat_count=0
            old_cur="$cur"
        fi

        if (( repeat_count == STUCK_REPEAT_LIMIT )); then
            log "  $bdf open $addr readback stuck at ${cur:-none}; handoff refresh"
            soft_rehandoff "$bdf"
        fi

        if (( repeat_count == STUCK_REPEAT_LIMIT + 4 )); then
            log "  $bdf open $addr still stuck at ${cur:-none}; reset stage"
            pci_function_reset_once "$bdf" "$addr"
            repeat_count=0
        fi

        delay="$(settle_for_try "$try")"
        log "  $bdf open $addr try $try readback=${cur:-none}; sleep ${delay}s"
        sleep "$delay"
    done

    cur="$(mask_val "$bdf" "$addr")"
    log "  $bdf open $addr FAIL (readback=${cur:-none})"
    return 1
}

    m_feat="$(mask_val "$bdf" "$MASK_FEAT_ECC")"
    m_xve="$(mask_val "$bdf" "$MASK_XVE")"
    log "$bdf masks feat_ecc=$m_feat xve=$m_xve"

    if [[ "$m_feat" == "0xffffffff" && "$m_xve" == "0xffffffff" ]]; then
        log "  masks already open - no reload cycles needed"
    else
        [[ "$m_feat" == "0xffffffff" ]] || open_mask "$bdf" "$MASK_FEAT_ECC" || true
        [[ "$m_xve"  == "0xffffffff" ]] || open_mask "$bdf" "$MASK_XVE"      || true
    fi

    retrain_gen2 "$bdf"
    spd="$(cat "/sys/bus/pci/devices/${bdf}/current_link_speed" 2>/dev/null || true)"
    gen="$(nvidia-smi --query-gpu=pcie.link.gen.current,pci.bus_id --format=csv,noheader,nounits 2>/dev/null \
           | awk -v b="${bdf#0000:}" '$2 ~ b {print $1; exit}' || true)"
    log "  $bdf link=${spd:-?} gen=${gen:-?}"
    sleep 5
)

soft_pass() {
    local bdf="$1" label="$2"
    log "$bdf SOFT: $label"
    handoff "$bdf" || true
    run_card_masks "$bdf" 0 "$SOFT_MASK_TRIES" || true
    card_is_gen2 "$bdf"
}

aggressive_pass() {
    local bdf="$1"
    log "$bdf AGGRESSIVE: handoff -> masks with PCI reset"
    rm -rf /run/cmp90hx-gen2-reset-done 2>/dev/null || true
    handoff "$bdf" || true
    run_card_masks "$bdf" 1 "$AGGR_MASK_TRIES" || true
    card_is_gen2 "$bdf"
}

stop_gpu_users() {
    log "stop GPU users"
    systemctl stop nvidia-persistenced 2>/dev/null || true
    systemctl stop ollama llama open-webui librechat comfyui docker containerd 2>/dev/null || true
    pkill -f 'nvidia-smi|llama-server|ollama|comfyui|python.*cuda|python.*torch|python.*nvidia' 2>/dev/null || true
    if ls /dev/nvidia* >/dev/null 2>&1; then
        fuser -k /dev/nvidia* 2>/dev/null || true
    fi
    sleep 2
}

nvidia_loaded() {
    lsmod | awk '{print $1}' | grep -Eq '^nvidia($|_)|^nvidia-vgpu-vfio$|^nvidia_vgpu_vfio$'
}

force_unload_nvidia() {
    local i loaded
    for i in 1 2 3 4 5; do
        stop_gpu_users
        modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia_peermem nvidia 2>/dev/null || true
        modprobe -r nvidia-vgpu-vfio nvidia_uvm nvidia_drm nvidia_modeset nvidia_peermem nvidia 2>/dev/null || true
        rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia_peermem nvidia_vgpu_vfio nvidia 2>/dev/null || true
        sleep 2

        if ! nvidia_loaded; then
            log "nvidia stack unloaded"
            return 0
        fi

        loaded="$(lsmod | awk '/^nvidia/ {print $1}' | tr '\n' ' ')"
        log "nvidia stack still loaded after pass $i/5: ${loaded:-unknown}"
    done

    log "FAIL: nvidia stack still loaded"
    lsmod | grep '^nvidia' || true
    return 1
}

retrain_gen2() {
    local bdf="$1" up lc nc
    up="$(upstream_of "$bdf")"
    log "$bdf pre-retrain target Gen2 via upstream=$up"
    setpci -s "$bdf" CAP_EXP+2c.w=0x0002 2>/dev/null || true
    setpci -s "$up"  CAP_EXP+2c.w=0x0002 2>/dev/null || true
    lc="$(setpci -s "$up" CAP_EXP+10.w 2>/dev/null || true)"
    if [[ -n "$lc" ]]; then
        printf -v nc '0x%x' $(( (16#$lc) | 0x20 ))
        setpci -s "$up" CAP_EXP+10.w="$nc" 2>/dev/null || true
    fi
    sleep 3
}

hard_feat_card() {
    local bdf="$1" try feat

    log "=== hard FEAT fallback for $bdf ==="
    log "$bdf exact method: unload nvidia -> PCI reset card -> rescan -> handoff -> repeated rejoin16-cycle FEAT + retrain"

    force_unload_nvidia || return 1

    if [[ -w "/sys/bus/pci/devices/$bdf/reset" ]]; then
        log "$bdf PCI function reset"
        echo 1 > "/sys/bus/pci/devices/$bdf/reset" 2>/dev/null || true
        sleep 5
    else
        log "$bdf no writable PCI reset"
    fi

    log "PCI rescan"
    echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
    sleep 5

    log "$bdf masks before hard handoff: $(python3 "$READER" "$bdf" "$MASK_FEAT" "$MASK_XVE" 2>/dev/null || true)"

    dmesg -C 2>/dev/null || true
    CMP90_BDF="$bdf" bash "$HANDOFF" || true

    for try in $(seq 1 "$HARD_FEAT_TRIES"); do
        check_timeout
        log "----- $bdf FEAT try $try/$HARD_FEAT_TRIES -----"
        CMP90_BDF="$bdf" bash "$CYCLE" "$MASK_FEAT" 0xffffffff || true

        feat="$(mask_val "$bdf" "$MASK_FEAT")"
        log "$bdf masks after FEAT try $try: $(python3 "$READER" "$bdf" "$MASK_FEAT" "$MASK_XVE" 2>/dev/null || true)"

        if [[ "$feat" == "0xffffffff" ]]; then
            log "$bdf FEAT OPENED on try $try"
            retrain_gen2 "$bdf"
            return 0
        fi

        retrain_gen2 "$bdf"
    done

    log "$bdf hard FEAT fallback did not open FEAT"
    return 1
}



main() {
    local bdf index=0
    [[ "$(id -u)" == 0 ]] || { log "FAIL: run as root"; exit 1; }
    need_runtime
    mapfile -t BDFS < <(find_cmps)
    (( ${#BDFS[@]} > 0 )) || { log "FAIL: no CMP 90HX cards found"; exit 2; }
    if [[ "${1:-}" == --verify-only ]]; then
        verify_links
        exit $?
    fi
    log "LOG: $LOG"
    log "known-good card order: ${BDFS[*]}"
    log "tries: soft=$SOFT_MASK_TRIES aggressive=$AGGR_MASK_TRIES hard_FEAT=$HARD_FEAT_TRIES"
    if verify_links; then
        log "already Gen2"
        exit 0
    fi

    for bdf in "${BDFS[@]}"; do
        check_timeout
        index=$((index + 1))
        log "$bdf CARD $index/${#BDFS[@]} START"
        if card_is_gen2 "$bdf"; then
            log "$bdf already Gen2; skip"
        elif soft_pass "$bdf" "initial known-good pass"; then
            log "$bdf Gen2 after soft pass"
        else
            aggressive_pass "$bdf" || true
            # Always finish an aggressive attempt with the known-good soft stage.
            soft_pass "$bdf" "mandatory soft after aggressive" || true
        fi
        log "$bdf CARD END"
    done

    # Recheck each GPU now, since a shared driver reload may change its state.
    for bdf in "${BDFS[@]}"; do
        check_timeout
        card_is_gen2 "$bdf" && continue
        log "$bdf RESCUE START"
        if [[ "$(mask_val "$bdf" "$MASK_FEAT")" != 0xffffffff ]]; then
            hard_feat_card "$bdf" || true
        else
            log "$bdf FEAT already open; skip hard-FEAT reset"
        fi
        # Includes XVE processing; run even if hard FEAT already reached Gen2.
        soft_pass "$bdf" "final known-good pass after rescue" || true
        log "$bdf RESCUE END"
    done

    if verify_links; then
        log "SUCCESS: GEN2 all/all"
        exit 0
    fi
    log "FAIL: Gen2 did not converge. Reboot the server and run PCIe GEN2 again."
    log "Card state varies between boots; another attempt may help."
    exit 1
}

main "$@"
EOF_APPLY
    chmod +x "$APPLY_SCRIPT" || return $?
}

clean_install_unlock() {
    STEP_NO=0
    TOTAL_STEPS=14
    clear_left
    banner
    run_step 'backup' backup_state
    run_step 'stop GPU users' stop_gpu_users
    run_step 'remove previous pwner install' purge_old_pwner
    run_step 'remove previous NVIDIA driver' nvidia_uninstall_best_effort
    run_step 'install dependencies' apt_install_base
    run_step 'block nouveau' blacklist_nouveau
    run_step 'install stock NVIDIA driver' install_stock_driver
    run_step 'install patched driver' install_patched_driver
    run_step 'remove obsolete boot hook' remove_obsolete_boot_hook
    run_step 'install compute startup' write_compute_runtime
    run_step 'activate patched compute driver' activate_compute_driver
    run_step 'preserve compute verifier' preserve_rejoin_verifiers
    run_step 'verify compute driver' verify_compute_unlock
    run_step 'verify compute unlock' verify_rejoin_compute_full
    ok 'COMPUTE UNLOCK COMPLETE'
    ui 'Press Enter to return: '
    [[ -t 0 ]] && read -r _ || true
}

show_apply_gen2() {
    STEP_NO=0
    TOTAL_STEPS=3
    clear_left
    banner
    if [[ ! -x "$PREFIX/cmp90hx-gen2-handoff.sh" || ! -x "$PREFIX/bar0poke" ]]; then
        fail 'Required driver runtime is missing. Install COMPUTE UNLOCK first.'
    elif ! run_step 'disable Gen2 autostart' remove_obsolete_boot_hook; then
        fail 'Could not disable the old boot hook. See the right log pane.'
    elif ! run_step 'write integrated known-good Gen2 runtime' write_gen2_runtime; then
        fail 'Could not write the Gen2 runtime. See the right log pane.'
    else
        ui '\nEach card: known-good soft pass, then aggressive and final soft if needed.\n'
        ui 'Remaining failures: known-good hard FEAT reset and up to 13 fresh writes, then final soft.\n'
        ui 'This can take several minutes. Details remain in the right log pane.\n'
        if run_step 'apply Gen2 with known-good recovery' apply_now; then
            ok 'PCIe GEN2 COMPLETE'
            ui '\nGen2 is manual. Run this item again after every reboot.\n'
        else
            warn 'Gen2 could not be enabled on all cards.'
            ui 'Please reboot the server, then run PCIe GEN2 again.\n'
            ui 'Card state varies between boots; another attempt may succeed, but is not guaranteed.\n'
            ui 'No reboot is started automatically. Both tmux panes remain open.\n'
        fi
    fi
    ui '\nPress Enter to return to the menu: '
    [[ -t 0 ]] && read -r _ || true
    return 0
}

remove_optional_helpers(){
    systemctl disable --now "$BOOT_BEEP_SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/$BOOT_BEEP_SERVICE" /usr/local/sbin/boot-beep4.py 2>/dev/null || true
    rm -f "$HELPER_BIN_DIR/fan-100" "$HELPER_BIN_DIR/fan-60" "$HELPER_BIN_DIR/fan-auto" "$HELPER_BIN_DIR/gpu-full" "$HELPER_BIN_DIR/gpu-idle" 2>/dev/null || true
    systemctl daemon-reload || true
}

install_boot_beep(){
    cat > /usr/local/sbin/boot-beep4.py <<'PY_BEEP4'
#!/usr/bin/env python3
import fcntl, os, time
KIOCSOUND=0x4B2F; DIVISOR=int(1193180/1000)
for dev in ("/dev/console","/dev/tty0"):
    try:
        fd=os.open(dev, os.O_WRONLY)
        for _ in range(4):
            fcntl.ioctl(fd,KIOCSOUND,DIVISOR); time.sleep(0.15); fcntl.ioctl(fd,KIOCSOUND,0); time.sleep(0.15)
        os.close(fd); break
    except Exception: pass
PY_BEEP4
    chmod +x /usr/local/sbin/boot-beep4.py
    cat > "/etc/systemd/system/${BOOT_BEEP_SERVICE}" <<'EOF_BEEP_UNIT'
[Unit]
Description=Four PC speaker beeps after successful boot
After=multi-user.target
ConditionPathExists=/usr/local/sbin/boot-beep4.py
[Service]
Type=oneshot
ExecStartPre=-/sbin/modprobe pcspkr
ExecStart=/usr/local/sbin/boot-beep4.py
[Install]
WantedBy=multi-user.target
EOF_BEEP_UNIT
    systemctl daemon-reload; systemctl enable "$BOOT_BEEP_SERVICE"; systemctl start "$BOOT_BEEP_SERVICE" || true
}

install_fan_gpu_helpers(){
    mkdir -p "$HELPER_BIN_DIR"
    cat > "$HELPER_BIN_DIR/fan-100" <<'EOF_FAN100'
#!/usr/bin/env bash
set -u
if ! command -v nvidia-settings >/dev/null 2>&1; then echo "nvidia-settings is missing"; exit 1; fi
export DISPLAY="${DISPLAY:-:0}"
for g in $(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null); do
    nvidia-settings -a "[gpu:${g}]/GPUFanControlState=1" || true
    nvidia-settings -a "[fan:${g}]/GPUTargetFanSpeed=100" || true
done
EOF_FAN100
    cat > "$HELPER_BIN_DIR/fan-60" <<'EOF_FAN60'
#!/usr/bin/env bash
set -u
if ! command -v nvidia-settings >/dev/null 2>&1; then echo "nvidia-settings is missing"; exit 1; fi
export DISPLAY="${DISPLAY:-:0}"
for g in $(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null); do
    nvidia-settings -a "[gpu:${g}]/GPUFanControlState=1" || true
    nvidia-settings -a "[fan:${g}]/GPUTargetFanSpeed=60" || true
done
EOF_FAN60
    cat > "$HELPER_BIN_DIR/fan-auto" <<'EOF_FANAUTO'
#!/usr/bin/env bash
set -u
if ! command -v nvidia-settings >/dev/null 2>&1; then echo "nvidia-settings is missing"; exit 1; fi
export DISPLAY="${DISPLAY:-:0}"
for g in $(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null); do
    nvidia-settings -a "[gpu:${g}]/GPUFanControlState=0" || true
done
EOF_FANAUTO
    cat > "$HELPER_BIN_DIR/gpu-full" <<'EOF_GPUFULL'
#!/usr/bin/env bash
set -u
command -v nvidia-smi >/dev/null 2>&1 || { echo "nvidia-smi is missing"; exit 1; }
for g in $(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null); do
    nvidia-smi -i "$g" -pm 1 || true
    nvidia-smi -i "$g" -rgc || true
    nvidia-smi -i "$g" -rmc || true
    nvidia-smi -i "$g" -lmc 9501,9501 || true
done
EOF_GPUFULL
    cat > "$HELPER_BIN_DIR/gpu-idle" <<'EOF_GPUIDLE'
#!/usr/bin/env bash
set -u
command -v nvidia-smi >/dev/null 2>&1 || { echo "nvidia-smi is missing"; exit 1; }
for g in $(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null); do
    nvidia-smi -i "$g" -pm 1 || true
    nvidia-smi -i "$g" -rgc || true
    nvidia-smi -i "$g" -lmc 405,405 || true
done
EOF_GPUIDLE
    chmod +x "$HELPER_BIN_DIR/fan-100" "$HELPER_BIN_DIR/fan-60" "$HELPER_BIN_DIR/fan-auto" "$HELPER_BIN_DIR/gpu-full" "$HELPER_BIN_DIR/gpu-idle"
    printf 'installed helpers:\n'
    ls -l "$HELPER_BIN_DIR/fan-100" "$HELPER_BIN_DIR/fan-60" "$HELPER_BIN_DIR/fan-auto" "$HELPER_BIN_DIR/gpu-full" "$HELPER_BIN_DIR/gpu-idle"
}

show_install_boot_beep(){ STEP_NO=0; TOTAL_STEPS=1; clear_left; banner; run_step 'install 4-beep at start' install_boot_beep; ok '4-BEEP INSTALLED'; ui '\nPress Enter to return: '; [[ -t 0 ]] && read -r _ || true; }
show_install_helpers(){ STEP_NO=0; TOTAL_STEPS=1; clear_left; banner; run_step 'install fan/gpu helpers' install_fan_gpu_helpers; ok 'FAN/GPU HELPERS INSTALLED'; ui '\nPress Enter to return: '; [[ -t 0 ]] && read -r _ || true; }

uninstall_all() {
    STEP_NO=0
    TOTAL_STEPS=9
    clear_left
    banner
    warn 'UNINSTALL removes runtime, optional helpers, patched driver and NVIDIA driver files.'
    run_step 'stop services' stop_gpu_users || true
    run_step 'remove pwner runtime' purge_old_pwner || true
    run_step 'remove optional helpers' remove_optional_helpers || true
    run_step 'remove NVIDIA driver' nvidia_uninstall_best_effort || true
    run_step 'remove nouveau blacklist' remove_bootloader_nouveau_blacklist || true
    run_step 'sanitize depmod' sanitize_depmod || true
    run_step 'restore initramfs' bash -c 'depmod -a; command -v update-initramfs >/dev/null 2>&1 && update-initramfs -u -k all || true' || true
    run_step 'reload systemd' systemctl daemon-reload || true
    run_step 'sync' sync || true
    ok 'UNINSTALL COMPLETE'
}

usage() {
    cat <<EOF_USAGE
$PROGRAM_NAME
$REPO_URL

Usage:
  sudo ./rejoin17.sh
  sudo ./rejoin17.sh --compute-unlock
  sudo ./rejoin17.sh --gen2
  sudo ./rejoin17.sh --p2p-enable
  sudo ./rejoin17.sh --p2p-status
  sudo ./rejoin17.sh --verify
  sudo ./rejoin17.sh --install-cuda
  sudo ./rejoin17.sh --install-beep
  sudo ./rejoin17.sh --install-helpers
  sudo ./rejoin17.sh --uninstall
  sudo ./rejoin17.sh --no-tui --verify

PCIe Gen2 is manual and is not enabled at boot.
Run --gen2 again after every reboot when Gen2 is wanted.

Gen2 mask-open attempts per card/register/pass:
  known-good soft=13, aggressive=13 (fixed)
  confirmed hard-FEAT recovery=13 fresh attempts after target reset
Convergence timing defaults:
  CMP90HX_TOTAL_TIMEOUT=3600
EOF_USAGE
}

main() {
    case "${1:-}" in
        --compute-unlock|--compute) clean_install_unlock ;;
        --gen2|--apply-gen2)
            show_apply_gen2
            # A command-line Gen2 action in the split UI also returns to its menu.
            if [[ "${CMP90HX_TUI_CHILD:-0}" == "1" && -t 0 ]]; then
                main
            fi
            ;;
        --p2p|--p2p-menu|--p2p-enable) show_enable_p2p ;;
        --p2p-status) show_p2p_status ;;
        --verify|--status) show_verify ;;
        --install-cuda|--cuda) show_install_cuda ;;
        --install-beep|--beep) show_install_boot_beep ;;
        --install-helpers|--helpers|--fan-scripts|--gpu-scripts) show_install_helpers ;;
        --uninstall|--rollback|--remove|--cancel) uninstall_all ;;
        --unlock-this-shit|--unlock)
            fail 'combined compute+Gen2 mode was removed; choose COMPUTE UNLOCK or PCIe GEN2'
            exit 2
            ;;
        --help|-h) usage ;;
        '')
            while true; do
                menu
                IFS= read -r choice
                case "$choice" in
                    1) clean_install_unlock ;;
                    2) show_apply_gen2 ;;
                    3) show_enable_p2p ;;
                    4) show_verify ;;
                    5) show_install_cuda ;;
                    6) show_install_boot_beep ;;
                    7) show_install_helpers ;;
                    8)
                        ui 'Type UNINSTALL to remove everything: '
                        IFS= read -r confirm
                        [[ "$confirm" == "UNINSTALL" ]] && uninstall_all || warn 'cancelled'
                        ;;
                    0) exit 0 ;;
                    *) warn 'unknown option'; sleep 1 ;;
                esac
            done
            ;;
        *) usage; exit 2 ;;
    esac
}

main "$@"
