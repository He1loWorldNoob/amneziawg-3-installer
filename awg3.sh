#!/usr/bin/env bash
#
# awg3.sh — AmneziaWG 3.0: сервер с нуля, клиенты, перевод конфигов на 3.0.
#
# Самодостаточный файл, без внешних библиотек:
#   * создание сервера сразу в 3.1 (ключи, NAT, обфускация, awg0.conf);
#   * создание клиента (ключи, свободный IP, [Peer] в awg0.conf, apply, QR,
#     ссылка vpn:// для приложения Amnezia);
#   * генерация параметров обфускации AWG 3.1.
#
# Каждый клиент держит свои файлы в собственном каталоге ~/awg/ИМЯ/ — конфиг,
# QR, ссылку и пару ключей рядом, чтобы отдать клиента целиком одной папкой.
#
#   ./awg3.sh server-init            # поднять сервер AWG 3.1 с нуля
#   ./awg3.sh add ivan2              # новый клиент сразу в AWG 3.1
#   ./awg3.sh link ivan2             # пересобрать ссылку по готовому конфигу
#   ./awg3.sh list                   # клиенты и фактическое состояние сервера
#   ./awg3.sh migrate                # разложить старых клиентов по каталогам
#   ./awg3.sh gen                    # просто выдать набор параметров
#   ./awg3.sh server-rekey           # новые общие параметры для интерфейса
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
# она задавалась флагом -v (1.0|1.5|2.0|3.0), здесь же выбора нет — интерфейс
# всегда 3.1. Более старые режимы не поддерживаются намеренно: нужен клиент
# Amnezia 5.0.1.5 или новее.
SCRIPT_VERSION="1.2.0"
readonly AWG_PROTOCOL="3.1"

# ── Пути ────────────────────────────────────────────────────────────────────
#
# Переопределяются переменными окружения — этим же пользуется прогон на копии
# конфига, чтобы не трогать рабочий сервер.

# readlink -f обязателен: скрипт вызывается через симлинк /usr/local/sbin/awg3,
# и без разыменования SCRIPT_DIR указал бы на /usr/local/sbin — каталог, где
# нет ни одного клиента.
SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Явно заданные переменные окружения сильнее вычисления по интерфейсу: ими
# пользуются юнит-тесты и прогон на копии конфига. Запоминаем факт задания
# отдельно, иначе --iface затирал бы их при пересчёте.
AWG_ROOT_EXPLICIT="${AWG3_DIR:-}"
SERVER_CONF_EXPLICIT="${AWG3_SERVER_CONF:-}"
AWG_IFACE="${AWG3_IFACE:-awg0}"

# resolve_paths — вычисляет AWG_ROOT, AWG_DIR, SERVER_CONF, LOG_FILE и
# LEGACY_KEYS_DIR по текущему AWG_IFACE.
#
# AWG_ROOT — корень данных, каталог самого скрипта (~/awg). Всё лежит внутри
# него: журнал, бэкапы и по каталогу на интерфейс. Клиенты — ещё уровнем
# ниже: ~/awg/awg1/ИМЯ/ИМЯ.conf.
#
# Раскладка по интерфейсам, а не вперемешку, снимает и столкновение имён:
# клиент, названный awg1, иначе занял бы каталог интерфейса.
#
# Вызывается дважды: здесь, чтобы работали ранние сообщения об ошибках, и
# после разбора аргументов, где --iface мог сменить интерфейс.
resolve_paths() {
    if [[ -n "$AWG_ROOT_EXPLICIT" ]]; then
        AWG_ROOT="$AWG_ROOT_EXPLICIT"
    else
        AWG_ROOT="$SCRIPT_DIR"
    fi
    AWG_DIR="$AWG_ROOT/$AWG_IFACE"
    SERVER_CONF="${SERVER_CONF_EXPLICIT:-/etc/amnezia/amneziawg/${AWG_IFACE}.conf}"
    LOG_FILE="$AWG_ROOT/awg3.log"
    LEGACY_KEYS_DIR="$AWG_ROOT/keys"
}
resolve_paths

# Раскладка файлов: каждый клиент живёт в своём каталоге.
#
#   ~/awg/ИМЯ/ИМЯ.conf     ~/awg/ИМЯ/ИМЯ.private
#   ~/awg/ИМЯ/ИМЯ.png      ~/awg/ИМЯ/ИМЯ.public
#   ~/awg/ИМЯ/ИМЯ.vpnuri
#
# Прежняя плоская раскладка (~/awg/ИМЯ.conf + ~/awg/keys/ИМЯ.private) ещё
# читается, чтобы list и remove работали до переноса; `awg3.sh migrate`
# перекладывает всё на новую схему.

client_dir() { printf '%s/%s' "$AWG_DIR" "$1"; }

