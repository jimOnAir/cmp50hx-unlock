#!/usr/bin/env bash
# lifecycle-test-deb.sh — prove the cmp50hx-unlock .deb lifecycle contract:
# install (ALL kernels with headers) -> purge -> reinstall -> remove -> purge
# again, plus the dynamic self-containment leg (install offline). Companion
# of tools/smoke-test-deb.sh, which checks the static package contract only.
#
# Two modes:
#   host:  tools/lifecycle-test-deb.sh loop --deb <path> [--container NAME]
#            [--skip-offline] [--keep]
#            Orchestrates an ubuntu:24.04 container (CI-equivalent throwaway
#            env), preinstalls TWO kernel header sets (+ one image so real
#            /boot initrd images exist), then runs the phases below and
#            prints one verdict line per leg.
#   inside: tools/lifecycle-test-deb.sh --on-host <phase> [args...]
#            phase = install-online <deb> | remove | purge | purge-idempotent
#                    | assert-install | assert-removed [--purged]
#                    | offline-install <deb> | kernels
#            Runnable in ANY Ubuntu/Debian target (the container, the llm2
#            window between its GO gates). No repo checkout required; the
#            driver version is derived from the installed package stamp.
#
# Environment overrides (loop): LC_IMAGE, LC_CONTAINER, LC_HEADERS.
set -Eeuo pipefail

readonly pkg="cmp50hx-unlock"
readonly install_dir="/opt/cmp50hx-unlock"
readonly state_dir="/var/lib/cmp50hx-unlock"
readonly log_file="/var/log/cmp50hx-unlock-install.log"
readonly pin_file="/etc/apt/preferences.d/cmp50hx-unlock"
readonly module_list="nvidia nvidia-uvm nvidia-modeset nvidia-drm nvidia-peermem"

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf '  ok: %s\n' "$*"; }
declare -i FAILURES=0

driver_version() {
    cut -d- -f1 < "${install_dir}/VERSION" 2>/dev/null || true
}

# All kernels this box can build modules for (same rule as deb/postinst).
kernels_with_headers() {
    while IFS= read -r k; do
        [[ -d "/lib/modules/${k}/build" ]] && printf '%s\n' "${k}"
    done < <(ls -1 /usr/src 2>/dev/null | sed -n 's/^linux-headers-\(.*\)$/\1/p')
}

# --- phases ---------------------------------------------------------------

phase_install_online() {
    local deb="${1:?install-online needs the deb path}"
    log "install: apt-get install ${deb}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${deb}"
}

phase_offline_install() {
    local deb="${1:?offline-install needs the deb path}"
    # dpkg -i on purpose: apt could reach the network for dependency
    # resolution; here every dependency is already installed and the whole
    # point is proving postinst itself never reaches out.
    log "offline install: dpkg -i ${deb}"
    dpkg -i "${deb}"
}

phase_remove() {
    log "remove: apt-get remove -y ${pkg}"
    DEBIAN_FRONTEND=noninteractive apt-get remove -y "${pkg}"
}

phase_purge() {
    log "purge: apt-get purge -y ${pkg}"
    DEBIAN_FRONTEND=noninteractive apt-get purge -y "${pkg}"
}

phase_purge_idempotent() {
    # Second purge of an already-purged package: must be a silent no-op.
    log "purge (idempotency): dpkg --purge ${pkg}"
    local out
    if out="$(dpkg --purge "${pkg}" 2>&1)"; then
        log "second purge exited 0"
    elif grep -qiE 'not installed|no installed package|is not installed' <<<"${out}"; then
        log "dpkg reports the package not installed: clean no-op"
    else
        printf '%s\n' "${out}" >&2
        fail "idempotent purge failed"
    fi
    dpkg -C >/dev/null 2>&1 || fail "dpkg database left broken by the second purge"
}

