#!/bin/bash

# Minimum Bash version check
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "ERROR: Bash >= 4.0 required (current: ${BASH_VERSION})" >&2; exit 1
fi

# ==============================================================================
# install-awg3.sh — установка AmneziaWG 3.1 на Debian/Ubuntu.
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

# CLI flags
UNINSTALL=0; HELP=0; HELP_EXIT_RC=0; DIAGNOSTIC=0; VERBOSE=0; NO_COLOR=0; AUTO_YES=0
_APT_UPDATED=0

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
# apt_lists_usable [каталог] — есть ли на диске хоть один индекс пакетов.
#
# Пустой /var/lib/apt/lists означает, что ставить не из чего, чем бы ни
# закончился apt update. Каталог берётся аргументом только ради тестов: путь на
# Debian и Ubuntu один и тот же, а других систем скрипт не поддерживает.
# shellcheck disable=SC2120  # в установщике зовётся без аргумента, bats передаёт каталог
apt_lists_usable() {
    local dir="${1:-/var/lib/apt/lists}" n
    n=$(find "$dir" -maxdepth 1 -type f -name '*_Packages*' 2>/dev/null | wc -l)
    [[ "${n:-0}" -gt 0 ]]
}

# apt_failed_hosts <вывод apt update> — хосты, до которых apt не достучался.
# Нужны в сообщении: без них человек видит стену одинаковых строк и не понимает,
# какое из зеркал его подвело.
apt_failed_hosts() {
    printf '%s' "$1"         | grep -E '^(Err:|W: Failed to fetch)'         | grep -oE 'https?://[^/ ]+'         | sed 's|https\?://||'         | sort -u
}

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

    # rc=0 ещё ничего не значит: недоступное зеркало для apt-get update —
    # предупреждение, а не ошибка, и он выходит с нулём, не скачав НИ ОДНОГО
    # индекса. Дальше установка шла с пустым кэшем и падала через минуту на
    # «Unable to locate package gpg» — сообщении, которое отправляет искать
    # пропавший пакет вместо недоступного зеркала.
    if [[ $rc -eq 0 ]]; then
        if apt_lists_usable; then
            local failed
            failed=$(apt_failed_hosts "$err_output")
            if [[ -n "$failed" ]]; then
                log_warn "часть репозиториев недоступна, продолжаю с тем, что скачалось:"
                printf '%s
' "$failed" | while IFS= read -r h; do log_warn "  $h"; done
            fi
            return 0
        fi

        log_error "apt update завершился без ошибки, но не скачал ни одного индекса пакетов."
        log_error "Ставить не из чего. Недоступны:"
        apt_failed_hosts "$err_output" | while IFS= read -r h; do log_error "  $h"; done
        log_error " "
        log_error "Проверьте с этой машины: curl -4 -sI https://deb.debian.org/debian/dists/stable/InRelease"
        log_error "Если зеркало недоступно именно из вашей сети, замените его:"
        log_error "  Debian 13:  /etc/apt/mirrors/debian.list и debian-security.list"
        log_error "  остальные:  /etc/apt/sources.list, /etc/apt/sources.list.d/"
        return 1
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

