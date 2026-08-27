#!/usr/bin/env bash
#
# bootstrap.sh — подготовка свежего сервера перед установкой AmneziaWG.
#
# Обновляет систему, ставит sudo, создаёт sudo-пользователя, переносит SSH на
# другой порт, при желании отключает вход root по SSH и настраивает фаервол.
# Про AmneziaWG не знает ничего: его задача — сделать сервер пригодным к
# дальнейшей работе и при этом не отрезать вас от него.
#
#   ./bootstrap.sh                       интерактивно
#   ./bootstrap.sh --user vpnadmin --ssh-port 2222 --disable-root-ssh yes --yes
#
# Порядок шагов и есть защита от потери доступа: старый и новый порты открыты
# одновременно, sshd перезапускается только после проверки конфигурации, а
# вход root закрывается лишь после того, как вы вручную подтвердили работу
# нового доступа.
#
# Лицензия: MIT.

set -Eeuo pipefail

BOOTSTRAP_VERSION="1.0.0"

# ── Значения по умолчанию ───────────────────────────────────────────────────

NEW_USER="user"
NEW_SSH_PORT="22"
DISABLE_ROOT_SSH="no"
PASSWORD_FILE=""
NEW_PASSWORD=""
ASSUME_YES=0
# --no-tweaks: не трогать swap, sysctl, сетевую карту и лишние пакеты.
NO_TWEAKS=0

OLD_SSH_PORT=""
NEEDS_REBOOT=0
ROOT_SSH_DISABLED=0
SERVER_ADDR=""
SUMMARY_FILE=""
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-awg3-hardening.conf"
SSH_SOCKET_DROPIN="/etc/systemd/system/ssh.socket.d/99-awg3-port.conf"

# ── Вывод ───────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_OFF=""
fi

log()      { printf '%s\n' "$1"; }
log_ok()   { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_OFF" "$1"; }
log_warn() { printf '%s[WARN]%s %s\n' "$C_YEL" "$C_OFF" "$1" >&2; }
log_err()  { printf '%s[ERR ]%s %s\n' "$C_RED" "$C_OFF" "$1" >&2; }
die()      { log_err "$1"; exit 1; }
# Псевдонимы для кода, перенесённого из установщика: там имена другие.
log_error() { log_err "$1"; }
log_debug() { [[ "${VERBOSE:-0}" -eq 1 ]] && printf '  %s\n' "$1" >&2; return 0; }

# ── Предполётные проверки ───────────────────────────────────────────────────

require_root() {
    [[ "$EUID" -eq 0 ]] || { log_err "нужны права root"; return 1; }
    return 0
}

# detect_os [FILE] — заполняет OS_ID, OS_VERSION_ID, OS_CODENAME.
# Аргумент нужен тестам, в бою всегда используется путь по умолчанию.
# shellcheck disable=SC2120
detect_os() {
    local f="${1:-/etc/os-release}"
    [[ -r "$f" ]] || { log_err "не читается $f"; return 1; }
    # shellcheck disable=SC1090
    . "$f"
    OS_ID="${ID:-}"
    OS_VERSION_ID="${VERSION_ID:-}"
    OS_CODENAME="${VERSION_CODENAME:-}"
    return 0
}

os_supported() {
    case "${OS_ID:-}" in
        debian)
            (( 10#${OS_VERSION_ID%%.*} >= 12 )) && return 0
            ;;
        ubuntu)
            case "${OS_VERSION_ID:-}" in
                22.04|22.10|23.*|24.*|25.*|26.*) return 0 ;;
            esac
            ;;
    esac
    log_err "неподдерживаемая ОС: ${OS_ID:-?} ${OS_VERSION_ID:-?} (нужны Debian 12+ или Ubuntu 22.04+)"
    return 1
}

# Аргумент нужен тестам, в бою используется путь по умолчанию.
# shellcheck disable=SC2120
# Сборка ядра: то, что отличает cloud-amd64 от amd64 и generic от lowlatency.
# Ubuntu вставляет между версией и сборкой ABI-номер (6.8.0-51-generic) — он к
# сборке не относится и выбрасывается, иначе каждое обновление выглядело бы
# сменой сборки.
kernel_flavor() {
    local rest="${1#*-}"
    if [[ "$rest" =~ ^[0-9]+- ]]; then rest="${rest#*-}"; fi
    printf '%s' "$rest"
}