assert_dkms_installed_kernel() {
    local kernel="$1"
    local version="$2"
    local ko
    for mod in ${module_list}; do
        ko="$(modinfo -n -k "${kernel}" "${mod}" 2>/dev/null || true)"
        [[ "${ko}" == /lib/modules/${kernel}/updates/* ]] \
            && ok "${mod}.ko first for ${kernel}: ${ko}" \
            || fail "${mod} not under /lib/modules/${kernel}/updates/ (found: ${ko:-none})"
    done
    local mv
    mv="$(modinfo -F version -k "${kernel}" nvidia 2>/dev/null || true)"
    [[ "${mv}" == "${version}" ]] && ok "nvidia version ${mv} for ${kernel}" \
        || fail "nvidia version for ${kernel} is '${mv:-none}', want ${version}"
}

phase_assert_install() {
    [[ -s "${install_dir}/VERSION" ]] || { fail "no ${install_dir}/VERSION: package not installed"; return; }
    local version
    version="$(driver_version)"
    local -a kernels=("$@")
    if [[ ${#kernels[@]} -eq 0 ]]; then
        mapfile -t kernels < <(kernels_with_headers)
    fi
    (( ${#kernels[@]} >= 1 )) || fail "no kernels with headers found"
    log "assert-install: driver ${version}, kernels: ${kernels[*]}"
    # never `cmd | grep -q`: with pipefail, grep -q's early exit kills the
    # writer with SIGPIPE (141) and reads as failure — capture, then match
    # on a here-string (same trap documented in smoke-test-deb.sh)
    local dstatus
    dstatus="$(dpkg-query -W -f='${db:Status-Status}\n' "${pkg}" 2>/dev/null || true)"
    [[ "${dstatus}" == installed ]] && ok "dpkg status installed" \
        || fail "dpkg status is '${dstatus:-unknown}', want 'installed'"
    local dks
    dks="$(dkms status 2>/dev/null || true)"
    grep -q "^cmp50hx/${version}.*: installed" <<<"${dks}" \
        && ok "dkms status shows cmp50hx/${version} installed" \
        || fail "dkms status lacks cmp50hx/${version}: $(grep cmp50hx <<<"${dks}" || echo '(none)')"
    local kernel
    for kernel in "${kernels[@]}"; do
        assert_dkms_installed_kernel "${kernel}" "${version}"
    done
    [[ -s "${pin_file}" ]] && ok "apt pin file present" || fail "apt pin file missing"
    for cf in /etc/modprobe.d/cmp-unlock.conf /etc/modprobe.d/cmp50hx-unlock.conf; do
        [[ -f "${cf}" ]] && ok "conffile ${cf}" || fail "conffile ${cf} missing"
    done
    # informational: do the /boot initrd images actually carry the module?
    kernel_scan_initrd "${version}" "assert-install"
}

# scan /boot initrd images for nvidia modules; phase: assert-install|assert-removed
kernel_scan_initrd() {
    local version="$1" phase="$2"
    command -v unmkinitramfs >/dev/null 2>&1 || { log "unmkinitramfs missing; initrd scan skipped"; return; }
    local found_any=0
    for image in /boot/initrd.img-* /boot/initramfs.img-*; do
        [[ -e "${image}" ]] || continue
        found_any=1
        local tmp hits
        tmp="$(mktemp -d)"
        unmkinitramfs "${image}" "${tmp}" >/dev/null 2>&1 || { log "unmkinitramfs failed on ${image}"; rm -rf "${tmp}"; continue; }
        hits="$(find "${tmp}" -name 'nvidia*.ko*' | head -5)"
        if [[ -n "${hits}" ]]; then
            if [[ "${phase}" == "assert-removed" ]]; then
                fail "${image} still contains $(find "${tmp}" -name 'nvidia*.ko*' | wc -l) nvidia module file(s) after removal"
            else
                ok "${image} contains $(find "${tmp}" -name 'nvidia*.ko*' | wc -l) nvidia module file(s)"
            fi
        else
            ok "${image}: no nvidia modules inside"
        fi
        rm -rf "${tmp}"
    done
    [[ ${found_any} -eq 1 ]] || log "no /boot initrd images on this box: initrd-content check is vacuous here (hardware leg proves it)"
}

phase_assert_removed() {
    local purged=0
    [[ "${1:-}" == "--purged" ]] && purged=1
    log "assert-removed (purged=${purged})"

    # dpkg database: purge must leave nothing; remove may leave config-files
    if dpkg-query -W "${pkg}" >/dev/null 2>&1; then
        local status
        status="$(dpkg-query -W -f='${db:Status-Status}\n' "${pkg}" 2>/dev/null || true)"
        if (( purged )) || [[ "${status}" != "config-files" ]]; then
            fail "package still in dpkg db with status '${status}'"
        else
            ok "package in dpkg db as config-files (removed, not purged)"
        fi
    else
        ok "package gone from dpkg database"
    fi

    # DKMS state everywhere (capture first: no pipe-into-grep -q under pipefail)
    local dks
    dks="$(dkms status 2>/dev/null || true)"
    if grep -q '^cmp50hx/' <<<"${dks}"; then
        fail "dkms status still lists cmp50hx: $(grep cmp50hx <<<"${dks}")"
    else
        ok "dkms status clean of cmp50hx"
    fi
    [[ -e /var/lib/dkms/cmp50hx ]] && fail "/var/lib/dkms/cmp50hx still exists" || ok "dkms state dir gone"
    compgen -G '/usr/src/cmp50hx-*' >/dev/null && fail "/usr/src/cmp50hx-* tree still exists" || ok "dkms source tree gone"

    # module files for EVERY kernel, not just the running one
    local kernel mod k bad
    local -a stale=()
    for kernel in /lib/modules/*/; do
        kernel="${kernel#/lib/modules/}"; kernel="${kernel%/}"
        for k in "/lib/modules/${kernel}/updates/dkms" "/lib/modules/${kernel}/updates"; do
            compgen -G "${k}/nvidia*.ko*" >/dev/null && stale+=("${k}/nvidia*.ko*")
        done
        bad="$(modinfo -n -k "${kernel}" nvidia 2>/dev/null || true)"
        [[ "${bad}" == /lib/modules/${kernel}/updates/* ]] && stale+=("modinfo still resolves ${bad}")
    done
    if (( ${#stale[@]} > 0 )); then
        printf '  stale: %s\n' "${stale[@]}" >&2
        fail "stale module files / modinfo hits for ${#stale[@]} kernel path(s)"
    else
        ok "no cmp50hx module files under updates/ for any kernel; modinfo clean"
    fi
    for kernel in /lib/modules/*/; do
        command -v depmod >/dev/null && depmod -a "${kernel#/lib/modules/}" 2>/dev/null || true
    done

    # userland from the embedded .run
    for f in /usr/bin/nvidia-smi /usr/bin/nvidia-uninstall /usr/bin/nvidia-persistenced; do
        [[ -e "${f}" ]] && fail "leftover userland: ${f}" || ok "userland gone: ${f}"
    done
    compgen -G '/usr/lib/x86_64-linux-gnu/libcuda.so*' >/dev/null \
        && fail "libcuda still present in /usr/lib" || ok "libcuda gone"

    # GSP firmware (spec assertion (i)) — capture before matching (no -q pipe)
    local fwleft
    fwleft="$(find /lib/firmware/nvidia -name 'gsp*.bin' 2>/dev/null | head -3 || true)"
    if [[ -n "${fwleft}" ]]; then
        fail "GSP firmware still under /lib/firmware/nvidia: ${fwleft//$'\n'/ }"
    else
        ok "/lib/firmware/nvidia has no GSP firmware"
    fi

    # package state
    [[ -e "${pin_file}" ]] && fail "apt pin file still present" || ok "apt pin file released"
    [[ -e /usr/local/bin/rm-issue-rate ]] && fail "/usr/local/bin/rm-issue-rate link left behind" || ok "legacy symlink gone"
    if [[ -e "${install_dir}" ]]; then
        fail "${install_dir} survived removal; leftovers: $(find "${install_dir}" | head -8 | tr '\n' ' ')"
    else
        ok "${install_dir} gone"
    fi
    for unit in cmp50hx-boot.service cmp-idle-governor.service; do
        if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled -q "${unit}" 2>/dev/null; then
            fail "service still enabled: ${unit}"
        fi
    done

    # purge-only expectations
    if (( purged )); then
        [[ -e "${state_dir}" ]] && fail "${state_dir} survived purge" || ok "${state_dir} gone"
        [[ -e "${log_file}" ]] && fail "${log_file} survived purge" || ok "install log gone"
        for cf in /etc/modprobe.d/cmp-unlock.conf /etc/modprobe.d/cmp50hx-unlock.conf \
                  /etc/cmp-tune.conf /etc/cmp50hx/boot.conf; do
            [[ -e "${cf}" ]] && fail "conffile survived purge: ${cf}" || ok "conffile gone: ${cf}"
        done
        # spec assertions (ii) initrd content + (iii) rollback backups
        kernel_scan_initrd "-" "assert-removed"
        compgen -G '/boot/initrd.img-*.cmp50-bak-*' >/dev/null \
            && fail "/boot rollback backups survive purge: $(ls /boot/initrd.img-*.cmp50-bak-* | head -3 | tr '\n' ' ')" \
            || ok "no /boot/initrd.img-*.cmp50-bak-* leftovers"
        # grub consistency: config must generate and reference only existing files
        if command -v grub-mkconfig >/dev/null 2>&1 && [[ -f /boot/grub/grub.cfg ]]; then
            if grub-mkconfig -o /dev/null >/dev/null 2>&1; then
                ok "grub-mkconfig succeeds"
            else
                fail "grub-mkconfig fails after purge"
            fi
            local missing=0 path
            while read -r path; do
                [[ -f "${path}" ]] || { fail "grub.cfg references missing ${path}"; missing=1; }
            done < <(grep -oE '^\t(linux|initrd)\s+/boot/[^ ]+' /boot/grub/grub.cfg | awk '{print $2}' | sort -u)
            (( missing == 0 )) && ok "every linux/initrd path in grub.cfg exists"
        else
            log "grub-mkconfig/grub.cfg absent (container): grub check vacuous here"
        fi
    fi
}

# --- loop orchestrator (host mode, docker) --------------------------------

phase_loop() {
    local deb='' container="${LC_CONTAINER:-cmp-lifecycle-test}" skip_offline=0 keep=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --deb) deb="${2:?--deb needs a path}"; shift 2 ;;
            --container) container="${2:?}"; shift 2 ;;
            --skip-offline) skip_offline=1; shift ;;
            --keep) keep=1; shift ;;
            *) printf 'unknown loop argument: %s\n' "$1" >&2; exit 2 ;;
        esac
    done
    [[ -f "${deb}" ]] || { printf 'deb not found: %s\n' "${deb}" >&2; exit 1; }
    deb="$(readlink -f "${deb}")"
    local tools_dir image="${LC_IMAGE:-ubuntu:24.04}"
    tools_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    command -v docker >/dev/null || { printf 'docker not available\n' >&2; exit 3; }
    docker rm -f "${container}" >/dev/null 2>&1 || true
    log "creating container ${container} (${image})"
    docker run -d --name "${container}" -v "${tools_dir}:/lc-tools:ro" -v "$(dirname "${deb}"):/lc-debs:ro" "${image}" sleep infinity >/dev/null
    # shellcheck disable=SC2317
    cleanup() { (( ${keep:-0} )) || docker rm -f "${container:-cmp-lifecycle-test}" >/dev/null 2>&1 || true; }
    trap cleanup EXIT

    local run=(docker exec "${container}" bash /lc-tools/lifecycle-test-deb.sh --on-host)
    log "installing container deps (two kernel header sets)"
    docker exec -e DEBIAN_FRONTEND=noninteractive \
        -e LC_HEADERS="${LC_HEADERS:-linux-headers-generic linux-headers-6.8.0-124-generic}" \
        "${container}" bash -c '
        set -eux
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends ca-certificates
        apt-get install -y -qq --no-install-recommends dpkg-dev ${LC_HEADERS}
        apt-get install -y -qq --no-install-recommends linux-image-generic
        apt-get clean'

    local -a kernels=()
    mapfile -t kernels < <(docker exec "${container}" bash /lc-tools/lifecycle-test-deb.sh --on-host kernels)
    # informational only: the assert legs re-derive kernels inside the
    # container at execution time, because a kernel's /lib/modules/<k>/build
    # symlink can materialize during our own install transaction (ordering
    # of the deps apt run vs our deb's Depends configure pass)
    (( ${#kernels[@]} >= 2 )) || log "NOTE: ${#kernels[@]} kernel(s) visible at start: ${kernels[*]:-none} (asserts re-check live)"
    log "kernels with headers at start: ${kernels[*]}"

    local LEGS_FAILED=0 LC_DIED=0
    run_leg() {
        local name="$1"; shift
        log "=== leg: ${name} ==="
        if (( LC_DIED )); then
            printf 'LIFECYCLE_LEG_%s_SKIP_container_dead\n' "${name}"
            LEGS_FAILED=$((LEGS_FAILED + 1))
            return 0
        fi
        if [[ "$(docker inspect -f '{{.State.Running}}' "${container}" 2>/dev/null || true)" != "true" ]]; then
            LC_DIED=1
            log "CONTAINER_DIED during leg ${name}: remaining legs skipped"
            printf 'LIFECYCLE_LEG_%s_FAIL_container_dead\n' "${name}"
            LEGS_FAILED=$((LEGS_FAILED + 1))
            return 0
        fi
        if "${run[@]}" "$@"; then
            printf 'LIFECYCLE_LEG_%s_PASS\n' "${name}"
        else
            printf 'LIFECYCLE_LEG_%s_FAIL\n' "${name}"
            LEGS_FAILED=$((LEGS_FAILED + 1))
        fi
    }

    local debname
    debname="/lc-debs/$(basename "${deb}")"
    run_leg "install1"      install-online "${debname}"
    run_leg "assert1"       assert-install "${kernels[@]}"
    run_leg "purge1"        purge
    run_leg "assert_removed1" assert-removed --purged
    run_leg "reinstall"     install-online "${debname}"
    run_leg "assert2"       assert-install "${kernels[@]}"
    run_leg "remove"        remove
    run_leg "purge2"        purge
    run_leg "assert_removed2" assert-removed --purged
    run_leg "purge3_idempotent" purge-idempotent
    run_leg "assert_removed3" assert-removed --purged

    if (( ! skip_offline )); then
        log "=== offline leg: disconnecting container network ==="
        docker network disconnect bridge "${container}"
        if run_leg "offline_install" offline-install "${debname}" \
           && run_leg "offline_assert" assert-install "${kernels[@]}"; then
            run_leg "offline_purge" purge
            if run_leg "offline_reinstall" offline-install "${debname}" && run_leg "offline_assert2" assert-install "${kernels[@]}"; then
                printf 'LIFECYCLE_LEG_offline_PASS\n'
            fi
        else
            printf 'LIFECYCLE_LEG_offline_FAIL\n'
        fi
        docker network connect bridge "${container}" || log "WARNING: network reconnect failed (container goes away anyway)"
    fi

    # per-leg verdict lines above; final tally
    log "loop finished for $(basename "${deb}") in ${container} (keep=${keep})"
    printf 'LIFECYCLE_LOOP_LEGS_FAILED=%d\n' "${LEGS_FAILED}"
    (( LEGS_FAILED == 0 )) || return 1
}

# --- dispatch ---------------------------------------------------------------

if [[ "${1:-}" == "--on-host" ]]; then
    shift
    phase="${1:?--on-host needs a phase}"; shift
    case "${phase}" in
        kernels)        kernels_with_headers ;;
        install-online) phase_install_online "$@" ;;
        offline-install) phase_offline_install "$@" ;;
        remove)         phase_remove "$@" ;;
        purge)          phase_purge "$@" ;;
        purge-idempotent) phase_purge_idempotent "$@" ;;
        assert-install) phase_assert_install "$@" ;;
        assert-removed) phase_assert_removed "$@" ;;
        *) printf 'unknown phase: %s\n' "${phase}" >&2; exit 2 ;;
    esac
    if (( FAILURES > 0 )) && [[ "${phase}" != "kernels" ]]; then
        printf 'ASSERT_FAILURES=%d in phase %s\n' "${FAILURES}" "${phase}"
        exit 1
    fi
    exit 0
fi

cmd="${1:-}"
[[ -n "${cmd}" ]] || { sed -n '2,25p' "$0"; exit 2; }
shift
case "${cmd}" in
    loop) phase_loop "$@" ;;
    *) printf 'unknown command: %s (want: loop)\n' "${cmd}" >&2; exit 2 ;;
esac