# request_reboot <следующий шаг> [причина]
#
# Причина передаётся аргументом: перезагрузка нужна и после обновления ядра, и
# когда модуль собран под другое ядро, а объяснение у них разное. Раньше текст
# был один на оба случая и всегда говорил про обновление ядра.
request_reboot() {
    local next_step=$1
    local reason="${2:-Обновилось ядро.}"
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
    log_warn "  ${reason} Модуль AmneziaWG должен собираться под то ядро,"
    log_warn "  которое реально работает, иначе он не загрузится."
    log_warn " "
    log_warn "  После перезагрузки повторите:"
    log_warn "    sudo $0 ${ORIGINAL_ARGS}"
    log_warn " "
    log_warn "  Установка продолжится с того места, где остановилась."
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

# check_kernel_version - an EARLY advisory check, before system prep and the
# reboot. The load-bearing gate is in install_amneziawg_stack: it runs after the
# upgrade and reboot, when uname -r is the kernel the module is built against.
# Here we only warn, because a staged kernel does become the running one after
# step 1 - dying now would refuse a machine that would have worked.
check_kernel_version() {
    local kver
    kver=$(uname -r)
    if _kernel_supports_awg3 "$kver"; then
        log "Kernel $kver (OK for the AmneziaWG module)."
        return 0
    fi
    log_warn "Kernel $kver is not recognised as 6.7 or newer - the AmneziaWG module cannot be built on it."
    log_warn "If the system has a newer kernel staged, it will be picked up after the reboot in step 1."
    log_warn "Otherwise install a 6.7+ kernel (on Debian 12 - from bookworm-backports) or reinstall"
    log_warn "the VPS on Ubuntu 24.04/25.10/26.04 or Debian 13."
    if [[ "$AUTO_YES" -eq 0 ]]; then
        local confirm
        read -rp "Continue anyway? [y/N]: " confirm < /dev/tty
        if ! [[ "$confirm" =~ ^[[:space:]]*[Yy]([Ee][Ss])?[[:space:]]*$ ]]; then
            die "Cancelled: kernel $kver is too old for the AmneziaWG module."
        fi
    else
        log "Continuing on kernel $kver (--yes)."
    fi
}

_kernel_supports_awg3() {
    # Returns 0 if the kernel version is >= 6.7 - i.e. the kernel can build the
    # AmneziaWG 3.x module. Threshold 6.7: nla_put_uint, which the 3.x code uses,
    # first appeared in mainline kernel v6.7 (it is absent in 6.6); on 6.1
    # (Debian 12) the build fails with 'implicit declaration of nla_put_uint'.
    # Arg $1: kernel release (default uname -r). A version that does not parse is
    # reported as NOT supported - callers word it as "not recognised as 6.7+"
    # rather than "older than 6.7", so the message stays true either way.
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


# ==============================================================================
# Вспомогательное
# ==============================================================================





# ==============================================================================
# System optimization (new in v5.0)
# ==============================================================================






# ==============================================================================
# Sysctl configuration (minimal, for --no-tweaks)
# ==============================================================================



# ==============================================================================
# Sysctl configuration (extended)
# ==============================================================================


# ==============================================================================
# Firewall and security
# ==============================================================================



secure_files() {
    log "Setting secure file permissions..."
    chmod 700 "$AWG_DIR" 2>/dev/null
    chmod 700 /etc/amnezia 2>/dev/null
    chmod 700 /etc/amnezia/amneziawg 2>/dev/null
    chmod 600 /etc/amnezia/amneziawg/*.conf 2>/dev/null
    find "$AWG_DIR" -name "*.conf" -type f -exec chmod 600 {} \; 2>/dev/null
    find "$AWG_DIR" -name "*.key" -type f -exec chmod 600 {} \; 2>/dev/null
    find "$AWG_DIR" -name "*.png" -type f -exec chmod 600 {} \; 2>/dev/null
    # Ссылка vpn:// несёт приватный ключ клиента наравне с конфигом и QR.
    find "$AWG_DIR" -name "*.vpnuri" -type f -exec chmod 600 {} \; 2>/dev/null
    find "$AWG_DIR" -name "*.private" -type f -exec chmod 600 {} \; 2>/dev/null
    find "$AWG_DIR" -name "*.public" -type f -exec chmod 600 {} \; 2>/dev/null
    # Каталоги клиентов: у каждого свой, внутри ключи, QR и ссылка.
    find "$AWG_DIR" -mindepth 1 -maxdepth 1 -type d -exec chmod 700 {} \; 2>/dev/null
    [[ -f "$LOG_FILE" ]] && chmod 640 "$LOG_FILE"
    [[ -f "$AWG_DIR/awg3.sh" ]] && chmod 700 "$AWG_DIR/awg3.sh"
    log "File permissions set."
}


# ==============================================================================
# Service status check
# ==============================================================================


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
        echo "=== AMNEZIAWG DIAGNOSTIC REPORT ==="
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
    if true; then
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
    # Clear the hold on the PPA packages (older installers pinned them) BEFORE the PPA
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
    if true; then
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
    if true; then
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
# ШАГ 1: apt в рабочем состоянии
# ==============================================================================
#
# Обновление системы, чистка пакетов, swap, тюнинг NIC и sysctl переехали в
# bootstrap.sh: это подготовка машины, а не установка AmneziaWG. Здесь остаётся
# ровно то, без чего нельзя добавить репозиторий и поставить пакеты.
#
# Вместе с обновлением системы отсюда ушла и перезагрузка: она была нужна
# только потому, что установщик сам менял ядро. Осталась единственная — если
# модуль собран под другое ядро (шаг 2).
step1_prepare_apt() {
    update_state 1
    log "### ШАГ 1: подготовка apt ###"

    # unattended-upgrades и apt-daily часто держат dpkg-lock по несколько минут
    # после первой загрузки (issue #150), и apt падал сразу.
    # DPkg::Lock::Timeout заставляет его дождаться.
    mkdir -p /etc/apt/apt.conf.d
    printf 'DPkg::Lock::Timeout "300";
' > /etc/apt/apt.conf.d/99-amneziawg-lock-timeout         || log_warn "не записан apt lock-timeout"

    log "Обновление списков пакетов..."
    apt_update_tolerant || die "apt update не отработал."
    # Кэш свежий: install_packages ниже не должен повторять update.
    _APT_UPDATED=1

    if ! apt-get check &>/dev/null; then
        log_warn "dpkg занят или повреждён, чиню..."
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a             || log_warn "dpkg --configure -a не отработал"
    fi

    # gpg нужен для ключа репозитория Amnezia, curl и wget — чтобы его забрать.
    install_packages curl wget gpg

    log "Шаг 1 завершён."
    update_state 2
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

    # H1 (AWG 3.1): a kernel older than 6.7 cannot build the AmneziaWG 3.x
    # module - it uses nla_put_uint, which first appeared in mainline 6.7 (it
    # is absent in 6.6). The pinned 2.0 module we used to build from source on
    # such kernels is gone: the PPA tools are 3.1 now and do not drive the
    # 1.0.0 module, so that path produced a server that came up but refused
    # every 3.x parameter. One protocol, one module.
    #
    # The gate lives here rather than among the early checks on purpose: by
    # this point the system has been upgraded and rebooted, so uname -r is the
    # kernel the module will actually be built against.
    if ! _kernel_supports_awg3; then
        log_error "Kernel $(uname -r) is not recognised as 6.7 or newer - the AmneziaWG module will not build here."
        log_error "Options: install a 6.7+ kernel (on Debian 12 - from bookworm-backports)"
        log_error "or reinstall the VPS on Ubuntu 24.04/25.10/26.04 or Debian 13."
        die "Kernel $(uname -r) is not supported by AmneziaWG 3.x."
    fi

    # Drop a hold a previous version of this installer could have left behind:
    # it used to pin amneziawg-dkms so that apt would not pull the 3.0 module
    # onto an old kernel. `apt install -y` refuses to proceed on a held package.
    apt-mark unhold amneziawg-dkms amneziawg >/dev/null 2>&1 || true

    local packages
    packages=("amneziawg-dkms" "amneziawg-tools" "wireguard-tools" "dkms"
              "build-essential" "dpkg-dev" "qrencode")

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
    local load_rc=0
    load_amneziawg_module || load_rc=$?
    case "$load_rc" in
        0)
            log "Модуль amneziawg загружен, перезагрузка не требуется."
            update_state 3
            return 0
            ;;
        2)
            die "модуль AmneziaWG не загружается, и перезагрузка этого не изменит."
            ;;
    esac
    log_warn "модуль собран под другое ядро — нужна перезагрузка"
    request_reboot 3 "Модуль AmneziaWG собран под другое ядро, чем работает сейчас."
}

# ==============================================================================
# STEP 3: Kernel module check
# ==============================================================================

# load_amneziawg_module — загрузить модуль и, если не вышло, объяснить почему.
#
#   0 — загружен
#   1 — не загружен, перезагрузка поможет
#   2 — не загружен, перезагрузка НЕ поможет (причина уже выведена)
#
# Различать эти два случая обязательно. Раньше любой отказ modprobe объявлялся
# следствием обновления ядра и приводил к перезагрузке — а при включённом
# Secure Boot модуль не грузится никогда, и человек ходил по кругу: ребут,
# то же сообщение, снова ребут.
load_amneziawg_module() {
    local err
    if err=$(modprobe amneziawg 2>&1); then
        return 0
    fi

    # Ядро отвергло неподписанный DKMS-модуль. Единственное лекарство — снять
    # Secure Boot или подписать модуль; перезагрузка тут бесполезна.
    if printf '%s' "$err" | grep -qiE 'key was rejected|required key not available'; then
        log_error "ядро отказалось грузить модуль: $err"
        log_error "Причина — Secure Boot: DKMS-модуль не подписан."
        log_error "Проверить: mokutil --sb-state"
        log_error "Выключите Secure Boot в BIOS/UEFI прошивке сервера"
        log_error "(в Proxmox: Hardware → EFI Disk, pre-enrolled-keys=0)"
        log_error "либо подпишите модуль собственным MOK-ключом."
        return 2
    fi

    # Модуль уже собран под РАБОТАЮЩЕЕ ядро и всё равно не грузится.
    # Перезагрузка ничего не изменит — показываем настоящую ошибку.
    if compgen -G "/lib/modules/$(uname -r)/updates/dkms/amneziawg.ko*" >/dev/null 2>&1; then
        log_error "модуль для ядра $(uname -r) собран, но не загружается: $err"
        log_error "Собранные версии: $(dkms status -m amneziawg 2>/dev/null | tr '
' ' ')"
        return 2
    fi

    log_warn "модуль не загрузился: $err"
    return 1
}

step3_check_module() {
    update_state 3
    log "### STEP 3: Kernel module check ###"
    sleep 2

    if ! lsmod | grep -q -w amneziawg; then
        log "Module not loaded. Loading..."
        load_amneziawg_module             || die "модуль AmneziaWG не загрузился — см. сообщения выше."
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


# ==============================================================================
# STEP 5: Downloading scripts (NO Python!)
# ==============================================================================




# ==============================================================================
# STEP 6: Config generation (native, without awgcfg.py)
# ==============================================================================


# ==============================================================================
# STEP 99: Completion
# ==============================================================================

step99_finish() {
    log "### УСТАНОВКА ЗАВЕРШЕНА ###"
    log "=============================================================================="
    log "AmneziaWG установлен. Сервера ещё нет — его создаёт awg3."
    log " "
    log "ДАЛЬШЕ:"
    log "  sudo awg3 server-init                 создать интерфейс (спросит параметры)"
    log "  sudo awg3 add ИМЯ                     выдать клиента"
    log " "
    log "  Клиент живёт в своём каталоге ${AWG_DIR}/ИНТЕРФЕЙС/ИМЯ/ — conf, QR,"
    log "  ссылка vpn:// и пара ключей. Забрать целиком:"
    log "    scp -r ПОЛЬЗОВАТЕЛЬ@<СЕРВЕР>:${AWG_DIR}/awg0/ИМЯ ./"
    log " "
    log "ЕЩЁ КОМАНДЫ:"
    log "  sudo awg3 list                        клиенты и состояние интерфейса"
    log "  sudo awg3 ifaces                      все интерфейсы сервера"
    log "  sudo awg3 --help                      остальное"
    log " "
    log "ВАЖНО: нужен клиент Amnezia VPN 5.0.1.5 или новее — с поддержкой AWG 3.1."
    log " "
    cleanup_apt
    log " "

    log "Удаление файла состояния установки..."
    rm -f "$STATE_FILE" "${STATE_FILE}.lock" "$AWG_DIR/.boot_id_before_step2" \
        || log_warn "Не удалён $STATE_FILE"
    log "Готово. Журнал: $LOG_FILE"
    log "=============================================================================="
}

# ==============================================================================
# Запуск
# ==============================================================================

show_help() {
    cat <<EOF
install-awg3.sh ${SCRIPT_VERSION} — установка AmneziaWG 3.1
(форк bivlked/amneziawg-installer ${UPSTREAM_VERSION})

Ставит пакеты, собирает модуль ядра и кладёт awg3.sh в PATH. Сервер он НЕ
настраивает: интерфейс создаёт 'awg3 server-init', и он же спрашивает порт,
подсеть и остальное. Одна команда — одна задача.

ИСПОЛЬЗОВАНИЕ
    sudo ./install-awg3.sh [опции]

ОПЦИИ
    --awg-dir PATH        каталог данных   (по умолч.: ~/awg текущего пользователя)
    -y, --yes             не задавать вопросов
        --uninstall       удалить AmneziaWG
        --diagnostic      собрать диагностический отчёт
        --verbose         подробный вывод
        --no-color        без цвета
    -h, --help            эта справка

ПОРЯДОК РАЗВЁРТЫВАНИЯ
    sudo ./bootstrap.sh --user vpnadmin --ssh-port 2222   подготовка системы
    sudo ./install-awg3.sh                                этот скрипт
    sudo awg3 server-init                                 создать интерфейс
    sudo awg3 add ИМЯ                                     выдать клиента

ПРИМЕЧАНИЯ
    Систему этот скрипт не настраивает: обновление, swap, sysctl, фаервол и
    fail2ban — задача bootstrap.sh. Порт интерфейса открывает
    'awg3 server-init'. Здесь только пакеты, модуль ядра и awg3 в PATH.

    Перезагрузка нужна в одном случае: модуль собран под другое ядро, чем
    работает сейчас. Тогда скрипт скажет об этом — перезагрузитесь и запустите
    ту же команду, установка продолжится с нужного места.
EOF
    exit "${HELP_EXIT_RC:-0}"
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

# Установка AmneziaWG: пакеты, модуль ядра, общая часть фаервола.
#
# Вопросов о VPN здесь нет ни одного — ни до перезагрузок, ни после. Их задаёт
# 'awg3 server-init', то есть тот, кто эти ответы применяет.
install_amneziawg_stack() {
    step1_prepare_apt
    step2_install_amnezia
    step3_check_module
}

# Исходные аргументы запоминаются, чтобы предложить их дословно при
# перезагрузке: от них зависит, в чей домашний каталог лягут конфиги.
ORIGINAL_ARGS=""

parse_args() {
    ORIGINAL_ARGS="$*"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --awg-dir)           AWG3_DIR="${2:-}"; shift 2 ;;
            -y|--yes)            AUTO_YES=1; shift ;;
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

    [[ "$(id -u)" -eq 0 ]] || die "нужны права root: sudo $0"

    prepare_awg_dir

    if [[ "$UNINSTALL" -eq 1 ]]; then step_uninstall; exit 0; fi

    check_container
    check_os_version
    check_kernel_version
    check_free_space

    install_amneziawg_stack
    install_awg3_script
    secure_files
    step99_finish
}

if [[ "${INSTALL_LIB_ONLY:-0}" -ne 1 && "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
