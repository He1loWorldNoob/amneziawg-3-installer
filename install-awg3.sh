#!/bin/bash

# Minimum Bash version check
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "ERROR: Bash >= 4.0 required (current: ${BASH_VERSION})" >&2; exit 1
fi

# ==============================================================================
# install-awg3.sh — установка AmneziaWG 3.0 на Debian/Ubuntu.
#
# Форк bivlked/amneziawg-installer v5.23.0 (2026-07-31), MIT.
# Что изменено относительно апстрима — docs/upstream.md.
#
# Ключевые отличия: сервер создаётся сразу в 3.0 силами awg3.sh server-init,
# без промежуточной 2.0-стадии; отдельного файла настроек нет — источник
# истины только awg0.conf; каталог данных вычисляется, а не прибит к /root.
# ==============================================================================

# --- Safe mode and Constants ---
set -o pipefail
SCRIPT_VERSION="6.0.0"
UPSTREAM_VERSION="5.23.0"

# Каталог данных: домашний каталог целевого пользователя, иначе /root/awg.
# $HOME не годится — под sudo он указывает то на root, то на вызвавшего, в
# зависимости от настроек sudoers.
resolve_awg_dir() {
    local user="${1:-}"
    if [[ -n "${AWG3_DIR:-}" ]]; then
        printf '%s' "$AWG3_DIR"
        return 0
    fi
    if [[ -z "$user" ]]; then
        user="${SUDO_USER:-root}"
    fi
    local home
    home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
    [[ -n "$home" ]] || home="/root"
    printf '%s/awg' "$home"
}

AWG_DIR="$(resolve_awg_dir "")"
STATE_FILE="$AWG_DIR/setup_state"
LOG_FILE="$AWG_DIR/install-awg3.log"
SERVER_CONF_FILE="/etc/amnezia/amneziawg/awg0.conf"

