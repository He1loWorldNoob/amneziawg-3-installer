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

@test "фаервол установщик не настраивает вовсе" {
    # Стартовый фаервол — дело bootstrap.sh, порт интерфейса открывает
    # awg3 server-init: он один знает, какой порт у какого интерфейса.
    ! grep -q "setup_improved_firewall" "$SCRIPT"
    ! grep -q "detect_ssh_ports" "$SCRIPT"
    ! grep -q "step4_setup_firewall" "$SCRIPT"
    grep -q "ufw_setup" "$REPO_ROOT/bootstrap.sh"
}

@test "стек установки — только пакеты и модуль" {
    local body
    body=$(sed -n '/^install_amneziawg_stack() {/,/^}/p' "$SCRIPT")
    [[ "$body" == *step1_prepare_apt* ]]
    [[ "$body" == *step2_install_amnezia* ]]
    [[ "$body" == *step3_check_module* ]]
    [[ "$body" != *step4* ]]
    [[ "$body" != *ask_params* ]]
}

@test "финальное сообщение отправляет к server-init" {
    local body
    body=$(sed -n '/^step99_finish() {/,/^}/p' "$SCRIPT")
    [[ "$body" == *"awg3 server-init"* ]]
}

@test "подготовка системы уехала в bootstrap целиком" {
    # Установщик AmneziaWG не должен решать, как настроен чужой сервер:
    # swap, sysctl, тюнинг сетевой карты, снос пакетов и fail2ban — не его дело.
    local f
    for f in cleanup_system optimize_system optimize_swap optimize_nic              setup_advanced_sysctl setup_minimal_sysctl apply_sysctl_profile              setup_fail2ban step7_start_service; do
        ! grep -q "^${f}() {" "$SCRIPT"
        grep -q "$f" "$REPO_ROOT/bootstrap.sh" || [[ "$f" == step7_start_service ]]
    done
}

@test "обновление системы установщик не делает — оно в bootstrap" {
    # Иначе то же самое делалось бы дважды, и перезагрузка после обновления
    # ядра случалась бы в середине установки.
    ! grep -q "full-upgrade" "$SCRIPT"
    grep -q "full-upgrade" "$REPO_ROOT/bootstrap.sh"
}

# ── Разбор аргументов ───────────────────────────────────────────────────────

@test "оставшиеся флаги разбираются" {
    parse_args --awg-dir "$TEST_TMP/data" --yes --verbose
    [ "$AWG3_DIR" = "$TEST_TMP/data" ]
    [ "$AUTO_YES" -eq 1 ]
    [ "$VERBOSE" -eq 1 ]
}

