#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    export REPO_ROOT
    SCRIPT="$REPO_ROOT/install-awg3.sh"
    TEST_TMP="$(mktemp -d)"
    INSTALL_LIB_ONLY=1 source "$SCRIPT"
}

teardown() {
    [[ -n "${TEST_TMP:-}" && "$TEST_TMP" == /tmp/* ]] && rm -rf "$TEST_TMP"
    return 0
}

# Функции, вызывающие die, обязаны проверяться в подоболочке: die выходит
# через exit и иначе завершил бы сам процесс bats, а тест просто исчез бы из
# отчёта, не показавшись упавшим.
run_isolated() {
    run bash -c "INSTALL_LIB_ONLY=1 source '$SCRIPT' >/dev/null 2>&1; $*"
}

# ── Чистка форка ────────────────────────────────────────────────────────────

@test "скачивание скриптов апстрима удалено" {
    ! grep -q "COMMON_SCRIPT_URL" "$SCRIPT"
    ! grep -q "MANAGE_SCRIPT_URL" "$SCRIPT"
    ! grep -q "step5_download_scripts" "$SCRIPT"
    ! grep -q "raw.githubusercontent.com/bivlked" "$SCRIPT"
}

@test "работа с awgsetup_cfg.init удалена" {
    ! grep -q "awgsetup_cfg.init" "$SCRIPT"
    ! grep -q "CONFIG_FILE" "$SCRIPT"
    ! grep -q "safe_read_config_key" "$SCRIPT"
    ! grep -q "safe_load_config" "$SCRIPT"
}

@test "путь закреплённого модуля 2.0 удалён" {
    # tools 3.1 из PPA не работают с модулем 1.0.0: интерфейс поднимался, но
    # параметры 3.x не принимал. Держать в проекте два протокола незачем.
    ! grep -q "AWG2_PIN_TAG" "$SCRIPT"
    ! grep -q "AWG2_PIN_COMMIT" "$SCRIPT"
    ! grep -q "_install_pinned_awg2_module" "$SCRIPT"
    ! grep -q "use_pinned_awg2" "$SCRIPT"
}

@test "готовые ARM-пакеты из чужого релиза больше не скачиваются" {
    ! grep -q "_try_install_prebuilt_arm" "$SCRIPT"
    ! grep -q "releases/download/arm-packages" "$SCRIPT"
}

@test "ядро младше 6.7 не поддерживается" {
    run _kernel_supports_awg3 "6.1.0-18-amd64"
    [ "$status" -ne 0 ]
    run _kernel_supports_awg3 "6.6.99-generic"
    [ "$status" -ne 0 ]
    run _kernel_supports_awg3 "6.7.0-generic"
    [ "$status" -eq 0 ]
    run _kernel_supports_awg3 "6.8.0-51-generic"
    [ "$status" -eq 0 ]
    run _kernel_supports_awg3 "7.0.1"
    [ "$status" -eq 0 ]
}

@test "неразбираемая версия ядра считается неподдерживаемой" {
    run _kernel_supports_awg3 "какая-то-ерунда"
    [ "$status" -ne 0 ]
}

@test "установка стека падает на старом ядре, а не собирает 2.0" {
    grep -q 'die "Kernel $(uname -r) is not supported by AmneziaWG 3.x."' "$SCRIPT"
}

@test "генерация параметров 2.0 удалена" {
    ! grep -q "generate_awg_params" "$SCRIPT"
    ! grep -q "generate_awg_h_ranges" "$SCRIPT"
    ! grep -q "generate_cps_i1" "$SCRIPT"
}

@test "жёсткого пути /root/awg не осталось" {
    ! grep -qF 'AWG_DIR="/root/awg"' "$SCRIPT"
}

@test "step6_generate_configs удалён вместе с зависимостью от awg_common" {
    ! grep -q "step6_generate_configs" "$SCRIPT"
    ! grep -q "awg_common" "$SCRIPT"
}

# ── Каталог данных ──────────────────────────────────────────────────────────

@test "resolve_awg_dir даёт домашний каталог указанного пользователя" {
    run resolve_awg_dir root
    [ "$output" = "/root/awg" ]
}

@test "resolve_awg_dir для несуществующего пользователя падает на /root/awg" {
    run resolve_awg_dir nosuchuser_qwerty
    [ "$output" = "/root/awg" ]
}

@test "переменная AWG3_DIR перекрывает вычисление" {
    AWG3_DIR="$TEST_TMP/custom" run resolve_awg_dir root
    [ "$output" = "$TEST_TMP/custom" ]
}

# ── Режимы ──────────────────────────────────────────────────────────────────

@test "все четыре режима валидны" {
    local m
    for m in full awg-only reinstall uninstall; do
        run validate_mode "$m"
        [ "$status" -eq 0 ]
    done
}

@test "режим upgrade больше не принимается" {
    # 2.0 из проекта ушёл целиком: переводить с него нечего, а пересоздание
    # сервера — это reinstall.
    run validate_mode upgrade
    [ "$status" -ne 0 ]
}

@test "невалидный режим отвергается" {
    run validate_mode nonsense
    [ "$status" -ne 0 ]
}

@test "пустой режим отвергается" {
    run validate_mode ""
    [ "$status" -ne 0 ]
}

@test "номер пункта меню превращается в режим" {
    run mode_from_choice 1
    [ "$output" = "full" ]
    run mode_from_choice 2
    [ "$output" = "awg-only" ]
    run mode_from_choice 3
    [ "$output" = "reinstall" ]
    run mode_from_choice 4
    [ "$output" = "uninstall" ]
}

@test "недопустимый номер пункта отвергается" {
    run mode_from_choice 9
    [ "$status" -ne 0 ]
}

@test "пятого пункта меню больше нет" {
    # Пункты сдвинулись после удаления upgrade: если 5 снова начнёт что-то
    # значить, человек по привычке выберет не то, что думает.
    run mode_from_choice 5
    [ "$status" -ne 0 ]
}

# ── Аргументы server-init ───────────────────────────────────────────────────

@test "аргументы server-init собираются из параметров" {
    SRV_PORT=48872 SRV_SUBNET="10.9.9.1/24" SRV_MTU=1280
    SRV_ISOLATION=off SRV_IPV6=off SRV_PROFILE=quic SRV_INTENSITY=medium
    MODE=awg-only
    run build_server_init_args
    [[ "$output" == *"--awg-port 48872"* ]]
    [[ "$output" == *"--subnet 10.9.9.1/24"* ]]
    [[ "$output" == *"--mtu 1280"* ]]
    [[ "$output" == *"--isolation off"* ]]
    [[ "$output" == *"--ipv6 off"* ]]
    [[ "$output" == *"-p quic"* ]]
    [[ "$output" == *"-i medium"* ]]
    [[ "$output" != *"--force"* ]]
}

@test "режим reinstall добавляет --force" {
    SRV_PORT=48872 SRV_SUBNET="10.9.9.1/24" SRV_MTU=1280
    SRV_ISOLATION=off SRV_IPV6=off SRV_PROFILE=quic SRV_INTENSITY=medium
    MODE=reinstall
    run build_server_init_args
    [[ "$output" == *"--force"* ]]
}

# ── Разбор аргументов ───────────────────────────────────────────────────────

@test "параметры сервера читаются из флагов" {
    parse_args --mode awg-only --awg-port 51820 --subnet 10.8.0.1/24 \
               --mtu 1420 --isolation on --ipv6 on \
               --profile tls --intensity high --clients a,b
    [ "$MODE" = "awg-only" ]
    [ "$SRV_PORT" = "51820" ]
    [ "$SRV_SUBNET" = "10.8.0.1/24" ]
    [ "$SRV_MTU" = "1420" ]
    [ "$SRV_ISOLATION" = "on" ]
    [ "$SRV_IPV6" = "on" ]
    [ "$SRV_PROFILE" = "tls" ]
    [ "$SRV_INTENSITY" = "high" ]
    [ "$CLIENTS" = "a,b" ]
}

@test "флаги bootstrap прокидываются как есть" {
    parse_args --user admin --ssh-port 2222 --disable-root-ssh yes
    [ "${BOOTSTRAP_ARGS[0]}" = "--user" ]
    [ "${BOOTSTRAP_ARGS[1]}" = "admin" ]
    [ "${BOOTSTRAP_ARGS[2]}" = "--ssh-port" ]
    [ "${BOOTSTRAP_ARGS[3]}" = "2222" ]
    [ "${BOOTSTRAP_ARGS[4]}" = "--disable-root-ssh" ]
    [ "${BOOTSTRAP_ARGS[5]}" = "yes" ]
}

@test "IPv6 в туннеле снимает глобальное отключение IPv6" {
    # Регрессия: step1 глушил IPv6 в sysctl, awg-quick не мог назначить
    # интерфейсу IPv6-адрес, и сервис оставался в failed — сервера не было.
    SRV_IPV6=on
    configure_ipv6() { :; }
    configure_ipv6_tunnel() { :; }
    # Заглушка обязательна: настоящая функция пишет в /etc/sysctl.d.
    apply_sysctl_profile() { SYSCTL_REAPPLIED=1; }
    sync_ipv6_settings
    [ "$CLI_ALLOW_IPV6_TUNNEL" -eq 1 ]
    [ "$CLI_DISABLE_IPV6" -eq 0 ]
}

@test "ответ про IPv6 переписывает sysctl, а не только рантайм" {
    # Вопросы задаются после шага 1, а он уже записал файл с выключенным
    # IPv6. Снять отключение только через sysctl -w мало: после следующей
    # перезагрузки файл вернул бы его и туннель встал бы без адреса.
    SRV_IPV6=on
    SYSCTL_REAPPLIED=0
    configure_ipv6() { :; }
    configure_ipv6_tunnel() { :; }
    apply_sysctl_profile() { SYSCTL_REAPPLIED=1; }
    sync_ipv6_settings
    [ "$SYSCTL_REAPPLIED" -eq 1 ]
}

@test "без IPv6 в туннеле глобальное отключение остаётся" {
    SRV_IPV6=off
    configure_ipv6() { :; }
    configure_ipv6_tunnel() { :; }
    apply_sysctl_profile() { :; }
    sync_ipv6_settings
    [ "$CLI_DISABLE_IPV6" -eq 1 ]
}

# ── Порядок вопросов ────────────────────────────────────────────────────────

# Номер строки внутри тела функции: по нему проверяется порядок вызовов.
line_in_stack() {
    sed -n '/^install_amneziawg_stack() {/,/^}/p' "$SCRIPT"         | grep -n "$1" | head -1 | cut -d: -f1
}

@test "параметры спрашиваются после проверки модуля, а не до перезагрузок" {
    # Шаг 1 уходит в перезагрузку при обновлении ядра, шаг 2 — если модуль не
    # загрузился сразу; после неё человек запускает ТУ ЖЕ команду заново.
    # Вопросы перед ними задавались бы по два раза за установку.
    local i_step3 i_ask i_port i_step4
    i_step3=$(line_in_stack step3_check_module)
    i_ask=$(line_in_stack ask_params)
    i_port=$(line_in_stack resolve_awg_port)
    i_step4=$(line_in_stack step4_setup_firewall)
    [ -n "$i_step3" ] && [ -n "$i_ask" ] && [ -n "$i_port" ] && [ -n "$i_step4" ]
    [ "$i_step3" -lt "$i_ask" ]
    # Порт обязан быть известен ДО фаервола: шаг 4 открывает именно его.
    [ "$i_port" -lt "$i_step4" ]
    [ "$i_ask" -lt "$i_step4" ]
}

@test "в диспетчере режимов вопросов не осталось" {
    # Иначе они снова оказались бы перед перезагрузками — по одному набору
    # на каждый запуск команды.
    ! grep -qE 'ask_params; validate_params' "$SCRIPT"
}

@test "шаг 1 и согласование IPv6 пишут sysctl одной и той же функцией" {
    # Разъехавшись, они дали бы разный файл до и после ответа про IPv6.
    local body
    body=$(sed -n '/^step1_update_and_optimize() {/,/^}/p' "$SCRIPT")
    [[ "$body" == *apply_sysctl_profile* ]]
    [[ "$body" != *setup_advanced_sysctl* ]]
    body=$(sed -n '/^sync_ipv6_settings() {/,/^}/p' "$SCRIPT")
    [[ "$body" == *apply_sysctl_profile* ]]
}

@test "каталог данных достаётся пользователю, а не root" {
    # Регрессия: каталог создавался из-под root и оставался root:root —
    # человек не мог забрать свои конфиги и QR без sudo.
    local dir="$TEST_TMP/home/testuser/awg"
    mkdir -p "$TEST_TMP/home/testuser"
    # chown под обычным пользователем не сработает, поэтому проверяем, что
    # владелец вычисляется из пути и функция не падает.
    run prepare_awg_dir "$dir"
    [ -d "$dir" ]
    [ "$(stat -c '%a' "$dir")" = "700" ]
}

@test "владелец /root/awg определяется как root" {
    grep -q 'if \[\[ "\$dir" == /root/\* \]\]; then owner="root"; fi' "$SCRIPT"
}

@test "имя создаваемого пользователя запоминается для каталога данных" {
    # Регрессия: клиенты ложились в домашний каталог того, кто запустил sudo,
    # а не созданного пользователя.
    parse_args --user vpnadmin
    [ "$BOOTSTRAP_USER" = "vpnadmin" ]
}

@test "--yes прокидывается в bootstrap" {
    # Регрессия: без него подтверждение доступа требует tty, которого при
    # неинтерактивном запуске нет, и root молча остаётся включённым.
    grep -q 'BOOTSTRAP_ARGS+=(--yes)' "$SCRIPT"
}

@test "неизвестная опция отвергается" {
    run_isolated 'parse_args --нет-такой-опции'
    [ "$status" -ne 0 ]
}

@test "--yes выставляет автоответ" {
    parse_args --yes
    [ "$AUTO_YES" -eq 1 ]
}

# ── Валидация параметров ────────────────────────────────────────────────────

@test "неизвестный профиль отвергается" {
    run_isolated 'SRV_PROFILE=nonsense SRV_INTENSITY=medium SRV_ISOLATION=off SRV_IPV6=off; validate_params'
    [ "$status" -ne 0 ]
}

@test "неизвестная интенсивность отвергается" {
    run_isolated 'SRV_PROFILE=quic SRV_INTENSITY=turbo SRV_ISOLATION=off SRV_IPV6=off; validate_params'
    [ "$status" -ne 0 ]
}

@test "isolation принимает только on|off" {
    run_isolated 'SRV_PROFILE=quic SRV_INTENSITY=medium SRV_ISOLATION=yes SRV_IPV6=off; validate_params'
    [ "$status" -ne 0 ]
}

@test "ipv6 принимает только on|off" {
    run_isolated 'SRV_PROFILE=quic SRV_INTENSITY=medium SRV_ISOLATION=off SRV_IPV6=maybe; validate_params'
    [ "$status" -ne 0 ]
}

@test "заданный порт переносится в AWG_PORT для правил фаервола" {
    SRV_PORT=48872
    resolve_awg_port
    [ "$AWG_PORT" = "48872" ]
}

@test "пустой порт разрешается до настройки фаервола, а не остаётся пустым" {
    # Иначе ufw получит "ERROR: Bad port", а server-init выберет свой порт —
    # фаервол и конфиг разошлись бы.
    SRV_PORT=""
    resolve_awg_port
    [ -n "$SRV_PORT" ]
    [ "$AWG_PORT" = "$SRV_PORT" ]
    [ "$SRV_PORT" -ge 1024 ]
    [ "$SRV_PORT" -le 65000 ]
}

@test "корректный набор параметров проходит" {
    run_isolated 'SRV_PROFILE=dtls SRV_INTENSITY=high SRV_ISOLATION=on SRV_IPV6=on; validate_params'
    [ "$status" -eq 0 ]
}

@test "недопустимый пункт меню роняет скрипт, а не молча продолжает" {
    run_isolated 'MODE=$(mode_from_choice 9) || die "недопустимый пункт"'
    [ "$status" -ne 0 ]
}