# Каталог данных лежит в домашнем каталоге пользователя, но создаётся из-под
# root — без смены владельца он остаётся root:root, и человек не может забрать
# собственные конфиги и QR без sudo. Владелец выводится из пути: awg3.sh потом
# наследует его для всех создаваемых файлов через _fix_owner.
# Аргумент нужен тестам, в бою используется текущий AWG_DIR.
# shellcheck disable=SC2120
prepare_awg_dir() {
    local dir="${1:-$AWG_DIR}" owner
    mkdir -p "$dir" || die "не создан каталог $dir"
    chmod 700 "$dir"

    owner=$(basename "$(dirname "$dir")")
    if [[ "$dir" == /root/* ]]; then owner="root"; fi
    if getent passwd "$owner" >/dev/null 2>&1; then
        chown "${owner}:$(id -gn "$owner" 2>/dev/null || echo "$owner")" "$dir" \
            || log_warn "не сменился владелец $dir"
    fi
}

# AmneziaWG 2.0 pin (H0, 31 jul 2026). Upstream merged AmneziaWG 3.0 into the
# amneziawg-linux-kernel-module default branch and the PPA switched to it. The 3.0
# module needs kernel >= 6.7 (nla_put_uint), so on older kernels (Debian 12 = 6.1)
# the PPA DKMS build fails. On such kernels we build the last pinned 2.0 module
# (the 1.0.x line) from source. AWG2_PIN_COMMIT is checked after clone (integrity:
# more robust than a fragile tarball SHA - a tag can be moved, an immutable commit
# cannot).
AWG2_PIN_TAG="v1.0.20260725"
AWG2_PIN_COMMIT="ae0924ca700520ca34c5bdbcfd05b2f683ea9353"

# CLI flags
UNINSTALL=0; HELP=0; HELP_EXIT_RC=0; DIAGNOSTIC=0; VERBOSE=0; NO_COLOR=0; AUTO_YES=0; NO_TWEAKS=0; NO_CPS=0
FORCE_REINSTALL=0
_APT_UPDATED=0
CLI_PORT=""; CLI_SUBNET=""; CLI_DISABLE_IPV6="default"; CLI_SSH_PORT=""
CLI_ROUTING_MODE="default"; CLI_CUSTOM_ROUTES=""; CLI_ENDPOINT=""; CLI_NO_TWEAKS=0; CLI_NO_CPS=0
CLI_ALLOW_IPV6_TUNNEL=0
CLI_ISOLATION="default"
CLI_SERVER_NAME=""
CLI_MOBILE=0

# --- Auto-cleanup of temporary files ---
_install_temp_files=()
_install_cleaned=0
_install_cleanup() {
    # Idempotent: on INT/TERM it is called from the signal handler, then again on
    # EXIT - the second call must be a no-op.
    [[ "$_install_cleaned" -eq 1 ]] && return 0
    _install_cleaned=1
    local f
    for f in "${_install_temp_files[@]}"; do [[ -f "$f" ]] && rm -f "$f"; done
}
# On INT/TERM the cleanup used to run but the script did NOT exit - execution
# continued past the interrupted command (dangerous mid apt/dpkg/config edits)
# and cleanup ran again on EXIT. A signal now means cleanup + explicit 130/143.
_install_on_signal() {
    _install_cleanup
    exit "$1"
}
trap _install_cleanup EXIT
trap '_install_on_signal 130' INT
trap '_install_on_signal 143' TERM

# Разбор аргументов живёт в parse_args() и вызывается из main() — на верхнем
# уровне его быть не должно, иначе скрипт нельзя подключить как библиотеку
# для тестов.

# ==============================================================================
# Logging functions
# ==============================================================================

log_msg() {
    local type="$1" msg="$2"
    local ts
    ts=$(date +'%F %T')
    local entry="[$ts] $type: $msg"
    local color_start="" color_end=""

    if [[ "$NO_COLOR" -eq 0 ]]; then
        color_end="\033[0m"
        case "$type" in
            INFO)  color_start="\033[0;32m" ;;
            WARN)  color_start="\033[0;33m" ;;
            ERROR) color_start="\033[1;31m" ;;
            DEBUG) color_start="\033[0;36m" ;;
            *)     color_start=""; color_end="" ;;
        esac
    fi

    if ! mkdir -p "$(dirname "$LOG_FILE")" || ! echo "$entry" >> "$LOG_FILE"; then
        echo "[$ts] ERROR: Log write error $LOG_FILE" >&2
    fi

    if [[ "$type" == "ERROR" || "$type" == "WARN" ]]; then
        printf "${color_start}%s${color_end}\n" "$entry" >&2
    elif [[ "$type" == "DEBUG" && "$VERBOSE" -eq 1 ]]; then
        printf "${color_start}%s${color_end}\n" "$entry" >&2
    elif [[ "$type" == "INFO" ]]; then
        printf "${color_start}%s${color_end}\n" "$entry"
    elif [[ "$type" != "DEBUG" ]]; then
        printf "${color_start}%s${color_end}\n" "$entry"
    fi
}

log()       { log_msg "INFO" "$1"; }
log_warn()  { log_msg "WARN" "$1"; }
log_error() { log_msg "ERROR" "$1"; }
log_debug() { if [[ "$VERBOSE" -eq 1 ]]; then log_msg "DEBUG" "$1"; fi; }
die()       { log_error "CRITICAL ERROR: $1"; log_error "Installation aborted. Log: $LOG_FILE"; exit 1; }

# ==============================================================================
# apt-get update wrapper that tolerates 404s only for source packages (deb-src).
# Встроено: нужно на шагах 1-2.
# Some mirrors (Hetzner, AWS) do not serve source packages, but the default
# ubuntu.sources contains 'Types: deb deb-src'. We do not need source packages
# (kernel module is built via DKMS using binary headers), so such 404s are safe
# to ignore. Returns 0 if update succeeded OR if all errors are on source markers.
# Any other error (GPG, binary-package network, silent crash / OOM / SIGKILL) → non-zero.
# ==============================================================================
apt_update_tolerant() {
    # --ppa-amnezia-tolerant: also ignore errors from the Amnezia PPA. Used
    # in step 2 — apt_wait_for_ppa_package below already retries for the
    # ppa.launchpadcontent.net outage scenario (issue #68). Without this
    # flag we must fail fast on any non-source error, otherwise the script
    # would continue installing on a stale apt-cache (PR #69 review finding).
    local ppa_tolerant=0
    if [[ "${1:-}" == "--ppa-amnezia-tolerant" ]]; then
        ppa_tolerant=1
        shift
    fi

    local err_output rc non_src_errors raw_had_non_src_errors=0
    err_output=$(LANG=C LC_ALL=C apt-get update -y 2>&1)
    rc=$?
    echo "$err_output"

    if [[ $rc -eq 0 ]]; then
        return 0
    fi

    # Filter error lines. Ignore:
    #   1. Lines about source packages (deb-src / /source/ / Sources)
    #   2. Generic 'Some index files failed to download' — symptom, not cause
    # Additionally exclude known informational W: lines that are never the
    # CAUSE of rc!=0 but used to survive the filters and turn a tolerable
    # failure (e.g. deb-src 404 with duplicated sources) into a false fatal:
    #   - "Target ... is configured multiple times" (duplicate sources entries)
    #   - "... stored in legacy trusted.gpg keyring" (old key format)
    non_src_errors=$(printf '%s\n' "$err_output" \
        | grep -E '^(E:|Err:|W:)' \
        | grep -vE '(deb-src|/source/|Sources([^[:alpha:]]|$))' \
        | grep -vE 'Some index files failed to download' \
        | grep -vE '^W: (Target .* is configured multiple times|.* stored in legacy trusted\.gpg)' || true)

    # Remember pre-PPA-filter state — we need to distinguish "real APT errors,
    # but all on Amnezia PPA" (tolerant OK) from "no classifiable errors at all"
    # (OOM / silent crash — NOT tolerant even if the output happens to mention
    # a PPA URL elsewhere).
    [[ -n "$non_src_errors" ]] && raw_had_non_src_errors=1

    # Optional (step 2): drop errors that are only on the Amnezia PPA — they
    # will be re-checked via apt_wait_for_ppa_package against apt-cache (issue #68).
    if [[ $ppa_tolerant -eq 1 && -n "$non_src_errors" ]]; then
        non_src_errors=$(printf '%s\n' "$non_src_errors" \
            | grep -vE 'ppa\.launchpadcontent\.net.*amnezia' || true)
    fi

    if [[ -z "$non_src_errors" ]]; then
        # Edge case: rc != 0 but no classifiable E:/Err:/W: lines found
        # (OOM-killer SIGKILL, silent crash, unknown apt output format).
        # Ignore ONLY if the output actually contains source-markers, or if
        # ppa-tolerant + there were real APT lines and all of them were on the
        # Amnezia PPA.
        if printf '%s\n' "$err_output" | grep -qE '(deb-src|/source/|Sources([^[:alpha:]]|$))'; then
            log_warn "apt update: source packages unavailable in mirror (expected, ignored)"
            return 0
        fi
        if [[ $ppa_tolerant -eq 1 && $raw_had_non_src_errors -eq 1 ]] \
            && printf '%s\n' "$err_output" | grep -qE 'ppa\.launchpadcontent\.net.*amnezia'; then
            log_warn "apt update: errors only on Amnezia PPA (issue #68), continuing with retry."
            return 0
        fi
        log_error "apt update exited with rc=$rc without any classifiable APT lines — possible silent crash / OOM / SIGKILL"
        return "$rc"
    fi

    log_error "apt update failed with non-source errors:"
    printf '%s\n' "$non_src_errors" | while IFS= read -r line; do
        log_error "  $line"
    done
    return "$rc"
}

# ==============================================================================
# apt_wait_for_ppa_package <package> [max_attempts] [initial_delay_seconds]
#   Waits until the given package becomes visible in apt-cache, with
#   exponential backoff between attempts. Needed in step 2 after the
#   Amnezia PPA is added: ppa.launchpadcontent.net sometimes briefly
#   goes down (issue #68), and without retries the first cold install
#   fails even though the PPA is back a minute later.
#
#   IMPORTANT: this checks apt-cache show, not the rc of apt-get update.
#   apt-get update returns 0 tolerantly even when an InRelease file did
#   not download — so a plain rc-based retry does not catch a PPA outage.
#   Package visibility in apt-cache is the only reliable signal that
#   the PPA actually got indexed.
#
#   With the defaults (3 attempts × initial=30s) the timeline is:
#   attempt 1 → sleep 30s → apt update + attempt 2 → sleep 60s →
#   apt update + attempt 3 (last). After the third fail we return 1.
#   Total wait between attempts is about 1.5 minutes.
#
#   The 1800s delay cap guards against arithmetic overflow if the helper
#   is ever called with a very large max.
# ==============================================================================
apt_wait_for_ppa_package() {
    local pkg="$1" max="${2:-3}" delay="${3:-30}" attempt
    for ((attempt = 1; attempt <= max; attempt++)); do
        if apt-cache show "$pkg" >/dev/null 2>&1; then
            return 0
        fi
        if (( attempt == max )); then
            return 1
        fi
        log_warn "Package '${pkg}' did not appear in apt-cache (attempt ${attempt}/${max}, PPA still unavailable), retrying in ${delay}s..."
        sleep "$delay"
        apt_update_tolerant >/dev/null 2>&1 || true
        delay=$(( delay * 2 > 1800 ? 1800 : delay * 2 ))
    done
    return 1
}

# ==============================================================================
# Help
# ==============================================================================


# ==============================================================================
# Utilities and validation
# ==============================================================================

update_state() {
    local next_step=$1
    mkdir -p "$(dirname "$STATE_FILE")"
    # Atomic write: tmp-file + flock + mv. Protects against a truncated
    # state file if the process is killed / power-lost between write and close.
    (
        flock -x 200
        local tmp="${STATE_FILE}.tmp.$BASHPID"
        if printf '%s\n' "$next_step" > "$tmp" && mv -f "$tmp" "$STATE_FILE"; then
            exit 0
        fi
        rm -f "$tmp" 2>/dev/null
        exit 1
    ) 200>"${STATE_FILE}.lock" || die "Failed to write state"
    log "State: next step - $next_step"
}

request_reboot() {
    local next_step=$1
    update_state "$next_step"

    # Capture boot_id before the 1→2 reboot gate. On step 2 entry we
    # compare it with the current boot_id — if they match, the user did
    # not reboot, which means apt full-upgrade staged a new kernel on
    # disk but the running kernel is still the old one. DKMS would build
    # the module against the old kernel and modprobe would fail after
    # the next reboot. Fail fast instead.
    if [[ "$next_step" == "2" ]] && [[ -r /proc/sys/kernel/random/boot_id ]]; then
        if cat /proc/sys/kernel/random/boot_id > "$AWG_DIR/.boot_id_before_step2" 2>/dev/null; then
            log_debug "boot_id captured before reboot"
        fi
    fi

    echo "" >> "$LOG_FILE"
    log_warn "=============================================================="
    log_warn "  НУЖНА ПЕРЕЗАГРУЗКА"
    log_warn "  Обновилось ядро. Модуль AmneziaWG должен собираться под то"
    log_warn "  ядро, которое реально работает, иначе после следующей"
    log_warn "  перезагрузки он не загрузится."
    log_warn " "
    log_warn "  После перезагрузки повторите ТУ ЖЕ команду целиком:"
    log_warn "    sudo $0 ${ORIGINAL_ARGS:-<те же параметры>}"
    log_warn " "
    log_warn "  Важно повторить именно её: от параметров зависит, в чей"
    log_warn "  домашний каталог лягут конфиги клиентов."
    log_warn "=============================================================="
    echo "" >> "$LOG_FILE"
    local confirm="y"
    if [[ "$AUTO_YES" -eq 0 ]]; then
        read -rp "Перезагрузить сейчас? [y/N]: " confirm < /dev/tty
    else
        log "Перезагрузка подтверждена автоматически (--yes)."
    fi
    if [[ "$confirm" =~ ^[[:space:]]*[YyДд]([Ee][Ss]|[Аа])?[[:space:]]*$ ]]; then
        log "Перезагружаюсь..."
        sleep 5
        if ! reboot; then die "команда reboot не сработала"; fi
        exit 1
    else
        log "Перезагрузка отменена. Перезагрузите вручную и повторите команду."
        exit 1
    fi
}

# Early container detection (LXC/OpenVZ/Docker/WSL) - 4pda case: on a
# container VDS the install used to reach step 3 and die with a raw
# 'modprobe: FATAL: Module amneziawg not found' with no explanation. AmneziaWG
# installs a kernel module via DKMS, and containers share the host kernel and
# cannot load their own modules - it is more honest to stop right away.
# systemd-detect-virt exists on all supported Ubuntu/Debian; if it is somehow
# missing, the check is skipped (soft degradation, the install is not blocked).
check_container() {
    command -v systemd-detect-virt &>/dev/null || return 0
    local virt
    virt=$(systemd-detect-virt --container 2>/dev/null) || true
    [[ -z "$virt" || "$virt" == "none" ]] && return 0
    log_error "Container detected: ${virt}."
    log_error "AmneziaWG requires loading a kernel module (DKMS), and containers (LXC/OpenVZ/Docker/WSL) share the host kernel and cannot load their own modules."
    die "Use a full VPS (KVM/QEMU) or bare-metal. The container option is userspace amneziawg-go: ADVANCED.en.md, section 'LXC / Docker via amneziawg-go'."
}

check_os_version() {
    log "Checking OS..."

    # Detection via /etc/os-release (universal for Ubuntu and Debian)
    OS_ID=""
    OS_VERSION=""
    OS_CODENAME=""
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
        OS_CODENAME="$VERSION_CODENAME"
    elif command -v lsb_release &>/dev/null; then
        OS_ID=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        OS_VERSION=$(lsb_release -sr)
        OS_CODENAME=$(lsb_release -sc)
    else
        log_warn "Cannot detect OS (/etc/os-release and lsb_release not found)."
        return 0
    fi
    export OS_ID OS_VERSION OS_CODENAME

    # Supported OS
    local supported=0
    case "$OS_ID" in
        ubuntu)
            if [[ "$OS_VERSION" == "24.04" || "$OS_VERSION" == "25.10" || "$OS_VERSION" == "26.04" ]]; then
                supported=1
            fi
            ;;
        debian)
            if [[ "$OS_VERSION" == "12" || "$OS_VERSION" == "13" ]]; then
                supported=1
            fi
            ;;
    esac

    if [[ "$supported" -eq 1 ]]; then
        log "OS: ${OS_ID^} $OS_VERSION ($OS_CODENAME) — supported"
    else
        log_warn "Detected $OS_ID $OS_VERSION ($OS_CODENAME). Script tested on Ubuntu 24.04/25.10/26.04 and Debian 12/13."
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "Continue? [y/N]: " confirm < /dev/tty
            if ! [[ "$confirm" =~ ^[[:space:]]*[Yy]([Ee][Ss])?[[:space:]]*$ ]]; then die "Cancelled."; fi
        else
            log "Continuing on $OS_ID $OS_VERSION (--yes)."
        fi
    fi
}

check_kernel_version() {
    # The AmneziaWG 2.0 module is built via DKMS against the host kernel. On
    # kernels older than 5.15 (Ubuntu < 22.04, e.g. 5.4 on 20.04) the build
    # usually fails at step 2 with an opaque package-failure. Warn EXPLICITLY and
    # early, before updates and reboots (issue #163). Not a die: on some older
    # kernels the module still builds (HWE and such), so WARN + confirm.
    local kver kmaj kmin
    kver=$(uname -r)
    if [[ "$kver" =~ ^([0-9]+)\.([0-9]+) ]]; then
        kmaj=${BASH_REMATCH[1]}; kmin=${BASH_REMATCH[2]}
    else
        log_warn "Could not parse the kernel version ('$kver') - skipping the minimum-version check."
        return 0
    fi
    if (( kmaj < 5 || (kmaj == 5 && kmin < 15) )); then
        log_warn "Kernel $kver is older than 5.15 - usually too old for the AmneziaWG 2.0 module."
        log_warn "The DKMS module build on such a kernel most often fails. Reinstall the VPS on Ubuntu 24.04 LTS or Debian 12 (or newer). Matrix: Ubuntu 24.04/25.10/26.04, Debian 12/13."
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "Continue anyway? [y/N]: " confirm < /dev/tty
            if ! [[ "$confirm" =~ ^[[:space:]]*[Yy]([Ee][Ss])?[[:space:]]*$ ]]; then die "Cancelled: kernel $kver is too old for the AmneziaWG 2.0 module."; fi
        else
            log "Continuing on kernel $kver (--yes)."
        fi
    else
        log "Kernel $kver (OK for the AmneziaWG 2.0 module)."
    fi
}

# shellcheck disable=SC2120  # called without args in the installer (uses uname -r); bats passes versions
_kernel_supports_awg3() {
    # Returns 0 if the kernel version is >= 6.7 - i.e. the kernel can build the
    # AmneziaWG 3.0 module. Returns 1 if the kernel is older than 6.7 (a pinned
    # 2.0 module is needed). Threshold 6.7: nla_put_uint, which the 3.0 code uses,
    # first appeared in mainline kernel v6.7 (it is absent in 6.6); on 6.1
    # (Debian 12) the 3.0 build fails with 'implicit declaration of nla_put_uint'.
    # Arg $1: kernel release (default uname -r). An unparseable version is treated
    # as "NOT supported" -> pinned 2.0 (it builds on ANY of our kernels, so the
    # conservative choice never breaks connectivity, it only withholds 3.0 features
    # which H0 does not ship anyway).
    # Pure function with no external deps (bats: extracted via sed-range + source).
    local kver="${1:-$(uname -r)}" kmaj kmin
    local min_maj=6 min_min=7
    if [[ "$kver" =~ ^([0-9]+)\.([0-9]+) ]]; then
        kmaj=${BASH_REMATCH[1]}; kmin=${BASH_REMATCH[2]}
    else
        return 1
    fi
    if (( kmaj > min_maj || (kmaj == min_maj && kmin >= min_min) )); then
        return 0
    fi
    return 1
}

check_free_space() {
    log "Checking disk space..."
    local req=2048
    local avail
    avail=$(df -m / | awk 'NR==2 {print $4}')
    if [[ -z "$avail" ]]; then
        log_warn "Failed to determine free space."
        return 0
    fi
    if [ "$avail" -lt "$req" ]; then
        log_warn "Available $avail MB. Recommended >= $req MB."
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "Continue? [y/N]: " confirm < /dev/tty
            if ! [[ "$confirm" =~ ^[[:space:]]*[Yy]([Ee][Ss])?[[:space:]]*$ ]]; then die "Cancelled."; fi
        else
            log "Continuing with $avail MB (--yes)."
        fi
    else
        log "Free: $avail MB (OK)"
    fi
}

check_port_availability() {
    local port=$1
    log "Checking port $port..."
    local proc
    proc=$(ss -lunp | grep ":${port} ")
    if [[ -n "$proc" ]]; then
        log_error "Port ${port}/udp already in use! Process: $proc"
        return 1
    else
        log "Port $port/udp is free."
        return 0
    fi
}

install_packages() {
    local packages=("$@")
    local to_install=()
    local pkg
    log "Checking packages: ${packages[*]}..."
    for pkg in "${packages[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            to_install+=("$pkg")
        fi
    done
    if [ ${#to_install[@]} -eq 0 ]; then
        log "All packages already installed."
        return 0
    fi
    log "Installing: ${to_install[*]}..."
    if [[ "${_APT_UPDATED:-0}" -eq 0 ]]; then
        # C4: a hard apt_update_tolerant failure (GPG / binary-repo network / OOM)
        # is NOT source noise but a real error; continuing on a stale cache is not
        # safe (contract line ~138, same as callers 1975/2108). die aborts the
        # install, so _APT_UPDATED=1 is set only on success - otherwise a later
        # install_packages call in this session would silently skip the update.
        apt_update_tolerant || die "apt update error."
        _APT_UPDATED=1
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt install -y "${to_install[@]}"; then
        # v5.13.0: typical failure on 25.10/26.04 after an in-place upgrade
        # from 24.04 — the amneziawg-dkms postinst runs `dkms autoinstall`
        # which iterates over ALL kernels in /lib/modules/. The leftover
        # 6.8.x headers were compiled with gcc-13, but 25.10 ships only
        # gcc-15 by default → autoinstall fails, dpkg leaves the dependent
        # amneziawg-tools / amneziawg unconfigured. Force-build the module
        # for the running kernel only and finish with dpkg --configure -a.
        if printf '%s\n' "${to_install[@]}" | grep -qx "amneziawg-dkms"; then
            log_warn "apt install did not complete — trying a DKMS build for the running kernel $(uname -r) only..."
            local _mver
            _mver="$(ls /var/lib/dkms/amneziawg/ 2>/dev/null | head -n1)"
            if [[ -n "$_mver" ]] \
               && dkms install -m amneziawg -v "$_mver" -k "$(uname -r)" --force \
               && DEBIAN_FRONTEND=noninteractive dpkg --configure -a; then
                log "DKMS module built for $(uname -r), dpkg configured."
                log "Packages installed."
                return 0
            fi
        fi
        die "Package installation error."
    fi
    log "Packages installed."
}

cleanup_apt() {
    log "Cleaning apt..."
    apt-get clean || log_warn "apt-get clean error"
    rm -rf /var/lib/apt/lists/* || log_warn "rm /var/lib/apt/lists/* error"
    log "apt cache cleared."
}

configure_ipv6() {
    if [[ "$CLI_DISABLE_IPV6" != "default" ]]; then
        DISABLE_IPV6=$CLI_DISABLE_IPV6
        log "IPv6 from CLI: $DISABLE_IPV6"
    elif [[ "$AUTO_YES" -eq 1 ]]; then
        DISABLE_IPV6=1
        log "IPv6 disabled (--yes, default)."
    else
        read -rp "Disable IPv6 (recommended)? [Y/n]: " dis_ipv6 < /dev/tty
        if [[ "$dis_ipv6" =~ ^[Nn]$ ]]; then
            DISABLE_IPV6=0
        else
            DISABLE_IPV6=1
        fi
    fi
    export DISABLE_IPV6
    log "IPv6 disable: $(if [ "$DISABLE_IPV6" -eq 1 ]; then echo 'Yes'; else echo 'No'; fi)"
}

# Detect whether the VPS has native IPv6.
# Native IPv6 = a globally routable address (NOT ULA fc00::/7, NOT link-local
# fe80::) AND a default IPv6 route. Either condition alone is insufficient:
#   - a global address without a default route -> no IPv6 internet egress (a client
#     with ::/0 would black-hole);
#   - a ULA (fddd::/...) has global scope to `ip` but is not internet-routable.
# Echo 1 only when both conditions hold, otherwise 0.
detect_native_ipv6() {
    local have_addr=0 have_route=0
    if ip -6 addr show scope global 2>/dev/null \
        | grep -oP 'inet6\s+\K[0-9a-fA-F:]+' \
        | grep -qviE '^(fc|fd)'; then
        have_addr=1
    fi
    if ip -6 route show default 2>/dev/null | grep -q .; then
        have_route=1
    fi
    if [[ "$have_addr" -eq 1 && "$have_route" -eq 1 ]]; then
        echo 1
    else
        echo 0
    fi
}

configure_ipv6_tunnel() {
    if [[ "$CLI_ALLOW_IPV6_TUNNEL" -eq 1 ]]; then
        ALLOW_IPV6_TUNNEL=1
    elif [[ -z "${ALLOW_IPV6_TUNNEL:-}" ]]; then
        ALLOW_IPV6_TUNNEL=0
    fi
    : "${IPV6_SUBNET:=fddd:2c4:2c4:2c4::/64}"
    # The IPv6 tunnel requires host IPv6 enabled. Override --disallow-ipv6 AND
    # actively re-enable IPv6 at runtime BEFORE detection/render: on an upgrade
    # from a default past install (IPv6 was runtime-disabled), the kernel hides
    # all IPv6 addresses, so detect_native_ipv6 would false-negative and a client
    # would be rendered with an IPv6 Address while the kernel has IPv6 off
    # (awg-quick restart can fail). weaq P1.
    if [[ "$ALLOW_IPV6_TUNNEL" -eq 1 ]]; then
        if [[ "$DISABLE_IPV6" -eq 1 ]]; then
            log_warn "--allow-ipv6-tunnel requires host IPv6 forwarding; overriding --disallow-ipv6 (DISABLE_IPV6=0)"
            DISABLE_IPV6=0
        fi
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true
    fi
    # Detect native IPv6 AFTER the runtime re-enable (cached in init for client render in Phase 4).
    SERVER_HAS_NATIVE_IPV6=$(detect_native_ipv6)
    if [[ "$ALLOW_IPV6_TUNNEL" -eq 1 && "$SERVER_HAS_NATIVE_IPV6" -eq 0 ]]; then
        log_warn "Native IPv6 not detected on VPS - the IPv6 tunnel will work peer-to-peer only, without IPv6 internet egress."
    fi
    export ALLOW_IPV6_TUNNEL IPV6_SUBNET SERVER_HAS_NATIVE_IPV6 DISABLE_IPV6
}





validate_port() {
    local port="$1"
    # ^[1-9][0-9]{0,4}$ forbids leading zeros ('0080' would otherwise be parsed as
    # octal in arithmetic and slip past the range check) and bounds the length:
    # without a limit 64-bit (( )) arithmetic wraps, so 2^64+51820 would pass the
    # range check. Comparison uses plain decimal.
    if ! [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || (( port > 65535 )); then
        die "Invalid port: '$port'. Allowed range: 1-65535."
    fi
}

validate_subnet() {
    local subnet="$1" o
    # Самодостаточно: не использует
    # _valid_ipv4/_cidr_bounds. Octets without leading zeros ('010...' would
    # otherwise be parsed as octal).
    if ! [[ "$subnet" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})/([0-9]{1,2})$ ]]; then
        die "Invalid subnet: '$subnet'. Expected CIDR /16-/30, e.g. 10.9.0.0/16."
    fi
    local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}" c="${BASH_REMATCH[3]}" d="${BASH_REMATCH[4]}" prefix="${BASH_REMATCH[5]}"
    for o in "$a" "$b" "$c" "$d"; do
        (( 10#$o <= 255 )) || die "Invalid subnet: '$subnet'. Octet out of range 0-255."
    done
    (( 10#$prefix >= 16 && 10#$prefix <= 30 )) || die "Invalid subnet: '$subnet'. Only /16-/30 masks are supported."
    # Inline arithmetic: the address must be network or network+1.
    local ip=$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
    local mask=$(( (0xFFFFFFFF << (32 - 10#$prefix)) & 0xFFFFFFFF ))
    local network=$(( ip & mask ))
    local n1=$(( network + 1 ))
    local srv="$(( (n1 >> 24) & 255 )).$(( (n1 >> 16) & 255 )).$(( (n1 >> 8) & 255 )).$(( n1 & 255 ))"
    if (( ip != network && ip != n1 )); then
        die "Invalid subnet: '$subnet'. Server address must be ${srv} (network+1), or specify the network."
    fi
    # Normalize the global to <network+1>/<prefix> (server = network+1).
    AWG_TUNNEL_SUBNET="${srv}/${prefix}"
}

# Tunnel network from a CIDR string (<network+1>/<prefix> -> <network>/<prefix>).
# Needed for client isolation (issue #178): with isolation disabled, it is the
# network address itself that goes into client AllowedIPs. Self-contained
# Самодостаточно: не использует _cidr_bounds/_int_to_ipv4.
tunnel_network_cidr() {
    local subnet="${1:-$AWG_TUNNEL_SUBNET}"
    if ! [[ "$subnet" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})/([0-9]{1,2})$ ]]; then
        return 1
    fi
    local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}" c="${BASH_REMATCH[3]}" d="${BASH_REMATCH[4]}" prefix="${BASH_REMATCH[5]}"
    (( 10#$prefix <= 32 )) || return 1
    local o
    for o in "$a" "$b" "$c" "$d"; do (( 10#$o <= 255 )) || return 1; done
    local ip=$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
    local mask
    if (( 10#$prefix == 0 )); then mask=0; else mask=$(( (0xFFFFFFFF << (32 - 10#$prefix)) & 0xFFFFFFFF )); fi
    local net=$(( ip & mask ))
    echo "$(( (net >> 24) & 255 )).$(( (net >> 16) & 255 )).$(( (net >> 8) & 255 )).$(( net & 255 ))/${prefix}"
}

# Explicit client isolation choice (issue #178). Priority:
# CLI flag > saved config > interactive question (first run only, no --yes) >
# 1 (isolated). An old config without the key = 1: before this feature,
# split modes were isolated de facto, so the behaviour is preserved.
configure_client_isolation() {
    case "$CLI_ISOLATION" in
        on)  CLIENT_ISOLATION=1; log "Client isolation from CLI: enabled." ;;
        off) CLIENT_ISOLATION=0; log "Client isolation from CLI: disabled." ;;
        default)
            if [[ -n "${CLIENT_ISOLATION:-}" ]]; then
                log "Client isolation (from config): $( [[ "$CLIENT_ISOLATION" -eq 1 ]] && echo enabled || echo disabled )."
            elif [[ "${config_exists:-0}" -eq 1 ]]; then
                CLIENT_ISOLATION=1
                log "Client isolation: enabled (pre-v5.20 config - previous behaviour)."
            elif [[ "$AUTO_YES" -eq 1 ]]; then
                CLIENT_ISOLATION=1
                log "Client isolation: enabled (--yes, default)."
            else
                local r_iso
                read -rp "Isolate VPN clients from each other? [Y/n]: " r_iso < /dev/tty
                case "$r_iso" in
                    [nN]*) CLIENT_ISOLATION=0; log "Client isolation disabled: clients will see each other inside the VPN." ;;
                    *)     CLIENT_ISOLATION=1; log "Client isolation enabled." ;;
                esac
            fi
            ;;
        *) die "Invalid --isolation='$CLI_ISOLATION'. Allowed: on|off." ;;
    esac
    export CLIENT_ISOLATION
}

# Brings ALLOWED_IPS in line with CLIENT_ISOLATION (idempotent, called on every
# run after the routing mode is determined). Isolation OFF: the tunnel subnet
# is appended to the list (modes 2/3; in mode 1, 0.0.0.0/0 already covers it).
# Isolation ON: our token is removed from mode 2 (off->on round-trip); mode 3
# is left untouched - the custom list belongs to the user, and isolation is
# enforced by the server-side DROP rule regardless.
# CLIENT_ISOLATION_NET tracks ownership of our token (empty if the token is
# user-owned or isolation is enabled) - needed to clean up the previous route
# when the tunnel subnet changes (issue #178, final audit).
_apply_isolation_to_allowed_ips() {
    local net
    net=$(tunnel_network_cidr "$AWG_TUNNEL_SUBNET") || return 0
    # Strip ALL whitespace, not just spaces: validate_cidr_list accepts tabs
    # as separators, and a tab-carrying token would otherwise slip past the
    # pattern match below - duplicating instead of a no-op (PR #179 review).
    local compact=",${ALLOWED_IPS//[[:space:]]/},"

    # Tunnel subnet changed: our previous token (persisted CLIENT_ISOLATION_NET)
    # differs from the current network - remove it in any mode and regardless
    # of the isolation state: by construction the token was added by us, not
    # the user.
    if [[ -n "${CLIENT_ISOLATION_NET:-}" && "$CLIENT_ISOLATION_NET" != "$net" ]]; then
        if [[ "$compact" == *",${CLIENT_ISOLATION_NET},"* ]]; then
            # A loop, not a single replace: a corrupted list may carry the
            # token more than once - purge every copy (PR #179 review).
            while [[ "$compact" == *",${CLIENT_ISOLATION_NET},"* ]]; do
                compact="${compact/,${CLIENT_ISOLATION_NET},/,}"
            done
            compact="${compact#,}"; compact="${compact%,}"
            ALLOWED_IPS="${compact//,/, }"
            log "Tunnel subnet changed: previous route ${CLIENT_ISOLATION_NET} removed from client AllowedIPs."
            compact=",${ALLOWED_IPS// /},"
        fi
        CLIENT_ISOLATION_NET=""
    fi

    if [[ "${CLIENT_ISOLATION:-1}" -eq 0 ]]; then
        if [[ "$ALLOWED_IPS_MODE" == "1" ]]; then
            CLIENT_ISOLATION_NET=""
        elif [[ "$compact" == *",${net},"* ]]; then
            # Already present: our previous token (CLIENT_ISOLATION_NET==net kept)
            # or a user-owned one (CLIENT_ISOLATION_NET empty) - ownership unchanged.
            :
        else
            ALLOWED_IPS="${ALLOWED_IPS}, ${net}"
            CLIENT_ISOLATION_NET="$net"
            log "Isolation disabled: tunnel subnet ${net} added to client AllowedIPs."
        fi
    else
        # Isolation ON: mode 2 - the token is always removed (the list is
        # generated by us); mode 3 - only if we added the token (ownership
        # tracked in CLIENT_ISOLATION_NET).
        if [[ "$compact" == *",${net},"* ]] \
           && { [[ "$ALLOWED_IPS_MODE" == "2" ]] || [[ "${CLIENT_ISOLATION_NET:-}" == "$net" ]]; }; then
            while [[ "$compact" == *",${net},"* ]]; do
                compact="${compact/,${net},/,}"
            done
            compact="${compact#,}"; compact="${compact%,}"
            ALLOWED_IPS="${compact//,/, }"
            log "Isolation enabled: tunnel subnet ${net} removed from client AllowedIPs."
        fi
        CLIENT_ISOLATION_NET=""
    fi
    export CLIENT_ISOLATION_NET
}






# Endpoint validation (FQDN / IPv4 / [IPv6]).
# Returns 0 if the endpoint is safe and matches one of the formats,
# otherwise 1 (the caller decides between die or log_warn + unset).
# Forbids newline/CR/quotes/backslash to prevent injection into
# awgsetup_cfg.init and client.conf via the --endpoint flag (audit).
validate_endpoint() {
    local ep="$1"
    [[ -n "$ep" ]] || return 1
    # Forbid characters that could break the config or inject content
    [[ "$ep" != *$'\n'* && "$ep" != *$'\r'* && \
       "$ep" != *"'"* && "$ep" != *'"'* && "$ep" != *'\\'* && \
       "$ep" != *' '* && "$ep" != *$'\t'* ]] || return 1
    # Bracketed [IPv6] form: structural check of the bracket contents. The previous
    # charset-only test let junk like [:::] / [1:2:3] through. Mirrors _valid_ipv6.
    if [[ "$ep" == \[*\] ]]; then
        local inner="${ep#\[}"; inner="${inner%\]}"
        [[ "$inner" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
        case "$inner" in
            *:::*|*::*::*) return 1 ;;
        esac
        [[ "$inner" == :* && "$inner" != ::* ]] && return 1
        [[ "$inner" == *: && "$inner" != *:: ]] && return 1
        local has_dcolon=0; [[ "$inner" == *::* ]] && has_dcolon=1
        local IFS=':' parts=() p ngroups=0
        read -ra parts <<< "$inner"
        for p in "${parts[@]}"; do
            [[ -z "$p" ]] && continue
            [[ "$p" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
            ngroups=$((ngroups + 1))
        done
        if [[ $has_dcolon -eq 1 ]]; then
            (( ngroups <= 7 )) || return 1
        else
            (( ngroups == 8 )) || return 1
        fi
        return 0
    fi
    # Otherwise FQDN or IPv4
    [[ "$ep" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*|[0-9]{1,3}(\.[0-9]{1,3}){3})$ ]] || return 1
    # If IPv4 format - additionally validate octet range 0-255
    if [[ "$ep" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        [[ "${BASH_REMATCH[1]}" -le 255 && "${BASH_REMATCH[2]}" -le 255 && \
           "${BASH_REMATCH[3]}" -le 255 && "${BASH_REMATCH[4]}" -le 255 ]] || return 1
    fi
    return 0
}

validate_cidr_list() {
    local input="$1" cidr o nospace
    input="${input//$'\r'/}"
    input="${input//$'\t'/ }"
    # A newline means injection into awgsetup_cfg.init (read <<< only sees the
    # first line, the rest would pass unchecked). Same policy as validate_endpoint.
    [[ "$input" != *$'\n'* ]] || return 1
    # Structural comma check before split: bash IFS drops a trailing empty element,
    # so '10.0.0.0/24,' used to pass. Reject leading/trailing/double comma and empty
    # input (spaces are ignored for this check).
    nospace="${input// /}"
    case "$nospace" in
        ""|,*|*,|*,,*) return 1 ;;
    esac
    IFS=',' read -ra cidrs <<< "$input"
    for cidr in "${cidrs[@]}"; do
        cidr="${cidr// /}"
        # Octets without leading zeros; prefix 0-32 enforced in the regex (no octal).
        if ! [[ "$cidr" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})/([0-9]|[12][0-9]|3[0-2])$ ]]; then
            return 1
        fi
        for o in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
            (( o <= 255 )) || return 1
        done
    done
}

configure_routing_mode() {
    if [[ "$CLI_ROUTING_MODE" != "default" ]]; then
        ALLOWED_IPS_MODE=$CLI_ROUTING_MODE
        if [[ "$CLI_ROUTING_MODE" -eq 3 ]]; then
            ALLOWED_IPS=$CLI_CUSTOM_ROUTES
            if [ -z "$ALLOWED_IPS" ]; then die "No networks specified for --route-custom."; fi
        fi
        log "Routing mode from CLI: $ALLOWED_IPS_MODE"
    elif [[ "$AUTO_YES" -eq 1 ]]; then
        ALLOWED_IPS_MODE=2
        log "Routing mode: Amnezia+DNS (--yes, default)."
    else
        echo ""
        log "Select routing mode (client AllowedIPs):"
        echo "  1) All traffic (0.0.0.0/0) - Max privacy, may block LAN"
        echo "  2) Amnezia List+DNS (default) - Recommended for bypassing restrictions"
        echo "  3) Only specified networks (Split Tunneling)"
        read -rp "Your choice [2]: " r_mode < /dev/tty
        ALLOWED_IPS_MODE=${r_mode:-2}
    fi
    case "$ALLOWED_IPS_MODE" in
        1) ALLOWED_IPS="0.0.0.0/0"
           log "Selected mode: All traffic." ;;
        3) if [[ -z "$CLI_CUSTOM_ROUTES" ]]; then
               read -rp "Enter networks (a.b.c.d/xx,...): " ALLOWED_IPS < /dev/tty
               while ! validate_cidr_list "$ALLOWED_IPS"; do
                   log_warn "Invalid CIDR format: '$ALLOWED_IPS'. Expected: x.x.x.x/y[,x.x.x.x/y]"
                   read -rp "Try again: " ALLOWED_IPS < /dev/tty
               done
           else
               ALLOWED_IPS=$CLI_CUSTOM_ROUTES
               if ! validate_cidr_list "$ALLOWED_IPS"; then
                   die "Invalid CIDR format: '$ALLOWED_IPS'. Expected: x.x.x.x/y[,x.x.x.x/y]"
               fi
           fi
           log "Selected mode: Custom ($ALLOWED_IPS)" ;;
        *) ALLOWED_IPS_MODE=2
           # iOS breaks the tunnel if the list starts with 0.0.0.0/5: that block covers
           # the reserved 0.0.0.0/8 which the iOS kernel chokes on, so it never reaches the
           # rest of the routes. 1.0.0.0/8 + 2.0.0.0/7 + 4.0.0.0/6 is the same range minus the
           # zero block (0.0.0.0/8 is non-routable anyway). Do not revert to 0.0.0.0/5 (Issue #42).
           ALLOWED_IPS="1.0.0.0/8, 2.0.0.0/7, 4.0.0.0/6, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/2, 128.0.0.0/3, 160.0.0.0/5, 168.0.0.0/6, 172.0.0.0/12, 172.32.0.0/11, 172.64.0.0/10, 172.128.0.0/9, 173.0.0.0/8, 174.0.0.0/7, 176.0.0.0/4, 192.0.0.0/9, 192.128.0.0/11, 192.160.0.0/13, 192.169.0.0/16, 192.170.0.0/15, 192.172.0.0/14, 192.176.0.0/12, 192.192.0.0/10, 193.0.0.0/8, 194.0.0.0/7, 196.0.0.0/6, 200.0.0.0/5, 208.0.0.0/4, 8.8.8.8/32, 1.1.1.1/32"
           log "Selected mode: Amnezia List+DNS." ;;
    esac
    if [ -z "$ALLOWED_IPS" ]; then die "Failed to determine AllowedIPs."; fi
    export ALLOWED_IPS_MODE ALLOWED_IPS
}

# ==============================================================================
# Вспомогательное
# ==============================================================================





# ==============================================================================
# System optimization (new in v5.0)
# ==============================================================================

# Detect hardware characteristics
detect_hardware() {
    TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
    CPU_CORES=$(nproc)
    MAIN_NIC=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    log "Hardware: RAM=${TOTAL_RAM_MB}MB, CPU=${CPU_CORES} cores, NIC=${MAIN_NIC}"
}

# Remove unnecessary packages and services
cleanup_system() {
    log "Cleaning system of unnecessary components..."

    # Snapshot default route BEFORE cleanup - detects when we break the network.
    # Issue #84: on clean Ubuntu 26.04 server (subiquity, no cloud-init netplan
    # markers) apt-get autoremove after purging cloud-init removed
    # netplan-generator as a transitive dep, and the server lost its IP on reboot.
    local pre_default_route
    pre_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
    log_debug "Pre-cleanup default route: ${pre_default_route:-<none>}"

    # apt-mark hold for critical network stack packages: defence against
    # accidental removal via transitive deps. Covers both netplan naming
    # variants (netplan.io on 24.04, netplan-generator on 25.10/26.04) plus
    # systemd-resolved and netcfg/ifupdown legacy. There is no standalone
    # systemd-networkd package - the binary lives inside systemd, nothing to hold.
    # Before holding we snapshot the user's existing holds so we never strip
    # holds we did not place (e.g. on linux-image-* held by the user).
    local _hold_pkgs="netplan.io netplan-generator systemd-resolved netcfg ifupdown"
    local _preexisting_holds=""
    _preexisting_holds="$(apt-mark showhold 2>/dev/null || true)"
    local _held_actual=()
    local _hpkg
    for _hpkg in $_hold_pkgs; do
        if dpkg-query -W -f='${Status}' "$_hpkg" 2>/dev/null | grep -q "ok installed"; then
            # Skip if user already held - that hold is not ours to release.
            if grep -qxF "$_hpkg" <<<"$_preexisting_holds"; then
                continue
            fi
            apt-mark hold "$_hpkg" >/dev/null 2>&1 && _held_actual+=("$_hpkg")
        fi
    done
    [ ${#_held_actual[@]} -gt 0 ] && log_debug "Apt-mark hold: ${_held_actual[*]}"

    # Packages to remove (safe for VPS)
    # snapd and lxd-agent-loader — Ubuntu only, not present on Debian
    local packages_to_remove=()
    local pkg
    local cleanup_list="modemmanager networkd-dispatcher unattended-upgrades packagekit udisks2"
    if [[ "${OS_ID:-ubuntu}" == "ubuntu" ]]; then
        cleanup_list="snapd $cleanup_list lxd-agent-loader"
    fi
    for pkg in $cleanup_list; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            packages_to_remove+=("$pkg")
        fi
    done

    if [ ${#packages_to_remove[@]} -gt 0 ]; then
        log "Removing: ${packages_to_remove[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get purge -y "${packages_to_remove[@]}" || log_warn "Error removing some packages"
    fi

    # Cleaning snap artifacts (Ubuntu only)
    if [[ "${OS_ID:-ubuntu}" == "ubuntu" && -d /snap ]]; then
        log "Cleaning snap artifacts..."
        rm -rf /snap /var/snap /var/lib/snapd 2>/dev/null || log_warn "snap cleanup error"
    fi

    # cloud-init: remove only if NOT managing network
    # Conservative approach: check cloud-init markers first, then renderer
    if dpkg-query -W -f='${Status}' cloud-init 2>/dev/null | grep -q "ok installed"; then
        local cloud_manages_network=0
        # Check cloud-init markers (priority — safety)
        if ls /etc/netplan/*cloud-init* &>/dev/null 2>&1; then
            cloud_manages_network=1
        elif grep -rq "cloud-init" /etc/netplan/ 2>/dev/null; then
            cloud_manages_network=1
        elif [[ -f /etc/network/interfaces ]] && grep -q "cloud-init" /etc/network/interfaces 2>/dev/null; then
            cloud_manages_network=1
        fi
        if [[ $cloud_manages_network -eq 0 ]]; then
            log "Removing cloud-init (network doesn't depend on it)..."
            DEBIAN_FRONTEND=noninteractive apt-get purge -y cloud-init 2>/dev/null || log_warn "cloud-init removal error"
            rm -rf /etc/cloud /var/lib/cloud 2>/dev/null
        else
            log_warn "cloud-init manages network — skipping removal."
        fi
    fi

    # apt-get autoremove dropped (was the source of Issue #84 on Ubuntu 26.04
    # ISO): autoremove zapped netplan-generator as a transitive dep of
    # cloud-init. Orphans left after purge take ~50-200 MB - acceptable trade
    # for stability. User can manually run apt-get autoremove --no-install-recommends.

    # Release apt-mark holds so packages do not stay frozen for the user.
    local _upkg
    for _upkg in "${_held_actual[@]}"; do
        apt-mark unhold "$_upkg" >/dev/null 2>&1 || true
    done

    # Verify default route is still present. If lost, attempt recovery.
    # We reinstall netplan.io unconditionally (present on every supported
    # distro). netplan-generator only ships from Ubuntu 25.10+ / Debian 13+ -
    # gate the install behind apt-cache show so Debian 12 does not abort the
    # transaction trying to fetch a non-existent package.
    local post_default_route
    post_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
    if [[ -n "$pre_default_route" && -z "$post_default_route" ]]; then
        log_error "Default route lost after cleanup. Attempting recovery..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            netplan.io 2>/dev/null || true
        if apt-cache show netplan-generator &>/dev/null; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                netplan-generator 2>/dev/null || true
        fi
        systemctl restart systemd-networkd 2>/dev/null || true
        netplan apply 2>/dev/null || true
        # Route-wait loop: up to ~26 seconds, polling every 1-5 seconds.
        # Fixed sleeps are unreliable - DHCP route appearance on slow VMs is
        # unpredictable.
        local _wait
        for _wait in 1 2 3 5 5 5 5; do
            post_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
            [[ -n "$post_default_route" ]] && break
            sleep "$_wait"
        done
        # Last-ditch: bring up the interface from pre_default_route. Try
        # networkctl renew first (for systemd-networkd-managed link); if the
        # route still does not come back, fall through to dhclient (ifupdown).
        if [[ -z "$post_default_route" ]]; then
            local _iface
            _iface="$(awk '{for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit } }' <<<"$pre_default_route")"
            if [[ -n "$_iface" ]]; then
                log_warn "Last-ditch attempt to bring $_iface up..."
                ip link set "$_iface" up 2>/dev/null || true
                if command -v networkctl &>/dev/null; then
                    networkctl renew "$_iface" 2>/dev/null || true
                    sleep 3
                    post_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
                fi
                # If networkctl did not bring the route back (or is absent) - dhclient.
                if [[ -z "$post_default_route" ]] && command -v dhclient &>/dev/null; then
                    dhclient -4 "$_iface" 2>/dev/null || true
                    sleep 3
                    post_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
                fi
            fi
        fi
        if [[ -z "$post_default_route" ]]; then
            die "Network did not recover after cleanup_system. Restore it from the console (e.g. sudo dhclient -4 <iface>) and retry the installer with --no-tweaks flag."
        fi
        log_warn "Network recovered: $post_default_route"
    fi

    log "System cleanup completed."
}

# Swap configuration
optimize_swap() {
    log "Optimizing swap..."
    local target_swap_mb

    if [[ $TOTAL_RAM_MB -le 2048 ]]; then
        target_swap_mb=1024
    else
        target_swap_mb=512
    fi

    # Check current swap
    local current_swap_mb
    current_swap_mb=$(free -m | awk '/Swap:/ {print $2}')

    if [[ $current_swap_mb -ge $target_swap_mb ]]; then
        log "Swap is already sufficient: ${current_swap_mb}MB (target: ${target_swap_mb}MB)"
    else
        log "Creating swap file: ${target_swap_mb}MB"
        # Disable existing swap file if present
        if [[ -f /swapfile ]]; then
            swapoff /swapfile 2>/dev/null
            rm -f /swapfile
        fi
        dd if=/dev/zero of=/swapfile bs=1M count="$target_swap_mb" status=none 2>/dev/null || {
            log_warn "Error creating swap file"
            return 1
        }
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1 || { log_warn "mkswap error"; return 1; }
        swapon /swapfile || { log_warn "swapon error"; return 1; }
        # Add to fstab if missing. Precise field match: ignore commented
        # lines and partial matches (e.g. `/swapfile.bak` or an old entry
        # left in a comment).
        if ! awk '!/^[[:space:]]*#/ && $1 == "/swapfile" && $3 == "swap" {found=1} END {exit !(found+0)}' \
             /etc/fstab; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
        log "Swap file created: ${target_swap_mb}MB"
    fi

    # Setting swappiness
    sysctl -w vm.swappiness=10 >/dev/null 2>&1
}

# Network interface optimization
optimize_nic() {
    if [[ -z "$MAIN_NIC" ]]; then
        log_warn "Main NIC not detected, skipping optimization."
        return 1
    fi

    if ! command -v ethtool &>/dev/null; then
        log_debug "ethtool not found, skipping NIC optimization."
        return 0
    fi

    log "NIC optimization: $MAIN_NIC"
    # Disable GRO/GSO/TSO — may interfere with VPN traffic
    ethtool -K "$MAIN_NIC" gro off 2>/dev/null || log_debug "GRO: not supported/already off."
    ethtool -K "$MAIN_NIC" gso off 2>/dev/null || log_debug "GSO: not supported/already off."
    ethtool -K "$MAIN_NIC" tso off 2>/dev/null || log_debug "TSO: not supported/already off."
    log "NIC optimization completed."
}

# Full system optimization
optimize_system() {
    log "Optimizing system for VPN server..."
    detect_hardware
    optimize_swap
    optimize_nic
    log "System optimization completed."
}

# ==============================================================================
# Sysctl configuration (minimal, for --no-tweaks)
# ==============================================================================

setup_minimal_sysctl() {
    log "Configuring minimal sysctl (--no-tweaks)..."
    local f="/etc/sysctl.d/99-amneziawg-forwarding.conf"
    cat > "$f" << SYSEOF
# AmneziaWG — minimal settings (--no-tweaks)
net.ipv4.ip_forward = 1
SYSEOF
    if [[ "${DISABLE_IPV6:-1}" -eq 1 ]]; then
        cat >> "$f" << SYSEOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
SYSEOF
    else
        cat >> "$f" << SYSEOF
net.ipv6.conf.all.forwarding = 1
SYSEOF
    fi
    sysctl -p "$f" >/dev/null 2>&1 || log_warn "sysctl -p error"
    log "Minimal sysctl configured."
}

# ==============================================================================
# Sysctl configuration (extended)
# ==============================================================================

setup_advanced_sysctl() {
    log "Configuring sysctl..."
    local f="/etc/sysctl.d/99-amneziawg-security.conf"

    # Adaptive buffers based on RAM
    local rmem_max wmem_max netdev_backlog
    if [[ ${TOTAL_RAM_MB:-1024} -ge 2048 ]]; then
        rmem_max=16777216    # 16MB
        wmem_max=16777216
        netdev_backlog=5000
    else
        rmem_max=4194304     # 4MB
        wmem_max=4194304
        netdev_backlog=2500
    fi

    cat > "$f" << EOF
# AmneziaWG 2.0 Security/Performance Settings - $(date)
# Auto-generated by install_amneziawg_en.sh v${SCRIPT_VERSION}

# --- IP Forwarding ---
net.ipv4.ip_forward = 1
$(if [[ "${DISABLE_IPV6:-1}" -eq 1 ]]; then
    echo "net.ipv6.conf.all.disable_ipv6 = 1"
    echo "net.ipv6.conf.default.disable_ipv6 = 1"
    echo "net.ipv6.conf.lo.disable_ipv6 = 1"
else
    echo "# IPv6 not disabled"
    echo "net.ipv6.conf.all.forwarding = 1"
fi)

# --- TCP/IP Hardening ---
# rp_filter = 2 (loose mode): validates source IP against ANY route in the
# table, not against the reverse path through the same interface. Strict mode
# (=1) breaks routing on cloud hosters (Hetzner and similar) where the gateway
# is in a different subnet than the VPS IP — reply packets fail the strict
# reverse path check. Loose mode is safe: spoofed source IPs are still dropped
# if no route exists for them at all. Discussion #41 (z036).
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5
net.ipv4.tcp_rfc1337 = 1

# --- Redirects ---
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
$(if [[ "${DISABLE_IPV6:-1}" -ne 1 ]]; then
    echo "net.ipv6.conf.all.accept_redirects = 0"
    echo "net.ipv6.conf.default.accept_redirects = 0"
fi)

# --- BBR Congestion Control ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- Network Buffers (adaptive) ---
net.core.rmem_max = ${rmem_max}
net.core.wmem_max = ${wmem_max}
net.core.netdev_max_backlog = ${netdev_backlog}

# --- Conntrack ---
net.netfilter.nf_conntrack_max = 65536

# --- Security ---
vm.swappiness = 10
kernel.sysrq = 0

# Suppress kernel warning/notice messages in the hoster VNC console.
# Without this, fail2ban UFW blocks spam the VNC window with "[UFW BLOCK]"
# lines and make the console unusable.
# Format: console_loglevel default_msg_loglevel min_console_loglevel default_console_loglevel
# Value 3 = KERN_ERR — only errors and above reach the console.
# Discussion #41 (z036).
kernel.printk = 3 4 1 3
EOF

    log "Applying sysctl..."
    if ! sysctl -p "$f" >/dev/null 2>&1; then
        # nf_conntrack may be unavailable before module is loaded
        log_warn "Some sysctl parameters did not apply (nf_conntrack will be available later)."
        sysctl -p "$f" 2>/dev/null || true
    fi
}

# ==============================================================================
# Firewall and security
# ==============================================================================

# Detect the real SSH port(s) so the UFW rule does not lock you out.
# Without this, ufw limit 22/tcp + default deny incoming cuts server access
# after ufw enable when SSH runs on a non-standard port (Issue #91).
# Самодостаточно: вызывается на шаге 4.
# Sources:
#   1. CLI_SSH_PORT (--ssh-port=, manual override, comma-separated list) - authoritative
#   otherwise UNION (not fallback - so we never miss the real port):
#   2. sshd -T   (effective config: `Port` AND `ListenAddress host:port`, honours drop-ins)
#   3. ss -tlnp  (real sshd listening sockets: ground truth for ListenAddress)
#   4. /etc/ssh/sshd_config + sshd_config.d/*.conf (parsing, only if 2-3 are empty)
#   5. 22 (default, if nothing is found)
# Prints unique valid ports (1-65535) space-separated to stdout.
# IMPORTANT: only log_warn/log_error (stderr) inside; log() writes to stdout
# and would corrupt the $(detect_ssh_ports) capture.
detect_ssh_ports() {
    local ports="" p pp valid=""
    # awk: pulls the port from `port N` and `listenaddress host:port` lines
    # (IPv4 and [IPv6]); a bare address without a port is skipped.
    local awk_ports='tolower($1)=="port"&&$2~/^[0-9]+$/{print $2} tolower($1)=="listenaddress"{v=$2; if(v~/\]:[0-9]+$/){sub(/.*\]:/,"",v); print v} else if(v~/^[0-9.]+:[0-9]+$/){sub(/.*:/,"",v); print v}}'

    if [[ -n "$CLI_SSH_PORT" ]]; then
        # 1. Manual override - authoritative source
        ports="${CLI_SSH_PORT//,/ }"
    else
        # 2. sshd -T: effective configuration (Port + ListenAddress, drop-ins)
        if command -v sshd &>/dev/null; then
            ports+=" $(sshd -T 2>/dev/null | awk "$awk_ports" | tr '\n' ' ')"
        fi
        # 3. ss: real sshd listening sockets. Merged, not fallback - catches the
        #    ListenAddress port even when sshd -T prints the default port 22.
        if command -v ss &>/dev/null; then
            ports+=" $(ss -H -tlnp 2>/dev/null | awk '/"sshd"/{n=split($4,a,":"); print a[n]}' | tr '\n' ' ')"
        fi
        # 4. Parse config files - only if sshd -T and ss yielded nothing
        if [[ -z "${ports// }" ]]; then
            local cfgs=() d
            [[ -f /etc/ssh/sshd_config ]] && cfgs+=(/etc/ssh/sshd_config)
            for d in /etc/ssh/sshd_config.d/*.conf; do
                [[ -f "$d" ]] && cfgs+=("$d")
            done
            if [[ "${#cfgs[@]}" -gt 0 ]]; then
                ports+=" $(awk "$awk_ports" "${cfgs[@]}" 2>/dev/null | tr '\n' ' ')"
            fi
        fi
    fi

    # Validate (decimal 1-65535, 10# guards against octal) + dedup preserving order
    for p in $ports; do
        if [[ "$p" =~ ^[0-9]+$ ]]; then
            pp=$((10#$p))
            if (( pp >= 1 && pp <= 65535 )); then
                case " $valid " in
                    *" $pp "*) ;;
                    *) valid+="${valid:+ }$pp" ;;
                esac
            fi
        fi
    done

    # 5. Default if detection produced nothing valid
    if [[ -z "$valid" ]]; then
        [[ -n "$CLI_SSH_PORT" ]] && log_warn "--ssh-port has no valid ports, falling back to 22."
        valid="22"
    fi
    printf '%s' "$valid"
}

setup_improved_firewall() {
    log "Configuring UFW..."
    if ! command -v ufw &>/dev/null; then install_packages ufw; fi

    # Detect main network interface for route rule
    local main_nic
    main_nic=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    if [[ -z "$main_nic" ]]; then
        log_warn "Could not detect network interface for UFW route."
    fi

    # Detect the real SSH port(s) so we do not lock out access on a non-standard port (Issue #91)
    local ssh_ports _sp
    ssh_ports=$(detect_ssh_ports)
    log "SSH port(s) for the UFW rule: ${ssh_ports}"

    # Port change on reinstall: delete the old port's rule before adding the
    # new one, otherwise the old UDP port stays open forever - the only other
    # ufw delete lives in uninstall and reads the already rewritten config
    # (Issue #175). SSH limit rules are deliberately left alone: auto-removing
    # an SSH rule on a misdetected port would cut off access to the server.
    if [[ -n "${PREV_AWG_PORT:-}" && "$PREV_AWG_PORT" =~ ^[0-9]+$ \
          && "$PREV_AWG_PORT" != "$AWG_PORT" ]]; then
        if ufw delete allow "${PREV_AWG_PORT}/udp" >/dev/null 2>&1; then
            log "UFW: old port rule ${PREV_AWG_PORT}/udp deleted (port changed to ${AWG_PORT})."
            PREV_AWG_PORT=""
        else
            log_warn "UFW: failed to delete the old port rule ${PREV_AWG_PORT}/udp (the rule may not exist). Will retry on the next installer run."
        fi
    fi

    local ufw_errors=0
    if ufw status 2>/dev/null | grep -q inactive; then
        log "UFW is inactive. Configuring..."
        ufw default deny incoming  || { log_warn "UFW: failed to set default deny incoming"; ufw_errors=1; }
        ufw default allow outgoing || { log_warn "UFW: failed to set default allow outgoing"; ufw_errors=1; }
        for _sp in $ssh_ports; do
            ufw limit "${_sp}/tcp" comment "SSH Rate Limit" || { log_warn "UFW: failed to limit SSH (port ${_sp})"; ufw_errors=1; }
        done
        ufw allow "${AWG_PORT}/udp" comment "AmneziaWG VPN" || { log_warn "UFW: failed to allow VPN port"; ufw_errors=1; }
        if [[ -n "$main_nic" ]]; then
            ufw route allow in on awg0 out on "$main_nic" comment "AmneziaWG Routing" \
                || { log_warn "UFW: failed to add route rule"; ufw_errors=1; }
            log "VPN routing rule added (awg0 → ${main_nic})."
        fi
        if [[ "$ufw_errors" -ne 0 ]]; then
            log_error "One or more UFW rules failed to apply. Check settings manually."
            return 1
        fi
        log "UFW rules added."
        log_warn "--- ENABLING UFW ---"
        log_warn "UFW will allow SSH ONLY on port(s): ${ssh_ports}. Make sure you connect over it."
        if [[ "$ssh_ports" != "22" ]]; then
            log_warn "NOTE: SSH on a non-standard port. If the port is detected wrong, you will lose server access."
            log_warn "Override if needed: --ssh-port=PORT"
        fi
        local confirm_ufw="y"
        if [[ "$AUTO_YES" -eq 0 ]]; then
            sleep 5
            read -rp "Enable UFW? [y/N]: " confirm_ufw < /dev/tty
        else
            log "Auto-enabling UFW (--yes)."
        fi
        if ! [[ "$confirm_ufw" =~ ^[[:space:]]*[Yy]([Ee][Ss])?[[:space:]]*$ ]]; then
            log_warn "UFW configured but not activated by your choice."
            log_warn "The server is running WITHOUT a firewall. Enable later: sudo ufw enable"
            return 0
        fi
        if ! ufw --force enable; then die "UFW enable error."; fi
        log "UFW enabled."
        # Marker: UFW was enabled by our installer (not by the user beforehand).
        # Used in step_uninstall to decide whether disabling UFW is safe.
        # Protects against destructive uninstall on a VPS where UFW was used
        # for SSH/web hardening BEFORE our script was installed (audit).
        touch "$AWG_DIR/.ufw_enabled_by_installer" 2>/dev/null || \
            log_warn "Failed to create UFW marker — uninstall will not disable UFW automatically."
    else
        log "UFW is active. Updating rules..."
        for _sp in $ssh_ports; do
            ufw limit "${_sp}/tcp" comment "SSH Rate Limit" || { log_warn "UFW: failed to limit SSH (port ${_sp})"; ufw_errors=1; }
        done
        ufw allow "${AWG_PORT}/udp" comment "AmneziaWG VPN" || { log_warn "UFW: failed to allow VPN port"; ufw_errors=1; }
        if [[ -n "$main_nic" ]]; then
            ufw route allow in on awg0 out on "$main_nic" comment "AmneziaWG Routing" \
                || { log_warn "UFW: failed to add route rule"; ufw_errors=1; }
        fi
        if [[ "$ufw_errors" -ne 0 ]]; then
            log_error "One or more UFW rules failed to apply. Check settings manually."
            return 1
        fi
        ufw reload || log_warn "UFW reload error."
        log "Rules updated."
    fi
    log "UFW configured."
    log "$(ufw status verbose 2>&1)"
    return 0
}

secure_files() {
    log "Setting secure file permissions..."
    chmod 700 "$AWG_DIR" 2>/dev/null
    chmod 700 /etc/amnezia 2>/dev/null
    chmod 700 /etc/amnezia/amneziawg 2>/dev/null
    chmod 600 /etc/amnezia/amneziawg/*.conf 2>/dev/null
    find "$AWG_DIR" -name "*.conf" -type f -exec chmod 600 {} \; 2>/dev/null
    find "$AWG_DIR" -name "*.key" -type f -exec chmod 600 {} \; 2>/dev/null
    find "$AWG_DIR" -name "*.png" -type f -exec chmod 600 {} \; 2>/dev/null
    find "$AWG_DIR" -name "*.private" -type f -exec chmod 600 {} \; 2>/dev/null
    find "$AWG_DIR" -name "*.public" -type f -exec chmod 600 {} \; 2>/dev/null
    # Каталоги клиентов: у каждого свой, внутри ключи и QR.
    find "$AWG_DIR" -mindepth 1 -maxdepth 1 -type d -exec chmod 700 {} \; 2>/dev/null
    [[ -f "$LOG_FILE" ]] && chmod 640 "$LOG_FILE"
    [[ -f "$AWG_DIR/awg3.sh" ]] && chmod 700 "$AWG_DIR/awg3.sh"
    log "File permissions set."
}

setup_fail2ban() {
    log "Configuring Fail2Ban..."
    if ! command -v fail2ban-client &>/dev/null; then
        install_packages fail2ban
        # Marker: the fail2ban package was installed by our installer (rather
        # than being present before it). step_uninstall purges fail2ban only
        # when the marker exists, so it never wipes SSH protection the user
        # had set up beforehand (symmetric to .ufw_enabled_by_installer).
        if command -v fail2ban-client &>/dev/null; then
            touch "$AWG_DIR/.fail2ban_installed_by_installer" 2>/dev/null || \
                log_warn "Failed to create the fail2ban marker - uninstall will not remove the fail2ban package."
        fi
    fi
    if ! command -v fail2ban-client &>/dev/null; then
        log_warn "Fail2Ban not installed, skipping."
        return 1
    fi

    # banaction=ufw only takes effect with UFW active: if the user declined to
    # enable UFW at step 4, bans land in an inactive ruleset and effectively
    # do nothing (while fail2ban itself looks "green").
    if ufw status 2>/dev/null | grep -q inactive; then
        log_warn "UFW is not active: fail2ban bans (banaction=ufw) have no effect while UFW is off. Enable with: sudo ufw enable"
    fi

    # Debian: journald instead of rsyslog, needs python3-systemd
    if [[ "${OS_ID:-}" == "debian" ]]; then
        install_packages python3-systemd
    fi

    mkdir -p /etc/fail2ban/jail.d 2>/dev/null

    # Backend: systemd for Debian and Ubuntu (no rsyslog)
    local f2b_backend="systemd"

    cat > /etc/fail2ban/jail.d/amneziawg.conf << JAILEOF || { log_warn "jail.d/amneziawg.conf write error"; return 1; }
# AmneziaWG — SSH protection (managed by amneziawg-installer)
[sshd]
enabled = true
backend = ${f2b_backend}
maxretry = 5
findtime = 10m
bantime  = 1h
banaction = ufw
JAILEOF

    systemctl restart fail2ban
    # Wait a second, service is restarting...
    sleep 1

    if systemctl is-active --quiet fail2ban; then
        log "Fail2Ban configured and restarted."
    else
        log_warn "fail2ban restart error"
    fi
    return 0
}

# ==============================================================================
# Service status check
# ==============================================================================

check_service_status() {
    log "Checking service status..."
    local ok=1

    if systemctl is-failed --quiet awg-quick@awg0; then
        log_error "Service FAILED!"
        ok=0
    fi

    if ! ip addr show awg0 &>/dev/null; then
        log_error "Interface awg0 not found!"
        ok=0
    fi

    if ! awg show 2>/dev/null | grep -q "interface: awg0"; then
        log_error "awg show cannot see interface!"
        ok=0
    fi

    # Port check. Порт читается из самого awg0.conf — другого источника нет.
    local port_check=${AWG_PORT:-0}
    if [[ "$port_check" -eq 0 ]] && [[ -f "$SERVER_CONF_FILE" ]]; then
        port_check=$(awk -F'=' '/^[[:space:]]*ListenPort[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' \
                     "$SERVER_CONF_FILE" 2>/dev/null)
        port_check=${port_check:-0}
    fi
    if [[ "$port_check" -ne 0 ]]; then
        if ! ss -lunp | grep -q ":${port_check} "; then
            log_error "Port $port_check/udp is not listening!"
            ok=0
        fi
    fi

    # AWG 2.0 parameter check
    if awg show awg0 2>/dev/null | grep -q "jc:"; then
        log "AWG 2.0 parameters active."
    else
        log_warn "AWG 2.0 parameters not detected in awg show."
    fi

    if [[ "$ok" -eq 1 ]]; then
        log "Service and interface status OK."
        return 0
    else
        return 1
    fi
}

# ==============================================================================
# Diagnostics
# ==============================================================================

create_diagnostic_report() {
    # --diagnostic выполняется ДО основной проверки root: под обычным
    # пользователем каждая запись log_msg в каталог данных провалится, отчёт
    # не создастся, а exit 0 выглядел бы как ложный успех.
    if [ "$(id -u)" -ne 0 ]; then die "Run the script as root (sudo bash $0 --diagnostic)."; fi
    log "Creating diagnostics..."
    local rf
    rf="$AWG_DIR/diag_$(date +%F_%T).txt"
    {
        echo "=== AMNEZIAWG 2.0 DIAGNOSTIC REPORT ==="
        echo ""
        echo "!!! WARNING: This report contains IP addresses, ports and routes."
        echo "!!! Review and redact private data before posting to public issues."
        echo ""
        echo "Generated: $(date)"
        echo "Hostname: $(hostname)"
        echo "Installer: v${SCRIPT_VERSION}"
        echo ""
        echo "--- OS ---"
        lsb_release -ds 2>/dev/null || cat /etc/os-release
        uname -a
        echo ""
        echo "--- Hardware ---"
        echo "RAM: $(awk '/MemTotal/ {printf "%.0f MB", $2/1024}' /proc/meminfo)"
        echo "CPU: $(nproc) cores"
        echo "Swap: $(free -m | awk '/Swap:/ {print $2}') MB"
        echo ""
        echo "--- Server Config ($SERVER_CONF_FILE) ---"
        # Скрываются приватный ключ и общий ключ защиты заголовка: по ним
        # восстанавливается доступ к туннелю, а отчёт часто уходит в issue.
        if [[ -f "$SERVER_CONF_FILE" ]]; then
            sed -e 's/PrivateKey = .*/PrivateKey = [HIDDEN]/' \
                -e 's/HeaderProtectionKey = .*/HeaderProtectionKey = [HIDDEN]/' \
                -e 's/PresharedKey = .*/PresharedKey = [HIDDEN]/' "$SERVER_CONF_FILE"
        else
            echo "File not found"
        fi
        echo ""
        echo "--- Service Status ---"
        systemctl status awg-quick@awg0 --no-pager -l 2>/dev/null || echo "Service not found"
        echo ""
        echo "--- AWG Status ---"
        awg show 2>/dev/null || echo "awg show failed"
        echo ""
        echo "--- AWG Version ---"
        awg --version 2>/dev/null || echo "awg --version failed"
        echo ""
        echo "--- Network Interfaces ---"
        ip a 2>/dev/null
        echo ""
        echo "--- Listening Ports ---"
        ss -lunp 2>/dev/null
        echo ""
        echo "--- Firewall Status ---"
        if command -v ufw &>/dev/null; then ufw status verbose; else echo "UFW N/A"; fi
        echo ""
        echo "--- Routing Table ---"
        ip route 2>/dev/null
        echo ""
        echo "--- Kernel Params ---"
        sysctl net.ipv4.ip_forward net.ipv6.conf.all.disable_ipv6 2>/dev/null
        echo ""
        echo "--- AWG Journal (last 50) ---"
        journalctl -u awg-quick@awg0 -n 50 --no-pager --output=cat 2>/dev/null || echo "N/A"
        echo ""
        echo "--- Client List ---"
        grep "^#_Name = " "$SERVER_CONF_FILE" 2>/dev/null | sed 's/^#_Name = //' || echo "N/A"
        echo ""
        echo "--- DKMS Status ---"
        dkms status 2>/dev/null || echo "N/A"
        echo ""
        echo "--- Module Info ---"
        modinfo amneziawg 2>/dev/null || echo "N/A"
        echo ""
        echo "=== END ==="
    } > "$rf" || log_error "Report write error."
    chmod 600 "$rf" || log_warn "Report chmod error."
    log "Report: $rf"
}

# ==============================================================================
# Uninstall
# ==============================================================================

step_uninstall() {
    log "### AMNEZIAWG UNINSTALL ###"
    echo ""
    echo "WARNING! Complete removal of AmneziaWG and configurations."
    echo "This process is irreversible!"
    echo ""
    local confirm="" backup="Y"
    if [[ "$AUTO_YES" -eq 0 ]]; then
        read -rp "Are you sure? (type 'yes'): " confirm < /dev/tty
        if [[ "$confirm" != "yes" ]]; then log "Uninstall cancelled."; exit 1; fi
        read -rp "Create backup before removal? [Y/n]: " backup < /dev/tty
    else
        log "Auto-confirming uninstall (--yes)."
    fi
    if [[ -z "$backup" || "$backup" =~ ^[[:space:]]*[Yy]([Ee][Ss])?[[:space:]]*$ ]]; then
        local bf
        bf="$HOME/awg_uninstall_backup_$(date +%F_%H-%M-%S).tar.gz"
        log "Creating backup: $bf"
        if tar -czf "$bf" -C / etc/amnezia "$AWG_DIR" --ignore-failed-read 2>/dev/null \
            && chmod 600 "$bf"; then
            log "Backup created: $bf"
        else
            log_warn "Backup failed — check $bf manually before continuing"
        fi
    fi
    # Файла настроек больше нет, откуда читать прежний --no-tweaks: берём
    # текущее значение флага. Правила UFW и sysctl всё равно снимаются
    # идемпотентно, лишний проход безвреден.
    local saved_no_tweaks="${NO_TWEAKS:-0}"
    log "Stopping service..."
    systemctl stop awg-quick@awg0 2>/dev/null
    # Isolation DROP rules (issue #178): the on-disk config's PostDown may no
    # longer contain -D DROP (an on->off reinstall interrupted between steps
    # 6 and 7) - drain stale rules explicitly, same as step 7.
    while iptables -D FORWARD -i awg0 -o awg0 -j DROP 2>/dev/null; do :; done
    while ip6tables -D FORWARD -i awg0 -o awg0 -j DROP 2>/dev/null; do :; done
    systemctl disable awg-quick@awg0 2>/dev/null
    modprobe -r amneziawg 2>/dev/null || true
    # v5.12.0+: kernel module auto-repair on kernel upgrade.
    # Remove apt hook and systemd unit BEFORE apt purge so the hook does not
    # fire during amneziawg-dkms purge (the helper would try to rebuild DKMS,
    # but the package is already gone). Files may be absent on installs from
    # before v5.12.0 — all operations are idempotent.
    log "Removing kernel module auto-repair components (v5.12.0+)..."
    if systemctl is-enabled amneziawg-ensure-module.service &>/dev/null; then
        systemctl disable amneziawg-ensure-module.service 2>/dev/null || true
    fi
    rm -f /etc/systemd/system/amneziawg-ensure-module.service \
        /etc/apt/apt.conf.d/99-amneziawg-post-kernel \
        /etc/logrotate.d/amneziawg-ensure-module \
        /usr/local/sbin/amneziawg-ensure-module \
        2>/dev/null
    # Also clean up staging dotfiles that may be left over from an interrupted install (atomic deploy).
    rm -f /etc/systemd/system/.amneziawg-ensure-module.service.new \
        /etc/apt/apt.conf.d/.99-amneziawg-post-kernel.new \
        /etc/logrotate.d/.amneziawg-ensure-module.new \
        /usr/local/sbin/.amneziawg-ensure-module.new \
        2>/dev/null || true
    rm -f /var/log/amneziawg-ensure-module.log* 2>/dev/null || true
    rm -rf /var/lib/amneziawg 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    if [[ "$saved_no_tweaks" -eq 0 ]]; then
        log "Cleaning up AmneziaWG UFW rules..."
        if command -v ufw &>/dev/null; then
            # Порт для снятия правила читается из живого awg0.conf, пока он
            # ещё на месте: другого источника истины нет.
            local port_to_del=""
            if [[ -f "$SERVER_CONF_FILE" ]]; then
                port_to_del=$(awk -F'=' '/^[[:space:]]*ListenPort[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' \
                              "$SERVER_CONF_FILE" 2>/dev/null)
            fi
            port_to_del=${port_to_del:-39743}
            # Removing our rules is ALWAYS performed (idempotent)
            ufw delete allow "${port_to_del}/udp" 2>/dev/null
            # To delete a route rule we need an exact match with how it was created:
            # "ufw route allow in on awg0 out on <nic>". Without "out on", UFW will
            # not find the rule and it stays in ufw status. Discussion #41.
            local _nic
            _nic=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
            if [[ -n "$_nic" ]]; then
                ufw route delete allow in on awg0 out on "$_nic" 2>/dev/null
            fi
            # Fallback: try deleting without out on (for compatibility with older rules)
            ufw route delete allow in on awg0 2>/dev/null

            # ufw disable runs ONLY if UFW was enabled by our installer.
            # Protects against destructive uninstall on a VPS where UFW was used
            # for SSH/web hardening BEFORE our script was installed (audit).
            # Backwards compat: older installs without the marker keep UFW active.
            if [[ -f "$AWG_DIR/.ufw_enabled_by_installer" ]]; then
                log "Disabling UFW (was enabled by our installer)..."
                ufw --force disable 2>/dev/null
                rm -f "$AWG_DIR/.ufw_enabled_by_installer"
            else
                log "Leaving UFW active (was active before installation, or older installer version)."
            fi
        fi
        log "Removing Fail2Ban bans..."
        if command -v fail2ban-client &>/dev/null; then
            fail2ban-client unban --all 2>/dev/null || true
            systemctl stop fail2ban 2>/dev/null
        fi
    else
        log "Skipping UFW/Fail2Ban (installed with --no-tweaks)."
    fi
    log "Removing packages..."
    # Clear the hold on the PPA packages (set by the H0 pinned path) BEFORE the PPA
    # is removed: `apt-mark unhold` needs an installed or candidate version, and once
    # the PPA (below) is gone the candidate disappears and apt-mark fails with
    # 'Can't select ... version', leaving the hold in dpkg selections -> that blocks
    # a future reinstall. The dpkg fallback clears the selection directly if the PPA
    # was already removed by a prior run.
    local _hp
    for _hp in amneziawg amneziawg-dkms; do
        apt-mark unhold "$_hp" >/dev/null 2>&1 || true
        if dpkg --get-selections "$_hp" 2>/dev/null | grep -q '[[:space:]]hold$'; then
            echo "$_hp deinstall" | dpkg --set-selections >/dev/null 2>&1 || true
        fi
    done
    if [[ "$saved_no_tweaks" -eq 0 ]]; then
        local _purge_pkgs=(amneziawg-dkms amneziawg-tools qrencode)
        # Purge fail2ban only if we installed it ourselves (marker from
        # setup_fail2ban) - otherwise SSH protection the user had before the
        # installer must not disappear together with the VPN. Our jail file
        # is removed below in any case. Backwards compat: old installs
        # without the marker keep fail2ban installed.
        if [[ -f "$AWG_DIR/.fail2ban_installed_by_installer" ]]; then
            _purge_pkgs+=(fail2ban)
        else
            log "fail2ban left installed (was present before the installer or an older installer version)."
        fi
        DEBIAN_FRONTEND=noninteractive apt-get purge -y "${_purge_pkgs[@]}" 2>/dev/null || log_warn "Purge error."
    else
        DEBIAN_FRONTEND=noninteractive apt-get purge -y amneziawg-dkms amneziawg-tools qrencode 2>/dev/null || log_warn "Purge error."
    fi
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null || log_warn "Autoremove error."
    log "Removing PPA and files..."
    rm -f /etc/apt/sources.list.d/amnezia-ppa.sources \
        /etc/apt/sources.list.d/amnezia-ppa.list \
        /etc/apt/sources.list.d/amnezia-ubuntu-ppa-*.list \
        /etc/apt/sources.list.d/amnezia-ubuntu-ppa-*.sources \
        /etc/apt/keyrings/amnezia-ppa.gpg 2>/dev/null
    rm -rf /etc/amnezia \
        /etc/modules-load.d/amneziawg.conf \
        /etc/sysctl.d/99-amneziawg-security.conf \
        /etc/sysctl.d/99-amneziawg-forwarding.conf \
        /etc/logrotate.d/amneziawg* || log_warn "File removal error."
    if [[ "$saved_no_tweaks" -eq 0 ]]; then
        # Remove only our own jail file.
        # Previously there was a heuristic "if jail.local contains banaction = ufw,
        # remove the whole file" — too broad a filter, could wipe an unrelated
        # jail.local with custom jails. Heuristic removed (audit).
        # If a user still has a jail.local from very old installer versions,
        # leave it for them to deal with.
        rm -f /etc/fail2ban/jail.d/amneziawg.conf 2>/dev/null
        # If fail2ban was not purged (it predates us) - restart it without our
        # jail: it was stopped above (systemctl stop fail2ban).
        if command -v fail2ban-client &>/dev/null && [[ ! -f "$AWG_DIR/.fail2ban_installed_by_installer" ]]; then
            systemctl restart fail2ban 2>/dev/null || log_warn "Failed to restart fail2ban after removing our jail."
        fi
    fi
    log "Removing DKMS..."
    # Properly deregister the DKMS module (any amneziawg/* version) and remove the
    # source tree in /usr/src, not just the state in /var/lib/dkms. The hold on the
    # PPA packages was cleared above (before PPA removal). `dkms status`:
    # 'amneziawg/1.0.0, <kern>...'.
    if command -v dkms >/dev/null 2>&1; then
        local _dv
        while IFS= read -r _dv; do
            [[ -n "$_dv" ]] || continue
            if ! dkms remove -m amneziawg -v "$_dv" --all >/dev/null 2>&1; then
                log_warn "dkms remove amneziawg/$_dv failed - cleaning files manually."
            fi
        done < <(dkms status 2>/dev/null | awk -F'[,/ ]+' '/^amneziawg[,/]/{print $2}' | sort -u)
    fi
    rm -rf /var/lib/dkms/amneziawg* /usr/src/amneziawg-* || log_warn "DKMS removal error."
    # Clean up any leftover built .ko (if dkms remove did not run) + depmod.
    find /lib/modules -name 'amneziawg.ko*' -path '*/updates/dkms/*' -delete 2>/dev/null || true
    command -v depmod >/dev/null 2>&1 && depmod -a >/dev/null 2>&1 || true
    log "Restoring sysctl..."
    # Only the exact lines legacy versions of our installer wrote (=1 for
    # all/default/lo). Previously ANY line containing disable_ipv6 was removed -
    # including lines added by the user themselves (e.g. an =0 override).
    if grep -qE '^net\.ipv6\.conf\.(all|default|lo)\.disable_ipv6[[:space:]]*=[[:space:]]*1[[:space:]]*$' /etc/sysctl.conf 2>/dev/null; then
        sed -i -E '/^net\.ipv6\.conf\.(all|default|lo)\.disable_ipv6[[:space:]]*=[[:space:]]*1[[:space:]]*$/d' /etc/sysctl.conf || log_warn "sed sysctl.conf error"
    fi
    sysctl -p --system 2>/dev/null
    rm -f /etc/apt/sources.list.d/*.bak-* "$AWG_DIR"/ubuntu.sources.bak-* 2>/dev/null || true
    log "Removing cron and scripts..."
    rm -f /etc/cron.d/awg-expiry 2>/dev/null
    log "=== UNINSTALL COMPLETED ==="
    # Copy log and remove working directory
    cp "$LOG_FILE" "$HOME/awg_uninstall.log" 2>/dev/null || true
    rm -rf "$AWG_DIR" 2>/dev/null || true
    exit 0
}

# ==============================================================================
# STEP 0: Initialization
# ==============================================================================


# ==============================================================================
# STEP 1: System update, cleanup, and optimization
# ==============================================================================

step1_update_and_optimize() {
    update_state 1
    log "### STEP 1: System update, cleanup, and optimization ###"

    # First-boot dpkg-lock resilience: unattended-upgrades and apt-daily often
    # hold the lock for several minutes (issue #150 - apt full-upgrade used to
    # fail immediately). DPkg::Lock::Timeout makes apt wait for the lock to be
    # released instead of erroring out.
    mkdir -p /etc/apt/apt.conf.d
    printf 'DPkg::Lock::Timeout "300";\n' > /etc/apt/apt.conf.d/99-amneziawg-lock-timeout \
        || log_warn "Failed to write apt lock-timeout (issue #150 mitigation)."

    # Clean unnecessary components (BEFORE update to save bandwidth/time)
    if [[ "$NO_TWEAKS" -eq 0 ]]; then
        cleanup_system
    else
        log "Skipping system cleanup (--no-tweaks)."
    fi

    log "Updating package lists..."
    apt_update_tolerant || die "apt update error."
    # Cache is fresh: install_packages below must not rerun apt update
    # (sources do not change in step 1).
    _APT_UPDATED=1

    log "Unlocking dpkg..."
    if ! apt-get check &>/dev/null; then
        log_warn "dpkg locked or corrupted, fixing..."
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a || log_warn "dpkg --configure -a."
    fi

    log "Updating system..."
    if ! DEBIAN_FRONTEND=noninteractive apt full-upgrade -y; then
        _lock_holder="$(fuser /var/lib/dpkg/lock-frontend 2>/dev/null | tr -s ' ' || true)"
        if [[ -n "$_lock_holder" ]]; then
            log_warn "dpkg-lock is held by:${_lock_holder} (usually first-boot unattended-upgrades)."
        fi
        log_warn "apt full-upgrade failed, fixing dpkg and retrying..."
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true
        DEBIAN_FRONTEND=noninteractive apt full-upgrade -y \
            || die "apt full-upgrade error. Another apt/unattended-upgrades process is likely holding the dpkg lock. Wait for it to finish (check: fuser /var/lib/dpkg/lock-frontend) or run: systemctl stop unattended-upgrades; dpkg --configure -a - then run the script again."
    fi
    log "System updated."

    install_packages curl wget gpg sudo ethtool

    if [[ "$NO_TWEAKS" -eq 0 ]]; then
        # System optimization
        optimize_system
        # Sysctl configuration
        setup_advanced_sysctl
    else
        log "Skipping optimization and hardening (--no-tweaks)."
        setup_minimal_sysctl
    fi

    log "Step 1 completed successfully."

    # Апстрим здесь перезагружался БЕЗУСЛОВНО и полагался на то, что человек
    # запустит скрипт заново, а state-машина продолжит со второго шага. Мы
    # выполняем шаги подряд, поэтому безусловная перезагрузка означала бы
    # бесконечный цикл: обновлять уже нечего, а reboot всё равно происходит.
    #
    # Перезагрузка нужна ровно в одном случае — обновилось ядро. Иначе DKMS
    # соберёт модуль под работающее (старое) ядро, а после следующего ребута
    # он окажется несовместим. Признак берём из штатного маркера apt.
    if [[ -f /var/run/reboot-required ]]; then
        log_warn "обновилось ядро — нужна перезагрузка перед сборкой модуля"
        request_reboot 2
    fi
    log "Перезагрузка не требуется, продолжаю."
    update_state 2
}

# ==============================================================================
# ARM prebuilt support
# ==============================================================================

# _try_install_prebuilt_arm — download and install a prebuilt amneziawg .deb
# for the current ARM kernel from the arm-packages GitHub release.
#
# Returns 0 if a matching prebuilt was installed successfully.
# Returns 1 if no match was found or installation failed (caller falls back to DKMS).
#
# Prebuilt packages are built by .github/workflows/arm-build.yml and published
# to the arm-packages release tag. The filename encodes both the target ID and
# the exact kernel version: amneziawg-kmod-<target-id>_<kernel-version>_<arch>.deb
#
# Kernel version matching is exact — the module vermagic must match uname -r.
# DKMS is the preferred path for kernels that haven't been pre-built yet.
_try_install_prebuilt_arm() {
    local kernel arch target_id asset_name asset_url tmpfile tmpsha expected_sha actual_sha
    kernel="$(uname -r)"
    arch="$(dpkg --print-architecture)"

    # Map kernel string to a build target ID
    if [[ "$kernel" == *+rpt-rpi-2712* ]]; then
        target_id="rpi5-bookworm-arm64"
    elif [[ "$kernel" == *+rpt* && "$arch" == "arm64" ]]; then
        target_id="rpi-bookworm-arm64"
    elif [[ "$kernel" == *+rpt* && "$arch" == "armhf" ]]; then
        target_id="rpi-bookworm-armhf"
    elif [[ "$kernel" == *-generic* && "${OS_VERSION:-}" == "24.04" ]]; then
        target_id="ubuntu-2404-arm64"
    elif [[ "$kernel" == *-generic* && "${OS_VERSION:-}" == "25.10" ]]; then
        target_id="ubuntu-2510-arm64"
    elif [[ "$kernel" == *-arm64* && "${OS_ID:-}" == "debian" && "${OS_VERSION:-}" == "13" ]]; then
        target_id="debian-trixie-arm64"
    elif [[ "$kernel" == *-arm64* && "${OS_ID:-}" == "debian" ]]; then
        target_id="debian-bookworm-arm64"
    else
        log "No prebuilt target for kernel $kernel ($arch)"
        return 1
    fi

    # Asset filename encodes the exact kernel version
    asset_name="amneziawg-kmod-${target_id}_${kernel}_${arch}.deb"
    asset_url="https://github.com/bivlked/amneziawg-installer/releases/download/arm-packages/${asset_name}"

    log "Trying prebuilt: $asset_name"
    tmpfile="$(mktemp /tmp/amneziawg-prebuilt-XXXXXX.deb)"
    tmpsha="$(mktemp /tmp/amneziawg-prebuilt-XXXXXX.deb.sha256)"

    # Download SHA256 checksum first
    if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 \
            -o "$tmpsha" "${asset_url}.sha256" 2>/dev/null; then
        log "Prebuilt not available for $kernel — using DKMS"
        rm -f "$tmpfile" "$tmpsha"
        return 1
    fi

    if curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 \
            -o "$tmpfile" "$asset_url" 2>/dev/null; then
        # Verify integrity before installing a kernel module
        expected_sha="$(cat "$tmpsha")"
        actual_sha="$(sha256sum "$tmpfile" | awk '{print $1}')"
        rm -f "$tmpsha"
        if [[ "$expected_sha" != "$actual_sha" ]]; then
            log_warn "Prebuilt SHA256 mismatch — discarding download"
            rm -f "$tmpfile"
            return 1
        fi

        log "Downloaded prebuilt (SHA256 OK), installing..."
        if dpkg -i "$tmpfile" 2>/dev/null; then
            rm -f "$tmpfile"
            log "Prebuilt installed: $asset_name"
            return 0
        else
            log_warn "Prebuilt install failed (vermagic mismatch or corrupt package)"
            rm -f "$tmpfile"
            return 1
        fi
    else
        log "Prebuilt not available for $kernel — using DKMS"
        rm -f "$tmpfile" "$tmpsha"
        return 1
    fi
}

# H0 (AWG 3.0, 31 jul 2026): on kernels < 6.7 the current PPA module is AmneziaWG
# 3.0, which does not build (nla_put_uint only appeared in kernel 6.7). We install
# the last pinned 2.0 module (the 1.0.x line) from source via DKMS:
#   1. git clone the pinned tag --depth=1;
#   2. VERIFY the commit against AWG2_PIN_COMMIT (integrity: an immutable commit is
#      more robust than the GitHub auto-tarball SHA, which changes on recompression);
#   3. the upstream `make dkms-install` mechanism (lays it into /usr/src/amneziawg-1.0.0);
#   4. dkms add/build/install for the current kernel;
#   5. a modprobe check (built != loadable: Secure Boot may block it).
# The source dkms.conf carries AUTOINSTALL=yes, so our amneziawg-ensure-module helper
# (apt hook + systemd) rebuilds the pinned module on a kernel upgrade by itself - no
# separate maintenance code is needed. Returns: 0 success, 1 failure (logged to ERROR).
_install_pinned_awg2_module() {
    local repo="https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git"
    local kver work got_commit
    local dkms_ver="1.0.0"   # WIREGUARD_VERSION in the upstream Makefile (name of /usr/src/amneziawg-<ver>)
    kver="$(uname -r)"

    if ! command -v git >/dev/null 2>&1; then
        log_error "git is not installed - cannot fetch the pinned module source."
        return 1
    fi

    work="$(mktemp -d /tmp/awg2-pin-XXXXXX)" || { log_error "mktemp -d failed."; return 1; }

    log "Cloning the pinned AmneziaWG 2.0 source ($AWG2_PIN_TAG)..."
    if ! git clone --depth=1 --branch "$AWG2_PIN_TAG" "$repo" "$work/src" >/dev/null 2>&1; then
        log_error "Failed to clone $repo (tag $AWG2_PIN_TAG). Check access to github.com."
        rm -rf "$work"; return 1
    fi

    got_commit="$(git -C "$work/src" rev-parse HEAD 2>/dev/null || echo "")"
    if [[ "$got_commit" != "$AWG2_PIN_COMMIT" ]]; then
        log_error "Pin check failed: tag $AWG2_PIN_TAG -> commit '${got_commit:-<empty>}',"
        log_error "expected $AWG2_PIN_COMMIT. Refusing (the tag may have been moved/tampered with)."
        rm -rf "$work"; return 1
    fi
    log "Pinned commit confirmed: $got_commit"

    # Lay out the DKMS source via the upstream mechanism (the Makefile is in src/).
    # Save make output to a log: otherwise the real cause of a failure (environment /
    # coreutils) is invisible - unlike the dkms build path, no make.log is created here.
    local _mklog="/var/log/amneziawg-pin-dkms-install.log"
    if ! make -C "$work/src/src" dkms-install PREFIX=/usr >"$_mklog" 2>&1; then
        log_error "make dkms-install failed. Details: $_mklog"
        rm -rf "$work"; return 1
    fi
    rm -rf "$work"

    if [[ ! -f "/usr/src/amneziawg-${dkms_ver}/dkms.conf" ]]; then
        log_error "/usr/src/amneziawg-${dkms_ver}/dkms.conf did not appear after dkms-install."
        return 1
    fi

    # add is idempotent: on a re-run it is already added -> not fatal.
    dkms add -m amneziawg -v "$dkms_ver" >/dev/null 2>&1 || true
    # Idempotency (the installer is a resumable state machine): dkms build errors
    # with "already built" for a kernel already done -> build ONLY if there is no
    # build for this kernel yet. install --force below is idempotent by itself.
    if dkms status -m amneziawg -v "$dkms_ver" -k "$kver" 2>/dev/null | grep -qE ': (built|installed)'; then
        log "The pinned 2.0 module is already built for kernel $kver - skipping dkms build."
    else
        log "Building the pinned 2.0 module via DKMS (kernel $kver)..."
        if ! dkms build -m amneziawg -v "$dkms_ver" -k "$kver" >/dev/null 2>&1; then
            log_error "DKMS build of the pinned 2.0 module failed. See /var/lib/dkms/amneziawg/${dkms_ver}/${kver}/*/log/make.log"
            return 1
        fi
    fi
    if ! dkms install -m amneziawg -v "$dkms_ver" -k "$kver" --force >/dev/null 2>&1; then
        log_error "DKMS install of the pinned 2.0 module failed."
        return 1
    fi

    # Built != loadable: with Secure Boot enabled an unsigned module will not load.
    if ! modprobe amneziawg 2>/dev/null; then
        log_error "The module was built but modprobe amneziawg did not load it."
        log_error "The likely cause is Secure Boot: an unsigned DKMS module is blocked."
        log_error "Disable Secure Boot in the VPS BIOS/UEFI or enroll a MOK key."
        return 1
    fi
    log "The pinned AmneziaWG 2.0 module is built and loaded (DKMS $dkms_ver, kernel $kver)."
    return 0
}

# ==============================================================================
# STEP 2: Installing AmneziaWG and dependencies
# ==============================================================================

step2_install_amnezia() {
    update_state 2

    # Guard: make sure the user actually rebooted before step 2.
    # If boot_id matches the one saved in request_reboot 2 — the reboot
    # did not happen (e.g. user re-ran the script by mistake). Step 1's
    # apt full-upgrade staged a new kernel on disk, but the running
    # kernel is still the old one → DKMS would build the module against
    # the old kernel and modprobe would fail after the next reboot.
    local boot_id_file="$AWG_DIR/.boot_id_before_step2"
    if [[ -f "$boot_id_file" ]] && [[ -r /proc/sys/kernel/random/boot_id ]]; then
        local saved_boot_id current_boot_id
        saved_boot_id=$(< "$boot_id_file")
        current_boot_id=$(< /proc/sys/kernel/random/boot_id)
        if [[ -n "$saved_boot_id" ]] && [[ "$saved_boot_id" == "$current_boot_id" ]]; then
            die "Reboot expected before step 2 (kernel upgrade is only activated after reboot). Run: sudo reboot — then re-run the script."
        fi
        log "Reboot confirmed (boot_id changed) — continuing with step 2"
        rm -f "$boot_id_file" 2>/dev/null || true
    fi

    log "### STEP 2: Installing AmneziaWG and dependencies ###"
    _APT_UPDATED=0  # Reset: new sources will be added in this step

    # --ppa-amnezia-tolerant is REQUIRED already here: if a PPA file with a
    # broken suite is left on disk (404 Release; e.g. questing from an older
    # version or after an in-place upgrade), a strict update died BEFORE the
    # repair blocks below ever ran, so the repair never fired (live repro on
    # Debian 12, v5.16.0 cycle). Base repository errors remain fail-closed;
    # PPA errors are handled by the repair + post-PPA update +
    # apt_wait_for_ppa_package below.
    apt_update_tolerant --ppa-amnezia-tolerant || die "apt update error."

    # PPA Amnezia (without software-properties-common)
    log "Adding Amnezia PPA..."

    # Determine codename for PPA
    # On Debian, map to nearest Ubuntu codename since PPA is Launchpad (Ubuntu)
    # Debian 12 (bookworm) → focal, Debian 13 (trixie) → noble
    local codename ppa_codename
    codename="${OS_CODENAME:-$(lsb_release -sc 2>/dev/null || echo "noble")}"
    case "${OS_ID:-ubuntu}" in
        debian)
            case "$codename" in
                bookworm) ppa_codename="focal" ;;
                trixie)   ppa_codename="noble" ;;
                *)        ppa_codename="noble" ;;
            esac
            log "Debian ($codename) → PPA codename: $ppa_codename"
            ;;
        *)
            ppa_codename="$codename"
            # For Ubuntu non-LTS (questing/plucky/oracular/...) Amnezia PPA does
            # not publish packages — dists/<codename>/Release returns 404.
            # Pre-check via HEAD and fall back to noble (LTS): the noble build
            # gets DKMS-compiled against the running kernel.
            # Upstream: amnezia-vpn/amneziawg-linux-kernel-module#118
            case "$ppa_codename" in
                noble|jammy|focal)
                    # Known LTS — skip pre-check (PPA is reliably published)
                    ;;
                *)
                    log "Checking Amnezia PPA availability for Ubuntu '${ppa_codename}'..."
                    if ! curl -fsI --max-time 15 --retry 2 --retry-delay 5 \
                        "https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu/dists/${ppa_codename}/Release" \
                        >/dev/null 2>&1; then
                        log_warn "Amnezia PPA does not publish packages for Ubuntu '${ppa_codename}' (HTTP 404 or host unreachable)."
                        log_warn "Falling back to 'noble' — DKMS will build the module against the running kernel."
                        log_warn "Context: https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/issues/118"
                        ppa_codename="noble"
                    else
                        log "Amnezia PPA is available for '${ppa_codename}'."
                    fi
                    ;;
            esac
            ;;
    esac

    local keyring_dir="/etc/apt/keyrings"
    local keyring_file="${keyring_dir}/amnezia-ppa.gpg"
    local ppa_sources="/etc/apt/sources.list.d/amnezia-ppa.sources"
    local ppa_list="/etc/apt/sources.list.d/amnezia-ppa.list"
    # Check for legacy files (from add-apt-repository of previous versions)
    local legacy_list="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-${codename}.list"
    local legacy_sources="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-${codename}.sources"
    # Re-run on a server where a previous run (≤ v5.12.1) wrote a broken
    # .sources file with Suites=questing/plucky/etc.: if the existing suite
    # doesn't match the target ppa_codename, remove the file so it gets
    # recreated below with the correct suite. Same check for legacy
    # .sources (add-apt-repository format).
    # If the file exists but `Suites:` can't be parsed — treat as corrupt
    # and recreate, otherwise the broken file would slip through as
    # "PPA already added".
    local existing_suite=""
    if [[ -f "$ppa_sources" ]]; then
        existing_suite=$(awk '/^Suites:/{print $2; exit}' "$ppa_sources" 2>/dev/null)
    fi
    if [[ -f "$ppa_sources" && ( -z "$existing_suite" || "$existing_suite" != "$ppa_codename" ) ]]; then
        if [[ -z "$existing_suite" ]]; then
            log_warn "$ppa_sources exists but no Suites: line found — recreating."
        else
            log_warn "Existing PPA suite='${existing_suite}', target='${ppa_codename}' — recreating $ppa_sources."
        fi
        rm -f "$ppa_sources" "$ppa_list"
    fi
    local legacy_suite=""
    if [[ -f "$legacy_sources" ]]; then
        legacy_suite=$(awk '/^Suites:/{print $2; exit}' "$legacy_sources" 2>/dev/null)
    fi
    if [[ -f "$legacy_sources" && ( -z "$legacy_suite" || "$legacy_suite" != "$ppa_codename" ) ]]; then
        log_warn "Legacy PPA $legacy_sources (suite='${legacy_suite:-<empty>}') does not match target '${ppa_codename}' — removing."
        rm -f "$legacy_sources" "$legacy_list"
    fi
    # Same repair for the traditional .list (Debian 12): the suite is the token
    # after the URL in a 'deb [opts] URL <suite> main' line. Without this check
    # a file with an old/foreign suite (e.g. after an in-place upgrade
    # bookworm->trixie) would slip through below as "PPA already added" and apt
    # would keep pulling the wrong suite.
    local list_suite=""
    if [[ -f "$ppa_list" ]]; then
        list_suite=$(awk '/^deb([[:space:]]|$)/ {
            for (i = 2; i <= NF; i++) {
                if ($i ~ /^https?:/) { print $(i+1); exit }
            }
        }' "$ppa_list" 2>/dev/null)
        if [[ -z "$list_suite" || "$list_suite" != "$ppa_codename" ]]; then
            log_warn "Existing $ppa_list (suite='${list_suite:-<empty>}') does not match target '${ppa_codename}' - recreating."
            rm -f "$ppa_list"
        fi
    fi
    if [[ -f "$legacy_list" ]] || [[ -f "$legacy_sources" ]]; then
        log "PPA already added (legacy format)."
    elif [[ -f "$ppa_sources" ]] || [[ -f "$ppa_list" ]]; then
        log "PPA already added."
    else
        mkdir -p "$keyring_dir"
        log "Importing Amnezia PPA GPG key..."
        # Atomic: pipe into temp, then mv — a half-written keyring never
        # lives on the target path, even if curl/gpg die mid-way.
        local _kf_tmp
        _kf_tmp=$(mktemp -p "$keyring_dir" ".amnezia-ppa.gpg.tmp.XXXXXX") \
            || die "Failed to create temp file for GPG key."
        # --batch --no-tty --yes: gpg must not open /dev/tty (non-interactive
        # SSH, cloud-init, Ansible, etc.) and must not abort with "File exists"
        # when overwriting the mktemp-created tmp file. Without --yes gpg in
        # batch mode refuses to write into the pre-existing empty tmp file.
        # Request by the FULL 40-character fingerprint, not the short ID:
        # short 32-bit IDs have preimage collisions (evil32), and
        # keyserver.ubuntu.com accepts uploads of arbitrary keys. A swapped
        # key would not give RCE (package signatures would not match), but it
        # would break the install with a cryptic apt error.
        local _ppa_key_fpr="75C9DD72C799870E310542E24166F2C257290828"
        if ! curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${_ppa_key_fpr}" \
             | gpg --batch --no-tty --yes --dearmor -o "$_kf_tmp"; then
            rm -f "$_kf_tmp" 2>/dev/null
            die "Amnezia PPA GPG key import error."
        fi
        # Verify the downloaded key fingerprint against the expected one (pin).
        local _got_fpr
        _got_fpr=$(gpg --batch --no-tty --show-keys --with-colons "$_kf_tmp" 2>/dev/null \
            | awk -F: '/^fpr:/{print $10; exit}')
        if [[ "$_got_fpr" != "$_ppa_key_fpr" ]]; then
            rm -f "$_kf_tmp" 2>/dev/null
            die "Amnezia PPA GPG key failed the fingerprint check (got: '${_got_fpr:-<empty>}')."
        fi
        chmod 644 "$_kf_tmp" || { rm -f "$_kf_tmp" 2>/dev/null; die "chmod GPG key error."; }
        mv -f "$_kf_tmp" "$keyring_file" \
            || { rm -f "$_kf_tmp" 2>/dev/null; die "Failed to move GPG key to target path."; }

        # Debian 12 uses traditional .list format, Debian 13+ and Ubuntu 24.04+ use DEB822 .sources
        if [[ "${OS_ID:-ubuntu}" == "debian" && "${OS_VERSION}" == "12" ]]; then
            log "Debian 12: using traditional .list format"
            echo "deb [signed-by=${keyring_file}] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu ${ppa_codename} main" \
                > "$ppa_list" || die "Failed to create $ppa_list"
            chmod 644 "$ppa_list"
        else
            cat > "$ppa_sources" <<PPASRC || die "PPA sources creation error."