@test "--no-tweaks у установщика больше нет: тюнинг не его задача" {
    run_isolated 'parse_args --no-tweaks'
    [ "$status" -ne 0 ]
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

@test "шаг 1 остался только ради работоспособного apt" {
    # Без gpg и curl не добавить репозиторий Amnezia; всё остальное из шага 1
    # уехало в bootstrap.
    local body
    body=$(sed -n '/^step1_prepare_apt() {/,/^}/p' "$SCRIPT")
    [[ "$body" == *apt_update_tolerant* ]]
    [[ "$body" == *"install_packages curl wget gpg"* ]]
    [[ "$body" != *optimize_system* ]]
    [[ "$body" != *cleanup_system* ]]
}

@test "IPv6 глушит bootstrap, снимает отключение server-init" {
    # Bootstrap отрабатывает до того, как известно, нужен ли IPv6 в туннеле.
    # Ответ есть только у awg3 server-init, и его enable_forwarding пишет свой
    # файл sysctl.d, который применяется после bootstrap-овского.
    grep -q "disable_ipv6" "$REPO_ROOT/bootstrap.sh"
    grep -q "disable_ipv6" "$REPO_ROOT/awg3.sh"
    # В установщике упоминания остались только в удалении и диагностике —
    # писать sysctl он больше не умеет.
    ! grep -q "setup_advanced_sysctl" "$SCRIPT"
    ! grep -q "setup_minimal_sysctl" "$SCRIPT"
}

# ── Загрузка модуля ─────────────────────────────────────────────────────────

@test "Secure Boot отличается от устаревшего ядра, а не уводит в перезагрузки" {
    # Раньше любой отказ modprobe объявлялся следствием обновления ядра. При
    # включённом Secure Boot модуль не грузится никогда — и человек ходил по
    # кругу: перезагрузка, то же сообщение, снова перезагрузка.
    modprobe() { echo "modprobe: ERROR: could not insert 'amneziawg': Key was rejected by service" >&2; return 1; }
    run load_amneziawg_module
    [ "$status" -eq 2 ]
    [[ "$output" == *"Secure Boot"* ]]
    [[ "$output" == *"mokutil"* ]]
}

@test "модуль, собранный под работающее ядро, перезагрузкой не лечится" {
    modprobe() { echo "modprobe: ERROR: could not insert 'amneziawg': Invalid argument" >&2; return 1; }
    compgen() { return 0; }
    run load_amneziawg_module
    [ "$status" -eq 2 ]
}

@test "модуль под другое ядро — случай, когда перезагрузка помогает" {
    modprobe() { echo "modprobe: FATAL: Module amneziawg not found" >&2; return 1; }
    compgen() { return 1; }
    run load_amneziawg_module
    [ "$status" -eq 1 ]
}

@test "загруженный модуль — успех без единого сообщения" {
    modprobe() { return 0; }
    run load_amneziawg_module
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "слепого modprobe в установке не осталось" {
    # Проверяем по всему файлу, а не по телу шага 2: внутри него лежит
    # heredoc со вспомогательным скриптом, и его закрывающая скобка в первой
    # колонке обрывает выборку функции на середине.
    grep -q "load_amneziawg_module" "$SCRIPT"
    run grep -c "modprobe amneziawg 2>/dev/null" "$SCRIPT"
    [ "$output" = "0" ]
}

@test "текст перезагрузки не обещает несуществующих параметров" {
    # Флагов VPN у установщика больше нет, и повторять «те же параметры»
    # незачем: единственное, что влияет на каталог данных, — --awg-dir.
    local body
    body=$(sed -n '/^request_reboot() {/,/^}/p' "$SCRIPT")
    [[ "$body" != *"те же параметры"* ]]
    [[ "$body" != *"домашний каталог лягут конфиги"* ]]
}

# ── Недоступные репозитории ─────────────────────────────────────────────────

@test "пустой каталог индексов apt считается непригодным" {
    # apt-get update выходит с нулём, даже не скачав ни одного индекса:
    # недоступное зеркало для него предупреждение, а не ошибка. Дальше
    # установка падала на «Unable to locate package gpg» — сообщении, которое
    # отправляет искать пропавший пакет вместо недоступной сети.
    mkdir -p "$TEST_TMP/lists"
    run apt_lists_usable "$TEST_TMP/lists"
    [ "$status" -ne 0 ]

    touch "$TEST_TMP/lists/mirror.example.com_debian_dists_trixie_main_binary-amd64_Packages"
    run apt_lists_usable "$TEST_TMP/lists"
    [ "$status" -eq 0 ]
}

@test "недоступные хосты вытаскиваются из вывода apt" {
    local out
    out=$(apt_failed_hosts 'Err:6 https://deb.debian.org/debian-security trixie-security InRelease
  Cannot initiate the connection
W: Failed to fetch mirror+file:/etc/apt/mirrors/debian.list/dists/trixie/InRelease
Hit:7 https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu noble InRelease')
    [[ "$out" == *"deb.debian.org"* ]]
    # Успешные строки в список не попадают.
    [[ "$out" != *"ppa.launchpadcontent.net"* ]]
}

# ── Панель ──────────────────────────────────────────────────────────────────

@test "панель зовёт только существующие команды awg3" {
    # Панель — второй потребитель CLI после человека: переименование команды,
    # не отражённое в ней, всплывает уже у пользователя.
    local panel="$REPO_ROOT/panel/awg-panel.ps1"
    local cmd
    for cmd in $(grep -oE "CmdArgs @\('[a-z-]+" "$panel" | sed "s/.*'//" | sort -u); do
        grep -qE "^        ${cmd}[)|]|\|${cmd}[)|]|${cmd}\|" "$REPO_ROOT/awg3.sh" \
            || grep -q "\"$cmd\"" "$REPO_ROOT/awg3.sh" \
            || false
    done
}

@test "панель работает с каталогом ~/awg/ИНТЕРФЕЙС" {
    # Раскладка должна совпадать с awg3.sh, иначе панель скачивала бы файлы
    # не того интерфейса, что показывает в списке.
    grep -q 'RemoteDir = "$($script:HomeDir)/awg/$Name"' "$REPO_ROOT/panel/awg-panel.ps1"
}

@test "панель построена на четырёх экранах с единым возвратом" {
    # Серверы → интерфейсы → ключи → карточка ключа. Плоского меню больше нет:
    # по нему, когда интерфейсов несколько, не понять, к чему относится
    # «состояние» и «перезапустить».
    local panel="$REPO_ROOT/panel/awg-panel.ps1"
    grep -q "function Screen-Servers" "$panel"
    grep -q "function Screen-Ifaces" "$panel"
    grep -q "function Screen-Peers" "$panel"
    grep -q "function Screen-Peer " "$panel"
    ! grep -q "function Show-Menu" "$panel"
    # Возврат и выход одинаковы на всех уровнях.
    [ "$(grep -c "'\^0\\$'" "$panel")" -ge 3 ]
}

@test "панель берёт список ключей машиночитаемой командой" {
    grep -q "CmdArgs @('peers')" "$REPO_ROOT/panel/awg-panel.ps1"
    grep -qE "^ +peers\)" "$REPO_ROOT/awg3.sh"
}

@test "панель переживает отсутствие консоли" {
    # Clear-Host падает без дескриптора консоли: под перенаправлением в файл
    # или в конвейере. Панель умирала на первой же перерисовке — то есть
    # именно тогда, когда человек пытался снять лог, чтобы прислать его.
    grep -q "try { Clear-Host } catch { }" "$REPO_ROOT/panel/awg-panel.ps1"
}

@test "крошки показываются только после входа на сервер" {
    # Иначе на экране серверов печатался адрес прошлой (в том числе
    # неудавшейся) попытки, и панель выглядела подключённой к серверу,
    # которого в списке нет.
    grep -q 'if ($script:Connected -and $VpsHost)' "$REPO_ROOT/panel/awg-panel.ps1"
}

@test "сообщение об ошибке не стирается перерисовкой" {
    # Show-Banner зовёт Clear-Host: без паузы объяснение, почему не удалось
    # добавить сервер, исчезало раньше, чем его успевали прочитать.
    local body
    body=$(sed -n "/'\^\[Nn\]\\$' {/,/^            }/p" "$REPO_ROOT/panel/awg-panel.ps1" | head -12)
    [[ "$body" == *"Pause-Panel"* ]]
}
