#!/usr/bin/env bash
#
# awg3.sh — AmneziaWG 3.0: сервер с нуля, клиенты, перевод конфигов на 3.0.
#
# Самодостаточный файл, без внешних библиотек:
#   * создание сервера сразу в 3.0 (ключи, NAT, обфускация, awg0.conf);
#   * создание клиента (ключи, свободный IP, [Peer] в awg0.conf, apply, QR);
#   * генерация параметров обфускации AWG 3.0.
#
# Каждый клиент держит свои файлы в собственном каталоге ~/awg/ИМЯ/ — конфиг,
# QR и пару ключей рядом, чтобы отдать клиента целиком одной папкой.
#
#   ./awg3.sh server-init            # поднять сервер AWG 3.0 с нуля
#   ./awg3.sh add ivan2              # новый клиент сразу в AWG 3.0
#   ./awg3.sh list                   # клиенты и фактическое состояние сервера
#   ./awg3.sh migrate                # разложить старых клиентов по каталогам
#   ./awg3.sh gen                    # просто выдать набор параметров
#   ./awg3.sh server-upgrade         # перевести существующий 2.0-сервер на 3.0
#
# ЕДИНСТВЕННЫЙ источник истины — /etc/amnezia/amneziawg/awg0.conf. Отдельного
# файла настроек нет: порт, подсеть, MTU, изоляция клиентов и IPv6 читаются из
# самого конфига, поэтому расходиться с реальностью нечему.
#
# Общие параметры (S1-S4, H1-H4, HeaderProtectionKey) клиент обязан повторить
# за сервером. Остальное (Jc, Jmin, Jmax, I1-I5, ContentPaddingAddition,
# таймеры) — sender-side, генерируется для каждого клиента заново: одинаковые
# наборы у всех устройств сами по себе являются отпечатком.
#
# Лицензия: MIT.

# -E нужен, чтобы ERR-ловушка отката работала и внутри функций.
set -Eeuo pipefail

# Версия самого скрипта. Не путать с версией протокола: в исходном awg-gen.sh
# она задавалась флагом -v (1.0|1.5|2.0|3.0), здесь же выбора нет — генерируется
# всегда AWG 3.0, а более старые режимы не поддерживаются намеренно.
SCRIPT_VERSION="1.2.0"
readonly AWG_PROTOCOL="3.0"

# ── Пути ────────────────────────────────────────────────────────────────────
#
# Переопределяются переменными окружения — этим же пользуется прогон на копии
# конфига, чтобы не трогать рабочий сервер.

# readlink -f обязателен: скрипт вызывается через симлинк /usr/local/sbin/awg3,
# и без разыменования SCRIPT_DIR указал бы на /usr/local/sbin — каталог, где
# нет ни одного клиента.
SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
AWG_DIR="${AWG3_DIR:-$SCRIPT_DIR}"
SERVER_CONF="${AWG3_SERVER_CONF:-/etc/amnezia/amneziawg/awg0.conf}"
LOG_FILE="$AWG_DIR/awg3.log"
AWG_IFACE="${AWG3_IFACE:-awg0}"

# Раскладка файлов: каждый клиент живёт в своём каталоге.
#
#   ~/awg/ИМЯ/ИМЯ.conf     ~/awg/ИМЯ/ИМЯ.private
#   ~/awg/ИМЯ/ИМЯ.png      ~/awg/ИМЯ/ИМЯ.public
#
# Прежняя плоская раскладка (~/awg/ИМЯ.conf + ~/awg/keys/ИМЯ.private) ещё
# читается, чтобы list и remove работали до переноса; `awg3.sh migrate`
# перекладывает всё на новую схему.

LEGACY_KEYS_DIR="$AWG_DIR/keys"

client_dir() { printf '%s/%s' "$AWG_DIR" "$1"; }

# Путь к конфигу клиента: новая схема в приоритете, затем старая. Для
# несуществующего клиента возвращается путь по новой схеме — туда и создаём.
client_conf_path() {
    local name="$1"
    if [[ -f "$AWG_DIR/$name/$name.conf" ]]; then
        printf '%s/%s/%s.conf' "$AWG_DIR" "$name" "$name"
    elif [[ -f "$AWG_DIR/$name.conf" ]]; then
        printf '%s/%s.conf' "$AWG_DIR" "$name"
    else
        printf '%s/%s/%s.conf' "$AWG_DIR" "$name" "$name"
    fi
}

# ── Значения по умолчанию ───────────────────────────────────────────────────

PROFILE="quic"
INTENSITY="medium"
ROUTER_MODE=0
ENDPOINT_OVERRIDE=""
CLIENT_DNS="1.1.1.1, 1.0.0.1"
CLIENT_ALLOWED_IPS="0.0.0.0/0, ::/0"
# Задан ли список явно флагом: если да, он уважается как есть, даже когда
# IPv6-маршруты клиенту не нужны.
CLIENT_ALLOWED_IPS_EXPLICIT=0
MTU_OVERRIDE=""
MAKE_QR=1
DO_APPLY=1
ASSUME_YES=0
PRUNE_KEEP=""

# Параметры server-init. Пустой SRV_PORT означает «выбрать случайный»:
# предсказуемый порт сам по себе является признаком.
SRV_PORT=""
SRV_SUBNET="10.9.9.1/24"
SRV_MTU="1280"
SRV_ISOLATION="off"
SRV_IPV6="off"
SRV_IPV6_SUBNET="fddd:2c4:2c4:2c4::/64"
SRV_FORCE=0

# device/noise-types.go: HeaderCipherNonceSize. При включённой защите заголовка
# nonce читается из первых NONCE_SIZE байт padding'а, поэтому S1-S4 не могут
# быть короче.
readonly NONCE_SIZE=12
readonly S4_MAX=32

# ── Вывод ───────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'
    C_CYA=$'\033[0;36m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_CYA=""; C_OFF=""
fi

_log_file() {
    [[ -d "$AWG_DIR" ]] || return 0
    local existed=1
    [[ -f "$LOG_FILE" ]] || existed=0
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$LOG_FILE" 2>/dev/null || true
    # Скрипт работает под root, а каталог принадлежит admin: свежесозданный
    # лог иначе останется root-овым и станет недоступен на запись без sudo.
    if [[ "$existed" -eq 0 && -f "$LOG_FILE" ]]; then _fix_owner "$LOG_FILE"; fi
}

log()      { printf '%s\n' "$1"; _log_file INFO "$1"; }
log_ok()   { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_OFF" "$1"; _log_file INFO "$1"; }
log_warn() { printf '%s[WARN]%s %s\n' "$C_YEL" "$C_OFF" "$1" >&2; _log_file WARN "$1"; }
log_err()  { printf '%s[ERR ]%s %s\n' "$C_RED" "$C_OFF" "$1" >&2; _log_file ERROR "$1"; }
die()      { log_err "$1"; exit 1; }

# ── Энтропия ────────────────────────────────────────────────────────────────
#
# Значения берутся из /dev/urandom блоками, а не по одному процессу на число.
#
# Каждый helper присваивает переменную, а не печатает, и вызывающая сторона
# использует обычное присваивание вместо $( ). Это не стилистика: подстановка
# команд выполняется в подоболочке, поэтому курсор пула сдвигается у потомка и
# сбрасывается у родителя. Сделать иначе — получить одинаковые значения на
# последовательных выборках, то есть ровно тот отпечаток, ради устранения
# которого всё и затевалось.

RAND_POOL=()
RAND_IDX=0

_rand_refill() {
    local raw v
    raw=$(od -An -N4096 -tu4 -v < /dev/urandom | tr -s ' ' '\n') \
        || die "не читается /dev/urandom"

    RAND_POOL=()
    for v in $raw; do
        RAND_POOL+=("$v")
    done

    RAND_IDX=0
    [[ "${#RAND_POOL[@]}" -gt 0 ]] || die "пустой пул энтропии"
}

# _rand_u32 -> REPLY: одно равномерное 32-битное значение.
_rand_u32() {
    if [[ "$RAND_IDX" -ge "${#RAND_POOL[@]}" ]]; then
        _rand_refill
    fi
    REPLY=${RAND_POOL[$RAND_IDX]}
    RAND_IDX=$((RAND_IDX + 1))
}

# rand_int LO HI -> REPLY: равномерное целое в [LO, HI].
# Rejection sampling, иначе остаток от деления перекашивает низ диапазона.
rand_int() {
    local lo=$1 hi=$2 span limit
    span=$((hi - lo + 1))
    [[ "$span" -gt 0 ]] || die "rand_int: пустой диапазон ${lo}..${hi}"

    limit=$(( (4294967296 / span) * span - 1 ))

    while :; do
        _rand_u32
        if [[ "$REPLY" -le "$limit" ]]; then
            REPLY=$(( lo + REPLY % span ))
            return
        fi
    done
}

# rand_hex N -> RAND_HEX: N случайных байт в нижнем регистре hex.
RAND_HEX=""
rand_hex() {
    local n=$1 i byte
    RAND_HEX=""
    for (( i = 0; i < n; i++ )); do
        rand_int 0 255
        printf -v byte '%02x' "$REPLY"
        RAND_HEX="${RAND_HEX}${byte}"
    done
}

# rand_b64_32 -> RAND_B64: 32 случайных байта в base64 — кодировка ключей .conf.
RAND_B64=""
rand_b64_32() {
    local i byte bin=""
    for (( i = 0; i < 32; i++ )); do
        rand_int 0 255
        printf -v byte '\\x%02x' "$REPLY"
        bin="${bin}${byte}"
    done

    if command -v base64 >/dev/null 2>&1; then
        RAND_B64=$(printf '%b' "$bin" | base64 | tr -d '\n')
    elif command -v openssl >/dev/null 2>&1; then
        RAND_B64=$(printf '%b' "$bin" | openssl base64 | tr -d '\n')
    else
        die "для HeaderProtectionKey нужен base64 или openssl"
    fi
}

# ── Сигнатуры мимикрии ──────────────────────────────────────────────────────
#
# Справочник тегов (device/obf.go): <b hex> статические байты, <t> 32-битная
# метка времени, <r N> случайные байты, <rc N> случайные буквы,
# <rd N> случайные цифры.

CHAIN=""
cps_chain() {
    local profile=$1 iv=$2 a b pad

    case "$profile" in
        quic)
            # QUIC long header: байт типа с установленным fixed bit, версия 1,
            # затем connection ID.
            rand_hex 8
            rand_int 8 20; a=$REPLY
            CHAIN="<b 0xc00000000108${RAND_HEX}><rc ${a}><t>"
            ;;
        tls)
            # Заголовок TLS-записи вокруг байта handshake'а ClientHello.
            rand_hex 2
            rand_int 24 48; a=$REPLY
            CHAIN="<b 0x160303${RAND_HEX}01><r ${a}><t>"
            ;;
        dtls)
            # DTLS 1.2 handshake record.
            rand_hex 6
            rand_int 20 40; a=$REPLY
            CHAIN="<b 0x16fefd${RAND_HEX}><r ${a}><t>"
            ;;
        sip)
            # Печатаемая преамбула: "OPTIONS sip:" в ASCII.
            rand_int 10 18; a=$REPLY
            rand_int 4 8;   b=$REPLY
            CHAIN="<b 0x4f5054494f4e53207369703a><rc ${a}><rd ${b}><t>"
            ;;
        dns)
            # Заголовок DNS-запроса: transaction id, флаги обычного запроса,
            # QDCOUNT=1 и обнулённые остальные счётчики.
            rand_hex 2
            rand_int 6 14; a=$REPLY
            rand_int 2 4;  b=$REPLY
            CHAIN="<b 0x${RAND_HEX}01000001000000000000><rc ${a}><rd ${b}>"
            ;;
        noise)
            rand_int 40 90; a=$REPLY
            CHAIN="<r ${a}><t>"
            ;;
        *)
            die "неизвестный профиль: ${profile}"
            ;;
    esac

    rand_int $((20 * iv)) $((60 * iv)); pad=$REPLY
    if [[ "$pad" -gt 1000 ]]; then pad=1000; fi
    CHAIN="${CHAIN}<r ${pad}>"
}

