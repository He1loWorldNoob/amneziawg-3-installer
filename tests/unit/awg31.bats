#!/usr/bin/env bats
#
# Параметры 3.1 и работа с несколькими интерфейсами.

load '../lib/setup'

setup() {
    setup_awg3
    _rand_refill
    gen_shared_params
    gen_sender_params
    OUT="$TEST_TMP/client.conf"

    # Клиентский конфиг собирается из общих параметров СЕРВЕРА, поэтому их
    # надо сперва прочитать — иначе render_client_conf падает на S_S1.
    write_server_conf
    load_server_params
}
teardown() { teardown_awg3; }

# Типовой конфиг интерфейса. Параметры 3.1 дописываются аргументами: без них
# получается интерфейс, каким его создавал 3.0.
write_server_conf() {
    cat > "$AWG3_SERVER_CONF" <<EOF
[Interface]
PrivateKey = qEHb6VNVYRe7Yqrhh5S9j+MHKtRQPQmC6/6zDVDVeVo=
Address = 10.9.9.1/24
ListenPort = 48872
MTU = 1280

S1 = 77
S2 = 134
S3 = 51
S4 = 22
H1 = 512345678-512356789
H2 = 1512345678-1512356789
H3 = 2512345678-2512356789
H4 = 3712345678-3712356789
HeaderProtectionKey = 3lM9kLwzCq7wF0nHXlNTVoJbW1Kk4qMLU1yE0kK1cVs=
ContentPaddingAddition = 33-97
${1:-}
EOF
}

# ── Клиент повторяет параметры за интерфейсом ───────────────────────────────
#
# RandomTrailers обязан совпадать: включённый на одной стороне рвёт туннель
# целиком. Поэтому источник истины — конфиг сервера, а не флаги командной
# строки, с которыми запустили add.

@test "RandomTrailers сервера попадает в конфиг клиента" {
    S_RTR=on S_DC=off
    render_client_conf "$OUT" "PRIV" "10.9.9.2/32" "SRVPUB" "vpn.example.com" 48872
    grep -qx "RandomTrailers = on" "$OUT"
}

@test "на интерфейсе без RandomTrailers строки в клиенте нет" {
    # Приложения Amnezia старше 5.0.1.5 этого ключа не знают: лишняя строка
    # сломала бы им разбор конфига ровно там, где параметр и выключали.
    S_RTR=off S_DC=off
    render_client_conf "$OUT" "PRIV" "10.9.9.2/32" "SRVPUB" "vpn.example.com" 48872
    ! grep -q "RandomTrailers" "$OUT"
}

@test "DisableCookies берётся у интерфейса, а не из умолчания командной строки" {
    # Регрессия: клиент получал DisableCookies = on даже на интерфейсе, где
    # его не было, потому что читалась глобальная переменная сервера.
    SRV_DISABLE_COOKIES=on
    S_RTR=off S_DC=off
    render_client_conf "$OUT" "PRIV" "10.9.9.2/32" "SRVPUB" "vpn.example.com" 48872
    ! grep -q "DisableCookies" "$OUT"
}

@test "включённый на интерфейсе DisableCookies доходит до клиента" {
    SRV_DISABLE_COOKIES=off
    S_RTR=off S_DC=on
    render_client_conf "$OUT" "PRIV" "10.9.9.2/32" "SRVPUB" "vpn.example.com" 48872
    grep -qx "DisableCookies = on" "$OUT"
}

# ── PersistentKeepalive ─────────────────────────────────────────────────────

@test "на 3.1 keepalive идёт диапазоном" {
    # Постоянный интервал сам по себе признак, поэтому у каждого клиента он
    # свой. Диапазон понимают только tools 3.1 и приложение от 5.0.1.5.
    S_RTR=on S_DC=on
    render_client_conf "$OUT" "PRIV" "10.9.9.2/32" "SRVPUB" "vpn.example.com" 48872
    grep -qE "^PersistentKeepalive = [0-9]+-[0-9]+$" "$OUT"
}

