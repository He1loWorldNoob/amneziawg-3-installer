#!/usr/bin/env bats
#
# Подготовка машины: чистка пакетов, swap, sysctl, тюнинг сетевой карты и
# fail2ban. Раньше это делал install-awg3.sh — установщик AmneziaWG не должен
# решать, как настроен чужой сервер.

load '../lib/bootstrap'

setup() { setup_bootstrap; }
teardown() { teardown_bootstrap; }

@test "функции подготовки живут в bootstrap" {
    local f
    for f in cleanup_system optimize_system optimize_swap optimize_nic \
             detect_hardware apply_sysctl_profile setup_advanced_sysctl \
             setup_minimal_sysctl setup_fail2ban; do
        declare -F "$f" >/dev/null
    done
}

@test "main зовёт подготовку и уважает --no-tweaks" {
    local body
    body=$(sed -n '/^main() {/,/^}/p' "$REPO_ROOT/bootstrap.sh")
    [[ "$body" == *cleanup_system* ]]
    [[ "$body" == *optimize_system* ]]
    [[ "$body" == *setup_fail2ban* ]]
    [[ "$body" == *apply_sysctl_profile* ]]
    [[ "$body" == *NO_TWEAKS* ]]
}

@test "--no-tweaks разбирается и не путается с другими флагами" {
    NO_TWEAKS=0
    local body
    body=$(sed -n '/--no-tweaks)/p' "$REPO_ROOT/bootstrap.sh")
    [[ "$body" == *NO_TWEAKS=1* ]]
}

@test "профиль sysctl выбирается одной функцией" {
    # --no-tweaks не должен расходиться с обычным путём в том, какой файл и с
    # каким IPv6 окажется на диске.
    local body
    body=$(sed -n '/^apply_sysctl_profile() {/,/^}/p' "$REPO_ROOT/bootstrap.sh")
    [[ "$body" == *setup_advanced_sysctl* ]]
    [[ "$body" == *setup_minimal_sysctl* ]]
    [[ "$body" == *NO_TWEAKS* ]]
}

@test "минимальный sysctl включает форвардинг и глушит IPv6" {
    # IPv6 отключается по умолчанию: на этом шаге ещё неизвестно, понадобится
    # ли он в туннеле. Снимает отключение awg3 server-init --ipv6 on.
    local f="$TEST_TMP/sysctl.conf"
    setup_minimal_sysctl_to() { :; }
    run bash -c "grep -A6 'net.ipv4.ip_forward = 1' '$REPO_ROOT/bootstrap.sh' | head -8"
    [[ "$output" == *"disable_ipv6"* ]]
}

@test "jail fail2ban называется по своему хозяину, а не по AmneziaWG" {
    # Файл создаёт bootstrap, и удаление AmneziaWG не должно снимать защиту SSH.
    grep -q "/etc/fail2ban/jail.d/bootstrap-sshd.conf" "$REPO_ROOT/bootstrap.sh"
    ! grep -q "jail.d/amneziawg.conf" "$REPO_ROOT/bootstrap.sh"
}

@test "перенесённый код не зовёт помощников установщика" {
    # install_packages и AWG_DIR остались в install-awg3.sh — здесь их нет.
    ! grep -q "install_packages" "$REPO_ROOT/bootstrap.sh"
    ! grep -q "AWG_DIR" "$REPO_ROOT/bootstrap.sh"
}

@test "в перенесённом коде не осталось переменных установщика" {
    # Регрессия: setup_advanced_sysctl подписывал файл версией установщика и
    # падал на «SCRIPT_VERSION: unbound variable» — уже после того, как создал
    # swap и настроил fail2ban.
    ! grep -q "SCRIPT_VERSION" "$REPO_ROOT/bootstrap.sh"
    ! grep -q "_APT_UPDATED" "$REPO_ROOT/bootstrap.sh"
    ! grep -q "AWG_PORT" "$REPO_ROOT/bootstrap.sh"
}

@test "log_error и log_debug есть — их зовёт перенесённый код" {
    declare -F log_error >/dev/null
    declare -F log_debug >/dev/null
}