# kernel_upgrade_pending [работающее ядро] [каталог модулей]
#
# Установлено ли ядро свежее работающего. Сравниваются только ядра ТОЙ ЖЕ
# сборки: cloud-amd64 и amd64 лежат рядом, и переход между ними перезагрузкой
# не случается.
# shellcheck disable=SC2120  # в bootstrap зовётся без аргументов, bats передаёт свои
kernel_upgrade_pending() {
    local running="${1:-$(uname -r)}" dir="${2:-/lib/modules}"
    local flavor entry newest
    local -a found=()
    [[ -d "$dir" ]] || return 1
    flavor=$(kernel_flavor "$running")

    # Перебор глобом, а не `ls | grep`: имена каталогов приходят от пакетов, и
    # полагаться на то, что в них не окажется пробела, незачем.
    for entry in "$dir"/*"-${flavor}"; do
        [[ -d "$entry" ]] || continue
        found+=("$(basename "$entry")")
    done
    [[ "${#found[@]}" -gt 0 ]] || return 1

    newest=$(printf '%s\n' "${found[@]}" | sort -V | tail -1)
    [[ -n "$newest" && "$newest" != "$running" ]]
}

# Нужна ли перезагрузка.
#
# Маркер /var/run/reboot-required создаёт update-notifier, которого в облачных
# образах Debian нет: после смены ядра файла не появится, и bootstrap молчал —
# а потом установщик собирал модуль под новое ядро и всё равно требовал
# перезагрузку. Поэтому вторым признаком смотрим на сами ядра.
# shellcheck disable=SC2120  # маркер подменяется только в тестах
reboot_required() {
    local marker="${1:-/var/run/reboot-required}"
    [[ -f "$marker" ]] && return 0
    kernel_upgrade_pending
}

apt_upgrade_system() {
    log "Обновление списков пакетов..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq \
        || die "apt-get update не сработал — проверьте сеть и DNS"

    log "Обновление системы (может занять несколько минут)..."
    DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold \
        full-upgrade \
        || die "apt-get full-upgrade не сработал"

    log "Установка базовых пакетов..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        sudo ufw fail2ban openssh-server iproute2 \
        || die "не установлены базовые пакеты"

    if reboot_required; then
        NEEDS_REBOOT=1
        log_warn "обновилось ядро — перезагрузка понадобится ПОСЛЕ настройки"
    fi
    log_ok "система обновлена"
}

# ── Пользователь ────────────────────────────────────────────────────────────

# Имя по правилам useradd: начинается со строчной буквы или подчёркивания,
# дальше строчные, цифры, дефис, подчёркивание. До 32 символов.
validate_username() {
    local n="${1:-}"
    [[ -n "$n" ]] || { log_err "имя пользователя не задано"; return 1; }
    [[ "$n" != "root" ]] || { log_err "'root' уже есть, нужен другой пользователь"; return 1; }
    [[ "${#n}" -le 32 ]] || { log_err "имя длиннее 32 символов"; return 1; }
    [[ "$n" =~ ^[a-z_][a-z0-9_-]*$ ]] \
        || { log_err "недопустимое имя '$n': строчные буквы, цифры, дефис, подчёркивание"; return 1; }
    return 0
}

# Пароль уходит в chpasswd через stdin, поэтому перевод строки и двоеточие
# ломают формат — отвергаем сразу.
validate_password() {
    local p="${1:-}"
    [[ "${#p}" -ge 8 ]] || { log_err "пароль короче 8 символов"; return 1; }
    [[ "$p" != *$'\n'* ]] || { log_err "пароль не должен содержать перевод строки"; return 1; }
    [[ "$p" != *:* ]] || { log_err "пароль не должен содержать двоеточие"; return 1; }
    return 0
}

user_exists() {
    getent passwd "$1" >/dev/null 2>&1
}

# Группа sudo действительно даёт права? Если её нет в sudoers, создавать
# пользователя бессмысленно, и узнать это надо ДО изменений в SSH.
#
# Список файлов можно передать аргументами — это нужно тестам: /etc/sudoers
# имеет права 440 root:root и обычному пользователю недоступен.
# shellcheck disable=SC2120
sudo_group_enabled() {
    local files=("$@") f
    if [[ "${#files[@]}" -eq 0 ]]; then
        files=(/etc/sudoers /etc/sudoers.d/*)
    fi
    for f in "${files[@]}"; do
        [[ -f "$f" ]] || continue
        if grep -qE '^[[:space:]]*%sudo[[:space:]]+ALL=' "$f" 2>/dev/null; then
            return 0
        fi
    done
    log_err "группа sudo не даёт прав в /etc/sudoers — исправьте вручную"
    return 1
}

# Существующий пользователь может быть непригоден для входа: сервисная учётка
# с nologin-шеллом, заблокированный пароль, отсутствующий домашний каталог.
# Молча добавить такого в sudo и отрапортовать успех — значит отдать сервер,
# в который нельзя войти, и обнаружится это уже после закрытия root.
verify_existing_user() {
    local name="$1" shell home status problems=0

    shell=$(getent passwd "$name" | cut -d: -f7)
    case "$shell" in
        */nologin|*/false|"")
            log_err "у пользователя '$name' шелл '$shell' — вход по SSH невозможен"
            log_err "Исправьте: usermod -s /bin/bash $name"
            problems=1
            ;;
    esac

    home=$(getent passwd "$name" | cut -d: -f6)
    if [[ -z "$home" || ! -d "$home" ]]; then
        log_warn "нет домашнего каталога '$home' — создаю"
        mkhomedir_helper "$name" 2>/dev/null || {
            mkdir -p "$home" \
                && chown "${name}:$(id -gn "$name" 2>/dev/null || echo "$name")" "$home" \
                && chmod 750 "$home"
        } || { log_err "не создан домашний каталог для '$name'"; problems=1; }
    fi

    # Второе поле passwd -S: P — пароль задан, L — учётка заблокирована,
    # NP — пароля нет вовсе. Войти можно только с P.
    if status=$(passwd -S "$name" 2>/dev/null | awk '{print $2}'); then
        case "$status" in
            P) ;;
            L)
                log_err "учётная запись '$name' заблокирована — вход по паролю невозможен"
                log_err "Исправьте: usermod -U $name  (и задайте пароль: passwd $name)"
                problems=1
                ;;
            NP)
                log_err "у пользователя '$name' не задан пароль — вход по паролю невозможен"
                log_err "Исправьте: passwd $name"
                problems=1
                ;;
        esac
    fi

    [[ "$problems" -eq 0 ]] || return 1
    log_ok "существующий пользователь '$name' пригоден для входа"
    return 0
}

