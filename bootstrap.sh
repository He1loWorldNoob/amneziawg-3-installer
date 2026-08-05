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
reboot_required() {
    local marker="${1:-/var/run/reboot-required}"
    [[ -f "$marker" ]]
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

usage() {
    cat <<EOF
bootstrap.sh ${BOOTSTRAP_VERSION} — подготовка сервера перед установкой AmneziaWG

ИСПОЛЬЗОВАНИЕ
    bootstrap.sh [опции]

ОПЦИИ
        --user NAME           имя нового sudo-пользователя  (по умолч.: ${NEW_USER})
        --password-file FILE  файл с паролем первой строкой
        --ssh-port N          новый порт SSH                (по умолч.: ${NEW_SSH_PORT})
        --disable-root-ssh yes|no
                              отключить вход root по SSH    (по умолч.: ${DISABLE_ROOT_SSH})
    -y, --yes                 не задавать вопросов
    -h, --help                эта справка

ПРИМЕЧАНИЯ
    Пароль нельзя передать аргументом: аргументы видны в ps и попадают в
    историю shell. Только --password-file или интерактивный ввод.

    Старый и новый порты SSH открыты одновременно; старый закрывается лишь
    после того, как вы подтвердите работу нового доступа.
EOF
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user)              NEW_USER="${2:-}"; shift 2 ;;
            --password-file)     PASSWORD_FILE="${2:-}"; shift 2 ;;
            --ssh-port)          NEW_SSH_PORT="${2:-}"; shift 2 ;;
            --disable-root-ssh)  DISABLE_ROOT_SSH="${2:-}"; shift 2 ;;
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

    apt_upgrade_system
    read_password
    create_sudo_user "$NEW_USER" "$NEW_PASSWORD"
    ufw_setup "$OLD_SSH_PORT" "$NEW_SSH_PORT"
    apply_ssh_port "$NEW_SSH_PORT"

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