# Путь к конфигу клиента: текущая схема в приоритете, затем прежние. Для
# несуществующего клиента возвращается путь по текущей — туда и создаём.
#
# Прежних схем две, и обе бывают только у awg0: до раскладки по интерфейсам он
# держал клиентов прямо в корне (~/awg/ИМЯ/ИМЯ.conf), а ещё раньше — плоско
# (~/awg/ИМЯ.conf). Искать их для awg1 нельзя: там нашлись бы чужие клиенты.
client_conf_path() {
    local name="$1"
    if [[ -f "$AWG_DIR/$name/$name.conf" ]]; then
        printf '%s/%s/%s.conf' "$AWG_DIR" "$name" "$name"
    elif [[ "$AWG_IFACE" == "awg0" && -f "$AWG_ROOT/$name/$name.conf" ]]; then
        printf '%s/%s/%s.conf' "$AWG_ROOT" "$name" "$name"
    elif [[ "$AWG_IFACE" == "awg0" && -f "$AWG_ROOT/$name.conf" ]]; then
        printf '%s/%s.conf' "$AWG_ROOT" "$name"
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
MAKE_LINK=1
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

# Параметры AmneziaWG 3.1. Выключателей у них нет намеренно: 3.0 из проекта
# убран, и интерфейс либо 3.1, либо не наш.
#
# RandomTrailers дописывает к каждому служебному пакету случайный хвост, снимая
# постоянную длину рукопожатия (без него init всегда 148+S1, ответ 92+S2 — по
# ним сервер опознаётся с одного пакета). Приёмник при этом переходит с
# проверки «длина равна ожидаемой» на «не меньше ожидаемой», поэтому параметр
# обязан СОВПАДАТЬ на обоих концах: включённый только на одной стороне рвёт
# туннель полностью. Отсюда же он и не sender-side: клиент обязан повторить
# его за сервером, как S1-S4 и HeaderProtectionKey.
#
# DisableCookies запрещает отвечать на cookie-запросы. Он односторонний:
# включается на любом конце независимо.
#
# Требуется клиент Amnezia 5.0.1.5 или новее, а на сервере — модуль и tools 3.1.

# Переезд клиента между интерфейсами: куда и с каким ключом.
MIGRATE_TO=""
REUSE_PRIVKEY=""

# Минимальная версия модуля и tools, понимающая эти два параметра.
readonly AWG31_MIN_MAJOR=3
readonly AWG31_MIN_MINOR=1

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
    [[ -d "$AWG_ROOT" ]] || return 0
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

    # PersistentKeepalive: постоянный интервал сам по себе признак, поэтому
    # он тоже разный у каждого клиента. Диапазон понимают tools 3.1 и
    # приложение от 5.0.1.5 — то есть всё, с чем мы работаем.
    local pk_lo pk_hi
    rand_int 22 30; pk_lo=$REPLY
    rand_int 6 14;  pk_hi=$((pk_lo + REPLY))
    G_PKA="${pk_lo}-${pk_hi}"
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

    # Отсутствие строки означает выключено — так выглядят все конфиги,
    # созданные до 3.1. Читается не ради клиента (тот получает параметр
    # всегда), а ради опознания такого интерфейса: см. require_iface_awg31.
    S_RTR=$(_iface_value RandomTrailers)
    [[ -n "$S_RTR" ]] || S_RTR="off"

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

# ── Версии модуля и tools ───────────────────────────────────────────────────
#
# Сравнивается только major.minor: патч-часть — дата сборки (3.1.20260812), на
# возможности она не влияет. Строка, которую не удалось разобрать, считается
# устаревшей: это консервативный исход, он лишь запретит записать параметр.

# awg_version_ge <строка> — 0, если версия не ниже 3.1.
awg_version_ge() {
    local v="${1:-}" maj min
    [[ "$v" =~ ([0-9]+)\.([0-9]+) ]] || return 1
    maj=${BASH_REMATCH[1]}; min=${BASH_REMATCH[2]}
    (( maj > AWG31_MIN_MAJOR || (maj == AWG31_MIN_MAJOR && min >= AWG31_MIN_MINOR) ))
}

# Версия модуля, ЗАГРУЖЕННОГО в ядро. Именно она решает, примет ли устройство
# RandomTrailers, и она может отличаться от версии на диске — ровно так
# выглядит сервер сразу после обновления пакетов, до перезагрузки.
awg_module_loaded_version() {
    cat /sys/module/amneziawg/version 2>/dev/null | tr -d '[:space:]'
}

# Версия модуля НА ДИСКЕ: собран, но, возможно, ещё не загружен.
awg_module_disk_version() {
    modinfo amneziawg 2>/dev/null | awk '/^version:/ { print $2; exit }'
}

awg_tools_version() {
    awg --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
}

# require_awg31 <зачем> — не пускает дальше, если 3.1 не поддерживается.
#
# Разделяет два случая, потому что действие у них разное: если на диске уже
# 3.1, обновлять нечего и нужна перезагрузка; предложить здесь apt было бы
# враньём — он ничего не изменит, и человек застрял бы в цикле.
require_awg31() {
    local what="${1:-этот параметр}" loaded disk tools
    loaded=$(awg_module_loaded_version)
    disk=$(awg_module_disk_version)
    tools=$(awg_tools_version)

    if ! awg_version_ge "$tools"; then
        log_err "amneziawg-tools версии ${tools:-неизвестно} не знают $what — нужна 3.1 или новее."
        log_err "Обновите пакеты: apt-get update && apt-get install --only-upgrade amneziawg-tools"
        return 1
    fi

    if awg_version_ge "$loaded"; then return 0; fi

    if awg_version_ge "$disk"; then
        log_err "модуль ядра ${disk} уже собран, но в памяти всё ещё ${loaded:-не загружен}."
        log_err "Нужна ПЕРЕЗАГРУЗКА — заменить загруженный модуль иначе нечем."
        log_err "Обновлять пакеты не нужно, они уже свежие."
    else
        log_err "модуль ядра версии ${loaded:-не загружен} не знает $what — нужна 3.1 или новее."
        log_err "Обновите пакеты и перезагрузитесь:"
        log_err "  apt-get update && apt-get install --only-upgrade amneziawg-dkms amneziawg-tools"
    fi
    return 1
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
    log_err "в $SERVER_CONF нет HeaderProtectionKey — это не конфиг AWG 3.x."
    log_err "Проверьте, тот ли это конфиг: $SERVER_CONF"
    exit 1
}

# require_iface_awg31 — не даёт выдать клиента на интерфейсе, созданном до 3.1.
#
# Молчаливый отказ здесь дороже любого другого: клиент получил бы
# RandomTrailers, которого нет у сервера, и туннель не встал бы ВООБЩЕ — без
# ошибки в логах, без единого пакета, просто тишина. Отличить это от «провайдер
# режет» человек не может, поэтому ловим до выдачи конфига.
#
# Чинится одной командой, и она же — единственный способ: параметры интерфейса
# общие для всех его клиентов, выборочно перевести одного нельзя.
require_iface_awg31() {
    if [[ "${S_RTR:-off}" == "on" ]]; then return 0; fi
    log_err "интерфейс ${AWG_IFACE} создан до 3.1: в $SERVER_CONF нет RandomTrailers."
    log_err "Выдать на нём клиента 3.1 нельзя — туннель молча не встанет."
    log_err "Переведите интерфейс: $0 --iface ${AWG_IFACE} server-rekey"
    log_err "Клиентов после этого придётся выдать заново — параметры интерфейса общие."
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
    # Root проверяется ПЕРВЫМ. iptables и awg лежат в /usr/sbin, которого нет
    # в PATH обычного пользователя: без этой очерёдности запуск без sudo
    # сообщал «нет обязательных команд: iptables» и отправлял искать пакет
    # вместо того, чтобы сказать про права.
    [[ "$EUID" -eq 0 ]] || die "нужны права root: sudo $0 ..."

    # Переменная цикла объявлена local: без этого она перетирает одноимённую
    # переменную вызывающей функции — область видимости в bash динамическая.
    local missing=() dep
    for dep in awg awg-quick flock od grep awk sed ip iptables; do
        command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
    done
    [[ "${#missing[@]}" -eq 0 ]] || die "нет обязательных команд: ${missing[*]}"
    [[ -r /dev/urandom ]] || die "/dev/urandom нечитаем"

    # Каталог данных awg0 — это каталог самого скрипта. Запущенный из
    # распакованного репозитория, он сложил бы приватные ключи клиентов прямо
    # в дерево исходников, а следующая распаковка поверх легла бы рядом с
    # ними. Установленный экземпляр лежит в ~/awg, и там это ровно то, что
    # нужно, — поэтому запрещаем только исходники.
    if [[ -z "$AWG_ROOT_EXPLICIT" && -f "$SCRIPT_DIR/install-awg3.sh" && -d "$SCRIPT_DIR/tests" ]]; then
        log_err "запущен из каталога с исходниками: $SCRIPT_DIR"
        log_err "Клиентские ключи легли бы сюда же. Поставьте и работайте с установленным:"
        log_err "  sudo ./install-awg3.sh   (положит скрипт в ~/awg и даст awg3 в PATH)"
        log_err "  sudo awg3 ..."
        exit 1
    fi
}

# Файлы должны остаться у владельца каталога awg, иначе старый
# manage_amneziawg.sh, запущенный не под root, перестанет их читать.
_fix_owner() {
    local target="$1" owner
    owner=$(stat -c '%u:%g' "$AWG_ROOT" 2>/dev/null) || return 0
    chown "$owner" "$target" 2>/dev/null || true
}

# Владелец каталога берётся у РОДИТЕЛЯ — то есть у домашнего каталога того,
# чьи это ключи.
#
# _fix_owner здесь не годится: он смотрит на сам AWG_DIR, а каталог второго и
# следующих интерфейсов только что создан root'ом и остался бы root:root.
# Человек не смог бы ни прочитать свой конфиг, ни забрать его через scp — при
# том, что для awg0 всё работало, и разница выглядела бы необъяснимой.
_own_dir_from_parent() {
    local dir="$1" owner
    owner=$(stat -c '%u:%g' "$(dirname -- "$dir")" 2>/dev/null) || return 0
    chown "$owner" "$dir" 2>/dev/null || true
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

# Проверяется дважды: в main — то, что пришло флагами, и в server-init — то,
# что человек мог ввести в ответ на вопросы.
validate_profile_intensity() {
    case "$PROFILE" in
        quic|tls|dtls|sip|dns|noise) ;;
        *) die "неизвестный профиль: ${PROFILE}  (quic, tls, dtls, sip, dns, noise)" ;;
    esac
    case "$INTENSITY" in
        low|medium|high) ;;
        *) die "неизвестная интенсивность: ${INTENSITY}  (low, medium, high)" ;;
    esac
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
        # Повторяется за сервером: рассинхрон рвёт туннель целиком.
        printf 'RandomTrailers = on\n'
        printf 'DisableCookies = on\n'
        printf '\n'
        printf '[Peer]\n'
        printf 'PublicKey = %s\n' "$srv_pub"
        if [[ -n "$psk" ]]; then printf 'PresharedKey = %s\n' "$psk"; fi
        printf 'Endpoint = %s:%s\n' "$endpoint" "$port"
        printf 'AllowedIPs = %s\n' "$CLIENT_ALLOWED_IPS"
        printf 'PersistentKeepalive = %s\n' "$G_PKA"
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
        # Таймеры 3.0 на сервере: он тоже инициатор, когда пересогласует ключ.
        printf 'RekeyAfterTime = %s\n' "$G_RA"
        printf 'RekeyTimeout = %s\n' "$G_RT"
        printf 'RejectAfterTime = %s\n' "$G_RJ"
        printf 'KeepaliveTimeout = %s\n' "$G_KA"
        printf 'MaxHandshakeAttempts = %s\n' "$G_MHA"
        printf 'RandomTrailers = on\n'
        printf 'DisableCookies = on\n'
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