create_sudo_user() {
    local name="$1" password="$2"

    if user_exists "$name"; then
        log_warn "пользователь '$name' уже существует — пароль не меняю"
        verify_existing_user "$name" \
            || die "пользователь '$name' непригоден для входа — исправьте и запустите снова"
    else
        # В Ubuntu есть системная группа admin (наследие: раньше через неё
        # давали sudo). useradd по умолчанию создаёт группу с именем
        # пользователя и падает с «group admin exists» — на дефолтном
        # --user admin установка ломалась бы у всех. Существующую группу
        # берём как основную.
        local useradd_opts=(-m -s /bin/bash)
        if getent group "$name" >/dev/null 2>&1; then
            log "группа '$name' уже есть — использую её как основную"
            useradd_opts+=(-g "$name")
        fi
        useradd "${useradd_opts[@]}" "$name" || die "не создан пользователь '$name'"
        printf '%s:%s\n' "$name" "$password" | chpasswd \
            || die "не установлен пароль для '$name'"
        log_ok "пользователь '$name' создан"
    fi

    if id -nG "$name" 2>/dev/null | tr ' ' '\n' | grep -qx sudo; then
        log "пользователь '$name' уже в группе sudo"
    else
        usermod -aG sudo "$name" || die "не добавлен в группу sudo"
        log_ok "'$name' добавлен в группу sudo"
    fi

    sudo_group_enabled || die "sudo не заработает — прерываю до изменений SSH"
}

