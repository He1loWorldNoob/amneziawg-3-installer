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


# ── Параметры 3.1 в конфигах ────────────────────────────────────────────────
#
# Выключателей у них больше нет: 3.0 из проекта убран, интерфейс либо 3.1,
# либо не наш. Проверяем, что параметры доходят до обоих концов — рассинхрон
# RandomTrailers рвёт туннель целиком.

@test "клиент получает оба параметра 3.1" {
    render_client_conf "$OUT" "PRIV" "10.9.9.2/32" "SRVPUB" "vpn.example.com" 48872
    grep -qx "RandomTrailers = on" "$OUT"
    grep -qx "DisableCookies = on" "$OUT"
}

@test "keepalive у клиента идёт диапазоном" {
    # Постоянный интервал сам по себе признак, поэтому у каждого клиента он
    # свой. Диапазон понимают tools 3.1 и приложение от 5.0.1.5.
    render_client_conf "$OUT" "PRIV" "10.9.9.2/32" "SRVPUB" "vpn.example.com" 48872
    grep -qE "^PersistentKeepalive = [0-9]+-[0-9]+$" "$OUT"
}

@test "конфиг сервера тоже несёт оба параметра" {
    render_server_conf "$TEST_TMP/srv.conf" "PRIV" "10.9.9.1/24" 48872 1280 "PU" "PD"
    grep -qx "RandomTrailers = on" "$TEST_TMP/srv.conf"
    grep -qx "DisableCookies = on" "$TEST_TMP/srv.conf"
}

@test "сервер получает и свои таймеры: он тоже инициатор при пересогласовании" {
    render_server_conf "$TEST_TMP/srv.conf" "PRIV" "10.9.9.1/24" 48872 1280 "PU" "PD"
    grep -qE "^RekeyAfterTime = " "$TEST_TMP/srv.conf"
    grep -qE "^MaxHandshakeAttempts = " "$TEST_TMP/srv.conf"
}

# ── Интерфейс, созданный до 3.1 ─────────────────────────────────────────────

@test "load_server_params опознаёт интерфейс без RandomTrailers" {
    # Отсутствие строки — это выключено: так выглядят все конфиги до 3.1.
    load_server_params
    [ "$S_RTR" = "off" ]
}

@test "с RandomTrailers интерфейс опознаётся как 3.1" {
    write_server_conf "RandomTrailers = on"
    load_server_params
    [ "$S_RTR" = "on" ]
}

@test "на интерфейсе до 3.1 клиента выдать нельзя" {
    # Самый дорогой из возможных отказов, если его не сделать: клиент получил
    # бы RandomTrailers, которого нет у сервера, и туннель не встал бы ВООБЩЕ
    # — без ошибки, без пакета, просто тишина.
    S_RTR=off
    run require_iface_awg31
    [ "$status" -ne 0 ]
    [[ "$output" == *"server-rekey"* ]]
}

@test "на интерфейсе 3.1 сторож пропускает" {
    S_RTR=on
    run require_iface_awg31
    [ "$status" -eq 0 ]
}