# ── Ссылка vpn:// для приложения Amnezia ────────────────────────────────────
#
# Формат ровно тот, который приложение AmneziaVPN принимает при импорте
# ссылки:
#
#   vpn:// + base64url( BE32(длина JSON) || zlib(JSON) )
#
# Четыре байта длины впереди — это формат QByteArray::qCompress из Qt, на
# котором построен клиент; без них qUncompress не разожмёт поток.
#
# Внутри JSON лежит ВТОРОЙ JSON строкой в поле last_config, а тот несёт
# целиком текст клиентского конфига в поле config. Двойная вложенность не
# наша выдумка — так устроен формат.
#
# Параметры, которых в структурированных полях формата нет
# (HeaderProtectionKey, ContentPaddingAddition, таймеры 3.0), кладутся туда
# же по именам ключей конфига: приложение, которое их не знает, лишние поля
# проигнорирует, а полный текст конфига в любом случае едет в config.

# Обрезка пробелов по краям — значения из конфига приходят с ними постоянно.
_trim_ws() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Экранирование строки для JSON. Пяти символов достаточно: другого
# управляющего в конфиге взяться неоткуда.
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

# adler32 по stdin — хвост zlib-потока. Печатается восемью hex-цифрами.
_adler32() {
    od -An -v -tu1 | awk '
        BEGIN { a = 1; b = 0 }
        {
            for (i = 1; i <= NF; i++) {
                a = (a + $i) % 65521
                b = (b + a) % 65521
            }
        }
        # Двумя половинами: %x от 32-битного значения в mawk переполняется.
        END { printf "%04x%04x", b, a }
    '
}

# Четыре байта числа, старший вперёд.
_be32() {
    local n="$1"
    printf '%b' "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' \
        "$(( (n >> 24) & 255 ))" "$(( (n >> 16) & 255 ))" \
        "$(( (n >> 8) & 255 ))"  "$(( n & 255 ))")"
}

# zlib-поток из файла в stdout.
#
# Отдельного упаковщика zlib в системе может не быть, зато gzip есть всегда,
# а deflate внутри у них один и тот же — различаются только обёртки. С флагом
# -n gzip не пишет в заголовок имя файла и время, поэтому заголовок ровно
# 10 байт, а хвост (CRC32 + размер) — 8; остаётся заменить их на пару
# 0x78 0x9c впереди и adler32 в конце.
_zlib_compress() {
    local src="$1" gz size head4 adler
    gz="${src}.gz"
    # Внутри сжатого — приватный ключ клиента, поэтому файл создаётся сразу
    # закрытым: umask ставится в подоболочке вместе с самим перенаправлением.
    ( umask 077; gzip -c -n -9 < "$src" > "$gz" ) || { rm -f "$gz"; return 1; }
    size=$(wc -c < "$gz"); size=$(_trim_ws "$size")

    head4=$(head -c 4 "$gz" | od -An -v -tx1 | tr -d ' \n')
    # Заголовок обязан быть каноническим: 1f8b (магия), 08 (deflate), 00
    # (флагов нет). Иначе смещения ниже уедут и получится мусор.
    if [[ "$head4" != "1f8b0800" ]]; then
        rm -f "$gz"
        log_warn "неожиданный заголовок gzip ($head4)"
        return 1
    fi

    adler=$(_adler32 < "$src")

    printf '\x78\x9c'
    tail -c +11 "$gz" | head -c "$(( size - 18 ))"
    printf '%b' "\\x${adler:0:2}\\x${adler:2:2}\\x${adler:4:2}\\x${adler:6:2}"
    rm -f "$gz"
}

# build_vpn_uri <конфиг> [описание] — печатает ссылку vpn:// в stdout.
#
# Описание — имя сервера в списке приложения; по умолчанию берётся хост из
# Endpoint.
build_vpn_uri() {
    local conf="$1" desc="${2:-}"
    [[ -f "$conf" ]] || { log_warn "конфиг не найден: $conf"; return 1; }

    local dep
    for dep in gzip base64 od head tail; do
        command -v "$dep" >/dev/null 2>&1 \
            || { log_warn "нет команды $dep — ссылка vpn:// не создана"; return 1; }
    done

    local priv pub psk addr dns mtu endpoint_raw aips keepalive
    priv=$(_conf_value "$conf" PrivateKey interface)
    addr=$(_conf_value "$conf" Address interface)
    dns=$(_conf_value "$conf" DNS interface)
    mtu=$(_conf_value "$conf" MTU interface)
    pub=$(_conf_value "$conf" PublicKey peer)
    psk=$(_conf_value "$conf" PresharedKey peer)
    endpoint_raw=$(_conf_value "$conf" Endpoint peer)
    aips=$(_conf_value "$conf" AllowedIPs peer)
    keepalive=$(_conf_value "$conf" PersistentKeepalive peer)

    [[ -n "$priv" ]] || { log_warn "в $conf нет PrivateKey"; return 1; }
    [[ -n "$pub" ]]  || { log_warn "в $conf нет PublicKey сервера"; return 1; }
    [[ -n "$endpoint_raw" ]] || { log_warn "в $conf нет Endpoint"; return 1; }

    # Хост и порт. IPv6 приходит в скобках — [::1]:443, поэтому обрезать по
    # последнему двоеточию нельзя.
    local host port
    if [[ "$endpoint_raw" == \[*\]:* ]]; then
        host="${endpoint_raw%%]:*}"; host="${host#\[}"
        port="${endpoint_raw##*]:}"
    else
        host="${endpoint_raw%:*}"
        port="${endpoint_raw##*:}"
    fi
    # port уезжает в JSON единственным числом без кавычек: пустое или
    # нечисловое значение сделало бы JSON синтаксически битым, и приложение
    # молча откажется импортировать ссылку.
    [[ "$port" =~ ^[0-9]+$ ]] || { log_warn "непонятный Endpoint '$endpoint_raw'"; return 1; }

    local ip4="" ip6="" part
    while IFS= read -r part; do
        part=$(_trim_ws "$part")
        [[ -n "$part" ]] || continue
        part="${part%%/*}"
        if [[ "$part" == *:* ]]; then ip6="${ip6:-$part}"; else ip4="${ip4:-$part}"; fi
    done < <(printf '%s\n' "${addr//,/$'\n'}")

    local dns1 dns2
    dns1=$(_trim_ws "${dns%%,*}")
    if [[ "$dns" == *,* ]]; then dns2=$(_trim_ws "${dns#*,}"); dns2="${dns2%%,*}"; else dns2="$dns1"; fi
    dns1="${dns1:-1.1.1.1}"; dns2="${dns2:-$dns1}"
    mtu="${mtu:-1280}"
    keepalive="${keepalive:-33}"
    desc="${desc:-$host}"

    # AllowedIPs в формате уезжает массивом, а не строкой.
    local aips_json="" first=1
    while IFS= read -r part; do
        part=$(_trim_ws "$part")
        [[ -n "$part" ]] || continue
        if [[ "$first" -eq 1 ]]; then first=0; else aips_json+=","; fi
        aips_json+="\"$(_json_escape "$part")\""
    done < <(printf '%s\n' "${aips//,/$'\n'}")
    [[ -n "$aips_json" ]] || aips_json='"0.0.0.0/0"'

    local inner="{" key val
    for key in H1 H2 H3 H4 Jc Jmin Jmax S1 S2 S3 S4; do
        val=$(_conf_value "$conf" "$key" interface)
        inner+="\"${key}\":\"$(_json_escape "$val")\","
    done
    # I1-I5 в режиме роутера пустуют, а пустые поля приложение принимает за
    # заданные — поэтому только непустые.
    for key in I1 I2 I3 I4 I5; do
        val=$(_conf_value "$conf" "$key" interface)
        [[ -n "$val" ]] || continue
        inner+="\"${key}\":\"$(_json_escape "$val")\","
    done
    # RandomTrailers и DisableCookies обязаны попасть в ссылку: приложение
    # строит туннель по этим полям, а не по тексту в config. Без них клиент,
    # поднятый из ссылки, окажется с выключенным RandomTrailers против сервера
    # с включённым — и туннель молча не встанет.
    for key in HeaderProtectionKey ContentPaddingAddition RekeyAfterTime \
               RekeyTimeout RejectAfterTime KeepaliveTimeout MaxHandshakeAttempts \
               RandomTrailers DisableCookies; do
        val=$(_conf_value "$conf" "$key" interface)
        [[ -n "$val" ]] || continue
        inner+="\"${key}\":\"$(_json_escape "$val")\","
    done
    inner+="\"allowed_ips\":[${aips_json}],"
    inner+="\"client_ip\":\"$(_json_escape "$ip4")\","
    inner+="\"client_ipv6\":\"$(_json_escape "$ip6")\","
    inner+="\"client_priv_key\":\"$(_json_escape "$priv")\","
    # Без psk_key импорт теряет PresharedKey, и рукопожатие не проходит —
    # текста конфига в поле config для этого недостаточно.
    if [[ -n "$psk" ]]; then inner+="\"psk_key\":\"$(_json_escape "$psk")\","; fi
    inner+="\"config\":\"$(_json_escape "$(<"$conf")")\","
    inner+="\"hostName\":\"$(_json_escape "$host")\",\"mtu\":\"$(_json_escape "$mtu")\","
    inner+="\"persistent_keep_alive\":\"$(_json_escape "$keepalive")\",\"port\":${port},"
    inner+="\"server_pub_key\":\"$(_json_escape "$pub")\"}"

    local outer="{"
    outer+='"containers":[{"awg":{"isThirdPartyConfig":true,'
    outer+="\"last_config\":\"$(_json_escape "$inner")\","
    # "3.1" — та же метка, что ставит официальное приложение (awgV3 в
    # protocolConstants.h). Поле справочное: туннель строится по набору полей
    # в last_config, а версия идёт в подпись сервера в интерфейсе.
    outer+="\"port\":\"${port}\",\"protocol_version\":\"3.1\",\"transport_proto\":\"udp\"},"
    outer+='"container":"amnezia-awg"}],'
    outer+='"defaultContainer":"amnezia-awg",'
    outer+="\"description\":\"$(_json_escape "$desc")\","
    outer+="\"dns1\":\"$(_json_escape "$dns1")\",\"dns2\":\"$(_json_escape "$dns2")\","
    outer+="\"hostName\":\"$(_json_escape "$host")\"}"

    # Приватный ключ клиента идёт через файл рядом с конфигом (каталог 700),
    # а не через /tmp, который читаем всем.
    local tmp size b64
    tmp=$(mktemp "${conf}.uri.XXXXXX") || { log_warn "mktemp не сработал"; return 1; }
    chmod 600 "$tmp"
    printf '%s' "$outer" > "$tmp" || { rm -f "$tmp" "${tmp}.gz"; return 1; }
    size=$(wc -c < "$tmp"); size=$(_trim_ws "$size")

    if ! b64=$({ _be32 "$size"; _zlib_compress "$tmp"; } | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='); then
        rm -f "$tmp" "${tmp}.gz"
        log_warn "не удалось собрать ссылку vpn://"
        return 1
    fi
    rm -f "$tmp" "${tmp}.gz"
    [[ -n "$b64" ]] || { log_warn "пустая ссылка vpn://"; return 1; }

    printf 'vpn://%s\n' "$b64"
}

# generate_link <имя> <путь к conf> — файл со ссылкой рядом с конфигом.
# Готовая ссылка остаётся в LINK_LAST, чтобы её можно было ещё и напечатать.
generate_link() {
    local name="$1" conf="$2"
    LINK_LAST=""
    [[ "$MAKE_LINK" -eq 1 ]] || return 0

    local uri file="${conf%.conf}.vpnuri" tmp
    if ! uri=$(build_vpn_uri "$conf"); then
        log_warn "ссылка vpn:// для '$name' не создана"
        return 1
    fi

    tmp=$(mktemp "${file}.tmp.XXXXXX") || { log_warn "mktemp не сработал"; return 1; }
    chmod 600 "$tmp"
    printf '%s\n' "$uri" > "$tmp" || { rm -f "$tmp"; return 1; }
    if ! mv -f "$tmp" "$file"; then
        rm -f "$tmp"
        log_warn "не записана ссылка $file"
        return 1
    fi
    _fix_owner "$file"
    LINK_LAST="$uri"
    log_ok "ссылка: $file"
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
# Создание сервера AWG 3.1 с нуля: ключи, параметры обфускации, NAT, конфиг,
# форвардинг. Промежуточной стадии 2.0 не существует, server-rekey здесь не
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
            # Установщик по умолчанию глушит IPv6 целиком: на момент установки
            # ещё неизвестно, понадобится ли он в туннеле. Снимаем отключение
            # здесь, где ответ уже есть, — иначе awg-quick не сможет назначить
            # интерфейсу IPv6-адрес и сервис останется в failed.
            #
            # Файлы sysctl.d применяются по алфавиту, и 99-awg3.conf идёт
            # после 99-amneziawg-forwarding.conf установщика — то есть
            # последнее слово остаётся за нами.
            printf 'net.ipv6.conf.all.disable_ipv6 = 0\n'
            printf 'net.ipv6.conf.default.disable_ipv6 = 0\n'
            printf 'net.ipv6.conf.lo.disable_ipv6 = 0\n'
        fi
    } > "$file" || { log_err "не записан $file"; return 1; }
    chmod 644 "$file"

    if command -v sysctl >/dev/null 2>&1; then
        sysctl -q -p "$file" 2>/dev/null \
            || log_warn "sysctl не применил $file, потребуется перезагрузка"
    fi
    return 0
}

