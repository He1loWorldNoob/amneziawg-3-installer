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

# ── Установщик ничего не настраивает ────────────────────────────────────────
#
# Одна команда — одна задача: bootstrap готовит систему, этот скрипт ставит
# AmneziaWG, awg3 создаёт и ведёт интерфейсы. Вопросы про VPN задаёт тот, кто
# ответы применяет, — иначе они задавались бы до перезагрузки и после неё.

@test "режимов и меню больше нет" {
    ! grep -q "validate_mode" "$SCRIPT"
    ! grep -q "mode_from_choice" "$SCRIPT"
    ! grep -q "show_menu" "$SCRIPT"
    ! grep -qE '^\s+--mode\)' "$SCRIPT"
}

@test "установщик не спрашивает про VPN и не зовёт server-init" {
    ! grep -q "ask_params" "$SCRIPT"
    ! grep -q "build_server_init_args" "$SCRIPT"
    ! grep -q "run_server_init" "$SCRIPT"
    ! grep -q "create_initial_clients" "$SCRIPT"
    ! grep -q "deploy_server" "$SCRIPT"
}

@test "флаги параметров сервера отвергаются" {
    # Их место в awg3 server-init. Молча проглотить их было бы хуже всего:
    # человек решил бы, что порт задан, а интерфейс поднялся бы на случайном.
    local flag
    for flag in --awg-port --subnet --mtu --isolation --ipv6 --profile                 --intensity --clients --endpoint --mode; do
        run_isolated "parse_args $flag значение"
        [ "$status" -ne 0 ]
    done
}

@test "флаги bootstrap отвергаются" {
    local flag
    for flag in --user --ssh-port --disable-root-ssh --password-file; do
        run_isolated "parse_args $flag значение"
        [ "$status" -ne 0 ]
    done
}

@test "установщик не запускает bootstrap.sh, а только называет его в справке" {
    # Подготовка системы — отдельная команда. Упомянуть её в порядке
    # развёртывания полезно, запускать за человека — уже чужая задача.
    ! grep -q "BOOTSTRAP_ARGS" "$SCRIPT"
    ! grep -q "BOOTSTRAP_USER" "$SCRIPT"
    run grep -cE '^[^#]*"\$bs"' "$SCRIPT"
    [ "$output" = "0" ]
    grep -q "bootstrap.sh --user" "$SCRIPT"
}

@test "порт VPN в ufw установщик не открывает" {
    # Порт знает только тот, кто создаёт интерфейс, а интерфейсов может быть
    # несколько. Общая часть фаервола — политики и лимит на SSH — остаётся.
    ! grep -q 'ufw allow "${AWG_PORT}/udp"' "$SCRIPT"
    ! grep -q "ufw route allow in on awg0" "$SCRIPT"
    grep -q "SSH Rate Limit" "$SCRIPT"
}

@test "стек установки состоит только из шагов установки" {
    local body
    body=$(sed -n '/^install_amneziawg_stack() {/,/^}/p' "$SCRIPT")
    [[ "$body" == *step1_update_and_optimize* ]]
    [[ "$body" == *step2_install_amnezia* ]]
    [[ "$body" == *step3_check_module* ]]
    [[ "$body" == *step4_setup_firewall* ]]
    [[ "$body" != *ask_params* ]]
    [[ "$body" != *sync_ipv6_settings* ]]
}

@test "финальное сообщение отправляет к server-init" {
    local body
    body=$(sed -n '/^step99_finish() {/,/^}/p' "$SCRIPT")
    [[ "$body" == *"awg3 server-init"* ]]
}

@test "fail2ban переехал к фаерволу, а не пропал вместе с шагом 7" {
    ! grep -q "step7_start_service" "$SCRIPT"
    local body
    body=$(sed -n '/^step4_setup_firewall() {/,/^}/p' "$SCRIPT")
    [[ "$body" == *setup_fail2ban* ]]
}

# ── Разбор аргументов ───────────────────────────────────────────────────────

@test "оставшиеся флаги разбираются" {
    parse_args --awg-dir "$TEST_TMP/data" --no-tweaks --yes --verbose
    [ "$AWG3_DIR" = "$TEST_TMP/data" ]
    [ "$NO_TWEAKS" -eq 1 ]
    [ "$AUTO_YES" -eq 1 ]
    [ "$VERBOSE" -eq 1 ]
}

@test "неизвестная опция отвергается" {
    run_isolated 'parse_args --нет-такой-опции'
    [ "$status" -ne 0 ]
}

@test "--uninstall и --diagnostic взводят свои флаги" {
    parse_args --uninstall
    [ "$UNINSTALL" -eq 1 ]
    parse_args --diagnostic
    [ "$DIAGNOSTIC" -eq 1 ]
}

# ── Каталог данных ──────────────────────────────────────────────────────────

@test "каталог данных достаётся пользователю, а не root" {
    # Регрессия: каталог создавался из-под root и оставался root:root —
    # человек не мог забрать свои конфиги и QR без sudo.
    local dir="$TEST_TMP/home/testuser/awg"
    mkdir -p "$TEST_TMP/home/testuser"
    run prepare_awg_dir "$dir"
    [ -d "$dir" ]
    [ "$(stat -c '%a' "$dir")" = "700" ]
}

@test "владелец /root/awg определяется как root" {
    grep -q 'if \[\[ "\$dir" == /root/\* \]\]; then owner="root"; fi' "$SCRIPT"
}

# ── sysctl ──────────────────────────────────────────────────────────────────

@test "шаг 1 пишет sysctl одной функцией" {
    # Профиль выбирается в одном месте: --no-tweaks не должен расходиться с
    # обычным путём в том, какой файл и с каким IPv6 окажется на диске.
    local body
    body=$(sed -n '/^step1_update_and_optimize() {/,/^}/p' "$SCRIPT")
    [[ "$body" == *apply_sysctl_profile* ]]
    [[ "$body" != *setup_advanced_sysctl* ]]
}

@test "установщик глушит IPv6, снимать отключение — дело server-init" {
    # Он ставится до того, как известно, нужен ли IPv6 в туннеле. Ответ есть
    # только у awg3 server-init, и его enable_forwarding пишет свой файл
    # sysctl.d, который применяется после установщикова.
    ! grep -q "sync_ipv6_settings" "$SCRIPT"
    grep -q "disable_ipv6" "$SCRIPT"
    grep -q "disable_ipv6" "$REPO_ROOT/awg3.sh"
}