Types: deb
URIs: https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu
Suites: ${ppa_codename}
Components: main
Signed-By: ${keyring_file}
PPASRC
            chmod 644 "$ppa_sources"
        fi
        log "PPA added."
    fi
    # apt-get update + error classification:
    #   - Errors only on the Amnezia PPA → continue, apt_wait_for_ppa_package
    #     below will retry (issue #68: ppa.launchpadcontent.net briefly down).
    #   - Any other non-source error (DNS / GPG mismatch / dpkg lock on the
    #     base mirror) → fail fast. Continuing on a stale apt-cache is unsafe —
    #     the next apt-get install would fail with a less actionable error
    #     (PR #69 review finding).
    if ! apt_update_tolerant --ppa-amnezia-tolerant; then
        log_error "apt-get update failed with a hard error — not a PPA outage (issue #68)."
        log_error "Check: DNS, access to archive.ubuntu.com / deb.debian.org,"
        log_error "integrity of keys in /etc/apt/keyrings, dpkg lock contention."
        die "apt update returned an error (rc!=0, not the Amnezia PPA)."
    fi
    # PPA added, cache refreshed: sources do not change further in step 2, so
    # install_packages must not repeat apt update (on slow mirrors every run
    # is 10-60 seconds).
    _APT_UPDATED=1
    # apt-get update is tolerant to an unreachable InRelease (rc=0 even when
    # the PPA is down). So we check that amneziawg-dkms actually appears in
    # apt-cache, with three attempts and 30s/60s backoff (~1.5 min total).
    # A brief ppa.launchpadcontent.net outage (issue #68) must not break
    # the install.
    if ! apt_wait_for_ppa_package amneziawg-dkms 3 30; then
        log_error "Package amneziawg-dkms did not appear in apt-cache after 3 attempts."
        log_error "ppa.launchpadcontent.net appears to be down — this is a"
        log_error "Launchpad infrastructure outage, not a script bug."
        log_error "Wait 10–15 minutes and re-run the script with the same args."
        log_error "Details: https://github.com/bivlked/amneziawg-installer/issues/68"
        die "Amnezia PPA is temporarily unavailable."
    fi

    # AmneziaWG + qrencode packages (NO Python!)
    log "Installing AmneziaWG packages..."

    # H0 (AWG 3.0, 31 jul 2026): decide the pinned 2.0 module path BEFORE installing
    # any package - the hold must be in place before even the ARM prebuilt path, where
    # install_packages installs amneziawg-tools whose Recommends would otherwise pull
    # the incompatible 3.0 module. On kernels < 6.7 the PPA module is AmneziaWG 3.0
    # (does not build: nla_put_uint), so we do not install it and build the pinned 2.0
    # from source instead; only tools come from the PPA (version-aware, 2.0-compatible).
    local use_pinned_awg2=0
    if ! _kernel_supports_awg3; then
        use_pinned_awg2=1
        log "Kernel $(uname -r) is older than 6.7 - the PPA module (AmneziaWG 3.0) will not build here."
        log "Activated the pinned AmneziaWG 2.0 module path from source ($AWG2_PIN_TAG)."
        # Re-entry: if a prior run / the stock installer already installed (or left
        # half-configured) the 3.0 package - remove it and its source, otherwise its
        # failing postinst and /usr/src/amneziawg-* ownership conflict with the build.
        if dpkg -l amneziawg-dkms 2>/dev/null | grep -qE '^(ii|iU|iF|iH|rc)'; then
            log "Found a previously installed amneziawg-dkms (AmneziaWG 3.0) - removing it before the pinned build."
            DEBIAN_FRONTEND=noninteractive apt-get purge -y amneziawg-dkms amneziawg >/dev/null 2>&1 \
                || dpkg --purge --force-all amneziawg-dkms amneziawg >/dev/null 2>&1 \
                || log_warn "Could not fully remove the previously installed amneziawg-dkms - the install below may fail."
            command -v dkms >/dev/null 2>&1 && dkms remove -m amneziawg -v 1.0.0 --all >/dev/null 2>&1 || true
            rm -rf /var/lib/dkms/amneziawg* /usr/src/amneziawg-* 2>/dev/null || true
        fi
        # ⚠️ Hold BEFORE any install: amneziawg-tools RECOMMENDS amneziawg-dkms, apt
        # installs recommends by default -> without a hold, installing tools (incl. on
        # the ARM path) would pull the 3.0 dkms and fail on its build. This is a safety
        # mechanism, so its failure is fatal (we verify the hold actually took effect).
        apt-mark hold amneziawg-dkms amneziawg >/dev/null 2>&1 || true
        # We verify amneziawg-dkms specifically - it is the load-bearing package: it
        # is what amneziawg-tools Recommends and what carries the 3.0 module. The
        # metapackage amneziawg need not be held (its Depends: amneziawg-dkms is held
        # anyway), so we do not verify it separately.
        if ! apt-mark showhold 2>/dev/null | grep -qx "amneziawg-dkms"; then
            die "Failed to hold amneziawg-dkms. Without it, installing amneziawg-tools would pull the incompatible AmneziaWG 3.0 module. Aborted (check for an apt/dpkg lock)."
        fi
    else
        # Kernel >= 6.7: the normal path installs amneziawg-dkms from the PPA. Clear a
        # possible hold left by an earlier pinned run (else apt install -y aborts on hold).
        apt-mark unhold amneziawg-dkms amneziawg >/dev/null 2>&1 || true
    fi

    # On ARM: try prebuilt .deb first (no build tools or headers required).
    # Falls back to DKMS if no matching prebuilt is available or download fails.
    # ⚠️ On a kernel < 6.7 (use_pinned_awg2=1) using the prebuilt .deb is SAFE: our ARM
    # prebuilts are built from scripts/arm-module-version.txt, pinned to the same 2.0
    # tag (v1.0.20260725) and locked by a test, so it is a KNOWN 2.0 module, not 3.0.
    # And 3.0 physically cannot compile for a kernel < 6.7, so a 3.0 asset for such a
    # target (e.g. debian-bookworm-arm64) cannot exist in the release - on no match
    # _try_install_prebuilt_arm returns 1 and we fall through to the verified source
    # build below. The hold set above also applies here (keeps tools from pulling the
    # 3.0 dkms via Recommends).
    local arch
    arch="$(uname -m)"
    if [[ "$arch" == "aarch64" || "$arch" == "armv7l" ]]; then
        if _try_install_prebuilt_arm; then
            log "Prebuilt kernel module installed. Installing userspace tools from PPA..."
            install_packages "amneziawg-tools" "wireguard-tools" "qrencode"
            log "Step 2 completed (prebuilt ARM)."
            # request_reboot always terminates the process (exit), we never return here.
            request_reboot 3
        fi
        log "No matching prebuilt — falling back to DKMS build."
    fi

    # Packages: on the pinned path (kernel < 6.7) we do NOT install amneziawg-dkms
    # (it would be the 3.0 module); git is added instead to build the pinned 2.0
    # source. The gate, hold and cleanup of a previously installed 3.0 were done
    # above (before the ARM block).
    local packages
    if [[ "$use_pinned_awg2" -eq 1 ]]; then
        packages=("amneziawg-tools" "wireguard-tools" "dkms"
                  "build-essential" "dpkg-dev" "git" "qrencode")
    else
        packages=("amneziawg-dkms" "amneziawg-tools" "wireguard-tools" "dkms"
                  "build-essential" "dpkg-dev" "qrencode")
    fi

    # Linux headers: on Debian, exact linux-headers-$(uname -r) may not be available
    local current_headers
    current_headers="linux-headers-$(uname -r)"
    if dpkg -s "$current_headers" &>/dev/null || apt-cache show "$current_headers" &>/dev/null 2>&1; then
        packages+=("$current_headers")
    else
        log_warn "No headers for $(uname -r), installing generic package..."
        local kernel_release
        kernel_release="$(uname -r)"
        if [[ "$kernel_release" == *+rpt* || "$kernel_release" == *-rpi* ]]; then
            # Raspberry Pi Foundation kernel (+rpt suffix) — use RPi meta-package
            # linux-headers-rpi-2712: Pi 5 / Cortex-A76; linux-headers-rpi-v8: Pi 3/4 arm64
            local rpi_headers
            if [[ "$kernel_release" == *2712* ]]; then
                rpi_headers="linux-headers-rpi-2712"
            else
                rpi_headers="linux-headers-rpi-v8"
            fi
            log "Raspberry Pi kernel detected, using $rpi_headers"
            packages+=("$rpi_headers")
        elif [[ "${OS_ID:-ubuntu}" == "debian" ]]; then
            # On Debian: linux-headers-$(dpkg --print-architecture)
            local arch_pkg
            arch_pkg="linux-headers-$(dpkg --print-architecture 2>/dev/null || echo "amd64")"
            packages+=("$arch_pkg")
        else
            packages+=("linux-headers-generic")
        fi
    fi
    # v5.13.0: on 25.10/26.04 after an in-place upgrade from 24.04, the
    # system may still carry kernel headers from 24.04 (6.8.x) compiled with
    # gcc-13. 25.10 ships gcc-15 by default → dkms autoinstall in the
    # amneziawg-dkms postinst fails when building against stale kernels, and
    # dpkg leaves amneziawg* unconfigured. If we detect kernel headers other
    # than the running one, install gcc-13 ahead of time (available in
    # questing/universe and 26.04 archive) so autoinstall succeeds for every
    # kernel.
    local _running_kernel _has_stale=0 _hd _hd_kern
    _running_kernel="$(uname -r)"
    for _hd in /lib/modules/*/build; do
        [[ -e "$_hd" ]] || continue
        _hd_kern="${_hd#/lib/modules/}"
        _hd_kern="${_hd_kern%/build}"
        if [[ "$_hd_kern" != "$_running_kernel" ]]; then
            _has_stale=1
            break
        fi
    done
    if [[ "$_has_stale" -eq 1 ]] && ! command -v gcc-13 >/dev/null 2>&1; then
        if apt-cache madison gcc-13 2>/dev/null | grep -q .; then
            log "Stale kernel headers detected (other than $_running_kernel) — installing gcc-13 for DKMS autoinstall compatibility."
            DEBIAN_FRONTEND=noninteractive apt install -y gcc-13 \
                || log_warn "gcc-13 install failed — DKMS autoinstall may fail on stale kernels."
        else
            log_warn "Stale kernel headers detected, but gcc-13 is not in the repo — DKMS autoinstall may fail."
        fi
    fi
    install_packages "${packages[@]}"

    # H0: pinned path - build the 2.0 module from source INSTEAD of PPA amneziawg-dkms.
    # Headers for the current kernel are already installed above (in packages); the
    # hold was set earlier.
    if [[ "$use_pinned_awg2" -eq 1 ]]; then
        if ! _install_pinned_awg2_module; then
            log_error "Failed to install the pinned AmneziaWG 2.0 module."
            log_error "Kernel $(uname -r) is older than 6.7, and the current PPA module is"
            log_error "AmneziaWG 3.0, which does not build on this kernel. Options: upgrade the"
            log_error "kernel to 6.7+ (on Debian 12 via bookworm-backports) or reinstall the VPS"
            log_error "on Ubuntu 24.04/25.10 or Debian 13. See README/INSTALL_VPS for details."
            die "The pinned AmneziaWG 2.0 module was not installed."
        fi
        log "The pinned AmneziaWG 2.0 module is installed; PPA dkms is held (3.0 protection)."
    fi

    # v5.12.0: install a kernel-headers meta-package so apt automatically
    # pulls matching headers on every kernel upgrade. Without the meta only
    # linux-headers-$(uname -r) is installed, which does not track new
    # kernels and the DKMS module fails to rebuild on the next apt upgrade.
    #
    # Detect kernel flavor (Ubuntu cloud images: aws/azure/gcp/oracle/kvm/
    # lowlatency/raspi; Debian cloud-amd64) — a plain linux-headers-generic
    # on an Azure VM does not track the right kernel pipeline. Take the
    # uname -r suffix, try the flavor-specific meta first, fall back to
    # generic / arch.
    local arch_meta kernel_rel
    arch_meta="$(dpkg --print-architecture 2>/dev/null || echo '')"
    kernel_rel="$(uname -r)"
    local -a meta_candidates=()
    if [[ "$kernel_rel" == *+rpt* || "$kernel_rel" == *-rpi* ]]; then
        : # RPi: linux-headers-rpi-{2712,v8} meta is already in packages above.
    elif [[ "${OS_ID:-ubuntu}" == "ubuntu" ]]; then
        # Ubuntu uname -r format: 6.8.0-49-generic / 6.8.0-1009-aws / ...
        local flavor="${kernel_rel##*-}"
        if [[ -n "$flavor" && "$flavor" != "$kernel_rel" ]]; then
            meta_candidates+=("linux-headers-${flavor}")
        fi
        meta_candidates+=("linux-headers-generic")
    elif [[ "${OS_ID:-}" == "debian" && -n "$arch_meta" ]]; then
        # Debian: stock kernel 6.12.85+deb13-amd64, cloud — 6.12.85+deb13-cloud-amd64.
        [[ "$kernel_rel" == *-cloud-* ]] \
            && meta_candidates+=("linux-headers-cloud-${arch_meta}")
        meta_candidates+=("linux-headers-${arch_meta}")
    fi
    local meta meta_installed=0
    for meta in "${meta_candidates[@]}"; do
        if dpkg-query -W -f='${Status}' "$meta" 2>/dev/null \
                | grep -q 'install ok installed'; then
            log "$meta is already installed (auto-tracking kernel upgrades)."
            meta_installed=1
            break
        fi
        log "Installing meta-package $meta..."
        if DEBIAN_FRONTEND=noninteractive apt install -y "$meta" 2>/dev/null; then
            log "$meta installed."
            meta_installed=1
            break
        fi
        log_warn "Failed to install $meta — trying next candidate."
    done
    if [[ ${#meta_candidates[@]} -gt 0 && $meta_installed -eq 0 ]]; then
        log_warn "No kernel-headers meta-package installed — auto-rebuild on kernel upgrade may not work."
    fi

    # v5.12.0: deploy the standalone helper /usr/local/sbin/amneziawg-ensure-module.
    # It is invoked from the apt hook (DPkg::Post-Invoke) and from the Phase 4
    # systemd unit. The helper is self-contained — it does NOT source anything
    # from the data directory, so it keeps working even if that directory moves.
    #
    # Deploy uses a staging file in the SAME filesystem as the destination
    # plus a final `mv -f` — guaranteeing atomic replacement (a cross-FS
    # rename is copy+remove, NOT atomic). The staging file starts with a
    # dot so apt and logrotate skip dotfiles when scanning the directory.
    log "Deploying DKMS auto-repair helper..."
    mkdir -p /usr/local/sbin
    local _stage_helper=/usr/local/sbin/.amneziawg-ensure-module.new
    cat > "$_stage_helper" <<'AWG_ENSURE_HELPER_EOF'
#!/bin/bash
# amneziawg-ensure-module — rebuilds the AmneziaWG DKMS module after a
# kernel upgrade.
#
# Generated by install_amneziawg.sh (v5.12.0+). Do not edit; re-run the
# installer to refresh.
#
# Modes:
#   --hook     — invoked from /etc/apt/apt.conf.d/99-amneziawg-post-kernel
#                (DPkg::Post-Invoke). Constraints:
#                  - MUST NOT call apt-get install: the parent apt still
#                    holds /var/lib/dpkg/lock-frontend, a nested install
#                    would deadlock.
#                  - Skips modprobe and systemctl: the running kernel may
#                    still be the old one. The newly-built module is
#                    loaded after reboot via the systemd unit, or via
#                    `manage repair-module`.
#                Stamp-file fast-path keeps routine apt ops noise-free.
#
#   --systemd  — invoked from amneziawg-ensure-module.service at boot,
#                ordered Before=awg-quick@awg0.service. Builds for every
#                target kernel (same as --hook), then loads the module
#                via modprobe so awg-quick can start. No stamp fast-path
#                — boot must always verify load state, even if /lib/modules
#                hasn't changed since the last build (module not loaded
#                across reboots). Exit 1 if modprobe fails so systemd
#                marks the unit as failed (visible via systemctl status).
#
# Iteration target: every kernel that exposes /lib/modules/<ver>/build
# (= a directory with installed headers). uname -r alone is insufficient
# in apt-hook context because it returns the OLD running kernel while
# the new kernel's headers are already on disk.
#
# Output: stdout / stderr; --hook appends to
# /var/log/amneziawg-ensure-module.log (rotated weekly via
# /etc/logrotate.d/amneziawg-ensure-module). --systemd writes to journal
# (StandardOutput=journal, StandardError=journal in the unit file).

set -euo pipefail

MODE="${1:-}"
case "$MODE" in
    --hook|--systemd) ;;
    --help|-h) echo "Usage: $0 --hook | --systemd"; exit 0 ;;
    *) echo "amneziawg-ensure-module: missing or unknown mode (use --hook or --systemd)" >&2; exit 2 ;;
esac

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_line() { printf '[%s] [%s] %s\n' "$(ts)" "$MODE" "$*"; }

if [[ $(id -u) -ne 0 ]]; then
    log_line "ERROR: root privileges required" >&2
    exit 1
fi

if ! command -v dkms >/dev/null 2>&1; then
    log_line "WARN: dkms is not installed — nothing to do"
    exit 0
fi

declare -a target_kernels=()
shopt -s nullglob
for build_dir in /lib/modules/*/build; do
    [[ -d "$build_dir" || -L "$build_dir" ]] || continue
    target_kernels+=("$(basename "$(dirname "$build_dir")")")