# ask_server_params — интерактивные вопросы перед созданием интерфейса.
#
# Живут здесь, а не в установщике: установщик ставит AmneziaWG, настройка
# интерфейса — задача awg3.sh, и параметры спрашивает тот, кто их применяет.
# Значения, заданные флагами, показываются подсказкой по умолчанию — Enter
# оставляет их как есть.
#
# Молчит при -y и при неинтерактивном вводе: скриптам вопросы задавать некому.
ask_server_params() {
    [[ "$ASSUME_YES" -eq 0 ]] || return 0
    [[ -t 0 ]] || return 0

    local answer

    printf '
'
    log "Параметры интерфейса ${AWG_IFACE}. Enter оставляет значение в скобках."
    printf '
'

    if [[ -z "$SRV_PORT" ]]; then
        read -rp "  UDP-порт [Enter — случайный]: " answer < /dev/tty
        [[ -z "$answer" ]] || SRV_PORT="$answer"
    else
        read -rp "  UDP-порт [${SRV_PORT}]: " answer < /dev/tty
        [[ -z "$answer" ]] || SRV_PORT="$answer"
    fi

    read -rp "  Подсеть туннеля [${SRV_SUBNET}]: " answer < /dev/tty
    [[ -z "$answer" ]] || SRV_SUBNET="$answer"

    read -rp "  MTU [${SRV_MTU}]: " answer < /dev/tty
    [[ -z "$answer" ]] || SRV_MTU="$answer"

    read -rp "  Изолировать клиентов друг от друга? [y/N]: " answer < /dev/tty
    case "$answer" in [yY]*) SRV_ISOLATION="on" ;; *) SRV_ISOLATION="off" ;; esac

    read -rp "  Включить IPv6 в туннеле? [y/N]: " answer < /dev/tty
    case "$answer" in [yY]*) SRV_IPV6="on" ;; *) SRV_IPV6="off" ;; esac

    read -rp "  Профиль мимикрии quic|tls|dtls|sip|dns|noise [${PROFILE}]: " answer < /dev/tty
    [[ -z "$answer" ]] || PROFILE="$answer"

    read -rp "  Интенсивность low|medium|high [${INTENSITY}]: " answer < /dev/tty
    [[ -z "$answer" ]] || INTENSITY="$answer"

    if [[ -z "${ENDPOINT_OVERRIDE:-}" ]]; then
        printf '
'
        log "  Имя хоста попадёт в Endpoint выданных конфигов. DNS-имя лучше IP:"
        log "  при смене адреса сервера старые конфиги продолжат работать."
        read -rp "  Имя хоста [Enter — определить внешний IP]: " answer < /dev/tty
        [[ -z "$answer" ]] || ENDPOINT_OVERRIDE="$answer"
    fi
    printf '
'
}