@test "на legacy-интерфейсе keepalive остаётся числом" {
    S_RTR=off S_DC=off
    render_client_conf "$OUT" "PRIV" "10.9.9.2/32" "SRVPUB" "vpn.example.com" 48872
    grep -qE "^PersistentKeepalive = [0-9]+$" "$OUT"
}

# ── Проверка версий модуля и tools ──────────────────────────────────────────

@test "awg_version_ge принимает 3.1 и новее" {
    run awg_version_ge "3.1.20260812"; [ "$status" -eq 0 ]
    run awg_version_ge "3.2.0";        [ "$status" -eq 0 ]
    run awg_version_ge "4.0";          [ "$status" -eq 0 ]
}

@test "awg_version_ge отвергает всё, что ниже 3.1" {
    run awg_version_ge "3.0.20260731"; [ "$status" -ne 0 ]
    run awg_version_ge "1.0.0";        [ "$status" -ne 0 ]
    run awg_version_ge "";             [ "$status" -ne 0 ]
    run awg_version_ge "неизвестно";   [ "$status" -ne 0 ]
}

@test "сравнивается major.minor, а не дата сборки" {
    # Патч-часть у amneziawg — дата сборки, на возможности она не влияет.
    run awg_version_ge "3.1.20250101"; [ "$status" -eq 0 ]
}

# ── Пути по интерфейсу ──────────────────────────────────────────────────────

@test "awg0 остаётся в каталоге скрипта, остальные — рядом по имени" {
    # Переменные окружения из setup перекрывают вычисление, поэтому для этой
    # проверки их надо снять: иначе тест мерил бы не то.
    AWG_DIR_EXPLICIT="" SERVER_CONF_EXPLICIT="" SCRIPT_DIR="/home/user/awg"

    AWG_IFACE=awg0; resolve_paths
    [ "$AWG_DIR" = "/home/user/awg" ]
    [ "$SERVER_CONF" = "/etc/amnezia/amneziawg/awg0.conf" ]

    AWG_IFACE=awg1; resolve_paths
    [ "$AWG_DIR" = "/home/user/awg1" ]
    [ "$SERVER_CONF" = "/etc/amnezia/amneziawg/awg1.conf" ]
}

@test "заданные переменные окружения сильнее вычисления по интерфейсу" {
    AWG_IFACE=awg1; resolve_paths
    [ "$AWG_DIR" = "$AWG3_DIR" ]
    [ "$SERVER_CONF" = "$AWG3_SERVER_CONF" ]
}

@test "журнал и каталог старых ключей едут вместе с интерфейсом" {
    AWG_DIR_EXPLICIT="" SERVER_CONF_EXPLICIT="" SCRIPT_DIR="/home/user/awg"
    AWG_IFACE=awg1; resolve_paths
    [ "$LOG_FILE" = "/home/user/awg1/awg3.log" ]
    [ "$LEGACY_KEYS_DIR" = "/home/user/awg1/keys" ]
}

# ── Конфиг сервера ──────────────────────────────────────────────────────────

@test "включённые параметры 3.1 пишутся в конфиг сервера" {
    SRV_RANDOM_TRAILERS=on SRV_DISABLE_COOKIES=on
    render_server_conf "$TEST_TMP/srv.conf" "PRIV" "10.9.9.1/24" 48872 1280 "PU" "PD"
    grep -qx "RandomTrailers = on" "$TEST_TMP/srv.conf"
    grep -qx "DisableCookies = on" "$TEST_TMP/srv.conf"
}

@test "выключенные параметры не пишутся вовсе" {
    # Строка со значением off ничего не добавляет, а модуль ниже 3.1 на ней
    # откажется загружать конфиг — и сервис уйдёт в failed при следующем старте.
    SRV_RANDOM_TRAILERS=off SRV_DISABLE_COOKIES=off
    render_server_conf "$TEST_TMP/srv.conf" "PRIV" "10.9.9.1/24" 48872 1280 "PU" "PD"
    ! grep -q "RandomTrailers" "$TEST_TMP/srv.conf"
    ! grep -q "DisableCookies" "$TEST_TMP/srv.conf"
}