# Пароль: из файла или интерактивно с подтверждением. Аргументом — никогда:
# аргументы видны в ps любому пользователю системы.
read_password() {
    if [[ -n "$PASSWORD_FILE" ]]; then
        [[ -r "$PASSWORD_FILE" ]] || die "не читается $PASSWORD_FILE"
        NEW_PASSWORD=$(head -n1 "$PASSWORD_FILE")
        validate_password "$NEW_PASSWORD" || die "пароль из файла не прошёл проверку"
        return 0
    fi

    if user_exists "$NEW_USER"; then
        log "пользователь '$NEW_USER' уже существует — пароль не потребуется"
        NEW_PASSWORD=""
        return 0
    fi

    [[ -t 0 ]] || die "пароль не задан, а ввод не интерактивен — используйте --password-file"

    local p1 p2
    while :; do
        read -rsp "Пароль для '$NEW_USER': " p1 < /dev/tty; printf '\n'
        read -rsp "Повторите пароль: "        p2 < /dev/tty; printf '\n'
        if [[ "$p1" != "$p2" ]]; then
            log_warn "пароли не совпали, попробуйте снова"
            continue
        fi
        if validate_password "$p1"; then
            NEW_PASSWORD="$p1"
            return 0
        fi
    done
}

# ── SSH-порт: определение ───────────────────────────────────────────────────

# Порт из файла конфигурации sshd: директива Port или порт из ListenAddress
# (IPv4 host:port и IPv6 [addr]:port). Закомментированное игнорируется.
parse_ssh_port_from_config() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    awk '
        tolower($1) == "port" && $2 ~ /^[0-9]+$/ { print $2; exit }
        tolower($1) == "listenaddress" {
            v = $2
            if (v ~ /\]:[0-9]+$/)            { sub(/.*\]:/, "", v); print v; exit }
            else if (v ~ /^[0-9.]+:[0-9]+$/) { sub(/.*:/,  "", v); print v; exit }
        }
    ' "$f"
}