# open_firewall_port — открыть порт интерфейса в ufw.
#
# Раньше это делал установщик, потому что знал порт. Теперь порт знает только
# тот, кто создаёт интерфейс, — и это единственное место, где второй, третий и
# любой следующий интерфейс получают свой порт открытым сам собой.
#
# Неактивный или отсутствующий ufw — не ошибка: фаервол мог быть отключён
# намеренно, и включать его за человека мы не станем.
open_firewall_port() {
    local port="$1" old="${2:-}" nic="${3:-}"
    command -v ufw >/dev/null 2>&1 || return 0
    ufw status 2>/dev/null | grep -q "Status: active" || {
        log "ufw неактивен — порт ${port}/udp открывать не нужно"
        return 0
    }

    # Прежнее правило удаляется только при смене порта: иначе пересоздание
    # интерфейса на том же порту на мгновение закрывало бы его самому себе.
    if [[ -n "$old" && "$old" != "$port" ]]; then
        if ufw delete allow "${old}/udp" >/dev/null 2>&1; then
            log "ufw: убрано прежнее правило ${old}/udp"
        fi
    fi

    if ufw allow "${port}/udp" comment "AmneziaWG ${AWG_IFACE}" >/dev/null 2>&1; then
        log_ok "ufw: открыт ${port}/udp"
    else
        log_warn "не удалось открыть ${port}/udp в ufw — откройте вручную"
    fi

    # Маршрут наружу. PostUp вставляет свой ACCEPT первым правилом FORWARD, так
    # что трафик пойдёт и без этого, но с DEFAULT_FORWARD_POLICY=DROP правило
    # ufw описывает то же намерение в его собственных терминах — и переживает
    # `ufw reload`, который цепочки iptables пересобирает.
    if [[ -n "$nic" ]]; then
        ufw route allow in on "$AWG_IFACE" out on "$nic"             comment "AmneziaWG ${AWG_IFACE}" >/dev/null 2>&1             || log_warn "ufw: не добавлен маршрут ${AWG_IFACE} -> ${nic}"
    fi
    ufw reload >/dev/null 2>&1 || true
}

cmd_server_init() {
    guard_existing_server || exit 1

    # Проверка до записи, а не по коду возврата awg. Конфиг с RandomTrailers на
    # модуле ниже 3.1 не ломает уже поднятый интерфейс — он ломает СЛЕДУЮЩИЙ
    # запуск: awg setconf отдаёт «Invalid argument», awg-quick сносит
    # устройство, сервис уходит в failed. Такую мину лучше не закладывать.
    require_awg31 "параметры 3.1" || exit 1

    ask_server_params
    validate_profile_intensity

    [[ -n "$SRV_PORT" ]] || { rand_int 1024 65000; SRV_PORT=$REPLY; }
    validate_awg_port "$SRV_PORT" || exit 1
    validate_subnet   "$SRV_SUBNET" || exit 1
    validate_mtu      "$SRV_MTU"    || exit 1
    case "$SRV_ISOLATION" in on|off) ;; *) die "isolation ожидает on|off: $SRV_ISOLATION" ;; esac
    case "$SRV_IPV6"      in on|off) ;; *) die "ipv6 ожидает on|off: $SRV_IPV6" ;; esac
    port_is_free "$SRV_PORT" || die "UDP-порт $SRV_PORT уже занят"

    # Прежний порт нужен до перезаписи конфига: по нему снимается старое
    # правило ufw, если порт сменился.
    local old_port="" old_subnet=""
    if [[ -f "$SERVER_CONF" ]]; then
        old_port=$(_iface_value ListenPort)
        old_subnet=$(_iface_value Address)
        old_subnet="${old_subnet%%,*}"
        old_subnet="${old_subnet//[[:space:]]/}"
    fi

    # Смена подсети при переносе пиров: адреса у них остаются прежние и в новую
    # подсеть не попадают. Туннель для таких клиентов не поднимется, и по
    # конфигу этого не видно — предупреждаем до записи, а не после.
    if [[ -n "$old_subnet" && "$old_subnet" != "$SRV_SUBNET" ]] \
       && grep -q '^[[:space:]]*\[Peer\]' "$SERVER_CONF" 2>/dev/null; then
        log_warn "подсеть меняется: ${old_subnet} -> ${SRV_SUBNET}"
        log_warn "Перенесённые пиры сохранят прежние адреса и окажутся вне новой подсети."
        log_warn "Их придётся выдать заново: $0 --iface ${AWG_IFACE} remove ИМЯ, затем add ИМЯ"
    fi

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

    mkdir -p "$AWG_DIR"; chmod 700 "$AWG_DIR"; _own_dir_from_parent "$AWG_DIR"
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

    open_firewall_port "$SRV_PORT" "$old_port" "$nic"

    if [[ "$DO_APPLY" -eq 1 ]]; then
        systemctl enable --now "awg-quick@${AWG_IFACE}" 2>/dev/null \
            || log_warn "сервис не запустился, смотрите: systemctl status awg-quick@${AWG_IFACE}"
    fi

    log_ok "интерфейс ${AWG_IFACE}: сервер AWG 3.1 создан, $SERVER_CONF"
    log "  порт: ${SRV_PORT}/udp, подсеть: ${SRV_SUBNET}, MTU: ${SRV_MTU}"
    log "  изоляция клиентов: ${SRV_ISOLATION}, IPv6: ${SRV_IPV6}"
    # Подсказка обязана нести --iface: без него add уйдёт на awg0, а человек
    # решит, что завёл клиента только что созданному интерфейсу.
    if [[ "$AWG_IFACE" == "awg0" ]]; then
        log "  добавить клиента: $0 add ИМЯ"
    else
        log "  добавить клиента: $0 --iface ${AWG_IFACE} add ИМЯ"
    fi
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

# ── Команда: set-endpoint ───────────────────────────────────────────────────
#
# Меняет имя хоста для клиентских Endpoint, не трогая ничего больше. Отдельная
# команда нужна потому, что единственная альтернатива — server-init --force —
# перегенерирует общие параметры и обесценит все выданные конфиги.

cmd_set_endpoint() {
    local name="$1"
    [[ -n "$name" ]] || die "укажите имя хоста: $0 set-endpoint vpn.example.com"
    [[ "$name" =~ ^[a-zA-Z0-9._-]+$ ]] \
        || die "недопустимое имя хоста: '$name'"
    [[ -f "$SERVER_CONF" ]] || die "серверный конфиг не найден: $SERVER_CONF"

    local previous
    previous=$(server_endpoint_name)

    _backup_file "$SERVER_CONF"

    local tmp
    tmp=$(mktemp "${SERVER_CONF}.tmp.XXXXXX") || die "mktemp не сработал"
    chmod 600 "$tmp"

    # Строка живёт в [Interface] сразу после заголовка. Прежняя убирается, а
    # не дублируется: иначе server_endpoint_name читал бы первую попавшуюся.
    awk -v host="$name" '
        BEGIN { done = 0; in_peer = 0 }
        /^[[:space:]]*\[Peer\]/ { in_peer = 1 }
        # Прежняя строка удаляется независимо от флага: она идёт ПОСЛЕ
        # [Interface], то есть встречается уже со взведённым done, и проверка
        # на него оставила бы в файле обе строки разом.
        !in_peer && /^[[:space:]]*#_Endpoint[[:space:]]*=/ { next }
        /^[[:space:]]*\[Interface\]/ && !done {
            print
            printf "#_Endpoint = %s\n", host
            done = 1
            next
        }
        { print }
    ' "$SERVER_CONF" > "$tmp" || { rm -f "$tmp"; die "не перестроен $SERVER_CONF"; }

    grep -qxF "#_Endpoint = ${name}" "$tmp" \
        || { rm -f "$tmp"; die "строка не добавилась — в конфиге нет секции [Interface]?"; }

    mv -f "$tmp" "$SERVER_CONF" || { rm -f "$tmp"; die "не записан $SERVER_CONF"; }
    chmod 600 "$SERVER_CONF"

    if [[ -n "$previous" ]]; then
        log_ok "имя хоста изменено: ${previous} → ${name}"
    else
        log_ok "имя хоста задано: ${name}"
    fi
    log "Уже выданные конфиги продолжат работать по прежнему адресу."
    log "Новое имя попадёт в конфиги, созданные дальше: $0 add ИМЯ"
}

# ── Команда: add ────────────────────────────────────────────────────────────