@test "сервер получает и свои таймеры 3.0: он тоже инициатор при пересогласовании" {
    render_server_conf "$TEST_TMP/srv.conf" "PRIV" "10.9.9.1/24" 48872 1280 "PU" "PD"
    grep -qE "^RekeyAfterTime = " "$TEST_TMP/srv.conf"
    grep -qE "^MaxHandshakeAttempts = " "$TEST_TMP/srv.conf"
}

# ── Состояние интерфейса из конфига ─────────────────────────────────────────

@test "load_server_params читает RandomTrailers и DisableCookies" {
    cat > "$AWG3_SERVER_CONF" <<EOF
[Interface]
PrivateKey = PRIV
Address = 10.9.9.1/24
ListenPort = 48872
MTU = 1280
HeaderProtectionKey = KEY
RandomTrailers = on
DisableCookies = on
EOF
    load_server_params
    [ "$S_RTR" = "on" ]
    [ "$S_DC" = "on" ]
}

@test "конфиг без этих строк читается как выключенные, а не как пустые" {
    # Так выглядят все конфиги, созданные до 3.1: отсутствие строки — это off.
    cat > "$AWG3_SERVER_CONF" <<EOF
[Interface]
PrivateKey = PRIV
Address = 10.9.9.1/24
ListenPort = 48872
MTU = 1280
HeaderProtectionKey = KEY
EOF
    load_server_params
    [ "$S_RTR" = "off" ]
    [ "$S_DC" = "off" ]
}

# ── server-rekey ────────────────────────────────────────────────────────────

need_awg() { command -v awg >/dev/null 2>&1 || skip "awg не установлен"; }

@test "server-rekey переписывает общие параметры и не падает на CPA" {
    # Регрессия: команда вызывала только gen_shared_params, а
    # ContentPaddingAddition заполняет gen_sender_params — падение с
    # 'G_CPA: unbound variable' случалось уже ПОСЛЕ снятия бэкапа.
    need_awg
    write_server_conf
    printf '\n[Peer]\nPublicKey = PEERPUB\nAllowedIPs = 10.9.9.2/32\n' >> "$AWG3_SERVER_CONF"

    ASSUME_YES=1
    apply_restart() { :; }
    run cmd_server_rekey
    [ "$status" -eq 0 ]

    grep -qE "^S1 = [0-9]+$" "$AWG3_SERVER_CONF"
    grep -qE "^ContentPaddingAddition = [0-9]+-[0-9]+$" "$AWG3_SERVER_CONF"
    # Ключ обязан смениться — иначе смены параметров не произошло.
    ! grep -q "HeaderProtectionKey = 3lM9kLwzCq7wF0nHXlNTVoJbW1Kk4qMLU1yE0kK1cVs=" "$AWG3_SERVER_CONF"
    # Пиры переносятся дословно: рекей меняет параметры, а не состав клиентов.
    grep -qx "PublicKey = PEERPUB" "$AWG3_SERVER_CONF"
}

@test "server-rekey не включает RandomTrailers на legacy-интерфейсе молча" {
    # Иначе одна команда «сменить параметры» отключила бы всех клиентов
    # интерфейса, который держат на 3.0 ради старых приложений.
    need_awg
    write_server_conf

    ASSUME_YES=1
    apply_restart() { :; }
    run cmd_server_rekey
    [ "$status" -eq 0 ]
    ! grep -q "RandomTrailers" "$AWG3_SERVER_CONF"
    ! grep -q "DisableCookies" "$AWG3_SERVER_CONF"
}

@test "явный --random-trailers on сильнее прежнего состояния интерфейса" {
    need_awg
    write_server_conf

    ASSUME_YES=1
    SRV_RT_EXPLICIT=1
    SRV_RANDOM_TRAILERS=on
    require_awg31() { :; }
    apply_restart() { :; }
    run cmd_server_rekey
    [ "$status" -eq 0 ]
    grep -qx "RandomTrailers = on" "$AWG3_SERVER_CONF"
}