# entropy_chain IV -> CHAIN: наполнитель для I2..I5.
entropy_chain() {
    local iv=$1 a b c hexlen

    rand_int 6 16;  a=$REPLY
    rand_int 3 10;  hexlen=$REPLY
    rand_hex "$hexlen"
    rand_int 20 $((60 * iv)); b=$REPLY
    rand_int 3 8;   c=$REPLY

    CHAIN="<rc ${a}><b 0x${RAND_HEX}><t><r ${b}><rd ${c}>"
}

_intensity_value() {
    case "$INTENSITY" in
        low)    IV=1 ;;
        medium) IV=2 ;;
        high)   IV=3 ;;
    esac
}

# ── Генерация параметров ────────────────────────────────────────────────────
#
# gen_sender_params: то, что каждое устройство вправе иметь своё.
# Заполняет G_Jc G_Jmin G_Jmax G_I1..G_I5 G_CPA G_RA G_RT G_RJ G_KA G_MHA.

gen_sender_params() {
    local IV jc jmin jmax
    _intensity_value

    case "$INTENSITY" in
        low)    rand_int 64 256;  jmin=$REPLY; rand_int 256 512;  jmax=$REPLY ;;
        medium) rand_int 128 512; jmin=$REPLY; rand_int 512 1024; jmax=$REPLY ;;
        high)   rand_int 256 768; jmin=$REPLY; rand_int 768 1280; jmax=$REPLY ;;
    esac

    # Между границами нужен реальный разброс, иначе «случайная» длина таковой
    # не является.
    if [[ "$jmax" -le $((jmin + 64)) ]]; then
        rand_int 64 256
        jmax=$((jmin + 64 + REPLY))
    fi

    if [[ "$ROUTER_MODE" -eq 1 ]]; then
        rand_int 2 3; jc=$REPLY
        if [[ "$jmin" -gt 40 ]];  then jmin=40; fi
        if [[ "$jmax" -gt 128 ]]; then jmax=128; fi
    else
        rand_int 3 7; jc=$REPLY
    fi

    G_Jc=$jc; G_Jmin=$jmin; G_Jmax=$jmax

    cps_chain "$PROFILE" "$IV"; G_I1="$CHAIN"
    if [[ "$ROUTER_MODE" -eq 1 ]]; then
        G_I2=""; G_I3=""; G_I4=""; G_I5=""
    else
        entropy_chain "$IV"; G_I2="$CHAIN"
        entropy_chain "$IV"; G_I3="$CHAIN"
        entropy_chain "$IV"; G_I4="$CHAIN"
        entropy_chain "$IV"; G_I5="$CHAIN"
    fi

    local cpa_lo cpa_hi
    if [[ "$ROUTER_MODE" -eq 1 ]]; then
        rand_int 4 16;  cpa_lo=$REPLY
        rand_int 8 24;  cpa_hi=$((cpa_lo + REPLY))
    else
        rand_int 16 64;  cpa_lo=$REPLY
        rand_int 16 120; cpa_hi=$((cpa_lo + REPLY))
    fi
    G_CPA="${cpa_lo}-${cpa_hi}"

    local rt_lo rt_hi ka_lo ka_hi ra_lo ra_hi rj_lo rj_hi at_lo at_hi
    rand_int 4 6;     rt_lo=$REPLY
    rand_int 1 4;     rt_hi=$((rt_lo + REPLY))
    rand_int 8 14;    ka_lo=$REPLY
    rand_int 2 8;     ka_hi=$((ka_lo + REPLY))
    rand_int 100 120; ra_lo=$REPLY
    rand_int 10 30;   ra_hi=$((ra_lo + REPLY))

    # RejectAfterTime обязан перекрывать RekeyAfterTime вместе с окнами
    # keepalive и rekey. Ниже этого принимающая сторона перестаёт обновлять
    # ключи, и сессия умирает по достижении дедлайна.
    rj_lo=$((ra_hi + ka_hi + rt_hi + 15))
    if [[ "$rj_lo" -lt 170 ]]; then rj_lo=170; fi
    rand_int 10 30;   rj_hi=$((rj_lo + REPLY))

    rand_int 12 18;   at_lo=$REPLY
    rand_int 2 10;    at_hi=$((at_lo + REPLY))

    G_RA="${ra_lo}-${ra_hi}"
    G_RT="${rt_lo}-${rt_hi}"
    G_RJ="${rj_lo}-${rj_hi}"
    G_KA="${ka_lo}-${ka_hi}"
    G_MHA="${at_lo}-${at_hi}"
}

# gen_shared_params: то, что обязано совпадать на обоих концах.
# Заполняет G_S1..G_S4 G_H1..G_H4 G_HPK.
gen_shared_params() {
    local s1 s2 s3 s4
    local h1_lo h1_hi h2_lo h2_hi h3_lo h3_hi h4_lo h4_hi

    if [[ "$ROUTER_MODE" -eq 1 ]]; then
        rand_int 1 20; s1=$REPLY
        rand_int 1 20; s2=$REPLY
    else
        rand_int 1 150; s1=$REPLY
        rand_int 1 150; s2=$REPLY
    fi
    rand_int 1 64; s3=$REPLY
    rand_int 1 "$S4_MAX"; s4=$REPLY

    # Защита заголовка в 3.0 берёт nonce из этого padding'а, поэтому он не
    # может быть короче nonce.
    if [[ "$s1" -lt "$NONCE_SIZE" ]]; then s1=$NONCE_SIZE; fi
    if [[ "$s2" -lt "$NONCE_SIZE" ]]; then s2=$NONCE_SIZE; fi
    if [[ "$s3" -lt "$NONCE_SIZE" ]]; then s3=$NONCE_SIZE; fi
    if [[ "$s4" -lt "$NONCE_SIZE" ]]; then s4=$NONCE_SIZE; fi

    # len(init) = 148 + S1, len(resp) = 92 + S2. Равные размеры вернули бы
    # отпечаток обратно.
    if [[ "$s2" -eq $((s1 + 56)) ]]; then s2=$((s2 + 1)); fi
    if [[ "$s3" -eq $((s1 + 56)) ]]; then s3=$((s3 + 1)); fi
    if [[ "$s3" -eq $((s2 + 92)) ]]; then s3=$((s3 + 1)); fi
    if [[ "$s4" -gt "$S4_MAX" ]]; then s4=$S4_MAX; fi

    # Четыре непересекающиеся зоны, все в стороне от 1-4, которые upstream
    # WireGuard резервирует под свои типы сообщений. Каждая граница берётся
    # отдельно, чтобы диапазоны не повторяли форму друг друга.
    rand_int 100000000 900000000;   h1_lo=$REPLY
    rand_int 1000 50000;            h1_hi=$((h1_lo + REPLY))
    rand_int 1200000000 2000000000; h2_lo=$REPLY
    rand_int 1000 50000;            h2_hi=$((h2_lo + REPLY))
    rand_int 2400000000 3200000000; h3_lo=$REPLY
    rand_int 1000 50000;            h3_hi=$((h3_lo + REPLY))
    rand_int 3600000000 4000000000; h4_lo=$REPLY
    rand_int 1000 50000;            h4_hi=$((h4_lo + REPLY))

    G_S1=$s1; G_S2=$s2; G_S3=$s3; G_S4=$s4
    G_H1="${h1_lo}-${h1_hi}"; G_H2="${h2_lo}-${h2_hi}"
    G_H3="${h3_lo}-${h3_hi}"; G_H4="${h4_lo}-${h4_hi}"
    rand_b64_32; G_HPK="$RAND_B64"
}

# ── Чтение серверного конфига ───────────────────────────────────────────────

# Значение ключа из секции [Interface] (до первого [Peer]).
_iface_value() {
    local key="$1"
    awk -v k="$key" '
        /^[[:space:]]*\[Peer\]/ { exit }
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (index(line, "#") == 1) next
            split(line, kv, "=")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", kv[1])
            if (kv[1] == k) {
                sub(/^[^=]*=[[:space:]]*/, "", line)
                gsub(/[[:space:]]+$/, "", line)
                print line
                exit
            }
        }
    ' "$SERVER_CONF"
}

# Заполняет S_S1..S_S4 S_H1..S_H4 S_HPK S_MTU S_PORT S_ADDR S_ADDR6.
load_server_params() {
    [[ -r "$SERVER_CONF" ]] || die "серверный конфиг недоступен: $SERVER_CONF"

    S_S1=$(_iface_value S1); S_S2=$(_iface_value S2)
    S_S3=$(_iface_value S3); S_S4=$(_iface_value S4)
    S_H1=$(_iface_value H1); S_H2=$(_iface_value H2)
    S_H3=$(_iface_value H3); S_H4=$(_iface_value H4)
    S_HPK=$(_iface_value HeaderProtectionKey)
    S_MTU=$(_iface_value MTU)
    S_PORT=$(_iface_value ListenPort)

    local addr_line
    addr_line=$(_iface_value Address)
    S_ADDR=""; S_ADDR6=""
    local part
    IFS=',' read -ra _addr_parts <<< "$addr_line"
    for part in "${_addr_parts[@]}"; do
        part="${part//[[:space:]]/}"
        [[ -z "$part" ]] && continue
        if [[ "$part" == *:* ]]; then
            if [[ -z "$S_ADDR6" ]]; then S_ADDR6="$part"; fi
        else
            if [[ -z "$S_ADDR" ]]; then S_ADDR="$part"; fi
        fi
    done

    [[ -n "$S_ADDR" ]] || die "в $SERVER_CONF не найден IPv4 Address сервера"
    [[ -n "$S_PORT" ]] || die "в $SERVER_CONF не найден ListenPort"
}

server_is_awg3() {
    [[ -n "${S_HPK:-}" ]]
}

# Фактическое состояние сервера читается из PostUp, а не из отдельного файла
# настроек: конфиг — единственный источник истины, и расходиться с ним нечему.
server_isolation_state() {
    if grep -qE 'FORWARD -i %i -o %i -j DROP' "$SERVER_CONF" 2>/dev/null; then
        printf 'on'
    else
        printf 'off'
    fi
}

server_ipv6_state() {
    if grep -q 'ip6tables' "$SERVER_CONF" 2>/dev/null; then
        printf 'on'
    else
        printf 'off'
    fi
}