cmd_add() {
    local name="$1"
    validate_client_name "$name"
    load_server_params
    require_server_awg3
    require_iface_awg31

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

    # При переезде между интерфейсами ключ клиента берётся прежний: на сервере
    # это тот же пир, а у человека — та же личность. Меняются только общие
    # параметры интерфейса, адрес и порт.
    if [[ -n "$REUSE_PRIVKEY" ]]; then
        privkey=$(tr -d '[:space:]' < "$REUSE_PRIVKEY") \
            || die "не прочитан ключ клиента: $REUSE_PRIVKEY"
        [[ -n "$privkey" ]] || die "пустой ключ клиента: $REUSE_PRIVKEY"
    else
        privkey=$(awg genkey)
    fi
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
    # Ссылка — приятное дополнение, а не условие успеха: клиент уже создан,
    # применён и работоспособен с конфигом и QR даже без неё.
    generate_link "$name" "$conf" || true
    apply_peers || true

    log_ok "клиент '$name' создан: ${client_ip}${client_ip6:+, $client_ip6}"
    log "  каталог: $cdir"
    log "  конфиг: $conf"
    if [[ -f "${conf%.conf}.vpnuri" ]]; then log "  ссылка: ${conf%.conf}.vpnuri"; fi
    log "  профиль обфускации: AWG 3.1 / ${PROFILE} / ${INTENSITY}"
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

# ── Команда: link ───────────────────────────────────────────────────────────
#
# Пересобирает файл со ссылкой по уже существующему конфигу. Нужна тем, у
# кого клиенты созданы прежними версиями скрипта, и после правки конфига
# руками. Ключи и пир при этом не трогаются: ссылка — производная от конфига.

cmd_link() {
    local names=()
    if [[ $# -gt 0 ]]; then
        names=("$@")
    else
        mapfile -t names < <(list_client_names)
        [[ "${#names[@]}" -gt 0 ]] || die "клиентов нет"
    fi

    # Команду вызвали явно, значит ссылка нужна вопреки --no-qr-подобным
    # умолчаниям.
    MAKE_LINK=1

    local name conf ok=0 failed=0
    for name in "${names[@]}"; do
        validate_client_name "$name"
        conf=$(client_conf_path "$name")
        if [[ ! -f "$conf" ]]; then
            log_err "'$name': конфиг не найден"
            failed=$((failed + 1))
            continue
        fi
        if generate_link "$name" "$conf"; then
            ok=$((ok + 1))
            # Одно имя — почти всегда «покажи мне ссылку»; списком же
            # печатать ссылки бессмысленно, они по несколько килобайт.
            if [[ "${#names[@]}" -eq 1 ]]; then printf '%s\n' "$LINK_LAST"; fi
        else
            failed=$((failed + 1))
        fi
    done

    if [[ "${#names[@]}" -gt 1 ]]; then log "Готово: ссылок $ok, с ошибками $failed"; fi
    [[ "$failed" -eq 0 ]]
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

        # Прежние раскладки awg0: клиенты в корне и совсем старая плоская.
        # Каталоги интерфейсов сюда не попадают — внутри awg1 нет awg1.conf.
        if [[ "$AWG_IFACE" == "awg0" ]]; then
            for d in "$AWG_ROOT"/*/; do
                [[ -d "$d" ]] || continue
                base=$(basename "$d")
                if [[ -f "$d/$base.conf" ]]; then printf '%s\n' "$base"; fi
            done
            for f in "$AWG_ROOT"/*.conf; do
                [[ -f "$f" ]] || continue
                # Серверный конфиг, если он оказался в том же каталоге, клиентом
                # не является: у него есть ListenPort, которого у клиента не бывает.
                if [[ "$f" -ef "$SERVER_CONF" ]]; then continue; fi
                if grep -qE '^[[:space:]]*ListenPort[[:space:]]*=' "$f" 2>/dev/null; then continue; fi
                printf '%s\n' "$(basename "$f" .conf)"
            done
        fi
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

    local name conf addr hpk ver match c_s1 c_h1 c_rtr layout
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

        c_rtr=$(_conf_value "$conf" RandomTrailers interface)
        [[ -n "$c_rtr" ]] || c_rtr="off"

        if [[ "$c_rtr" == "on" ]]; then ver="3.1"
        elif [[ -n "$hpk" ]]; then ver="3.0"
        else ver="—"; fi

        # RandomTrailers сравнивается наравне с S1/H1/HeaderProtectionKey:
        # рассинхрон по нему рвёт туннель так же полно и так же молча, а
        # выданный до перехода на 3.1 конфиг выглядит совершенно исправным.
        if [[ "$c_s1" == "${S_S1}" && "$c_h1" == "${S_H1}"               && "$hpk" == "${S_HPK}" && "$c_rtr" == "${S_RTR:-off}" ]]; then
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
    if ! server_is_awg3; then
        printf 'Интерфейс %s: конфиг не похож на наш — нет HeaderProtectionKey\n' "$AWG_IFACE"
    elif [[ "${S_RTR:-off}" == "on" ]]; then
        printf 'Интерфейс %s: AWG 3.1 (S1=%s H1=%s)\n' \
            "$AWG_IFACE" "$S_S1" "$S_H1"
    else
        printf 'Интерфейс %s: AWG 3.0 — новых клиентов на нём выдать нельзя\n' "$AWG_IFACE"
        printf '  переведите на 3.1: %s --iface %s server-rekey\n' "$0" "$AWG_IFACE"
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
    local src_dir="$AWG_ROOT/$name"
    if [[ ! -f "$AWG_ROOT/${name}.conf" && ! -f "$src_dir/${name}.conf" ]]; then
        log_err "'$name': конфиг не найден"
        return 1
    fi

    mkdir -p "$cdir" || { log_err "'$name': не создан каталог $cdir"; return 1; }
    chmod 700 "$cdir"; _fix_owner "$cdir"

    local src dst
    for src in "$src_dir/${name}.conf" "$src_dir/${name}.png" \
               "$src_dir/${name}.vpnuri" "$src_dir/${name}.vpnuri.png" \
               "$src_dir/${name}.private" "$src_dir/${name}.public" \
               "$AWG_ROOT/${name}.conf" "$AWG_ROOT/${name}.png" \
               "$AWG_ROOT/${name}.vpnuri" "$AWG_ROOT/${name}.vpnuri.png" \
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
    for bak in "$src_dir/${name}.conf".bak-* "$AWG_ROOT/${name}.conf".bak-*; do
        [[ -f "$bak" ]] || continue
        if mv -f "$bak" "$cdir/"; then moved=$((moved + 1)); fi
    done

    # Опустевший каталог прежней раскладки убираем — он больше ни на что не
    # указывает, а оставленный сбивает с толку при следующем migrate.
    [[ "$src_dir" == "$cdir" ]] || rmdir "$src_dir" 2>/dev/null || true

    log_ok "'$name': перенесено файлов — $moved → $cdir"
    return 0
}

cmd_migrate() {
    local names=() name flat=()
    mapfile -t names < <(list_client_names)

    for name in "${names[@]}"; do
        if [[ ! -f "$AWG_DIR/$name/$name.conf" ]]; then
            flat+=("$name")
        fi
    done

    local keys_in_root=0
    if [[ "$AWG_IFACE" == "awg0" && ( -f "$AWG_ROOT/server_private.key" || -f "$AWG_ROOT/server_public.key" ) ]]; then
        keys_in_root=1
    fi

    if [[ "${#flat[@]}" -eq 0 && "$keys_in_root" -eq 0 ]]; then
        log_ok "переносить нечего: всё уже разложено по каталогам интерфейсов"
        return 0
    fi

    if [[ "${#flat[@]}" -gt 0 ]]; then
        log "Будут перенесены в каталог интерфейса ${AWG_IFACE}: ${flat[*]}"
    fi
    [[ "$keys_in_root" -eq 0 ]] || log "Ключи сервера из корня тоже переедут."
    log "Файлы перемещаются (conf, png, ключи, бэкапы), сервер не затрагивается."
    confirm "Продолжить?" || die "отменено"

    local ok=0 fail=0
    for name in "${flat[@]}"; do
        if migrate_one "$name"; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
    done

    # Ключи сервера awg0 прежде лежали в корне — там, где тогда был его
    # каталог. Переносим следом: приватный ключ, забытый в корне, ничем не
    # управляется и никому не нужен, а дублировать его негде.
    if [[ "$AWG_IFACE" == "awg0" ]]; then
        local key
        for key in server_private.key server_public.key; do
            [[ -f "$AWG_ROOT/$key" && ! -f "$AWG_DIR/$key" ]] || continue
            if mv -f "$AWG_ROOT/$key" "$AWG_DIR/$key"; then
                _fix_owner "$AWG_DIR/$key"
                log "ключ сервера перенесён: $AWG_DIR/$key"
            else
                log_warn "не перенесён $AWG_ROOT/$key"
            fi
        done
    fi

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
              "$AWG_DIR/${name}.vpnuri" "$AWG_DIR/${name}.vpnuri.png" \
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
    local bdir="$AWG_ROOT/backups"
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

# ── Команда: migrate-client ─────────────────────────────────────────────────
#
# Заводит существующего клиента на другом интерфейсе, сохраняя его ключевую
# пару: на сервере это остаётся тот же пир, у человека — та же личность.
# Меняются общие параметры интерфейса, адрес в туннеле и порт.
#
# С исходного интерфейса клиент НЕ удаляется намеренно. Пока он там есть,
# прежняя ссылка продолжает работать, и человек переезжает тогда, когда сам
# импортирует новую. Это и делает переезд безостановочным; убрать старого
# пира можно потом обычным remove.
cmd_migrate_client() {
    local name="$1"
    local from="$AWG_IFACE"

    [[ -n "$MIGRATE_TO" ]] || die "укажите целевой интерфейс: --to awgN"
    [[ "$MIGRATE_TO" != "$from" ]] || die "исходный и целевой интерфейс совпадают: $from"
    # Оба каталога вычисляются по имени интерфейса. Если их прибили
    # переменными окружения, клиент уехал бы в конфиг и каталог исходного
    # интерфейса — то есть переезда не случилось бы, а файлы перезаписались.
    [[ -z "$SERVER_CONF_EXPLICIT" ]] \
        || die "переезд несовместим с заданным AWG3_SERVER_CONF: путь вычисляется по интерфейсу"
    [[ -z "$AWG_ROOT_EXPLICIT" ]] \
        || die "переезд несовместим с заданным AWG3_DIR: каталог вычисляется по интерфейсу"
    validate_client_name "$name"

    local src_priv
    src_priv="$(client_dir "$name")/${name}.private"
    [[ -f "$src_priv" ]] \
        || die "у клиента '$name' не сохранён приватный ключ: $src_priv"

    local target_conf="/etc/amnezia/amneziawg/${MIGRATE_TO}.conf"
    [[ -f "$target_conf" ]] \
        || die "интерфейс $MIGRATE_TO не найден: $target_conf"

    log "переезд '$name': $from -> $MIGRATE_TO, ключ клиента сохраняется"

    REUSE_PRIVKEY="$src_priv"
    AWG_IFACE="$MIGRATE_TO"
    resolve_paths
    cmd_add "$name"

    log_ok "'$name' заведён на $MIGRATE_TO"
    log "На $from он остался: прежняя ссылка продолжает работать, пока человек не импортирует новую."
    log "Когда переедет — убрать старого: $0 --iface $from remove $name"
}

# ── Команда: ifaces ─────────────────────────────────────────────────────────
#
# Список серверных интерфейсов. Отдельного реестра нет намеренно: источник
# истины — сами конфиги в /etc/amnezia/amneziawg, расходиться с реальностью
# нечему. Формат — колонки с разделителем табуляцией, чтобы панель могла
# разобрать вывод, не вглядываясь в выравнивание.
cmd_ifaces() {
    local conf name port addr rtr ver clients state found=0

    printf 'ИНТЕРФЕЙС\tПОРТ\tПОДСЕТЬ\tВЕРСИЯ\tКЛИЕНТОВ\tСЕРВИС\n'
    for conf in /etc/amnezia/amneziawg/*.conf; do
        [[ -f "$conf" ]] || continue
        name=$(basename "$conf" .conf)
        found=1

        # Значения читаются тем же способом, что и в остальном скрипте, но по
        # чужому файлу — поэтому не через _iface_value, который смотрит только
        # в $SERVER_CONF.
        port=$(awk -F'=' '/^[[:space:]]*\[Peer\]/{exit} /^[[:space:]]*ListenPort[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$conf")
        addr=$(awk -F'=' '/^[[:space:]]*\[Peer\]/{exit} /^[[:space:]]*Address[[:space:]]*=/{sub(/^[^=]*=[[:space:]]*/,""); print; exit}' "$conf")
        rtr=$(awk -F'=' '/^[[:space:]]*\[Peer\]/{exit} /^[[:space:]]*RandomTrailers[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$conf")
        # grep -c печатает 0 и при этом возвращает 1: ветка `|| printf 0`
        # дописывала бы второй ноль через перевод строки, и колонки разъезжались.
        clients=$(grep -c '^[[:space:]]*\[Peer\]' "$conf" 2>/dev/null) || clients=0
        # Та же ловушка, что и с grep -c: `is-active` печатает inactive И
        # возвращает ненулевой код, поэтому ветка `||` дописывала бы второе
        # слово через перевод строки — строка таблицы разъезжалась на две.
        state=$(systemctl is-active "awg-quick@${name}" 2>/dev/null) || true
        [[ -n "$state" ]] || state="unknown"

        # Версия видна только по RandomTrailers: интерфейс без него создан до
        # 3.1, и клиента на нём выдать нельзя, пока не прошёл server-rekey.
        if [[ "$rtr" == "on" ]]; then ver="3.1"; else ver="3.0 — нужен server-rekey"; fi

        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$name" "${port:-?}" "${addr:-?}" "$ver" "$clients" "$state"
    done

    [[ "$found" -eq 1 ]] || log_warn "ни одного интерфейса в /etc/amnezia/amneziawg не найдено"
}

# ── Команда: iface ──────────────────────────────────────────────────────────
#
# Интерфейсами управляют одним набором: iface / iface add / iface remove.
# Прежние имена (ifaces, server-init) остались псевдонимами — их знает панель
# и помнят руки.

# Первое свободное имя вида awgN. Считаем от awg0: занятым считается любой, у
# которого есть конфиг, даже если сервис не запущен.
next_free_iface() {
    local n=0
    while [[ -f "/etc/amnezia/amneziawg/awg${n}.conf" ]]; do
        n=$(( n + 1 ))
        (( n < 100 )) || die "не найдено свободное имя интерфейса"
    done
    printf 'awg%s' "$n"
}

# iface remove — снести интерфейс целиком.
#
# Удаляются и ключи клиентов: держать их без интерфейса незачем, а забытая
# папка с приватными ключами хуже, чем её отсутствие. Поэтому спрашиваем, что
# именно исчезнет, и показываем число клиентов до, а не после.
cmd_iface_remove() {
    local name="$1"
    [[ -n "$name" ]] || die "укажите интерфейс: $0 iface remove awgN"
    [[ "$name" =~ ^[A-Za-z][A-Za-z0-9_-]{0,14}$ ]] || die "недопустимое имя: $name"

    local conf="/etc/amnezia/amneziawg/${name}.conf"
    [[ -f "$conf" ]] || die "интерфейс $name не найден: $conf"

    # Каталог клиентов вычисляется по тем же правилам, что и везде. Сам
    # awg3.sh лежит в корне, уровнем выше, — под удаление он не попадает.
    local dir="$AWG_ROOT/$name"

    local clients port
    clients=$(grep -c '^[[:space:]]*\[Peer\]' "$conf" 2>/dev/null) || clients=0
    port=$(awk -F'=' '/^[[:space:]]*\[Peer\]/{exit} /^[[:space:]]*ListenPort[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$conf")

    log_warn "Будет удалён интерфейс ${name}:"
    log "  конфиг:   $conf"
    log "  клиентов: $clients — их конфиги и ключи тоже"
    log "  каталог:  $dir целиком"
    [[ -z "$port" ]] || log "  порт:     ${port}/udp — правило ufw будет снято"
    confirm "Удалить $name?" || die "отменено"

    systemctl disable --now "awg-quick@${name}" 2>/dev/null         || log_warn "сервис awg-quick@${name} не остановился — проверьте вручную"

    if [[ -n "$port" ]] && command -v ufw >/dev/null 2>&1; then
        ufw delete allow "${port}/udp" >/dev/null 2>&1             && log "ufw: снято правило ${port}/udp" || true
        ufw route delete allow in on "$name" >/dev/null 2>&1 || true
    fi

    _backup_file "$conf"
    rm -f "$conf" || die "не удалён $conf"

    rm -rf "${dir:?}"

    log_ok "интерфейс $name удалён (конфиг сохранён в $BACKUP_LAST)"
}

cmd_iface() {
    local sub="${1:-list}"
    case "$sub" in
        list|"")
            cmd_ifaces
            ;;
        add)
            local name="${2:-}"
            [[ -n "$name" ]] || name=$(next_free_iface)
            [[ "$name" =~ ^[A-Za-z][A-Za-z0-9_-]{0,14}$ ]] || die "недопустимое имя: $name"
            AWG_IFACE="$name"
            resolve_paths
            log "новый интерфейс: $AWG_IFACE"
            cmd_server_init
            ;;
        remove|rm|delete)
            cmd_iface_remove "${2:-}"
            ;;
        *)
            die "неизвестное действие: iface $sub  (list, add, remove)"
            ;;
    esac
}