@test "add зовёт сторожа, а не только проверку HeaderProtectionKey" {
    local body
    body=$(sed -n '/^cmd_add() {/,/^}/p' "$REPO_ROOT/awg3.sh")
    [[ "$body" == *require_iface_awg31* ]]
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

@test "server-init требует 3.1 безусловно" {
    # Раньше проверка висела на флаге --random-trailers; флага больше нет.
    local body
    body=$(sed -n '/^cmd_server_init() {/,/^}/p' "$REPO_ROOT/awg3.sh")
    [[ "$body" == *require_awg31* ]]
    [[ "$body" != *SRV_RANDOM_TRAILERS* ]]
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

# ── server-rekey ────────────────────────────────────────────────────────────

need_awg() { command -v awg >/dev/null 2>&1 || skip "awg не установлен"; }

@test "server-rekey переписывает общие параметры и не падает на CPA" {
    # Регрессия: команда вызывала только gen_shared_params, а
    # ContentPaddingAddition заполняет gen_sender_params — падение с
    # 'G_CPA: unbound variable' случалось уже ПОСЛЕ снятия бэкапа.
    need_awg
    write_server_conf "RandomTrailers = on"
    printf '\n[Peer]\nPublicKey = PEERPUB\nAllowedIPs = 10.9.9.2/32\n' >> "$AWG3_SERVER_CONF"

    ASSUME_YES=1
    require_awg31() { :; }
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

@test "server-rekey переводит интерфейс до 3.1 на 3.1" {
    # Единственный способ это сделать: параметры интерфейса общие для всех его
    # клиентов, выборочно перевести одного нельзя.
    need_awg
    write_server_conf
    load_server_params
    [ "$S_RTR" = "off" ]

    ASSUME_YES=1
    require_awg31() { :; }
    apply_restart() { :; }
    run cmd_server_rekey
    [ "$status" -eq 0 ]
    grep -qx "RandomTrailers = on" "$AWG3_SERVER_CONF"
    grep -qx "DisableCookies = on" "$AWG3_SERVER_CONF"
}

@test "server-rekey не плодит вторую строку параметров" {
    need_awg
    write_server_conf "RandomTrailers = on"
    ASSUME_YES=1
    require_awg31() { :; }
    apply_restart() { :; }
    run cmd_server_rekey
    [ "$status" -eq 0 ]
    [ "$(grep -c '^RandomTrailers' "$AWG3_SERVER_CONF")" -eq 1 ]
}

# ── Настройка системы со стороны server-init ────────────────────────────────
#
# Установщик ставит пакеты и модуль, а порт в фаерволе и IPv6 в sysctl —
# свойства конкретного интерфейса. Их знает только тот, кто интерфейс создаёт,
# и интерфейсов может быть несколько.

@test "форвардинг для IPv6-туннеля снимает глобальное отключение IPv6" {
    # Установщик глушит IPv6: на момент установки неизвестно, понадобится ли
    # он в туннеле. Без этих строк awg-quick не сможет назначить интерфейсу
    # IPv6-адрес, и сервис останется в failed.
    enable_forwarding on "$TEST_TMP/fwd.conf"
    grep -qx "net.ipv4.ip_forward = 1" "$TEST_TMP/fwd.conf"
    grep -qx "net.ipv6.conf.all.forwarding = 1" "$TEST_TMP/fwd.conf"
    grep -qx "net.ipv6.conf.all.disable_ipv6 = 0" "$TEST_TMP/fwd.conf"
    grep -qx "net.ipv6.conf.default.disable_ipv6 = 0" "$TEST_TMP/fwd.conf"
    grep -qx "net.ipv6.conf.lo.disable_ipv6 = 0" "$TEST_TMP/fwd.conf"
}

@test "без IPv6 в туннеле отключение установщика остаётся в силе" {
    enable_forwarding off "$TEST_TMP/fwd.conf"
    grep -qx "net.ipv4.ip_forward = 1" "$TEST_TMP/fwd.conf"
    ! grep -q "ipv6" "$TEST_TMP/fwd.conf"
}

@test "файл sysctl от server-init применяется после установщикова" {
    # Оба лежат в /etc/sysctl.d и применяются по алфавиту. Если порядок
    # перевернётся, отключение IPv6 от установщика победит — и туннель с IPv6
    # молча останется без адреса.
    [[ "99-awg3.conf" > "99-amneziawg-forwarding.conf" ]]
}

@test "server-init открывает порт в фаерволе сам" {
    local body
    body=$(sed -n '/^cmd_server_init() {/,/^}/p' "$REPO_ROOT/awg3.sh")
    [[ "$body" == *open_firewall_port* ]]
}

@test "без ufw открывать нечего и это не ошибка" {
    # Фаервол могли отключить намеренно; включать его за человека мы не станем.
    command -v ufw >/dev/null 2>&1 && skip "на этой машине ufw есть"
    run open_firewall_port 51830 "" eth0
    [ "$status" -eq 0 ]
}

@test "server-init спрашивает параметры сам" {
    local body
    body=$(sed -n '/^cmd_server_init() {/,/^}/p' "$REPO_ROOT/awg3.sh")
    [[ "$body" == *ask_server_params* ]]
}

@test "при -y вопросов нет" {
    ASSUME_YES=1
    run ask_server_params
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "введённый профиль проверяется, а не уходит в конфиг как есть" {
    # Вопросы задаются после разбора флагов, поэтому валидация из main уже
    # прошла: без повторной проверки опечатка дошла бы до генератора.
    local body
    body=$(sed -n '/^cmd_server_init() {/,/^}/p' "$REPO_ROOT/awg3.sh")
    [[ "$body" == *validate_profile_intensity* ]]
}

# ── Вывод ifaces ────────────────────────────────────────────────────────────

@test "строка ifaces не разъезжается на неактивном интерфейсе" {
    # systemctl is-active печатает inactive И возвращает ненулевой код, grep -c
    # печатает 0 и тоже возвращает 1. Ветка `|| printf ...` в обоих случаях
    # дописывала второе значение через перевод строки — панель, которая читает
    # эти колонки по табуляции, получала мусор.
    local body
    body=$(sed -n '/^cmd_ifaces() {/,/^}/p' "$REPO_ROOT/awg3.sh")
    [[ "$body" != *"|| printf 'unknown'"* ]]
    [[ "$body" != *"|| printf '0'"* ]]
}

# ── Группа iface ────────────────────────────────────────────────────────────

@test "iface без действия показывает список" {
    cmd_ifaces() { echo "СПИСОК"; }
    run cmd_iface
    [ "$status" -eq 0 ]
    [ "$output" = "СПИСОК" ]
}

@test "iface list — то же самое" {
    cmd_ifaces() { echo "СПИСОК"; }
    run cmd_iface list
    [ "$output" = "СПИСОК" ]
}

@test "iface add без имени берёт первое свободное" {
    next_free_iface() { echo "awg7"; }
    cmd_server_init() { echo "создан:$AWG_IFACE"; }
    resolve_paths() { :; }
    run cmd_iface add
    [ "$status" -eq 0 ]
    [[ "$output" == *"создан:awg7"* ]]
}

@test "iface add с именем берёт его" {
    cmd_server_init() { echo "создан:$AWG_IFACE"; }
    resolve_paths() { :; }
    run cmd_iface add awg3
    [[ "$output" == *"создан:awg3"* ]]
}

@test "iface add отвергает недопустимое имя" {
    # Имя уходит в путь к файлу и в systemctl: awg-quick@ принимает только
    # это подмножество.
    cmd_server_init() { :; }
    resolve_paths() { :; }
    run cmd_iface add "awg 1; rm -rf /"
    [ "$status" -ne 0 ]
}

@test "iface remove без имени не угадывает, а требует его" {
    run cmd_iface_remove ""
    [ "$status" -ne 0 ]
}

@test "iface remove на несуществующем интерфейсе отказывается" {
    run cmd_iface_remove awg9
    [ "$status" -ne 0 ]
    [[ "$output" == *"не найден"* ]]
}

@test "неизвестное действие iface отвергается" {
    run cmd_iface нечто
    [ "$status" -ne 0 ]
}

@test "прежние имена команд остались псевдонимами" {
    # Их знает панель и помнят руки: ломать незачем.
    local body
    body=$(sed -n '/^main() {/,/^}/p' "$REPO_ROOT/awg3.sh")
    [[ "$body" == *"ifaces)"* ]]
    [[ "$body" == *"server-init)"* ]]
    [[ "$body" == *"server-upgrade) cmd=server-rekey"* ]]
}

# ── Запуск не из того каталога ──────────────────────────────────────────────

@test "запуск из каталога с исходниками запрещён" {
    # Каталог данных awg0 — каталог самого скрипта. Из распакованного
    # репозитория приватные ключи клиентов легли бы в дерево исходников.
    run bash -c "cd '$REPO_ROOT' && AWG3_DIR= AWG3_SERVER_CONF= ./awg3.sh list 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"исходниками"* ]] || [[ "$output" == *"root"* ]]
}

@test "права root проверяются раньше зависимостей" {
    # iptables лежит в /usr/sbin, которого нет в PATH обычного пользователя:
    # без этой очерёдности запуск без sudo советовал искать пакет.
    local body
    body=$(sed -n '/^check_dependencies() {/,/^}/p' "$REPO_ROOT/awg3.sh")
    local i_root i_dep
    i_root=$(printf '%s\n' "$body" | grep -n 'EUID' | head -1 | cut -d: -f1)
    # Ищем именно вызов die: та же фраза стоит в комментарии выше, и по ней
    # проверка порядка нашла бы комментарий вместо кода.
    i_dep=$(printf '%s\n' "$body" | grep -n 'die "нет обязательных команд' | head -1 | cut -d: -f1)
    [ "$i_root" -lt "$i_dep" ]
}