# Текущий порт: эффективная конфигурация sshd, затем реально слушающий сокет,
# затем разбор файлов, затем 22. Порядок важен — drop-in'ы и socket activation
# перекрывают основной файл.
detect_current_ssh_port() {
    local p=""

    if command -v sshd >/dev/null 2>&1; then
        p=$(sshd -T 2>/dev/null | awk 'tolower($1)=="port"{print $2; exit}')
    fi
    if [[ -z "$p" ]] && command -v ss >/dev/null 2>&1; then
        p=$(ss -Htlnp 2>/dev/null | awk '/"sshd"/{n=split($4,a,":"); print a[n]; exit}')
    fi
    if [[ -z "$p" ]]; then
        p=$(parse_ssh_port_from_config /etc/ssh/sshd_config)
    fi
    if [[ -z "$p" ]]; then
        local d
        for d in /etc/ssh/sshd_config.d/*.conf; do
            [[ -f "$d" ]] || continue
            p=$(parse_ssh_port_from_config "$d")
            [[ -n "$p" ]] && break
        done
    fi
    [[ -n "$p" ]] || p=22
    printf '%s' "$p"
}

# ── Фаервол ─────────────────────────────────────────────────────────────────

ufw_rule_exists() {
    ufw status 2>/dev/null | grep -qF "$1"
}

# Оба порта открываются одновременно. Старый закрывается позже и только после
# того, как вход на новый подтверждён вручную — иначе одна ошибка в
# определении порта отрезает доступ к серверу навсегда.
ufw_setup() {
    local old_port="$1" new_port="$2"

    command -v ufw >/dev/null 2>&1 || die "ufw не установлен"

    ufw default deny incoming  >/dev/null || die "ufw: не задан deny incoming"
    ufw default allow outgoing >/dev/null || die "ufw: не задан allow outgoing"

    ufw limit "${old_port}/tcp" comment "SSH (прежний порт)" >/dev/null \
        || die "ufw: не добавлено правило для порта $old_port"
    log_ok "ufw: разрешён SSH на порту $old_port"

    if [[ "$new_port" != "$old_port" ]]; then
        ufw limit "${new_port}/tcp" comment "SSH" >/dev/null \
            || die "ufw: не добавлено правило для порта $new_port"
        log_ok "ufw: разрешён SSH на порту $new_port"
    fi

    if ufw status 2>/dev/null | grep -q inactive; then
        ufw --force enable >/dev/null || die "ufw не включился"
        log_ok "ufw включён"
    else
        ufw reload >/dev/null || log_warn "ufw reload не сработал"
        log_ok "ufw: правила обновлены"
    fi
}

# ── SSH-порт: применение ────────────────────────────────────────────────────

# На Debian 13 и Ubuntu >= 22.10 порт может задавать ssh.socket, и тогда Port
# в sshd_config игнорируется МОЛЧА: правка выглядит успешной, но порт не
# меняется. Проверяем явно.
ssh_socket_active() {
    systemctl is-active --quiet ssh.socket 2>/dev/null \
        || systemctl is-enabled --quiet ssh.socket 2>/dev/null
}

# Drop-in переписывается целиком, а не дополняется: так повторный запуск не
# накапливает дубли директив.
write_sshd_dropin() {
    local port="$1" root_login="${2:-}"
    mkdir -p "$(dirname "$SSHD_DROPIN")"
    {
        printf '# Создано bootstrap.sh (awg3-deploy). Правки будут перезаписаны.\n'
        printf 'Port %s\n' "$port"
        if [[ -n "$root_login" ]]; then
            printf 'PermitRootLogin %s\n' "$root_login"
        fi
    } > "$SSHD_DROPIN"
    chmod 644 "$SSHD_DROPIN"
}

# Порт для socket activation задаётся в юните, а не в sshd_config.
#
# Адреса перечисляются явно. Голый `ListenStream=ПОРТ` рассчитан на
# dual-stack сокет [::]:ПОРТ, принимающий и IPv4 через v4-mapped адреса. Но
# если IPv6 выключен в sysctl — а установщик AmneziaWG его выключает — сокет
# поднимается только на IPv6, IPv4 не слушает никто, и подключение отбивается
# с "Connection refused" при обмене баннерами.
write_ssh_socket_override() {
    local port="$1"
    mkdir -p "$(dirname "$SSH_SOCKET_DROPIN")"
    {
        printf '# Создано bootstrap.sh (awg3-deploy).\n'
        printf '[Socket]\n'
        # Пустой ListenStream сбрасывает унаследованный список портов, иначе
        # сокет продолжит слушать и старый порт тоже.
        printf 'ListenStream=\n'
        printf 'ListenStream=0.0.0.0:%s\n' "$port"
        # IPv6 добавляем, только если он реально включён: иначе юнит не
        # поднимется вовсе и доступа не станет ни по одному протоколу.
        if [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" == "0" ]]; then
            printf 'ListenStream=[::]:%s\n' "$port"
            printf 'BindIPv6Only=ipv6-only\n'
        fi
    } > "$SSH_SOCKET_DROPIN"
    chmod 644 "$SSH_SOCKET_DROPIN"
    systemctl daemon-reload
}

sshd_listening_on() {
    local port="$1"
    ss -Htlnp 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"
}

# При socket activation порт держит ssh.socket, а ssh.service запускается им
# по требованию. Если перезапустить ещё и ssh.service самостоятельно, он
# поднимется в режиме демона и займёт тот же порт: два слушателя на одном
# сокете дают "Connection refused" при обмене баннерами. Поэтому здесь
# ветвление, а не перезапуск обоих подряд.
restart_ssh() {
    if ssh_socket_active; then
        # Только сокет. ssh.service при socket activation запускается им по
        # требованию и постоянно не работает, так что перезапускать его
        # незачем: `systemctl restart ssh` поднял бы демона рядом с сокетом
        # (два слушателя на порту → "Connection refused"), а
        # `systemctl stop ssh.service` убил бы все обслуживающие процессы
        # вместе с текущей SSH-сессией — то есть оборвал бы сам скрипт.
        systemctl restart ssh.socket || return 1
        return 0
    fi
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || return 1
    return 0
}

rollback_ssh_port() {
    log_warn "откатываю изменения SSH"
    rm -f "$SSHD_DROPIN" "$SSH_SOCKET_DROPIN"
    systemctl daemon-reload 2>/dev/null || true
    restart_ssh || true
}

# apply_ssh_port PORT — сменить порт и убедиться, что sshd его слушает.
# Уже установленные соединения переживают рестарт sshd, текущая сессия не
# рвётся.
apply_ssh_port() {
    local port="$1"

    if [[ "$port" == "$OLD_SSH_PORT" ]]; then
        log "SSH-порт не меняется ($port)"
        return 0
    fi

    if ssh_socket_active; then
        log "обнаружена socket activation (ssh.socket) — порт задаётся юнитом"
        write_ssh_socket_override "$port"
    fi
    write_sshd_dropin "$port"

    if ! sshd -t 2>/dev/null; then
        rm -f "$SSHD_DROPIN" "$SSH_SOCKET_DROPIN"
        systemctl daemon-reload 2>/dev/null || true
        die "конфигурация sshd невалидна — изменения отменены, sshd не перезапускался"
    fi

    restart_ssh || { rollback_ssh_port; die "sshd не перезапустился"; }

    # Сокету нужен момент, чтобы встать; без паузы проверка ложно провалится.
    local i
    for i in 1 2 3 4 5; do
        if sshd_listening_on "$port"; then
            log_ok "sshd слушает порт $port"
            return 0
        fi
        sleep 1
    done

    rollback_ssh_port
    die "sshd не слушает порт $port — изменения откачены, доступ на порту $OLD_SSH_PORT сохранён"
}

# ── Подтверждение доступа и отключение root ─────────────────────────────────

# Адрес, по которому к серверу подключаются: тот, на который пришло текущее
# SSH-соединение, иначе первый глобальный адрес.
detect_server_addr() {
    local a=""
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        a=$(awk '{print $3}' <<< "$SSH_CONNECTION")
    fi
    if [[ -z "$a" ]]; then
        a=$(ip -4 -br addr show scope global 2>/dev/null \
            | awk 'NR==1{split($3,x,"/"); print x[1]}')
    fi
    printf '%s' "${a:-АДРЕС_СЕРВЕРА}"
}

# Пауза перед необратимым шагом. Ответ строго "yes" целиком: "y" слишком легко
# нажать не глядя, а ценой ошибки будет потерянный сервер.
confirm_new_access() {
    local host="$1" port="$2" user="$3"

    if [[ "$ASSUME_YES" -eq 1 ]]; then
        log_warn "--yes: проверка нового доступа пропущена перед отключением root"
        return 0
    fi
    [[ -t 0 ]] || { log_warn "ввод не интерактивен — root останется включён"; return 1; }

    printf '\n'
    log_warn "СЕЙЧАС БУДЕТ ОТКЛЮЧЁН ВХОД ROOT ПО SSH."
    log "Текущая сессия жива, но НЕ ЗАКРЫВАЙТЕ ЕЁ."
    log "Откройте ВТОРОЕ окно терминала и проверьте:"
    printf '\n    ssh -p %s %s@%s\n    sudo -v\n\n' "$port" "$user" "$host"

    local answer
    read -rp "Вход и sudo работают? Введите yes целиком: " answer < /dev/tty
    [[ "$answer" == "yes" ]]
}

disable_root_ssh() {
    local port="$1"
    write_sshd_dropin "$port" "no"

    if ! sshd -t 2>/dev/null; then
        write_sshd_dropin "$port"
        die "конфигурация sshd невалидна — root остался включён"
    fi

    restart_ssh || { write_sshd_dropin "$port"; die "sshd не перезапустился — root остался включён"; }

    ROOT_SSH_DISABLED=1
    log_ok "вход root по SSH отключён"
}

close_old_port() {
    local old="$1" new="$2"
    [[ "$old" != "$new" ]] || return 0
    if ufw delete limit "${old}/tcp" >/dev/null 2>&1; then
        log_ok "ufw: старый порт $old закрыт"
    else
        log_warn "ufw: не удалось закрыть порт $old — проверьте 'ufw status'"
    fi
}

write_summary() {
    local f="$1"
    {
        printf 'Итог подготовки сервера (bootstrap.sh %s)\n' "$BOOTSTRAP_VERSION"
        printf '========================================\n\n'
        printf 'Пользователь:  %s\n' "$NEW_USER"
        printf 'SSH-порт:      %s\n' "$NEW_SSH_PORT"
        if [[ "$ROOT_SSH_DISABLED" -eq 1 ]]; then
            printf 'root по SSH:   отключён\n'
        else
            printf 'root по SSH:   включён\n'
        fi
        printf '\nПодключение:\n    ssh -p %s %s@%s\n' "$NEW_SSH_PORT" "$NEW_USER" "$SERVER_ADDR"
        printf '\nСОХРАНИТЕ ЭТИ ДАННЫЕ. Пароль пользователя восстановить нельзя.\n'
        if [[ "$NEEDS_REBOOT" -eq 1 ]]; then
            printf '\nОбновилось ядро — перезагрузите сервер: sudo reboot\n'
        fi
        printf '\nДальше: sudo ./install-awg3.sh\n'
    } > "$f"
    chmod 600 "$f"
    # Группа берётся у самого пользователя: она не обязана совпадать с его
    # именем — на Ubuntu для 'admin' это существующая системная группа.
    if user_exists "${NEW_USER:-}"; then
        chown "${NEW_USER}:$(id -gn "$NEW_USER" 2>/dev/null || echo "$NEW_USER")" "$f" 2>/dev/null || true
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Подготовка машины
# ══════════════════════════════════════════════════════════════════════════════
#
# Чистка лишних пакетов, swap, тюнинг сетевой карты и sysctl. Раньше это делал
# install-awg3.sh, и это было неправильно: установщик AmneziaWG не должен
# решать, как настроен чужой сервер. Подготовка машины — задача этого скрипта.
#
# Отключается флагом --no-tweaks: на сервере, настроенном под себя, чужое
# мнение о swap и sysctl не нужно.
#
# Код перенесён из установщика почти дословно (туда он, в свою очередь, попал
# из апстрима bivlked/amneziawg-installer) — поэтому комментарии внутри
# английские.

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
            die "сеть не поднялась после чистки пакетов. Восстановите её из консоли (например, dhclient -4 <интерфейс>) и запустите bootstrap.sh с --no-tweaks."
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
# Какой из двух наборов sysctl писать, решает --no-tweaks. Оба переписывают
# свой файл целиком, поэтому функцию можно звать повторно: именно так решение
# про IPv6, ставшее известным уже после шага 1, попадает в файл до следующей
# перезагрузки.
apply_sysctl_profile() {
    if [[ "$NO_TWEAKS" -eq 0 ]]; then
        setup_advanced_sysctl
    else
        setup_minimal_sysctl
    fi
}
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
# AmneziaWG Security/Performance Settings - $(date)
# Создано bootstrap.sh v${BOOTSTRAP_VERSION}

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
setup_fail2ban() {
    log "Configuring Fail2Ban..."
    if ! command -v fail2ban-client &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban >/dev/null 2>&1 || log_warn "fail2ban не установился"
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
        DEBIAN_FRONTEND=noninteractive apt-get install -y python3-systemd >/dev/null 2>&1 || log_warn "python3-systemd не установился"
    fi

    mkdir -p /etc/fail2ban/jail.d 2>/dev/null

    # Backend: systemd for Debian and Ubuntu (no rsyslog)
    local f2b_backend="systemd"

    cat > /etc/fail2ban/jail.d/bootstrap-sshd.conf << JAILEOF || { log_warn "jail.d/bootstrap-sshd.conf не записан"; return 1; }
# Защита SSH (создано bootstrap.sh)
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
usage() {
    cat <<EOF
bootstrap.sh ${BOOTSTRAP_VERSION} — подготовка сервера перед установкой AmneziaWG

Делает машину пригодной для работы: sudo-пользователь, порт SSH, фаервол,
fail2ban, обновление системы, swap, sysctl и чистка лишних пакетов. AmneziaWG
не ставит — это следующая команда, install-awg3.sh.

ИСПОЛЬЗОВАНИЕ
    bootstrap.sh [опции]

ОПЦИИ
        --user NAME           имя нового sudo-пользователя  (по умолч.: ${NEW_USER})
        --password-file FILE  файл с паролем первой строкой
        --ssh-port N          новый порт SSH                (по умолч.: ${NEW_SSH_PORT})
        --disable-root-ssh yes|no
                              отключить вход root по SSH    (по умолч.: ${DISABLE_ROOT_SSH})
        --no-tweaks           не трогать swap, sysctl, сетевую карту и не
                              сносить лишние пакеты
    -y, --yes                 не задавать вопросов
    -h, --help                эта справка

ПОРЯДОК РАЗВЁРТЫВАНИЯ
    sudo ./bootstrap.sh --user vpnadmin --ssh-port 2222   этот скрипт
    sudo ./install-awg3.sh                                пакеты и модуль
    sudo awg3 server-init                                 создать интерфейс
    sudo awg3 add ИМЯ                                     выдать клиента

ПРИМЕЧАНИЯ
    Пароль нельзя передать аргументом: аргументы видны в ps и попадают в
    историю shell. Только --password-file или интерактивный ввод.

    Старый и новый порты SSH открыты одновременно; старый закрывается лишь
    после того, как вы подтвердите работу нового доступа.

    Фаервол настраивается только в общей части: политики и лимит на SSH. Порт
    VPN открывает 'awg3 server-init' — он один знает, какой порт у какого
    интерфейса, а интерфейсов может быть несколько.
EOF
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user)              NEW_USER="${2:-}"; shift 2 ;;
            --password-file)     PASSWORD_FILE="${2:-}"; shift 2 ;;
            --ssh-port)          NEW_SSH_PORT="${2:-}"; shift 2 ;;
            --disable-root-ssh)  DISABLE_ROOT_SSH="${2:-}"; shift 2 ;;
            --no-tweaks)         NO_TWEAKS=1; shift ;;
            -y|--yes)            ASSUME_YES=1; shift ;;
            -h|--help)           usage; exit 0 ;;
            *)                   die "неизвестная опция: $1  (см. --help)" ;;
        esac
    done

    require_root || exit 1
    detect_os || exit 1
    os_supported || exit 1

    validate_username "$NEW_USER" || exit 1
    [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] && (( 10#$NEW_SSH_PORT >= 1 && 10#$NEW_SSH_PORT <= 65535 )) \
        || die "SSH-порт вне диапазона 1..65535: $NEW_SSH_PORT"
    case "$DISABLE_ROOT_SSH" in
        yes|no) ;;
        *) die "--disable-root-ssh ожидает yes|no: $DISABLE_ROOT_SSH" ;;
    esac

    log_ok "ОС: ${OS_ID} ${OS_VERSION_ID} (${OS_CODENAME})"
    SERVER_ADDR=$(detect_server_addr)
    OLD_SSH_PORT=$(detect_current_ssh_port)
    log "текущий SSH-порт: $OLD_SSH_PORT"

    if [[ "$NO_TWEAKS" -eq 0 ]]; then
        cleanup_system
    else
        log "Чистка лишних пакетов пропущена (--no-tweaks)."
    fi

    apt_upgrade_system
    read_password
    create_sudo_user "$NEW_USER" "$NEW_PASSWORD"
    ufw_setup "$OLD_SSH_PORT" "$NEW_SSH_PORT"
    apply_ssh_port "$NEW_SSH_PORT"

    # После смены порта: jail для sshd читает порт из конфига при рестарте, а
    # sysctl с форвардингом должен лечь до того, как машину перезагрузят.
    if [[ "$NO_TWEAKS" -eq 0 ]]; then
        optimize_system
        setup_fail2ban || log_warn "fail2ban не настроен"
    else
        log "Тюнинг системы пропущен (--no-tweaks)."
    fi
    apply_sysctl_profile

    if [[ "$DISABLE_ROOT_SSH" == "yes" ]]; then
        if confirm_new_access "$SERVER_ADDR" "$NEW_SSH_PORT" "$NEW_USER"; then
            disable_root_ssh "$NEW_SSH_PORT"
            close_old_port "$OLD_SSH_PORT" "$NEW_SSH_PORT"
        else
            log_warn "доступ не подтверждён — root остаётся включён, старый порт открыт"
        fi
    else
        close_old_port "$OLD_SSH_PORT" "$NEW_SSH_PORT"
    fi

    SUMMARY_FILE="/home/${NEW_USER}/awg3-bootstrap-summary.txt"
    [[ -d "/home/${NEW_USER}" ]] || SUMMARY_FILE="/root/awg3-bootstrap-summary.txt"
    write_summary "$SUMMARY_FILE"

    printf '\n'
    cat "$SUMMARY_FILE"
    log_ok "готово, итог сохранён: $SUMMARY_FILE"
}

if [[ "${BOOTSTRAP_LIB_ONLY:-0}" -ne 1 && "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