# ── Команда: server-rekey ───────────────────────────────────────────────────

cmd_server_rekey() {
    load_server_params

    require_awg31 "параметры 3.1" || exit 1

    # Для интерфейса, созданного до 3.1, это ещё и перевод на 3.1 — другого
    # способа нет, параметры интерфейса общие для всех его клиентов.
    if [[ "${S_RTR:-off}" != "on" ]]; then
        log_warn "Интерфейс ${AWG_IFACE} создан до 3.1 — он будет переведён на 3.1."
    fi

    log_warn "Будут сгенерированы НОВЫЕ общие параметры — все текущие подключения оборвутся."
    log "Каждого клиента придётся создать заново: $0 remove ИМЯ, затем $0 add ИМЯ"
    confirm "Продолжить?" || die "отменено"

    # gen_sender_params обязателен: ContentPaddingAddition — параметр
    # отправляющей стороны, и заполняет G_CPA именно он. Без этого вызова
    # команда падала на `unbound variable` сразу после снятия бэкапа.
    gen_sender_params
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
            printf "RandomTrailers = on\n"
            printf "DisableCookies = on\n"
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
                if (kv[1] ~ /^(S[1-4]|H[1-4]|HeaderProtectionKey|ContentPaddingAddition|Jc|Jmin|Jmax|I[1-5]|RandomTrailers|DisableCookies)$/) next
                if (line == "") next
            }
            print
        }
        END { if (in_iface && !done) emit_block() }
    ' "$SERVER_CONF" > "$tmp" || { rm -f "$tmp"; die "не удалось перестроить $SERVER_CONF"; }

    mv -f "$tmp" "$SERVER_CONF" || { rm -f "$tmp"; die "не записан $SERVER_CONF"; }
    chmod 600 "$SERVER_CONF"
    log_ok "общие параметры интерфейса ${AWG_IFACE} обновлены"

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
    add NAME              создать клиента с параметрами текущего интерфейса
    remove NAME...        удалить клиента: пир, файлы и ключи
    link [NAME...]        пересобрать ссылку vpn:// по конфигу
                          (без имён — всем клиентам; с одним именем ссылка
                          ещё и печатается)
    list                  клиенты: адрес, связь, совместимость с сервером
    names                 только имена клиентов, по одному в строке (для скриптов)
    stats                 трафик и последняя активность по клиентам
    show                  вывод 'awg show' по интерфейсу
    restart               перезапустить awg-quick@ИНТЕРФЕЙС
    backup [--prune N]    архив конфигов и ключей в ~/awg/backups
    migrate               разложить клиентов из старой плоской схемы по каталогам
    gen                   вывести готовый набор параметров AWG 3.1
    server-init           создать сервер AWG 3.1 с нуля
    set-endpoint HOST     сменить имя хоста для новых клиентских конфигов
    iface [list]          список серверных интерфейсов (то же, что ifaces)
    iface add [NAME]      создать интерфейс; без имени берётся первое свободное
    iface remove NAME     снести интерфейс: сервис, правило ufw, конфиг и
                          клиентов вместе с ключами
    migrate-client N --to IFACE
                          завести клиента на другом интерфейсе, сохранив его ключ
    server-rekey          сгенерировать новые общие параметры интерфейса
                          (прежнее имя server-upgrade ещё принимается)

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
        --no-link         не создавать файл со ссылкой vpn://
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
        --iface NAME      серверный интерфейс    (по умолч.: awg0)
                          Принимается и перед командой: awg3 --iface awg1 list
        --to IFACE        (migrate-client) целевой интерфейс
    -y, --yes             не задавать вопросов
    -h, --help            эта справка