done
shopt -u nullglob

if [[ ${#target_kernels[@]} -eq 0 ]]; then
    log_line "WARN: no /lib/modules/*/build directories — kernel headers missing"
    exit 0
fi

# Build per-run state signature (mtime + kver) used by both modes:
#   --hook     — for stamp-file fast-path comparison (silent exit if equal)
#   --systemd  — recorded after success so subsequent --hook calls can skip
STAMP_DIR=/var/lib/amneziawg
STAMP_FILE="${STAMP_DIR}/ensure-module.stamp"
current_state=""
for kver in "${target_kernels[@]}"; do
    # stat may fail (build dir removed in flight) — guard against set -e abort.
    # Empty mtime → comparison differs → we re-run dkms autoinstall (acceptable).
    mtime="$(stat -c '%Y' "/lib/modules/${kver}/build" 2>/dev/null || true)"
    current_state+="${mtime} ${kver} "
done

# Fast-path applies ONLY to --hook. Boot (--systemd) must always run the
# full path — module is not loaded across reboots even when /lib/modules
# state is unchanged.
if [[ "$MODE" == "--hook" ]] \
        && [[ -f "$STAMP_FILE" && "$(cat "$STAMP_FILE" 2>/dev/null)" == "$current_state" ]]; then
    # Silent exit — routine apt ops don't add log noise.
    exit 0
fi

# Strip the deprecated REMAKE_INITRD directive (triggers noisy warnings
# on modern DKMS releases).
for cfg in /var/lib/dkms/amneziawg/*/source/dkms.conf; do
    [[ -f "$cfg" ]] && sed -i '/^REMAKE_INITRD=/d' "$cfg" 2>/dev/null || true
done

build_rc=0
for kver in "${target_kernels[@]}"; do
    log_line "dkms autoinstall -k $kver"
    if ! dkms autoinstall -k "$kver"; then
        log_line "WARN: dkms autoinstall failed for kernel $kver" >&2
        build_rc=1
    fi
done

depmod -a 2>/dev/null || true

# --systemd: load the module so awg-quick can start. Exit 1 on modprobe
# failure — systemd marks the unit failed; visible via `systemctl status
# amneziawg-ensure-module.service`. awg-quick still starts (Before= is
# ordering only, not a dependency) and surfaces its own error if the
# module is unavailable.
if [[ "$MODE" == "--systemd" ]]; then
    log_line "modprobe amneziawg"
    if ! modprobe amneziawg 2>&1; then
        log_line "ERROR: modprobe amneziawg failed for running kernel $(uname -r)" >&2
        log_line "  Check: /var/lib/dkms/amneziawg/<ver>/<kernel>/log/make.log" >&2
        exit 1
    fi
    if ! lsmod 2>/dev/null | grep -q '^amneziawg '; then
        log_line "ERROR: amneziawg module not present in lsmod after modprobe" >&2
        exit 1
    fi
    log_line "amneziawg module loaded for $(uname -r)"
    # Update stamp on --systemd success (current kernel is usable, what matters
    # for boot) even if some other kernel's build failed (build_rc=1).
    mkdir -p "$STAMP_DIR" 2>/dev/null || true
    printf '%s' "$current_state" > "$STAMP_FILE" 2>/dev/null || true
    log_line "done"
    exit 0
fi

# --hook: update stamp only on full success — partial failures retry next run.
if [[ $build_rc -eq 0 ]]; then
    mkdir -p "$STAMP_DIR" 2>/dev/null || true
    printf '%s' "$current_state" > "$STAMP_FILE" 2>/dev/null || true
fi

log_line "done (rc=$build_rc)"
exit "$build_rc"
AWG_ENSURE_HELPER_EOF
    chown root:root "$_stage_helper" 2>/dev/null || true
    chmod 0755 "$_stage_helper" \
        || { rm -f "$_stage_helper"; die "Failed to chmod helper."; }
    mv -f "$_stage_helper" /usr/local/sbin/amneziawg-ensure-module \
        || { rm -f "$_stage_helper"; die "Failed to deploy amneziawg-ensure-module helper."; }
    log "Helper /usr/local/sbin/amneziawg-ensure-module deployed."

    # v5.12.0: apt hook DPkg::Post-Invoke calls the helper after a kernel upgrade.
    mkdir -p /etc/apt/apt.conf.d
    local _stage_hook=/etc/apt/apt.conf.d/.99-amneziawg-post-kernel.new
    cat > "$_stage_hook" <<'AWG_APT_HOOK_EOF'
// amneziawg-installer (v5.12.0+): rebuild DKMS module after kernel upgrades.
// Generated by install_amneziawg.sh — do not edit; re-run the installer to refresh.
DPkg::Post-Invoke {"if [ -x /usr/local/sbin/amneziawg-ensure-module ]; then /usr/local/sbin/amneziawg-ensure-module --hook >>/var/log/amneziawg-ensure-module.log 2>&1 || true; fi";};
AWG_APT_HOOK_EOF
    chown root:root "$_stage_hook" 2>/dev/null || true
    chmod 0644 "$_stage_hook" \
        || { rm -f "$_stage_hook"; die "Failed to chmod apt hook."; }
    mv -f "$_stage_hook" /etc/apt/apt.conf.d/99-amneziawg-post-kernel \
        || { rm -f "$_stage_hook"; die "Failed to deploy apt hook."; }
    log "Apt hook 99-amneziawg-post-kernel installed (auto-rebuild on apt kernel upgrade)."

    # v5.12.0: logrotate config for /var/log/amneziawg-ensure-module.log
    mkdir -p /etc/logrotate.d
    local _stage_logrotate=/etc/logrotate.d/.amneziawg-ensure-module.new
    cat > "$_stage_logrotate" <<'AWG_LOGROTATE_EOF'
/var/log/amneziawg-ensure-module.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
AWG_LOGROTATE_EOF
    chown root:root "$_stage_logrotate" 2>/dev/null || true
    chmod 0644 "$_stage_logrotate" \
        || { rm -f "$_stage_logrotate"; die "Failed to chmod logrotate config."; }
    mv -f "$_stage_logrotate" /etc/logrotate.d/amneziawg-ensure-module \
        || { rm -f "$_stage_logrotate"; die "Failed to deploy logrotate config."; }
    log "Logrotate config /etc/logrotate.d/amneziawg-ensure-module installed (weekly, rotate 4)."

    # v5.12.0 Phase 4: systemd unit guarantees the kernel module is built
    # and loaded BEFORE awg-quick@awg0 starts on every boot. Type=oneshot +
    # RemainAfterExit=yes + Before=awg-quick@awg0.service — the standard
    # pre-load pattern (after a kernel upgrade DKMS may need to rebuild on
    # the very first boot of the new kernel).
    log "Deploying systemd unit amneziawg-ensure-module.service..."
    mkdir -p /etc/systemd/system
    local _stage_unit=/etc/systemd/system/.amneziawg-ensure-module.service.new
    cat > "$_stage_unit" <<'AWG_SYSTEMD_UNIT_EOF'
[Unit]
Description=Ensure amneziawg kernel module is built and loaded
Documentation=https://github.com/bivlked/amneziawg-installer
Before=awg-quick@awg0.service
After=systemd-modules-load.service local-fs.target
ConditionPathExists=/usr/local/sbin/amneziawg-ensure-module

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/amneziawg-ensure-module --systemd
TimeoutStartSec=300
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
AWG_SYSTEMD_UNIT_EOF
    chown root:root "$_stage_unit" 2>/dev/null || true
    chmod 0644 "$_stage_unit" \
        || { rm -f "$_stage_unit"; die "Failed to chmod systemd unit."; }
    mv -f "$_stage_unit" /etc/systemd/system/amneziawg-ensure-module.service \
        || { rm -f "$_stage_unit"; die "Failed to deploy systemd unit."; }
    if ! systemctl daemon-reload; then
        log_warn "systemctl daemon-reload failed — the unit may not activate until reboot."
    fi
    if ! systemctl enable amneziawg-ensure-module.service; then
        log_warn "Failed to enable amneziawg-ensure-module.service — boot-time auto-rebuild will not run."
    fi
    log "Systemd unit amneziawg-ensure-module.service installed and enabled (Before=awg-quick@awg0)."

    # DKMS status
    log "Checking DKMS status..."
    local dkms_stat
    dkms_stat=$(dkms status 2>&1)
    if ! echo "$dkms_stat" | grep -q 'amneziawg.*installed'; then
        log_warn "DKMS status not OK."
        log_msg "WARN" "$dkms_stat"
    else
        log "DKMS status OK."
    fi

    log "Step 2 completed."

    # Как и на первом шаге: апстрим перезагружался безусловно. Нам ребут нужен
    # только если модуль не удаётся загрузить прямо сейчас — тогда причина
    # обычно в том, что работающее ядро старше того, под которое собран
    # модуль. Если modprobe проходит, перезагружаться незачем: step3 всё
    # равно проверит модуль ещё раз.
    if modprobe amneziawg 2>/dev/null; then
        log "Модуль amneziawg загружен, перезагрузка не требуется."
        update_state 3
        return 0
    fi
    log_warn "модуль не загрузился сразу — требуется перезагрузка"
    request_reboot 3
}

# ==============================================================================
# STEP 3: Kernel module check
# ==============================================================================

step3_check_module() {
    update_state 3
    log "### STEP 3: Kernel module check ###"
    sleep 2

    if ! lsmod | grep -q -w amneziawg; then
        log "Module not loaded. Loading..."
        modprobe amneziawg || die "modprobe amneziawg error."
        log "Module loaded."
        local mf="/etc/modules-load.d/amneziawg.conf"
        mkdir -p "$(dirname "$mf")"
        if ! grep -qxF 'amneziawg' "$mf" 2>/dev/null; then
            echo "amneziawg" > "$mf" || log_warn "Write error $mf"
            log "Added to $mf."
        fi
    else
        log "amneziawg module loaded."
    fi

    log "Module information:"
    modinfo amneziawg | grep -E "filename|version|vermagic|srcversion" | while IFS= read -r line; do
        log "  $line"
    done

    local cv kr
    cv=$(modinfo amneziawg 2>/dev/null | awk '/^vermagic:/{print $2}')
    if [[ -z "$cv" ]]; then
        die "Failed to read amneziawg vermagic. Check: modprobe amneziawg && modinfo amneziawg"
    fi
    kr=$(uname -r)
    if [[ "$cv" != "$kr" ]]; then
        log_warn "VerMagic MISMATCH: Module($cv) != Kernel($kr)!"
    else
        log "VerMagic matches."
    fi

    # Check awg version
    if command -v awg &>/dev/null; then
        local awg_ver
        awg_ver=$(awg --version 2>/dev/null || echo "unknown")
        log "awg version: $awg_ver"
    else
        log_warn "awg command not found!"
    fi

    log "Step 3 completed."
    update_state 4
}

# ==============================================================================
# STEP 4: Firewall configuration
# ==============================================================================

step4_setup_firewall() {
    update_state 4
    if [[ "$NO_TWEAKS" -eq 0 ]]; then
        log "### STEP 4: UFW firewall configuration ###"
        install_packages ufw
        setup_improved_firewall || die "UFW configuration error."
        log "Step 4 completed."
    else
        log "### STEP 4: Skipping UFW configuration (--no-tweaks) ###"
    fi
    update_state 5
}

# ==============================================================================
# STEP 5: Downloading scripts (NO Python!)
# ==============================================================================




# ==============================================================================
# STEP 6: Config generation (native, without awgcfg.py)
# ==============================================================================


# ==============================================================================
# STEP 7: Service startup
# ==============================================================================

step7_start_service() {
    update_state 7
    log "### STEP 7: Service startup and security configuration ###"

    log "Enabling and starting awg-quick@awg0..."

    # Isolation switched on->off: the new config's PostDown no longer has the
    # DROP rule to remove, and the restart's down phase already runs against
    # the new on-disk config. Remove stale rules explicitly, in a loop - a
    # repeated interrupted run may have left more than one (issue #178,
    # same deferred-cleanup pattern as PREV_AWG_PORT in #175).
    if [[ "${CLIENT_ISOLATION:-1}" -eq 0 ]]; then
        while iptables -D FORWARD -i awg0 -o awg0 -j DROP 2>/dev/null; do :; done
        while ip6tables -D FORWARD -i awg0 -o awg0 -j DROP 2>/dev/null; do :; done
    fi

    if systemctl is-active --quiet awg-quick@awg0; then
        log "Service already active — restarting to apply configuration..."
        systemctl enable awg-quick@awg0 || log_warn "Failed to enable awg-quick@awg0 — check autostart manually"
        systemctl restart awg-quick@awg0 || die "restart awg-quick@awg0 error."
    else
        systemctl enable --now awg-quick@awg0 || die "enable --now error."
    fi
    log "Service enabled and started."

    log "Checking service status..."
    local _attempt
    for _attempt in 1 2 3 4 5; do
        sleep 1
        check_service_status 2>/dev/null && break
        [[ $_attempt -lt 5 ]] && log_debug "Waiting for service startup... (attempt $_attempt/5)"
    done
    check_service_status || die "Service status check failed."

    # Fail2Ban
    if [[ "$NO_TWEAKS" -eq 0 ]]; then
        setup_fail2ban
    else
        log "Skipping Fail2Ban (--no-tweaks)."
    fi

    log "Step 7 completed successfully."
    update_state 99
}

# ==============================================================================
# STEP 99: Completion
# ==============================================================================

step99_finish() {
    log "### УСТАНОВКА ЗАВЕРШЕНА ###"
    log "=============================================================================="
    log "AmneziaWG 3.0 развёрнут."
    log " "
    log "КЛИЕНТЫ:"
    log "  каждый живёт в своём каталоге ${AWG_DIR}/ИМЯ/ — conf, QR и пара ключей"
    log "  добавить:  sudo awg3 add ИМЯ"
    log "  забрать:   scp -r ПОЛЬЗОВАТЕЛЬ@<СЕРВЕР>:${AWG_DIR}/ИМЯ ./"
    log " "
    log "КОМАНДЫ:"
    log "  sudo awg3 list                        клиенты и состояние сервера"
    log "  sudo awg3 stats                       трафик по клиентам"
    log "  systemctl status awg-quick@awg0       состояние сервиса"
    log "  ufw status verbose                    состояние фаервола"
    log " "
    log "ВАЖНО: нужен клиент Amnezia VPN с поддержкой AWG 3.0."
    log " "
    cleanup_apt
    log " "

    if [[ -f "$SERVER_CONF_FILE" ]]; then
        log "Конфигурация сервера: $SERVER_CONF_FILE"
    else
        log_error "Конфигурация сервера ОТСУТСТВУЕТ: $SERVER_CONF_FILE"
    fi

    log "Удаление файла состояния установки..."
    rm -f "$STATE_FILE" "${STATE_FILE}.lock" "$AWG_DIR/.boot_id_before_step2" \
        || log_warn "Не удалён $STATE_FILE"
    log "Готово. Журнал: $LOG_FILE"
    log "=============================================================================="
}

# ==============================================================================
# Сценарии развёртывания
# ==============================================================================

MODE=""
SRV_PORT=""
SRV_SUBNET="10.9.9.1/24"
SRV_MTU="1280"
SRV_ISOLATION="off"
SRV_IPV6="off"
SRV_PROFILE="quic"
SRV_INTENSITY="medium"
SRV_ENDPOINT=""
CLIENTS=""
BOOTSTRAP_ARGS=()
# Пользователь, которого создаёт bootstrap.sh: после подготовки системы
# каталог данных переезжает в его домашний каталог, а не остаётся у того, кто
# запустил sudo.
BOOTSTRAP_USER=""

show_help() {
    cat <<EOF
install-awg3.sh ${SCRIPT_VERSION} — развёртывание AmneziaWG 3.0
(форк bivlked/amneziawg-installer ${UPSTREAM_VERSION})

ИСПОЛЬЗОВАНИЕ
    sudo ./install-awg3.sh [опции]

Без опций выводится меню сценариев.

СЦЕНАРИИ
    --mode full           подготовка системы + AmneziaWG 3.0
    --mode awg-only       только AmneziaWG 3.0, система уже подготовлена
    --mode upgrade        перевести существующий 2.0-сервер на 3.0
    --mode reinstall      пересоздать сервер, сохранив пиров
    --mode uninstall      снести AmneziaWG (то же, что --uninstall)

ПАРАМЕТРЫ СЕРВЕРА
    --awg-port N          UDP-порт                    (по умолч.: случайный)
    --subnet CIDR         подсеть туннеля             (по умолч.: ${SRV_SUBNET})
    --mtu N               MTU                         (по умолч.: ${SRV_MTU})
    --isolation on|off    изоляция клиентов           (по умолч.: ${SRV_ISOLATION})
    --ipv6 on|off         IPv6 в туннеле              (по умолч.: ${SRV_IPV6})
    --profile NAME        мимикрия: quic|tls|dtls|sip|dns|noise (по умолч.: ${SRV_PROFILE})
    --intensity LVL       low|medium|high             (по умолч.: ${SRV_INTENSITY})
    --endpoint HOST       имя хоста для клиентских Endpoint: DNS-имя или IP
                          (синоним: --host-name; по умолч.: внешний IP)
    --clients a,b,c       создать клиентов сразу      (по умолч.: ни одного)
    --awg-dir PATH        каталог данных   (по умолч.: ~/awg целевого пользователя)

ПОДГОТОВКА СИСТЕМЫ (только --mode full, прокидывается в bootstrap.sh)
    --user NAME           имя нового sudo-пользователя
    --password-file FILE  файл с паролем первой строкой
    --ssh-port N          новый порт SSH
    --disable-root-ssh yes|no
                          отключить вход root по SSH

ПРОЧЕЕ
    -y, --yes             не задавать вопросов
        --force           переустановка поверх работающей установки
        --no-tweaks       не трогать sysctl, swap и fail2ban
        --uninstall       удалить AmneziaWG
        --diagnostic      собрать диагностический отчёт
        --verbose         подробный вывод
        --no-color        без цвета
    -h, --help            эта справка

ПРИМЕЧАНИЯ
    Источник истины о состоянии сервера — только awg0.conf. Отдельного файла
    настроек нет: порт, подсеть, MTU, изоляция и IPv6 читаются из конфига.

    Профиль мимикрии и интенсивность — свойства ОТПРАВЛЯЮЩЕЙ стороны. Здесь
    они задают параметры самого сервера и умолчание для создаваемых клиентов;
    каждый следующий 'awg3 add -p tls' переопределяет их свободно.

    Пароль нельзя передать аргументом: аргументы видны в ps.
EOF
    exit "${HELP_EXIT_RC:-0}"
}

validate_mode() {
    case "${1:-}" in
        full|awg-only|upgrade|reinstall|uninstall) return 0 ;;
        *) log_error "неизвестный режим: '${1:-}'"; return 1 ;;
    esac
}

mode_from_choice() {
    case "${1:-}" in
        1) printf 'full' ;;
        2) printf 'awg-only' ;;
        3) printf 'upgrade' ;;
        4) printf 'reinstall' ;;
        5) printf 'uninstall' ;;
        *) return 1 ;;
    esac
}

show_menu() {
    cat <<'EOF'

Что делаем?

  1) Полное развёртывание с нуля     подготовка системы + AmneziaWG 3.0
  2) Только AmneziaWG 3.0            система уже подготовлена
  3) Перевести 2.0-сервер на 3.0     клиентов придётся создать заново
  4) Переустановить поверх           пиры сохраняются, параметры новые
  5) Удалить                         снести AmneziaWG

EOF
    local choice
    read -rp "Пункт [1-5]: " choice < /dev/tty
    MODE=$(mode_from_choice "$choice") || die "недопустимый пункт: $choice"
}

# Аргументы для awg3.sh server-init. Печатаются одной строкой и разбираются
# вызывающей стороной через словоделение — значения без пробелов по построению.
build_server_init_args() {
    local args="--awg-port ${SRV_PORT} --subnet ${SRV_SUBNET} --mtu ${SRV_MTU}"
    args="${args} --isolation ${SRV_ISOLATION} --ipv6 ${SRV_IPV6}"
    args="${args} -p ${SRV_PROFILE} -i ${SRV_INTENSITY}"
    if [[ -n "${SRV_ENDPOINT:-}" ]]; then
        args="${args} --endpoint ${SRV_ENDPOINT}"
    fi
    if [[ "${MODE:-}" == "reinstall" ]]; then
        args="${args} --force"
    fi
    printf '%s' "$args"
}

script_dir() {
    cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd
}

# awg3.sh кладётся рядом с данными и получает симлинк в PATH, чтобы работало
# `sudo awg3 list` из любого каталога.
install_awg3_script() {
    local src
    src="$(script_dir)/awg3.sh"
    [[ -f "$src" ]] || die "рядом со скриптом нет awg3.sh"

    install -m 700 "$src" "$AWG_DIR/awg3.sh" || die "не установлен awg3.sh"
    local owner
    if owner=$(stat -c '%u:%g' "$AWG_DIR" 2>/dev/null); then
        chown "$owner" "$AWG_DIR/awg3.sh" 2>/dev/null || true
    fi
    ln -sf "$AWG_DIR/awg3.sh" /usr/local/sbin/awg3
    log "awg3.sh установлен: $AWG_DIR/awg3.sh (симлинк /usr/local/sbin/awg3)"
}

run_server_init() {
    local args
    args=$(build_server_init_args)
    log "Создание сервера AWG 3.0: $args"
    # Сервис поднимет step7_start_service — там же и проверки состояния,
    # поэтому server-init работает с --no-apply.
    # shellcheck disable=SC2086
    AWG3_DIR="$AWG_DIR" "$AWG_DIR/awg3.sh" server-init $args --no-apply -y \
        || die "server-init не отработал"
}

create_initial_clients() {
    [[ -n "$CLIENTS" ]] || return 0
    local name
    for name in ${CLIENTS//,/ }; do
        log "Создание клиента '$name'..."
        AWG3_DIR="$AWG_DIR" "$AWG_DIR/awg3.sh" add "$name" \
            -p "$SRV_PROFILE" -i "$SRV_INTENSITY" -y \
            || log_warn "клиент '$name' не создан"
    done
}

# Опрос параметров сервера. С --yes ничего не спрашивается — берутся значения
# флагов и умолчаний.
ask_params() {
    [[ "$AUTO_YES" -eq 0 ]] || return 0
    [[ -t 0 ]] || return 0

    local answer

    if [[ -z "$SRV_PORT" ]]; then
        read -rp "UDP-порт AmneziaWG [Enter — случайный]: " answer < /dev/tty
        [[ -z "$answer" ]] || SRV_PORT="$answer"
    fi

    read -rp "Подсеть туннеля [${SRV_SUBNET}]: " answer < /dev/tty
    [[ -z "$answer" ]] || SRV_SUBNET="$answer"

    read -rp "MTU [${SRV_MTU}]: " answer < /dev/tty
    [[ -z "$answer" ]] || SRV_MTU="$answer"

    read -rp "Изолировать клиентов друг от друга? [y/N]: " answer < /dev/tty
    case "$answer" in [yY]*) SRV_ISOLATION="on" ;; *) SRV_ISOLATION="off" ;; esac

    read -rp "Включить IPv6 в туннеле? [y/N]: " answer < /dev/tty
    case "$answer" in [yY]*) SRV_IPV6="on" ;; *) SRV_IPV6="off" ;; esac

    read -rp "Профиль мимикрии quic|tls|dtls|sip|dns|noise [${SRV_PROFILE}]: " answer < /dev/tty
    [[ -z "$answer" ]] || SRV_PROFILE="$answer"

    read -rp "Интенсивность low|medium|high [${SRV_INTENSITY}]: " answer < /dev/tty
    [[ -z "$answer" ]] || SRV_INTENSITY="$answer"

    if [[ -z "$SRV_ENDPOINT" ]]; then
        printf '\n'
        echo "  Имя хоста для клиентов — адрес, который попадёт в Endpoint выданных"
        echo "  конфигов. Укажите DNS-имя (vpn.example.com), если оно есть: тогда при"
        echo "  смене IP сервера старые конфиги продолжат работать."
        read -rp "Имя хоста [Enter — определить внешний IP автоматически]: " answer < /dev/tty
        [[ -z "$answer" ]] || SRV_ENDPOINT="$answer"
    fi

    read -rp "Клиенты через запятую [Enter — ни одного]: " answer < /dev/tty
    [[ -z "$answer" ]] || CLIENTS="$answer"
}

# Порт должен быть известен ДО настройки фаервола: step4_setup_firewall
# открывает ${AWG_PORT}/udp, а server-init выполняется позже. Поэтому пустой
# --awg-port разрешается здесь, а в server-init уходит уже конкретным числом —
# иначе установщик и конфиг выбрали бы разные порты.
resolve_awg_port() {
    if [[ -n "$SRV_PORT" ]]; then
        AWG_PORT="$SRV_PORT"
        return 0
    fi
    local candidate attempt
    for attempt in $(seq 1 20); do
        candidate=$(( (RANDOM % 63977) + 1024 ))
        if ! ss -Hulnp 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${candidate}\$"; then
            SRV_PORT="$candidate"
            AWG_PORT="$candidate"
            log "выбран случайный UDP-порт: $SRV_PORT"
            return 0
        fi
    done
    die "не удалось подобрать свободный UDP-порт — задайте его явно: --awg-port N"
}

validate_params() {
    case "$SRV_PROFILE" in
        quic|tls|dtls|sip|dns|noise) ;;
        *) die "неизвестный профиль: $SRV_PROFILE" ;;
    esac
    case "$SRV_INTENSITY" in
        low|medium|high) ;;
        *) die "неизвестная интенсивность: $SRV_INTENSITY" ;;
    esac
    case "$SRV_ISOLATION" in on|off) ;; *) die "--isolation ожидает on|off" ;; esac
    case "$SRV_IPV6"      in on|off) ;; *) die "--ipv6 ожидает on|off" ;; esac
}

# Согласование IPv6 между установщиком и сервером.
#
# Первый шаг установщика по умолчанию глушит IPv6 в sysctl. Если при этом
# сервер просят поднять с IPv6 в туннеле, awg-quick не сможет назначить
# интерфейсу IPv6-адрес, сервис останется в failed и сервера просто не будет.
# Обе настройки должны решаться до шага 1, а не после.
sync_ipv6_settings() {
    if [[ "$SRV_IPV6" == "on" ]]; then
        CLI_ALLOW_IPV6_TUNNEL=1
        CLI_DISABLE_IPV6=0
        log "IPv6 в туннеле запрошен — глобальное отключение IPv6 снимается"
    else
        CLI_DISABLE_IPV6=1
    fi
    configure_ipv6
    configure_ipv6_tunnel
}

# Установка AmneziaWG: пакеты, модуль ядра, фаервол.
install_amneziawg_stack() {
    sync_ipv6_settings
    step1_update_and_optimize
    step2_install_amnezia
    step3_check_module
    step4_setup_firewall
}

# Создание сервера и запуск сервиса.
deploy_server() {
    install_awg3_script
    run_server_init
    step7_start_service
    create_initial_clients
    secure_files
    step99_finish
}

# ==============================================================================
# Разбор аргументов и запуск
# ==============================================================================

# Исходные аргументы запоминаются, чтобы предложить их дословно при
# перезагрузке: от них зависит, в чей домашний каталог лягут конфиги.
ORIGINAL_ARGS=""

parse_args() {
    ORIGINAL_ARGS="$*"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)              MODE="${2:-}"; shift 2 ;;
            --awg-port)          SRV_PORT="${2:-}"; shift 2 ;;
            --subnet)            SRV_SUBNET="${2:-}"; shift 2 ;;
            --mtu)               SRV_MTU="${2:-}"; shift 2 ;;
            --isolation)         SRV_ISOLATION="${2:-}"; shift 2 ;;
            --ipv6)              SRV_IPV6="${2:-}"; shift 2 ;;
            --profile)           SRV_PROFILE="${2:-}"; shift 2 ;;
            --intensity)         SRV_INTENSITY="${2:-}"; shift 2 ;;
            --clients)           CLIENTS="${2:-}"; shift 2 ;;
            --endpoint|--host-name)
                                 SRV_ENDPOINT="${2:-}"; shift 2 ;;
            --awg-dir)           AWG3_DIR="${2:-}"; shift 2 ;;
            # Прокидываются в bootstrap.sh как есть
            --user)              BOOTSTRAP_USER="${2:-}"
                                 BOOTSTRAP_ARGS+=(--user "${2:-}"); shift 2 ;;
            --password-file)     BOOTSTRAP_ARGS+=(--password-file "${2:-}"); shift 2 ;;
            --ssh-port)          BOOTSTRAP_ARGS+=(--ssh-port "${2:-}"); shift 2 ;;
            --disable-root-ssh)  BOOTSTRAP_ARGS+=(--disable-root-ssh "${2:-}"); shift 2 ;;
            --ssh-port-fw)       CLI_SSH_PORT="${2:-}"; shift 2 ;;
            -y|--yes)            AUTO_YES=1; shift ;;
            --force)             FORCE_REINSTALL=1; shift ;;
            --no-tweaks)         NO_TWEAKS=1; CLI_NO_TWEAKS=1; shift ;;
            --uninstall)         UNINSTALL=1; shift ;;
            --diagnostic)        DIAGNOSTIC=1; shift ;;
            --verbose)           VERBOSE=1; shift ;;
            --no-color)          NO_COLOR=1; shift ;;
            -h|--help)           HELP=1; shift ;;
            *)                   die "неизвестная опция: $1  (см. --help)" ;;
        esac
    done
}

main() {
    parse_args "$@"

    if [[ "$HELP" -eq 1 ]]; then show_help; fi
    if [[ "$VERBOSE" -eq 1 ]]; then set -x; fi

    # AWG_DIR мог измениться флагом --awg-dir, пересчитываем до первой записи
    # в журнал.
    AWG_DIR="$(resolve_awg_dir "")"
    STATE_FILE="$AWG_DIR/setup_state"
    LOG_FILE="$AWG_DIR/install-awg3.log"

    if [[ "$DIAGNOSTIC" -eq 1 ]]; then create_diagnostic_report; exit 0; fi
    if [[ "$UNINSTALL" -eq 1 ]]; then MODE="uninstall"; fi

    [[ "$(id -u)" -eq 0 ]] || die "нужны права root: sudo $0"

    prepare_awg_dir

    [[ -n "$MODE" ]] || show_menu
    validate_mode "$MODE" || exit 1

    check_container
    check_os_version
    check_free_space

    if [[ "${AWG_FORCE_REINSTALL:-0}" == "1" ]]; then FORCE_REINSTALL=1; fi

    case "$MODE" in
        full)
            local bs
            bs="$(script_dir)/bootstrap.sh"
            [[ -x "$bs" ]] || die "рядом со скриптом нет исполняемого bootstrap.sh"
            # --yes обязан дойти до bootstrap: без него подтверждение нового
            # доступа требует tty, которого при неинтерактивном запуске нет,
            # и вход root молча остаётся включённым вопреки
            # --disable-root-ssh yes.
            if [[ "$AUTO_YES" -eq 1 ]]; then
                BOOTSTRAP_ARGS+=(--yes)
            fi
            "$bs" "${BOOTSTRAP_ARGS[@]+"${BOOTSTRAP_ARGS[@]}"}" \
                || die "bootstrap.sh не отработал"
            # Каталог данных переезжает к созданному пользователю: клиенты
            # нужны именно ему, а не тому, кто запустил sudo.
            AWG_DIR="$(resolve_awg_dir "${BOOTSTRAP_USER:-user}")"
            LOG_FILE="$AWG_DIR/install-awg3.log"
            STATE_FILE="$AWG_DIR/setup_state"
            prepare_awg_dir
            ask_params; validate_params; resolve_awg_port
            install_amneziawg_stack
            deploy_server
            ;;
        awg-only)
            # Повторный запуск — обычное дело: человек мог прервать установку
            # или просто перезапустить её. Пересоздавать сервер молча нельзя
            # (перегенерация общих параметров обесценит все выданные конфиги),
            # но и падать с аварийным сообщением незачем: нужное состояние уже
            # достигнуто.
            if [[ -f "$SERVER_CONF_FILE" ]] && [[ "$FORCE_REINSTALL" -ne 1 ]]; then
                log "AmneziaWG уже развёрнут: $SERVER_CONF_FILE"
                log " "
                log "  добавить клиента:      sudo awg3 add ИМЯ"
                log "  посмотреть состояние:  sudo awg3 list"
                log " "
                log "Пересоздать сервер с новыми параметрами обфускации можно так:"
                log "  sudo $0 --mode reinstall"
                log_warn "ВНИМАНИЕ: после пересоздания все выданные конфиги перестанут подключаться."
                exit 0
            fi
            ask_params; validate_params; resolve_awg_port
            install_amneziawg_stack
            deploy_server
            ;;
        reinstall)
            [[ -f "$SERVER_CONF_FILE" ]] \
                || die "переустанавливать нечего: $SERVER_CONF_FILE не найден"
            log_warn "Общие параметры будут перегенерированы — ВСЕ выданные клиентские"
            log_warn "конфиги перестанут подключаться, их придётся создать заново."
            if [[ "$AUTO_YES" -eq 0 ]]; then
                local ans
                read -rp "Продолжить? [y/N]: " ans < /dev/tty
                [[ "$ans" =~ ^[Yy] ]] || die "отменено"
            fi
            ask_params; validate_params; resolve_awg_port
            install_amneziawg_stack
            deploy_server
            ;;
        upgrade)
            [[ -f "$SERVER_CONF_FILE" ]] \
                || die "переводить нечего: $SERVER_CONF_FILE не найден"
            log_warn "После перевода на 3.0 все выданные клиентские конфиги перестанут"
            log_warn "подключаться — каждого клиента придётся создать заново."
            if [[ "$AUTO_YES" -eq 0 ]]; then
                local ans
                read -rp "Продолжить? [y/N]: " ans < /dev/tty
                [[ "$ans" =~ ^[Yy] ]] || die "отменено"
            fi
            install_awg3_script
            AWG3_DIR="$AWG_DIR" "$AWG_DIR/awg3.sh" server-upgrade -y \
                || die "server-upgrade не отработал"
            log_warn "прежние клиентские конфиги больше не подключатся — пересоздайте их"
            ;;
        uninstall)
            step_uninstall
            ;;
    esac
}

if [[ "${INSTALL_LIB_ONLY:-0}" -ne 1 && "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