require_server_awg3() {
    if server_is_awg3; then return 0; fi
    log_err "сервер ещё не переведён на AWG 3.0: в $SERVER_CONF нет HeaderProtectionKey."
    log_err "Сначала выполните: $0 server-upgrade"
    exit 1
}

# ── Работа с IP ─────────────────────────────────────────────────────────────

_ipv4_to_int() {
    local a b c d IFS='.'
    read -r a b c d <<< "$1"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

_int_to_ipv4() {
    local i=$1
    echo "$(( (i >> 24) & 255 )).$(( (i >> 16) & 255 )).$(( (i >> 8) & 255 )).$(( i & 255 ))"
}

# Границы сети по CIDR -> "network broadcast".
_cidr_bounds() {
    local cidr="$1" ip prefix ip_int mask
    ip="${cidr%%/*}"; prefix="${cidr##*/}"
    [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    (( prefix >= 8 && prefix <= 30 )) || return 1
    ip_int=$(_ipv4_to_int "$ip")
    mask=$(( 0xFFFFFFFF << (32 - prefix) & 0xFFFFFFFF ))
    echo "$(( ip_int & mask )) $(( (ip_int & mask) | (~mask & 0xFFFFFFFF) ))"
}

# Наименьший свободный адрес в подсети сервера.
get_next_client_ip() {
    local net_int bcast_int
    read -r net_int bcast_int < <(_cidr_bounds "$S_ADDR") \
        || die "не разобрана подсеть сервера '$S_ADDR'"

    declare -A used
    used["$(_int_to_ipv4 $((net_int + 1)))"]=1
    local ip
    while IFS= read -r ip; do
        used["$ip"]=1
    done < <(grep -oP 'AllowedIPs\s*=\s*\K[0-9.]+' "$SERVER_CONF" 2>/dev/null || true)

    local i candidate
    for (( i = net_int + 2; i <= bcast_int - 1; i++ )); do
        candidate=$(_int_to_ipv4 "$i")
        if [[ -z "${used[$candidate]+x}" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    die "в подсети ${S_ADDR} нет свободных адресов"
}

# IPv6 клиента выводится из его IPv4 по смещению в подсети — уникальному при
# любой маске. Для /24 смещение равно последнему октету, иначе кодируется hex.
get_client_ipv6() {
    local ipv4="$1"
    [[ -n "${S_ADDR6:-}" ]] || return 0
    local net_int bcast_int offset suffix prefix tprefix
    read -r net_int bcast_int < <(_cidr_bounds "$S_ADDR") || return 0
    offset=$(( $(_ipv4_to_int "$ipv4") - net_int ))
    tprefix="${S_ADDR##*/}"
    if [[ "$tprefix" == "24" ]]; then suffix="$offset"; else suffix=$(printf '%x' "$offset"); fi
    prefix="${S_ADDR6%%::*}"
    [[ "$prefix" == *:* ]] || return 0
    echo "${prefix}::${suffix}"
}

# ── Валидация параметров сервера ────────────────────────────────────────────

# Десятичный порт 1..65535.
#
# 10# обязательно: без него "08" трактуется как битое восьмеричное число и
# роняет арифметику под set -e.
validate_awg_port() {
    local p="${1:-}"
    [[ "$p" =~ ^[0-9]+$ ]] || { log_err "порт не число: '$p'"; return 1; }
    local n=$((10#$p))
    (( n >= 1 && n <= 65535 )) || { log_err "порт вне диапазона 1..65535: $p"; return 1; }
    return 0
}

# Адрес ХОСТА с префиксом 8..30.
#
# Именно хоста: в awg0.conf это Address самого сервера, и адрес сети или
# broadcast там означал бы неработающий интерфейс.
validate_subnet() {
    local cidr="${1:-}" ip prefix o
    [[ "$cidr" == */* ]] || { log_err "подсеть без префикса: '$cidr'"; return 1; }
    ip="${cidr%%/*}"; prefix="${cidr##*/}"

    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || { log_err "не IPv4-адрес: '$ip'"; return 1; }

    local IFS='.'
    for o in $ip; do
        (( 10#$o <= 255 )) || { log_err "октет больше 255 в '$ip'"; return 1; }
    done
    unset IFS

    [[ "$prefix" =~ ^[0-9]+$ ]] && (( 10#$prefix >= 8 && 10#$prefix <= 30 )) \
        || { log_err "префикс вне диапазона 8..30: '$prefix'"; return 1; }

    local net_int bcast_int ip_int
    read -r net_int bcast_int < <(_cidr_bounds "$cidr") \
        || { log_err "не разобрана подсеть '$cidr'"; return 1; }
    ip_int=$(_ipv4_to_int "$ip")
    (( ip_int != net_int )) \
        || { log_err "'$ip' — адрес сети, нужен адрес хоста"; return 1; }
    (( ip_int != bcast_int )) \
        || { log_err "'$ip' — broadcast, нужен адрес хоста"; return 1; }
    return 0
}

validate_mtu() {
    local m="${1:-}"
    [[ "$m" =~ ^[0-9]+$ ]] || { log_err "MTU не число: '$m'"; return 1; }
    (( 10#$m >= 576 && 10#$m <= 9100 )) \
        || { log_err "MTU вне диапазона 576..9100: $m"; return 1; }
    return 0
}

# UDP-порт свободен? Отсутствие ss означает «проверить нечем» — не блокируем.
port_is_free() {
    local p="$1"
    command -v ss >/dev/null 2>&1 || return 0
    ! ss -Hulnp 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${p}\$"
}

# Интерфейс, через который сервер выходит наружу — цель MASQUERADE.
get_main_nic() {
    local nic
    nic=$(ip route get 1.1.1.1 2>/dev/null \
          | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    [[ -n "$nic" ]] || return 1
    printf '%s' "$nic"
}

# ── PostUp / PostDown ───────────────────────────────────────────────────────
#
# Правила перенесены из render_server_config апстрима (bivlked v5.23.0) без
# изменения семантики. %i раскрывается awg-quick в имя интерфейса.
#
# TCPMSS-clamping обязателен: путь до клиента уже съеден заголовками туннеля,
# и без правки MSS TCP-сессии зависают на больших пакетах там, где PMTUD
# упирается в чёрную дыру — та самая жалоба «ping идёт, а сайт не грузится».

# build_postup NIC MTU ISOLATION IPV6   (ISOLATION/IPV6: on|off)
build_postup() {
    local nic="$1" mtu="$2" isolation="$3" ipv6="$4"
    local mss4=$(( mtu - 40 )) mss6=$(( mtu - 60 ))
    local r

    r="iptables -I FORWARD -i %i -j ACCEPT"
    r="${r}; iptables -t nat -A POSTROUTING -o ${nic} -j MASQUERADE"
    r="${r}; iptables -t mangle -A FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss4}"
    r="${r}; iptables -t mangle -A FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss4}"

    if [[ "$isolation" == "on" ]]; then
        # Цикл, а не одиночное -D: прерванный прошлый запуск мог оставить
        # несколько одинаковых правил, снять нужно все.
        r="${r}; while iptables -D FORWARD -i %i -o %i -j DROP 2>/dev/null; do :; done"
        r="${r}; iptables -I FORWARD -i %i -o %i -j DROP"
    fi

    if [[ "$ipv6" == "on" ]]; then
        r="${r}; ip6tables -I FORWARD -i %i -j ACCEPT"
        r="${r}; ip6tables -t nat -A POSTROUTING -o ${nic} -j MASQUERADE"
        r="${r}; ip6tables -t mangle -A FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss6}"
        r="${r}; ip6tables -t mangle -A FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss6}"
        if [[ "$isolation" == "on" ]]; then
            r="${r}; while ip6tables -D FORWARD -i %i -o %i -j DROP 2>/dev/null; do :; done"
            r="${r}; ip6tables -I FORWARD -i %i -o %i -j DROP"
        fi
    fi

    printf '%s' "$r"
}

# build_postdown NIC MTU ISOLATION IPV6 — зеркало build_postup.
#
# DROP снимается с `|| true`: интерфейс может опускаться после того, как
# правило уже убрали вручную, и падать на этом PostDown не должен.
build_postdown() {
    local nic="$1" mtu="$2" isolation="$3" ipv6="$4"
    local mss4=$(( mtu - 40 )) mss6=$(( mtu - 60 ))
    local r

    r="iptables -D FORWARD -i %i -j ACCEPT"
    r="${r}; iptables -t nat -D POSTROUTING -o ${nic} -j MASQUERADE"
    r="${r}; iptables -t mangle -D FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss4}"
    r="${r}; iptables -t mangle -D FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss4}"

    if [[ "$isolation" == "on" ]]; then
        r="${r}; iptables -D FORWARD -i %i -o %i -j DROP 2>/dev/null || true"
    fi

    if [[ "$ipv6" == "on" ]]; then
        r="${r}; ip6tables -D FORWARD -i %i -j ACCEPT"
        r="${r}; ip6tables -t nat -D POSTROUTING -o ${nic} -j MASQUERADE"
        r="${r}; ip6tables -t mangle -D FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss6}"
        r="${r}; ip6tables -t mangle -D FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss6}"
        if [[ "$isolation" == "on" ]]; then
            r="${r}; ip6tables -D FORWARD -i %i -o %i -j DROP 2>/dev/null || true"
        fi
    fi

    printf '%s' "$r"
}

# ── Endpoint ────────────────────────────────────────────────────────────────
#
# Порядок: --endpoint > #_Endpoint из awg0.conf > Endpoint уже существующего
# клиента > внешний IP.
#
# Отдельного файла настроек нет — источник истины только awg0.conf, поэтому
# имя хоста хранится там же комментарием.

server_endpoint_name() {
    [[ -r "$SERVER_CONF" ]] || return 0
    awk '
        /^[[:space:]]*\[Peer\]/ { exit }
        /^[[:space:]]*#_Endpoint[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, "")
            gsub(/[[:space:]]+$/, "")
            print
            exit
        }
    ' "$SERVER_CONF"
}

resolve_endpoint() {
    if [[ -n "$ENDPOINT_OVERRIDE" ]]; then
        echo "${ENDPOINT_OVERRIDE%%:*}"
        return 0
    fi

    local saved
    saved=$(server_endpoint_name)
    if [[ -n "$saved" ]]; then
        echo "$saved"
        return 0
    fi

    local f ep url name
    while IFS= read -r name; do
        f=$(client_conf_path "$name")
        [[ -f "$f" ]] || continue
        ep=$(grep -oP '^Endpoint\s*=\s*\K[^:]+' "$f" 2>/dev/null | head -1 || true)
        if [[ -n "$ep" ]]; then echo "$ep"; return 0; fi
    done < <(list_client_names)

    for url in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
        ep=$(curl -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$ep" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then echo "$ep"; return 0; fi
    done

    die "не удалось определить endpoint, укажите его явно: --endpoint HOST"
}

# ── Служебное ───────────────────────────────────────────────────────────────

# Выбрасывает IPv6-подсети из списка AllowedIPs, сохраняя порядок остальных.
strip_ipv6_routes() {
    local list="$1" part out=""
    local IFS=','
    for part in $list; do
        part="${part#"${part%%[![:space:]]*}"}"
        part="${part%"${part##*[![:space:]]}"}"
        [[ -n "$part" ]] || continue
        [[ "$part" == *:* ]] && continue
        out="${out:+$out, }${part}"
    done
    printf '%s' "$out"
}

validate_client_name() {
    local name="$1"
    [[ -n "$name" ]] || die "имя клиента не задано"
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] \
        || die "недопустимое имя '$name': разрешены буквы, цифры, дефис и подчёркивание"
    [[ "${#name}" -le 32 ]] || die "имя длиннее 32 символов"
}

check_dependencies() {
    # Переменная цикла объявлена local: без этого она перетирает одноимённую
    # переменную вызывающей функции — область видимости в bash динамическая.
    local missing=() dep
    for dep in awg awg-quick flock od grep awk sed ip iptables; do
        command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
    done
    [[ "${#missing[@]}" -eq 0 ]] || die "нет обязательных команд: ${missing[*]}"
    [[ -r /dev/urandom ]] || die "/dev/urandom нечитаем"
    [[ "$EUID" -eq 0 ]] || die "нужны права root (sudo -i)"
}

# Файлы должны остаться у владельца каталога awg, иначе старый
# manage_amneziawg.sh, запущенный не под root, перестанет их читать.
_fix_owner() {
    local target="$1" owner
    owner=$(stat -c '%u:%g' "$AWG_DIR" 2>/dev/null) || return 0
    chown "$owner" "$target" 2>/dev/null || true
}

_backup_file() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    # Объявление отдельно от присваивания: иначе local маскирует код возврата
    # подстановки, и сбой date остался бы незамеченным.
    local bak
    bak="${f}.bak-$(date '+%Y%m%d%H%M%S')"
    cp -p "$f" "$bak" || die "не создан бэкап $bak"
    BACKUP_LAST="$bak"
    log_ok "бэкап: $bak"
}

confirm() {
    if [[ "$ASSUME_YES" -eq 1 ]]; then return 0; fi
    [[ -t 0 ]] || die "нужно подтверждение, а ввод не интерактивен — добавьте -y"
    local answer
    read -r -p "$1 [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

# ── Применение конфигурации ─────────────────────────────────────────────────
#
# syncconf переносит только список пиров: параметры самого интерфейса
# (S/H/HeaderProtectionKey) им не меняются, поэтому смена общих параметров
# требует полного перезапуска.

apply_peers() {
    [[ "$DO_APPLY" -eq 1 ]] || { log_warn "применение пропущено (--no-apply)"; return 0; }

    local fd
    exec {fd}>"$AWG_DIR/.awg_apply.lock"
    if ! flock -x -w 120 "$fd"; then
        exec {fd}>&-
        log_warn "не получен apply-lock, изменения записаны, но не применены"
        return 1
    fi

    local strip_out rc=0
    if strip_out=$(timeout 10 awg-quick strip "$AWG_IFACE" 2>/dev/null) \
       && printf '%s\n' "$strip_out" | timeout 10 awg syncconf "$AWG_IFACE" /dev/stdin 2>/dev/null; then
        log_ok "конфигурация применена (syncconf)"
    else
        log_warn "syncconf не сработал, перезапускаю сервис"
        systemctl restart "awg-quick@${AWG_IFACE}" 2>/dev/null || rc=$?
        [[ $rc -eq 0 ]] && log_ok "сервис перезапущен" || log_warn "ошибка перезапуска сервиса"
    fi
    exec {fd}>&-
    return $rc
}

apply_restart() {
    [[ "$DO_APPLY" -eq 1 ]] || { log_warn "применение пропущено (--no-apply)"; return 0; }
    local rc=0
    systemctl restart "awg-quick@${AWG_IFACE}" 2>/dev/null || rc=$?
    [[ $rc -eq 0 ]] && log_ok "сервис перезапущен" || log_warn "ошибка перезапуска сервиса"
    return $rc
}

# ── Рендер клиентского конфига ──────────────────────────────────────────────
#
# render_client_conf <файл> <privkey> <address> <server_pubkey> <endpoint>
#                    <port> [psk]
#
# Общие параметры берутся из S_*, sender-side — из G_*, поэтому вызывающая
# сторона обязана предварительно вызвать load_server_params и
# gen_sender_params.

render_client_conf() {
    local out="$1" privkey="$2" address="$3" srv_pub="$4" endpoint="$5" port="$6" psk="${7:-}"
    local mtu="${MTU_OVERRIDE:-${S_MTU:-1280}}"

    local tmp
    tmp=$(mktemp "${out}.tmp.XXXXXX") || die "mktemp не сработал"
    chmod 600 "$tmp"

    {
        printf '[Interface]\n'
        printf 'PrivateKey = %s\n' "$privkey"
        printf 'Address = %s\n' "$address"
        printf 'DNS = %s\n' "$CLIENT_DNS"
        printf 'MTU = %s\n' "$mtu"
        printf '\n'
        printf 'S1 = %s\nS2 = %s\nS3 = %s\nS4 = %s\n' "$S_S1" "$S_S2" "$S_S3" "$S_S4"
        printf 'H1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n' "$S_H1" "$S_H2" "$S_H3" "$S_H4"
        printf 'HeaderProtectionKey = %s\n' "$S_HPK"
        printf 'ContentPaddingAddition = %s\n' "$G_CPA"
        printf 'Jc = %s\nJmin = %s\nJmax = %s\n' "$G_Jc" "$G_Jmin" "$G_Jmax"
        local n
        for n in 1 2 3 4 5; do
            local var="G_I${n}"
            if [[ -n "${!var}" ]]; then printf 'I%s = %s\n' "$n" "${!var}"; fi
        done
        printf 'RekeyAfterTime = %s\n' "$G_RA"
        printf 'RekeyTimeout = %s\n' "$G_RT"
        printf 'RejectAfterTime = %s\n' "$G_RJ"
        printf 'KeepaliveTimeout = %s\n' "$G_KA"
        printf 'MaxHandshakeAttempts = %s\n' "$G_MHA"
        printf '\n'
        printf '[Peer]\n'
        printf 'PublicKey = %s\n' "$srv_pub"
        if [[ -n "$psk" ]]; then printf 'PresharedKey = %s\n' "$psk"; fi
        printf 'Endpoint = %s:%s\n' "$endpoint" "$port"
        printf 'AllowedIPs = %s\n' "$CLIENT_ALLOWED_IPS"
        printf 'PersistentKeepalive = 33\n'
    } > "$tmp"

    mv -f "$tmp" "$out" || { rm -f "$tmp"; die "не записан $out"; }
    chmod 600 "$out"
    _fix_owner "$out"
}

# ── Рендер серверного конфига ───────────────────────────────────────────────

generate_server_keys() {
    local priv pub
    priv=$(awg genkey) || die "не сгенерирован приватный ключ сервера"
    pub=$(printf '%s' "$priv" | awg pubkey) || die "не выведен публичный ключ сервера"

    ( umask 077; printf '%s\n' "$priv" > "$AWG_DIR/server_private.key" ) \
        || die "не записан server_private.key"
    ( umask 077; printf '%s\n' "$pub" > "$AWG_DIR/server_public.key" ) \
        || die "не записан server_public.key"
    chmod 600 "$AWG_DIR/server_private.key" "$AWG_DIR/server_public.key"
    _fix_owner "$AWG_DIR/server_private.key"
    _fix_owner "$AWG_DIR/server_public.key"
    log_ok "ключи сервера созданы"
}

# Адрес сервера в IPv6-подсети — первый адрес, ::1.
derive_ipv6_server_addr() {
    local subnet="$1" prefix len
    prefix="${subnet%%/*}"; len="${subnet##*/}"
    prefix="${prefix%::}"
    printf '%s::1/%s' "$prefix" "$len"
}

# Все блоки [Peer] из файла: от первого до конца либо до следующего
# [Interface], который в норме встречается только в начале.
extract_peers() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    awk '
        /^[[:space:]]*\[Peer\]/      { in_peer = 1 }
        /^[[:space:]]*\[Interface\]/ { in_peer = 0 }
        in_peer { print }
    ' "$f"
}

# render_server_conf OUT PRIVKEY ADDRESS PORT MTU POSTUP POSTDOWN [PEERS_SRC]
#
# Общие параметры берутся из G_S*/G_H*/G_HPK, отправительские — из G_Jc,
# G_Jmin, G_Jmax, G_I1..G_I5, G_CPA, поэтому вызывающая сторона обязана
# заранее вызвать gen_shared_params и gen_sender_params.
#
# Пиры дописываются во ВРЕМЕННЫЙ файл до mv: иначе сбой между записью конфига
# и добавлением пиров оставил бы живой сервер без единого клиента.
render_server_conf() {
    local out="$1" privkey="$2" address="$3" port="$4" mtu="$5"
    local postup="$6" postdown="$7" peers_src="${8:-}"

    local dir tmp
    dir=$(dirname "$out")
    mkdir -p "$dir" || die "не создан каталог $dir"
    chmod 700 "$dir" 2>/dev/null || true

    tmp=$(mktemp "${out}.tmp.XXXXXX") || die "mktemp не сработал"
    chmod 600 "$tmp"

    {
        printf '[Interface]\n'
        # Имя хоста для клиентских Endpoint. Хранится комментарием в самом
        # конфиге, как и #_Name у пиров: отдельного файла настроек нет, а
        # выводить DNS-имя из адреса интерфейса неоткуда.
        if [[ -n "${ENDPOINT_OVERRIDE:-}" ]]; then
            printf '#_Endpoint = %s\n' "${ENDPOINT_OVERRIDE%%:*}"
        fi
        printf 'PrivateKey = %s\n' "$privkey"
        printf 'Address = %s\n' "$address"
        printf 'ListenPort = %s\n' "$port"
        printf 'MTU = %s\n' "$mtu"
        printf 'PostUp = %s\n' "$postup"
        printf 'PostDown = %s\n' "$postdown"
        printf '\n'
        printf 'S1 = %s\nS2 = %s\nS3 = %s\nS4 = %s\n' "$G_S1" "$G_S2" "$G_S3" "$G_S4"
        printf 'H1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n' "$G_H1" "$G_H2" "$G_H3" "$G_H4"
        printf 'HeaderProtectionKey = %s\n' "$G_HPK"
        printf 'ContentPaddingAddition = %s\n' "$G_CPA"
        printf 'Jc = %s\nJmin = %s\nJmax = %s\n' "$G_Jc" "$G_Jmin" "$G_Jmax"
        local n var
        for n in 1 2 3 4 5; do
            var="G_I${n}"
            if [[ -n "${!var}" ]]; then printf 'I%s = %s\n' "$n" "${!var}"; fi
        done
    } > "$tmp"

    if [[ -n "$peers_src" && -f "$peers_src" ]]; then
        local peers
        peers=$(extract_peers "$peers_src")
        if [[ -n "$peers" ]]; then
            printf '\n%s\n' "$peers" >> "$tmp"
        fi
    fi

    mv -f "$tmp" "$out" || { rm -f "$tmp"; die "не записан $out"; }
    chmod 600 "$out"
    _fix_owner "$out"
}

# generate_qr <имя> <путь к conf> — PNG кладётся рядом с конфигом.
generate_qr() {
    local name="$1" conf="$2"
    [[ "$MAKE_QR" -eq 1 ]] || return 0
    if ! command -v qrencode >/dev/null 2>&1; then
        log_warn "qrencode не установлен, QR-код для '$name' не создан"
        return 0
    fi
    local png="${conf%.conf}.png" tmp
    tmp=$(mktemp "${png}.tmp.XXXXXX") || return 1
    if qrencode -t png -o "$tmp" < "$conf"; then
        chmod 600 "$tmp"
        mv -f "$tmp" "$png"
        _fix_owner "$png"
        log_ok "QR-код: $png"
    else
        rm -f "$tmp"
        log_warn "не удалось создать QR-код для '$name'"
    fi
}

# Публичный ключ сервера: из сохранённого файла, иначе выводится из приватного.
server_public_key() {
    if [[ -r "$AWG_DIR/server_public.key" ]]; then
        tr -d '[:space:]' < "$AWG_DIR/server_public.key"
        return 0
    fi
    local priv
    priv=$(_iface_value PrivateKey)
    [[ -n "$priv" ]] || die "в $SERVER_CONF нет PrivateKey"
    printf '%s' "$priv" | awg pubkey
}

# ── Команда: server-init ────────────────────────────────────────────────────
#
# Создание сервера AWG 3.0 с нуля: ключи, параметры обфускации, NAT, конфиг,
# форвардинг. Промежуточной стадии 2.0 не существует, server-upgrade здесь не
# участвует — он остаётся только для уже существующих 2.0-серверов.

guard_existing_server() {
    if [[ -f "$SERVER_CONF" && "$SRV_FORCE" -ne 1 ]]; then
        log_err "сервер уже существует: $SERVER_CONF"
        log_err "Пересоздать с переносом пиров: $0 server-init --force"
        return 1
    fi
    return 0
}

# enable_forwarding IPV6 FILE — форвардинг через sysctl.d плюс немедленно.
enable_forwarding() {
    local ipv6="$1" file="$2"
    {
        printf '# Создано awg3.sh server-init.\n'
        printf 'net.ipv4.ip_forward = 1\n'
        if [[ "$ipv6" == "on" ]]; then
            printf 'net.ipv6.conf.all.forwarding = 1\n'
        fi
    } > "$file" || { log_err "не записан $file"; return 1; }
    chmod 644 "$file"

    if command -v sysctl >/dev/null 2>&1; then
        sysctl -q -p "$file" 2>/dev/null \
            || log_warn "sysctl не применил $file, потребуется перезагрузка"
    fi
    return 0
}

cmd_server_init() {
    guard_existing_server || exit 1

    [[ -n "$SRV_PORT" ]] || { rand_int 1024 65000; SRV_PORT=$REPLY; }
    validate_awg_port "$SRV_PORT" || exit 1
    validate_subnet   "$SRV_SUBNET" || exit 1
    validate_mtu      "$SRV_MTU"    || exit 1
    port_is_free "$SRV_PORT" || die "UDP-порт $SRV_PORT уже занят"

    local nic
    nic=$(get_main_nic) \
        || die "не определён внешний интерфейс — проверьте маршрут по умолчанию"
    log "внешний интерфейс: $nic"

    local peers_src=""
    if [[ -f "$SERVER_CONF" ]]; then
        # Имя хоста переживает пересоздание сервера: клиенты продолжат
        # подключаться по тому же адресу, если его не задали заново.
        if [[ -z "${ENDPOINT_OVERRIDE:-}" ]]; then
            ENDPOINT_OVERRIDE=$(server_endpoint_name)
            [[ -z "$ENDPOINT_OVERRIDE" ]] || log "имя хоста сохранено: $ENDPOINT_OVERRIDE"
        fi
        _backup_file "$SERVER_CONF"
        peers_src="$BACKUP_LAST"
    fi

    ROLLBACK_SERVER_BAK="$peers_src"
    ROLLBACK_ACTIVE=1
    trap '_rollback_server_init' EXIT

    mkdir -p "$AWG_DIR"; chmod 700 "$AWG_DIR"; _fix_owner "$AWG_DIR"
    generate_server_keys

    local address="$SRV_SUBNET"
    if [[ "$SRV_IPV6" == "on" ]]; then
        address="${address}, $(derive_ipv6_server_addr "$SRV_IPV6_SUBNET")"
    fi

    gen_shared_params
    gen_sender_params

    local postup postdown
    postup=$(build_postup     "$nic" "$SRV_MTU" "$SRV_ISOLATION" "$SRV_IPV6")
    postdown=$(build_postdown "$nic" "$SRV_MTU" "$SRV_ISOLATION" "$SRV_IPV6")

    local privkey
    privkey=$(tr -d '[:space:]' < "$AWG_DIR/server_private.key")

    render_server_conf "$SERVER_CONF" "$privkey" "$address" \
        "$SRV_PORT" "$SRV_MTU" "$postup" "$postdown" "$peers_src"

    enable_forwarding "$SRV_IPV6" /etc/sysctl.d/99-awg3.conf \
        || log_warn "форвардинг не настроен"

    ROLLBACK_ACTIVE=0
    trap - EXIT

    if [[ "$DO_APPLY" -eq 1 ]]; then
        systemctl enable --now "awg-quick@${AWG_IFACE}" 2>/dev/null \
            || log_warn "сервис не запустился, смотрите: systemctl status awg-quick@${AWG_IFACE}"
    fi

    log_ok "сервер AWG 3.0 создан: $SERVER_CONF"
    log "  порт: ${SRV_PORT}/udp, подсеть: ${SRV_SUBNET}, MTU: ${SRV_MTU}"
    log "  изоляция клиентов: ${SRV_ISOLATION}, IPv6: ${SRV_IPV6}"
    log "  добавить клиента: $0 add ИМЯ"
}

# Ловушка висит на EXIT, а не на ERR: die() выходит через exit, и ERR на нём
# не срабатывает.
_rollback_server_init() {
    local rc=$?
    if [[ "${ROLLBACK_ACTIVE:-0}" -ne 1 ]]; then return 0; fi
    ROLLBACK_ACTIVE=0
    log_err "сбой при создании сервера — откатываю"
    rm -f "$AWG_DIR/server_private.key" "$AWG_DIR/server_public.key" 2>/dev/null || true
    if [[ -n "${ROLLBACK_SERVER_BAK:-}" && -f "$ROLLBACK_SERVER_BAK" ]]; then
        if cp -p "$ROLLBACK_SERVER_BAK" "$SERVER_CONF"; then
            log_ok "прежний конфиг восстановлен"
        fi
    else
        rm -f "$SERVER_CONF" 2>/dev/null || true
    fi
    if [[ "$rc" -eq 0 ]]; then rc=1; fi
    exit "$rc"
}

# ── Команда: add ────────────────────────────────────────────────────────────

cmd_add() {
    local name="$1"
    validate_client_name "$name"
    load_server_params
    require_server_awg3

    local cdir conf
    cdir=$(client_dir "$name")
    conf="$cdir/${name}.conf"

    [[ ! -f "$conf" ]] || die "клиент '$name' уже существует: $conf"
    [[ ! -f "$AWG_DIR/${name}.conf" ]] \
        || die "клиент '$name' уже существует в старой раскладке: $AWG_DIR/${name}.conf"
    if grep -qxF "#_Name = ${name}" "$SERVER_CONF" 2>/dev/null; then
        die "пир '$name' уже есть в $SERVER_CONF"
    fi

    local endpoint
    endpoint=$(resolve_endpoint)

    # Блокировка на время правки серверного конфига — тот же файл, что
    # использует manage_amneziawg.sh, поэтому параллельный запуск безопасен.
    local lock_fd
    exec {lock_fd}>"$AWG_DIR/.awg_config.lock"
    flock -x -w 10 "$lock_fd" || die "не получен config-lock"

    local client_ip client_ip6 privkey pubkey address
    client_ip=$(get_next_client_ip)
    client_ip6=$(get_client_ipv6 "$client_ip")

    privkey=$(awg genkey)
    pubkey=$(printf '%s' "$privkey" | awg pubkey)

    if [[ -n "$client_ip6" ]]; then
        address="${client_ip}/32, ${client_ip6}/128"
    else
        address="${client_ip}/32"
        # У клиента нет IPv6-адреса, значит ::/0 в AllowedIPs — маршрут в
        # никуда. Хуже того, awg-quick на машине с отключённым IPv6 падает на
        # нём с «IPv6 is disabled on nexthop device» и не поднимает туннель
        # вообще. Убираем, если пользователь не потребовал явно.
        if [[ "$CLIENT_ALLOWED_IPS_EXPLICIT" -eq 0 ]]; then
            CLIENT_ALLOWED_IPS=$(strip_ipv6_routes "$CLIENT_ALLOWED_IPS")
        fi
    fi

    # Дальше идут изменения на диске: при сбое откатываем всё, что успели.
    # Ловушка висит на EXIT, а не только на ERR: die() выходит через exit,
    # и на нём ERR не срабатывает.
    ROLLBACK_NAME="$name"
    ROLLBACK_SERVER_BAK=""
    ROLLBACK_ACTIVE=1
    trap '_rollback_add' EXIT

    mkdir -p "$cdir"; chmod 700 "$cdir"; _fix_owner "$cdir"

    printf '%s\n' "$privkey" > "$cdir/${name}.private"
    printf '%s\n' "$pubkey"  > "$cdir/${name}.public"
    chmod 600 "$cdir/${name}.private" "$cdir/${name}.public"
    _fix_owner "$cdir/${name}.private"; _fix_owner "$cdir/${name}.public"

    _backup_file "$SERVER_CONF"
    ROLLBACK_SERVER_BAK="$BACKUP_LAST"

    {
        printf '\n[Peer]\n'
        printf '#_Name = %s\n' "$name"
        printf 'PublicKey = %s\n' "$pubkey"
        if [[ -n "$client_ip6" ]]; then
            printf 'AllowedIPs = %s/32, %s/128\n' "$client_ip" "$client_ip6"
        else
            printf 'AllowedIPs = %s/32\n' "$client_ip"
        fi
    } >> "$SERVER_CONF"
    chmod 600 "$SERVER_CONF"

    gen_sender_params
    render_client_conf "$conf" "$privkey" "$address" \
        "$(server_public_key)" "$endpoint" "$S_PORT"

    ROLLBACK_ACTIVE=0
    trap - EXIT
    exec {lock_fd}>&-

    generate_qr "$name" "$conf"
    apply_peers || true

    log_ok "клиент '$name' создан: ${client_ip}${client_ip6:+, $client_ip6}"
    log "  каталог: $cdir"
    log "  конфиг: $conf"
    log "  профиль обфускации: AWG 3.0 / ${PROFILE} / ${INTENSITY}"
}

_rollback_add() {
    local rc=$?
    if [[ "${ROLLBACK_ACTIVE:-0}" -ne 1 ]]; then return 0; fi
    ROLLBACK_ACTIVE=0
    log_err "сбой при создании клиента — откатываю изменения"
    # Каталог создаётся этим же вызовом, поэтому удаляется целиком; чужого
    # в нём быть не может — существование клиента проверено до начала работы.
    rm -rf "${AWG_DIR:?}/${ROLLBACK_NAME:?}" 2>/dev/null || true
    if [[ -n "${ROLLBACK_SERVER_BAK:-}" && -f "$ROLLBACK_SERVER_BAK" ]]; then
        if cp -p "$ROLLBACK_SERVER_BAK" "$SERVER_CONF"; then
            log_ok "серверный конфиг восстановлен"
        fi
    fi
    if [[ "$rc" -eq 0 ]]; then rc=1; fi
    exit "$rc"
}

# ── Чтение клиентского конфига ──────────────────────────────────────────────

_conf_value() {
    local file="$1" key="$2" section="${3:-any}"
    awk -v k="$key" -v want="$section" '
        /^[[:space:]]*\[Interface\]/ { sec = "interface"; next }
        /^[[:space:]]*\[Peer\]/      { sec = "peer"; next }
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (index(line, "#") == 1) next
            if (want != "any" && sec != want) next
            split(line, kv, "=")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", kv[1])
            if (kv[1] == k) {
                sub(/^[^=]*=[[:space:]]*/, "", line)
                gsub(/[[:space:]]+$/, "", line)
                print line
                exit
            }
        }
    ' "$file"
}

# Имена клиентов из обеих раскладок, без повторов и в алфавитном порядке.
list_client_names() {
    local d f base
    {
        for d in "$AWG_DIR"/*/; do
            [[ -d "$d" ]] || continue
            base=$(basename "$d")
            if [[ -f "$d/$base.conf" ]]; then printf '%s\n' "$base"; fi
        done
        for f in "$AWG_DIR"/*.conf; do
            [[ -f "$f" ]] || continue
            # Серверный конфиг, если он оказался в том же каталоге, клиентом не
            # является: у него есть ListenPort, которого у клиента не бывает.
            if [[ "$f" -ef "$SERVER_CONF" ]]; then continue; fi
            if grep -qE '^[[:space:]]*ListenPort[[:space:]]*=' "$f" 2>/dev/null; then continue; fi
            printf '%s\n' "$(basename "$f" .conf)"
        done
    } | sort -u
}

# ── Команда: list ───────────────────────────────────────────────────────────

# Выравнивание ячейки по ШИРИНЕ В СИМВОЛАХ. printf считает байты, поэтому
# колонка с кириллицей съезжает ровно на число многобайтовых символов.
_pad() {
    local s="$1" w="$2" chars bytes
    chars=${#s}
    bytes=$(LC_ALL=C printf '%s' "$s" | wc -c)
    printf '%-*s ' "$((w + bytes - chars))" "$s"
}

cmd_list() {
    load_server_params
    load_name_to_pk
    load_peer_dump

    _pad "КЛИЕНТ" 20; _pad "АДРЕС" 14; _pad "ВЕРСИЯ" 6; _pad "СВЯЗЬ" 14; _pad "РАСКЛАДКА" 9
    printf '%s\n' "СОВМЕСТИМ"
    printf '%s\n' "-------------------------------------------------------------------------------------"

    local name conf addr hpk ver match c_s1 c_h1 layout
    while IFS= read -r name; do
        conf=$(client_conf_path "$name")
        if [[ "$conf" == "$AWG_DIR/$name/$name.conf" ]]; then
            layout="папка"
        else
            layout="старая"
        fi
        addr=$(_conf_value "$conf" Address interface)
        hpk=$(_conf_value "$conf" HeaderProtectionKey interface)
        c_s1=$(_conf_value "$conf" S1 interface)
        c_h1=$(_conf_value "$conf" H1 interface)

        if [[ -n "$hpk" ]]; then ver="3.0"; else ver="2.0"; fi

        if [[ "$c_s1" == "${S_S1}" && "$c_h1" == "${S_H1}" && "$hpk" == "${S_HPK}" ]]; then
            match="${C_GRN}да${C_OFF}"
        else
            match="${C_RED}нет — клиент не подключится${C_OFF}"
        fi
        local pk="${NAME_PK[$name]:-}" link
        if [[ -n "$pk" ]]; then link=$(peer_status "${PK_HS[$pk]:-0}"); else link="нет пира"; fi

        _pad "$name" 20; _pad "${addr%%,*}" 14; _pad "$ver" 6
        _pad "$link" 14; _pad "$layout" 9
        printf '%s\n' "$match"
    done < <(list_client_names)

    printf '\n'
    if server_is_awg3; then
        printf 'Сервер: AWG 3.0 (S1=%s H1=%s)\n' "$S_S1" "$S_H1"
    else
        printf 'Сервер: AWG 2.0 — HeaderProtectionKey отсутствует\n'
    fi
    printf '  порт: %s/udp, подсеть: %s, MTU: %s\n' \
        "${S_PORT:-?}" "${S_ADDR:-?}" "${S_MTU:-?}"
    printf '  изоляция клиентов: %s, IPv6: %s\n' \
        "$(server_isolation_state)" "$(server_ipv6_state)"
    local ep
    ep=$(server_endpoint_name)
    if [[ -n "$ep" ]]; then
        printf '  имя хоста для клиентов: %s\n' "$ep"
    else
        printf '  имя хоста для клиентов: не задано (берётся внешний IP)\n'
    fi
}

# ── Команда: migrate ────────────────────────────────────────────────────────
#
# Переносит клиентов из плоской раскладки в ~/awg/ИМЯ/. Файлы перемещаются,
# а не копируются: две копии приватного ключа на диске никому не нужны.
# Повторный запуск безопасен — уже перенесённые пропускаются.

migrate_one() {
    local name="$1"
    local cdir moved=0
    cdir=$(client_dir "$name")

    if [[ -f "$cdir/${name}.conf" ]]; then
        log "'$name': уже в своём каталоге, пропускаю"
        return 0
    fi
    [[ -f "$AWG_DIR/${name}.conf" ]] || { log_err "'$name': конфиг не найден"; return 1; }

    mkdir -p "$cdir" || { log_err "'$name': не создан каталог $cdir"; return 1; }
    chmod 700 "$cdir"; _fix_owner "$cdir"

    local src dst
    for src in "$AWG_DIR/${name}.conf" "$AWG_DIR/${name}.png" \
               "$AWG_DIR/${name}.vpnuri" "$AWG_DIR/${name}.vpnuri.png" \
               "$LEGACY_KEYS_DIR/${name}.private" "$LEGACY_KEYS_DIR/${name}.public"; do
        [[ -f "$src" ]] || continue
        dst="$cdir/$(basename "$src")"
        if mv -f "$src" "$dst"; then
            _fix_owner "$dst"
            moved=$((moved + 1))
        else
            log_err "'$name': не перенесён $src"
            return 1
        fi
    done

    # Бэкапы конфигов, накопленные прежними запусками, едут следом:
    # иначе они осиротеют в корне каталога.
    local bak
    for bak in "$AWG_DIR/${name}.conf".bak-*; do
        [[ -f "$bak" ]] || continue
        if mv -f "$bak" "$cdir/"; then moved=$((moved + 1)); fi
    done

    log_ok "'$name': перенесено файлов — $moved → $cdir"
    return 0
}

cmd_migrate() {
    local names=() name flat=()
    mapfile -t names < <(list_client_names)
    [[ "${#names[@]}" -gt 0 ]] || die "клиентов не найдено"

    for name in "${names[@]}"; do
        if [[ ! -f "$AWG_DIR/$name/$name.conf" && -f "$AWG_DIR/${name}.conf" ]]; then
            flat+=("$name")
        fi
    done

    if [[ "${#flat[@]}" -eq 0 ]]; then
        log_ok "переносить нечего: все клиенты уже разложены по каталогам"
        return 0
    fi

    log "Будут перенесены в собственные каталоги: ${flat[*]}"
    log "Файлы перемещаются (conf, png, ключи, бэкапы), сервер не затрагивается."
    confirm "Продолжить?" || die "отменено"

    local ok=0 fail=0
    for name in "${flat[@]}"; do
        if migrate_one "$name"; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
    done

    # Каталог keys/ остаётся на месте, даже если опустел: удаление файлов —
    # отдельное решение, скрипт его за пользователя не принимает.
    if [[ -d "$LEGACY_KEYS_DIR" ]]; then
        local left
        left=$(find "$LEGACY_KEYS_DIR" -type f 2>/dev/null | wc -l)
        if [[ "$left" -eq 0 ]]; then
            log "Каталог $LEGACY_KEYS_DIR опустел — можно удалить вручную."
        else
            log_warn "В $LEGACY_KEYS_DIR осталось файлов: $left (ключи без клиента?)"
        fi
    fi

    log "Готово: перенесено $ok, с ошибками $fail"
    [[ "$fail" -eq 0 ]]
}

# ── Данные живого интерфейса ────────────────────────────────────────────────
#
# `awg show <iface> dump` отдаёт по строке на пира:
#   pubkey \t psk \t endpoint \t allowed-ips \t handshake \t rx \t tx \t keepalive
# Первая строка описывает сам интерфейс и пропускается.

# Заполняет ассоциативные массивы PK_HS, PK_RX, PK_TX, PK_EP (ключ — pubkey).
declare -A PK_HS PK_RX PK_TX PK_EP
load_peer_dump() {
    local dump pk psk ep aips hs rx tx ka
    dump=$(awg show "$AWG_IFACE" dump 2>/dev/null) || return 0
    [[ -n "$dump" ]] || return 0
    while IFS=$'\t' read -r pk psk ep aips hs rx tx ka; do
        [[ -n "$pk" ]] || continue
        PK_HS["$pk"]="$hs"; PK_RX["$pk"]="$rx"; PK_TX["$pk"]="$tx"; PK_EP["$pk"]="$ep"
    done < <(printf '%s\n' "$dump" | tail -n +2)
}

# Имя клиента -> публичный ключ, по маркерам #_Name в серверном конфиге.
declare -A NAME_PK
load_name_to_pk() {
    local line cur=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "#_Name = "* ]]; then
            cur="${line#\#_Name = }"; cur="${cur//[[:space:]]/}"
        elif [[ -n "$cur" && "$line" == "PublicKey = "* ]]; then
            local pk="${line#PublicKey = }"; pk="${pk//[[:space:]]/}"
            if [[ -n "$pk" ]]; then NAME_PK["$cur"]="$pk"; fi
            cur=""
        fi
    done < "$SERVER_CONF"
}

# Человекочитаемый статус по времени последнего рукопожатия.
peer_status() {
    local hs="${1:-0}" now diff
    if ! [[ "$hs" =~ ^[0-9]+$ ]] || [[ "$hs" -eq 0 ]]; then
        printf 'нет связи'; return 0
    fi
    now=$(date +%s); diff=$((now - hs))
    if   [[ "$diff" -lt 180 ]];   then printf 'активен'
    elif [[ "$diff" -lt 86400 ]]; then printf 'был %dч назад' "$((diff / 3600))"
    else printf 'был %dд назад' "$((diff / 86400))"
    fi
}

format_bytes() {
    local b="${1:-0}"
    if ! [[ "$b" =~ ^[0-9]+$ ]]; then printf '0 B'; return; fi
    if   [[ "$b" -ge 1073741824 ]]; then awk "BEGIN{printf \"%.2f GiB\", $b/1073741824}"
    elif [[ "$b" -ge 1048576 ]];    then awk "BEGIN{printf \"%.2f MiB\", $b/1048576}"
    elif [[ "$b" -ge 1024 ]];       then awk "BEGIN{printf \"%.1f KiB\", $b/1024}"
    else printf '%d B' "$b"
    fi
}

# ── Команда: remove ─────────────────────────────────────────────────────────

# Вырезает из серверного конфига секцию [Peer] с указанным #_Name.
_drop_peer_section() {
    local name="$1" tmp
    tmp=$(mktemp "${SERVER_CONF}.tmp.XXXXXX") || return 1
    chmod 600 "$tmp"

    # Секция копится в буфере до её конца, и только тогда решается судьба:
    # печатать или выбросить. Маркер #_Name стоит внутри секции, а не перед ней.
    awk -v target="$name" '
        function flush_buf() {
            if (nbuf > 0 && !drop) { for (i = 1; i <= nbuf; i++) print buf[i] }
            nbuf = 0; drop = 0
        }
        /^[[:space:]]*\[Peer\]/ { flush_buf(); in_peer = 1; buf[++nbuf] = $0; next }
        /^[[:space:]]*\[Interface\]/ { flush_buf(); in_peer = 0; print; next }
        {
            if (in_peer) {
                line = $0
                sub(/^[[:space:]]+/, "", line)
                if (line == "#_Name = " target) drop = 1
                buf[++nbuf] = $0
            } else print
        }
        END { flush_buf() }
    ' "$SERVER_CONF" > "$tmp" || { rm -f "$tmp"; return 1; }

    if ! grep -qxF "#_Name = ${name}" "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$SERVER_CONF" || { rm -f "$tmp"; return 1; }
        chmod 600 "$SERVER_CONF"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

cmd_remove() {
    load_server_params

    local names=("$@") name valid=()
    [[ "${#names[@]}" -gt 0 ]] || die "укажите имя клиента"

    for name in "${names[@]}"; do
        validate_client_name "$name"
        if grep -qxF "#_Name = ${name}" "$SERVER_CONF" 2>/dev/null; then
            valid+=("$name")
        else
            log_warn "'$name': пира нет в $SERVER_CONF"
            # Файлы могли остаться от прошлой неудачной попытки — заберём и их.
            if [[ -d "$(client_dir "$name")" || -f "$AWG_DIR/${name}.conf" ]]; then
                valid+=("$name")
            fi
        fi
    done
    [[ "${#valid[@]}" -gt 0 ]] || die "нечего удалять"

    log "Будет удалено безвозвратно:"
    for name in "${valid[@]}"; do
        local cdir; cdir=$(client_dir "$name")
        printf '  %s\n' "$name"
        if [[ -d "$cdir" ]]; then find "$cdir" -type f -printf '      %p\n' 2>/dev/null || true; fi
        if [[ -f "$AWG_DIR/${name}.conf" ]]; then printf '      %s\n' "$AWG_DIR/${name}.conf"; fi
        if grep -qxF "#_Name = ${name}" "$SERVER_CONF" 2>/dev/null; then
            printf '      [Peer] в %s\n' "$SERVER_CONF"
        fi
    done
    confirm "Удалить?" || die "отменено"

    local lock_fd
    exec {lock_fd}>"$AWG_DIR/.awg_config.lock"
    flock -x -w 10 "$lock_fd" || die "не получен config-lock"

    _backup_file "$SERVER_CONF"

    local removed=0 failed=0
    for name in "${valid[@]}"; do
        if grep -qxF "#_Name = ${name}" "$SERVER_CONF" 2>/dev/null; then
            if ! _drop_peer_section "$name"; then
                log_err "'$name': не удалён из серверного конфига"
                failed=$((failed + 1))
                continue
            fi
        fi
        # Приватный ключ затирается, а не просто отвязывается от имени файла.
        local cdir; cdir=$(client_dir "$name")
        if [[ -d "$cdir" ]]; then
            find "$cdir" -type f -name '*.private' -exec shred -u {} \; 2>/dev/null || true
            rm -rf "${AWG_DIR:?}/${name:?}"
        fi
        rm -f "$AWG_DIR/${name}.conf" "$AWG_DIR/${name}.png" \
              "$AWG_DIR/${name}.conf".bak-* 2>/dev/null || true
        if [[ -f "$LEGACY_KEYS_DIR/${name}.private" ]]; then
            shred -u "$LEGACY_KEYS_DIR/${name}.private" 2>/dev/null || true
        fi
        rm -f "$LEGACY_KEYS_DIR/${name}.public" 2>/dev/null || true
        log_ok "'$name' удалён"
        removed=$((removed + 1))
    done

    exec {lock_fd}>&-
    if [[ "$removed" -gt 0 ]]; then apply_peers || true; fi

    log "Готово: удалено $removed, с ошибками $failed"
    [[ "$failed" -eq 0 ]]
}

# ── Команда: stats ──────────────────────────────────────────────────────────

cmd_stats() {
    load_server_params
    load_name_to_pk
    load_peer_dump

    _pad "КЛИЕНТ" 20; _pad "ПРИНЯТО" 12; _pad "ОТДАНО" 12; _pad "СОСТОЯНИЕ" 16
    printf '%s\n' "ОТКУДА"
    printf '%s\n' "--------------------------------------------------------------------------------"

    local name pk total_rx=0 total_tx=0 ep
    while IFS= read -r name; do
        pk="${NAME_PK[$name]:-}"
        if [[ -z "$pk" ]]; then
            _pad "$name" 20; printf '%s\n' "нет пира в конфиге"
            continue
        fi
        local rx="${PK_RX[$pk]:-0}" tx="${PK_TX[$pk]:-0}"
        [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
        [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
        total_rx=$((total_rx + rx)); total_tx=$((total_tx + tx))
        ep="${PK_EP[$pk]:-}"
        if [[ -z "$ep" || "$ep" == "(none)" ]]; then ep="-"; fi
        _pad "$name" 20
        _pad "$(format_bytes "$rx")" 12
        _pad "$(format_bytes "$tx")" 12
        _pad "$(peer_status "${PK_HS[$pk]:-0}")" 16
        printf '%s\n' "$ep"
    done < <(list_client_names)

    printf '\n'
    printf 'Всего: принято %s, отдано %s\n' "$(format_bytes "$total_rx")" "$(format_bytes "$total_tx")"
}

# ── Команды: show, restart ──────────────────────────────────────────────────

cmd_show() {
    awg show "$AWG_IFACE" || die "интерфейс $AWG_IFACE не поднят"
}

cmd_restart() {
    log "Перезапуск awg-quick@${AWG_IFACE}..."
    if systemctl restart "awg-quick@${AWG_IFACE}"; then
        log_ok "сервис перезапущен"
    else
        die "перезапуск не удался, смотрите: systemctl status awg-quick@${AWG_IFACE}"
    fi
    systemctl is-active "awg-quick@${AWG_IFACE}"
}

# ── Команда: backup ─────────────────────────────────────────────────────────
#
# Архив кладётся в ~/awg/backups и содержит серверный конфиг, каталоги
# клиентов и ключи сервера. Старые архивы НЕ удаляются
# сами: чистка — только явным --prune N, и с подтверждением.

cmd_backup() {
    local bdir="$AWG_DIR/backups"
    mkdir -p "$bdir" || die "не создан $bdir"
    chmod 700 "$bdir"; _fix_owner "$bdir"

    # Миллисекунды в имени: два бэкапа в одну секунду (backup сразу после
    # remove, например) иначе молча затирают друг друга.
    local ts archive
    ts=$(date '+%Y%m%d-%H%M%S.%3N')
    archive="$bdir/awg_backup_${ts}.tar.gz"

    local staging
    staging=$(mktemp -d "${bdir}/.stage.XXXXXX") || die "mktemp не сработал"
    mkdir -p "$staging/server" "$staging/clients"

    if [[ -f "$SERVER_CONF" ]]; then cp -a "$SERVER_CONF" "$staging/server/"; fi
    local f
    for f in "$AWG_DIR/server_private.key" "$AWG_DIR/server_public.key"; do
        if [[ -f "$f" ]]; then cp -a "$f" "$staging/server/"; fi
    done

    local name cdir count=0
    while IFS= read -r name; do
        cdir=$(client_dir "$name")
        if [[ -d "$cdir" ]]; then
            cp -a "$cdir" "$staging/clients/"
        else
            mkdir -p "$staging/clients/$name"
            cp -a "$AWG_DIR/${name}.conf" "$staging/clients/$name/" 2>/dev/null || true
            cp -a "$LEGACY_KEYS_DIR/${name}."* "$staging/clients/$name/" 2>/dev/null || true
        fi
        count=$((count + 1))
    done < <(list_client_names)

    if ! tar -czf "$archive" -C "$staging" server clients; then
        rm -rf "$staging"
        die "не создан архив $archive"
    fi
    rm -rf "$staging"
    chmod 600 "$archive"; _fix_owner "$archive"

    log_ok "бэкап создан: $archive"
    log "  клиентов в архиве: $count, размер: $(du -h "$archive" | cut -f1)"

    local total
    total=$(find "$bdir" -maxdepth 1 -name 'awg_backup_*.tar.gz' | wc -l)
    log "  всего архивов: $total"

    if [[ -n "$PRUNE_KEEP" ]]; then
        local old=()
        mapfile -t old < <(find "$bdir" -maxdepth 1 -name 'awg_backup_*.tar.gz' \
                           | sort -r | tail -n +$((PRUNE_KEEP + 1)))
        if [[ "${#old[@]}" -eq 0 ]]; then
            log "  удалять нечего, архивов не больше $PRUNE_KEEP"
            return 0
        fi
        log "Будут удалены старые архивы:"
        printf '  %s\n' "${old[@]}"
        confirm "Удалить?" || { log "чистка отменена"; return 0; }
        rm -f "${old[@]}"
        log_ok "удалено архивов: ${#old[@]}"
    fi
}

# ── Команда: gen ────────────────────────────────────────────────────────────

cmd_gen() {
    gen_shared_params
    gen_sender_params

    cat <<EOF
# AmneziaWG ${AWG_PROTOCOL} — сгенерировано awg3.sh ${SCRIPT_VERSION}
#
# S1-S4, H1-H4 и HeaderProtectionKey должны совпадать на ОБОИХ концах.
# Jc, Jmin, Jmax, I1-I5, ContentPaddingAddition и таймеры — sender-side:
# у каждого устройства могут быть свои, и разные значения лучше.

[Interface]
S1 = ${G_S1}
S2 = ${G_S2}
S3 = ${G_S3}
S4 = ${G_S4}
H1 = ${G_H1}
H2 = ${G_H2}
H3 = ${G_H3}
H4 = ${G_H4}
HeaderProtectionKey = ${G_HPK}
ContentPaddingAddition = ${G_CPA}
Jc = ${G_Jc}
Jmin = ${G_Jmin}
Jmax = ${G_Jmax}
EOF
    local n var
    for n in 1 2 3 4 5; do
        var="G_I${n}"
        if [[ -n "${!var}" ]]; then printf 'I%s = %s\n' "$n" "${!var}"; fi
    done
    cat <<EOF
RekeyAfterTime = ${G_RA}
RekeyTimeout = ${G_RT}
RejectAfterTime = ${G_RJ}
KeepaliveTimeout = ${G_KA}
MaxHandshakeAttempts = ${G_MHA}

# Требуется amneziawg-go >= 3.0.1 и amneziawg-tools с поддержкой 3.0.
# S1-S4 подняты минимум до ${NONCE_SIZE}: nonce шифра берётся из этого padding'а.
EOF
}

# ── Команда: server-upgrade ─────────────────────────────────────────────────

cmd_server_upgrade() {
    load_server_params

    if server_is_awg3; then
        log_warn "сервер уже на AWG 3.0 (HeaderProtectionKey присутствует)."
        log_warn "Повторный запуск сгенерирует НОВЫЕ общие параметры и разорвёт все текущие подключения."
        confirm "Всё равно перегенерировать?" || die "отменено"
    fi

    log "После смены общих параметров все клиентские конфиги станут недействительны."
    log "Каждого клиента придётся создать заново: $0 remove ИМЯ, затем $0 add ИМЯ"
    confirm "Продолжить?" || die "отменено"

    gen_shared_params
    _backup_file "$SERVER_CONF"

    local tmp
    tmp=$(mktemp "${SERVER_CONF}.tmp.XXXXXX") || die "mktemp не сработал"
    chmod 600 "$tmp"

    # Старые S/H/HPK/CPA вырезаются из [Interface], новые вставляются единым
    # блоком перед первым [Peer]. Всё остальное — PostUp, MTU, ListenPort,
    # список пиров — переносится дословно.
    awk -v s1="$G_S1" -v s2="$G_S2" -v s3="$G_S3" -v s4="$G_S4" \
        -v h1="$G_H1" -v h2="$G_H2" -v h3="$G_H3" -v h4="$G_H4" \
        -v hpk="$G_HPK" -v cpa="$G_CPA" '
        function emit_block() {
            printf "\nS1 = %s\nS2 = %s\nS3 = %s\nS4 = %s\n", s1, s2, s3, s4
            printf "H1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n", h1, h2, h3, h4
            printf "HeaderProtectionKey = %s\n", hpk
            printf "ContentPaddingAddition = %s\n", cpa
        }
        BEGIN { in_iface = 0; done = 0 }
        /^[[:space:]]*\[Interface\]/ { in_iface = 1; print; next }
        /^[[:space:]]*\[Peer\]/ {
            if (in_iface && !done) { emit_block(); done = 1 }
            in_iface = 0; print; next
        }
        {
            if (in_iface) {
                line = $0
                sub(/^[[:space:]]+/, "", line)
                split(line, kv, "=")
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", kv[1])
                if (kv[1] ~ /^(S[1-4]|H[1-4]|HeaderProtectionKey|ContentPaddingAddition|Jc|Jmin|Jmax|I[1-5])$/) next
                if (line == "") next
            }
            print
        }
        END { if (in_iface && !done) emit_block() }
    ' "$SERVER_CONF" > "$tmp" || { rm -f "$tmp"; die "не удалось перестроить $SERVER_CONF"; }

    mv -f "$tmp" "$SERVER_CONF" || { rm -f "$tmp"; die "не записан $SERVER_CONF"; }
    chmod 600 "$SERVER_CONF"
    log_ok "сервер переведён на AWG 3.0"

    # syncconf не меняет параметры интерфейса — только полный перезапуск.
    apply_restart || true
    log_warn "старые конфиги больше не подключатся — пересоздайте клиентов заново"
}

# ── Справка и разбор аргументов ─────────────────────────────────────────────

usage() {
    cat <<EOF
awg3.sh ${SCRIPT_VERSION} — AmneziaWG ${AWG_PROTOCOL}: клиенты и параметры обфускации
                 в одном скрипте (режимы AWG 1.0/1.5/2.0 не поддерживаются)

ИСПОЛЬЗОВАНИЕ
    awg3.sh <команда> [аргументы] [опции]

КОМАНДЫ
    add NAME              создать клиента сразу с параметрами AWG 3.0
    remove NAME...        удалить клиента: пир, файлы и ключи
    list                  клиенты: адрес, связь, совместимость с сервером
    names                 только имена клиентов, по одному в строке (для скриптов)
    stats                 трафик и последняя активность по клиентам
    show                  вывод 'awg show' по интерфейсу
    restart               перезапустить awg-quick@ИНТЕРФЕЙС
    backup [--prune N]    архив конфигов и ключей в ~/awg/backups
    migrate               разложить клиентов из старой плоской схемы по каталогам
    gen                   вывести готовый набор параметров AWG 3.0
    server-init           создать сервер AWG 3.0 с нуля
    server-upgrade        сгенерировать новые общие параметры для сервера

ОПЦИИ
    -p, --profile NAME    профиль мимикрии для I1:
                          quic | tls | dtls | sip | dns | noise  (по умолч.: quic)
    -i, --intensity LVL   low | medium | high                    (по умолч.: medium)
    -r, --router          режим роутера: минимум шума для слабого железа
    -e, --endpoint HOST   адрес сервера в конфиге клиента
        --dns LIST        DNS клиента            (по умолч.: ${CLIENT_DNS})
        --mtu N           MTU клиента            (по умолч.: из awg0.conf)
        --allowed-ips L   AllowedIPs клиента     (по умолч.: ${CLIENT_ALLOWED_IPS})
        --no-qr           не создавать PNG с QR-кодом
        --no-apply        не применять изменения к запущенному интерфейсу
        --prune N         (backup) оставить N последних архивов, остальные
                          удалить — со списком и подтверждением
        --awg-port N      (server-init) UDP-порт сервера   (по умолч.: случайный)
        --subnet CIDR     (server-init) подсеть туннеля    (по умолч.: ${SRV_SUBNET})
        --isolation on|off
                          (server-init) изоляция клиентов  (по умолч.: ${SRV_ISOLATION})
        --ipv6 on|off     (server-init) IPv6 в туннеле     (по умолч.: ${SRV_IPV6})
        --ipv6-subnet CIDR
                          (server-init) подсеть IPv6       (по умолч.: ${SRV_IPV6_SUBNET})
        --force           (server-init) пересоздать сервер, перенеся пиров
    -y, --yes             не задавать вопросов
    -h, --help            эта справка

ПРИМЕЧАНИЯ
    S1-S4, H1-H4 и HeaderProtectionKey всегда берутся из awg0.conf: сервер —
    источник истины, клиент обязан их повторить. Jc, Jmin, Jmax, I1-I5,
    ContentPaddingAddition и таймеры генерируются заново для каждого клиента.

    Каждый клиент живёт в собственном каталоге:
        ${AWG_DIR}/ИМЯ/ИМЯ.conf
        ${AWG_DIR}/ИМЯ/ИМЯ.png
        ${AWG_DIR}/ИМЯ/ИМЯ.private, ИМЯ.public
    Прежняя плоская раскладка ещё читается командами list и remove;
    'migrate' переносит её на новую схему.

    Пути переопределяются переменными AWG3_DIR, AWG3_SERVER_CONF, AWG3_IFACE.
EOF
}

main() {
    [[ $# -gt 0 ]] || { usage; exit 1; }

    local cmd="$1"; shift
    case "$cmd" in
        -h|--help|help) usage; exit 0 ;;
        add|remove|list|names|stats|show|restart|backup|gen|migrate|server-upgrade|server-init) ;;
        *) die "неизвестная команда: ${cmd}  (см. --help)" ;;
    esac

    local positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--profile)   PROFILE="${2:-}"; shift 2 ;;
            -i|--intensity) INTENSITY="${2:-}"; shift 2 ;;
            -r|--router)    ROUTER_MODE=1; shift ;;
            -e|--endpoint)  ENDPOINT_OVERRIDE="${2:-}"; shift 2 ;;
            --dns)          CLIENT_DNS="${2:-}"; shift 2 ;;
            --mtu)          MTU_OVERRIDE="${2:-}"; shift 2 ;;
            --allowed-ips)  CLIENT_ALLOWED_IPS="${2:-}"; CLIENT_ALLOWED_IPS_EXPLICIT=1; shift 2 ;;
            --no-qr)        MAKE_QR=0; shift ;;
            --no-apply)     DO_APPLY=0; shift ;;
            --prune)        PRUNE_KEEP="${2:-}"; shift 2 ;;
            --awg-port)     SRV_PORT="${2:-}"; shift 2 ;;
            --subnet)       SRV_SUBNET="${2:-}"; shift 2 ;;
            --isolation)    SRV_ISOLATION="${2:-}"; shift 2 ;;
            --ipv6)         SRV_IPV6="${2:-}"; shift 2 ;;
            --ipv6-subnet)  SRV_IPV6_SUBNET="${2:-}"; shift 2 ;;
            --force)        SRV_FORCE=1; shift ;;
            -y|--yes)       ASSUME_YES=1; shift ;;
            -h|--help)      usage; exit 0 ;;
            -*)             die "неизвестная опция: $1  (см. --help)" ;;
            *)              positional+=("$1"); shift ;;
        esac
    done

    case "$PROFILE" in
        quic|tls|dtls|sip|dns|noise) ;;
        *) die "неизвестный профиль: ${PROFILE}  (quic, tls, dtls, sip, dns, noise)" ;;
    esac
    case "$INTENSITY" in
        low|medium|high) ;;
        *) die "неизвестная интенсивность: ${INTENSITY}  (low, medium, high)" ;;
    esac
    case "$SRV_ISOLATION" in
        on|off) ;;
        *) die "--isolation ожидает on|off: $SRV_ISOLATION" ;;
    esac
    case "$SRV_IPV6" in
        on|off) ;;
        *) die "--ipv6 ожидает on|off: $SRV_IPV6" ;;
    esac
    if [[ -n "$PRUNE_KEEP" ]]; then
        [[ "$PRUNE_KEEP" =~ ^[0-9]+$ ]] && (( PRUNE_KEEP >= 1 )) \
            || die "--prune ожидает число не меньше 1: $PRUNE_KEEP"
    fi
    if [[ -n "$MTU_OVERRIDE" ]]; then
        [[ "$MTU_OVERRIDE" =~ ^[0-9]+$ ]] && (( MTU_OVERRIDE >= 576 && MTU_OVERRIDE <= 9100 )) \
            || die "MTU вне диапазона 576..9100: $MTU_OVERRIDE"
    fi

    check_dependencies
    _rand_refill

    case "$cmd" in
        add)
            [[ "${#positional[@]}" -eq 1 ]] || die "add принимает ровно одно имя клиента"
            cmd_add "${positional[0]}"
            ;;
        remove)         cmd_remove "${positional[@]+"${positional[@]}"}" ;;
        list)           cmd_list ;;
        names)          list_client_names ;;
        stats)          cmd_stats ;;
        show)           cmd_show ;;
        restart)        cmd_restart ;;
        backup)         cmd_backup ;;
        gen)            cmd_gen ;;
        migrate)        cmd_migrate ;;
        server-upgrade) cmd_server_upgrade ;;
        server-init)    cmd_server_init ;;
    esac
}

# Запуск только при прямом вызове. При подключении через source (юнит-тесты)
# main не выполняется — иначе тест запустил бы сам скрипт.
if [[ "${AWG3_LIB_ONLY:-0}" -ne 1 && "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