ПРИМЕЧАНИЯ
    S1-S4, H1-H4 и HeaderProtectionKey всегда берутся из awg0.conf: сервер —
    источник истины, клиент обязан их повторить. Jc, Jmin, Jmax, I1-I5,
    ContentPaddingAddition и таймеры генерируются заново для каждого клиента.

    Всё лежит внутри ${AWG_ROOT}: журнал, бэкапы и по каталогу на интерфейс.
    Клиент — ещё уровнем ниже, в собственном каталоге:
        ${AWG_ROOT}/ИНТЕРФЕЙС/ИМЯ/ИМЯ.conf
        ${AWG_ROOT}/ИНТЕРФЕЙС/ИМЯ/ИМЯ.png
        ${AWG_ROOT}/ИНТЕРФЕЙС/ИМЯ/ИМЯ.vpnuri
        ${AWG_ROOT}/ИНТЕРФЕЙС/ИМЯ/ИМЯ.private, ИМЯ.public
    Прежние раскладки awg0 (клиенты в корне и совсем старая плоская) ещё
    читаются командами list и remove; 'migrate' переносит их на текущую.

    Пути переопределяются переменными AWG3_DIR, AWG3_SERVER_CONF, AWG3_IFACE.

    Интерфейсов может быть несколько, и они независимы: у каждого свой порт,
    подсеть, общие параметры и каталог клиентов. Одинаковые имена клиентов на
    РАЗНЫХ интерфейсах допустимы — на этом держится безостановочный переезд
    через migrate-client.
EOF
}

main() {
    [[ $# -gt 0 ]] || { usage; exit 1; }

    # --iface относится ко всему вызову, а не к команде, поэтому принимается и
    # перед ней: `awg3 --iface awg1 list` читается естественнее, чем
    # `awg3 list --iface awg1`. Оба порядка работают — ниже флаг разбирается
    # ещё раз вместе с остальными.
    while [[ "${1:-}" == "--iface" ]]; do
        [[ -n "${2:-}" ]] || die "--iface ожидает имя интерфейса"
        AWG_IFACE="$2"; shift 2
    done

    [[ $# -gt 0 ]] || { usage; exit 1; }

    local cmd="$1"; shift
    case "$cmd" in
        -h|--help|help) usage; exit 0 ;;
        add|remove|link|list|names|stats|show|restart|backup|gen|migrate|server-rekey|server-init|set-endpoint|iface|ifaces|migrate-client) ;;
        server-upgrade) cmd=server-rekey ;;
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
            --no-link)      MAKE_LINK=0; shift ;;
            --no-apply)     DO_APPLY=0; shift ;;
            --prune)        PRUNE_KEEP="${2:-}"; shift 2 ;;
            --awg-port)     SRV_PORT="${2:-}"; shift 2 ;;
            --subnet)       SRV_SUBNET="${2:-}"; shift 2 ;;
            --isolation)    SRV_ISOLATION="${2:-}"; shift 2 ;;
            --ipv6)         SRV_IPV6="${2:-}"; shift 2 ;;
            --ipv6-subnet)  SRV_IPV6_SUBNET="${2:-}"; shift 2 ;;
            --force)        SRV_FORCE=1; shift ;;
            --iface)        AWG_IFACE="${2:-}"; shift 2 ;;
            --to)           MIGRATE_TO="${2:-}"; shift 2 ;;
            -y|--yes)       ASSUME_YES=1; shift ;;
            -h|--help)      usage; exit 0 ;;
            -*)             die "неизвестная опция: $1  (см. --help)" ;;
            *)              positional+=("$1"); shift ;;
        esac
    done

    # Имя интерфейса уходит в пути к файлам и в systemctl, поэтому проверяется
    # до первого использования: awg-quick@ принимает только это подмножество.
    [[ "$AWG_IFACE" =~ ^[A-Za-z][A-Za-z0-9_-]{0,14}$ ]] \
        || die "недопустимое имя интерфейса: ${AWG_IFACE}"

    # --iface мог сменить интерфейс уже после первого вычисления путей.
    resolve_paths

    validate_profile_intensity
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
        link)           cmd_link "${positional[@]+"${positional[@]}"}" ;;
        list)           cmd_list ;;
        names)          list_client_names ;;
        stats)          cmd_stats ;;
        show)           cmd_show ;;
        restart)        cmd_restart ;;
        backup)         cmd_backup ;;
        gen)            cmd_gen ;;
        migrate)        cmd_migrate ;;
        server-rekey)   cmd_server_rekey ;;
        ifaces)         cmd_ifaces ;;
        iface)          cmd_iface "${positional[@]+"${positional[@]}"}" ;;
        migrate-client)
            [[ "${#positional[@]}" -eq 1 ]] || die "migrate-client принимает ровно одно имя клиента"
            cmd_migrate_client "${positional[0]}"
            ;;
        server-init)    cmd_server_init ;;
        set-endpoint)
            [[ "${#positional[@]}" -eq 1 ]] || die "set-endpoint принимает ровно одно имя хоста"
            cmd_set_endpoint "${positional[0]}"
            ;;
    esac
}

# Запуск только при прямом вызове. При подключении через source (юнит-тесты)
# main не выполняется — иначе тест запустил бы сам скрипт.
if [[ "${AWG3_LIB_ONLY:-0}" -ne 1 && "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
