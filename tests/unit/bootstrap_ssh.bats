#!/usr/bin/env bats

load '../lib/bootstrap'

setup() { setup_bootstrap; }
teardown() { teardown_bootstrap; }

# ── Определение порта ───────────────────────────────────────────────────────

@test "порт читается из sshd_config" {
    cat > "$TEST_TMP/sshd_config" <<'EOF'
#Port 22
Port 2222
PermitRootLogin yes
EOF
    run parse_ssh_port_from_config "$TEST_TMP/sshd_config"
    [ "$output" = "2222" ]
}

@test "закомментированный Port игнорируется" {
    printf '#Port 2222\n' > "$TEST_TMP/sshd_config"
    run parse_ssh_port_from_config "$TEST_TMP/sshd_config"
    [ -z "$output" ]
}

@test "порт читается из ListenAddress с IPv4" {
    printf 'ListenAddress 0.0.0.0:2222\n' > "$TEST_TMP/sshd_config"
    run parse_ssh_port_from_config "$TEST_TMP/sshd_config"
    [ "$output" = "2222" ]
}

@test "порт читается из ListenAddress с IPv6 в скобках" {
    printf 'ListenAddress [::]:2223\n' > "$TEST_TMP/sshd_config"
    run parse_ssh_port_from_config "$TEST_TMP/sshd_config"
    [ "$output" = "2223" ]
}

@test "ListenAddress без порта не даёт ложного значения" {
    printf 'ListenAddress 0.0.0.0\n' > "$TEST_TMP/sshd_config"
    run parse_ssh_port_from_config "$TEST_TMP/sshd_config"
    [ -z "$output" ]
}

@test "detect_current_ssh_port на этой системе возвращает 22" {
    run detect_current_ssh_port
    [ "$status" -eq 0 ]
    [ "$output" = "22" ]
}

# ── Drop-in ─────────────────────────────────────────────────────────────────

@test "drop-in содержит заданный порт" {
    write_sshd_dropin 2222
    grep -qx "Port 2222" "$SSHD_DROPIN"
}

@test "drop-in без запрета root не содержит PermitRootLogin" {
    write_sshd_dropin 2222
    ! grep -q "PermitRootLogin" "$SSHD_DROPIN"
}

@test "drop-in с запретом root содержит PermitRootLogin no" {
    write_sshd_dropin 2222 no
    grep -qx "PermitRootLogin no" "$SSHD_DROPIN"
}

@test "повторная запись не дублирует директивы" {
    write_sshd_dropin 2222
    write_sshd_dropin 2222 no
    [ "$(grep -c '^Port ' "$SSHD_DROPIN")" -eq 1 ]
    [ "$(grep -c '^PermitRootLogin ' "$SSHD_DROPIN")" -eq 1 ]
}

@test "права на drop-in — 644" {
    write_sshd_dropin 2222
    [ "$(stat -c '%a' "$SSHD_DROPIN")" = "644" ]
}

# ── Socket activation ───────────────────────────────────────────────────────

@test "override сокета сбрасывает прежний список портов" {
    systemctl() { return 0; }
    write_ssh_socket_override 2222
    # Пустой ListenStream обязателен: иначе сокет продолжит слушать и старый порт
    grep -qx "ListenStream=" "$SSH_SOCKET_DROPIN"
    grep -qx "ListenStream=2222" "$SSH_SOCKET_DROPIN"
}

@test "ssh_socket_active на Ubuntu 24.04 обнаруживает сокет" {
    if [ "$(. /etc/os-release; echo "$ID")" != "ubuntu" ]; then
        skip "проверка для Ubuntu с socket activation"
    fi
    run ssh_socket_active
    [ "$status" -eq 0 ]
}

# ── Проверка порта ──────────────────────────────────────────────────────────

@test "sshd_listening_on видит порт 22 на этой системе" {
    run sshd_listening_on 22
    [ "$status" -eq 0 ]
}

@test "sshd_listening_on не видит заведомо свободный порт" {
    run sshd_listening_on 64821
    [ "$status" -ne 0 ]
}

@test "при socket activation ssh.service останавливается, а не перезапускается" {
    # Регрессия: перезапуск обоих подряд поднимал sshd в режиме демона рядом
    # с сокетом — два слушателя на одном порту дают "Connection refused"
    # при обмене баннерами.
    local calls="$TEST_TMP/systemctl-calls"
    : > "$calls"
    systemctl() { printf '%s\n' "$*" >> "$calls"; return 0; }
    ssh_socket_active() { return 0; }

    restart_ssh

    grep -qx "stop ssh.service" "$calls"
    grep -qx "restart ssh.socket" "$calls"
    ! grep -qx "restart ssh" "$calls"
}

@test "без socket activation перезапускается сам сервис" {
    local calls="$TEST_TMP/systemctl-calls"
    : > "$calls"
    systemctl() { printf '%s\n' "$*" >> "$calls"; return 0; }
    ssh_socket_active() { return 1; }

    restart_ssh

    grep -qx "restart ssh" "$calls"
    ! grep -q "ssh.socket" "$calls"
}

@test "apply_ssh_port ничего не делает, если порт совпадает" {
    OLD_SSH_PORT=22
    run apply_ssh_port 22
    [ "$status" -eq 0 ]
    [[ "$output" == *"не меняется"* ]]
    [ ! -f "$SSHD_DROPIN" ]
}

# ── Итоговая сводка ─────────────────────────────────────────────────────────

@test "итог содержит пользователя, порт и состояние root" {
    NEW_USER="admin"; NEW_SSH_PORT="2222"
    ROOT_SSH_DISABLED=1; NEEDS_REBOOT=0; SERVER_ADDR="203.0.113.10"
    write_summary "$TEST_TMP/summary.txt"
    grep -q "admin" "$TEST_TMP/summary.txt"
    grep -q "2222" "$TEST_TMP/summary.txt"
    grep -q "отключён" "$TEST_TMP/summary.txt"
    grep -q "ssh -p 2222 admin@203.0.113.10" "$TEST_TMP/summary.txt"
}

@test "итог сообщает, что root остался включён" {
    NEW_USER="admin"; NEW_SSH_PORT="22"
    ROOT_SSH_DISABLED=0; NEEDS_REBOOT=0; SERVER_ADDR="203.0.113.10"
    write_summary "$TEST_TMP/summary.txt"
    grep -q "root по SSH:   включён" "$TEST_TMP/summary.txt"
}

@test "итог предупреждает о перезагрузке" {
    NEW_USER="admin"; NEW_SSH_PORT="22"
    ROOT_SSH_DISABLED=0; NEEDS_REBOOT=1; SERVER_ADDR="203.0.113.10"
    write_summary "$TEST_TMP/summary.txt"
    grep -qi "перезагруз" "$TEST_TMP/summary.txt"
}

@test "права на файл итога — 600" {
    NEW_USER="admin"; NEW_SSH_PORT="22"
    ROOT_SSH_DISABLED=0; NEEDS_REBOOT=0; SERVER_ADDR="203.0.113.10"
    write_summary "$TEST_TMP/summary.txt"
    [ "$(stat -c '%a' "$TEST_TMP/summary.txt")" = "600" ]
}

@test "detect_server_addr возвращает непустой адрес" {
    run detect_server_addr
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

# ── Отключение root ─────────────────────────────────────────────────────────

@test "disable_root_ssh дописывает PermitRootLogin no, сохраняя порт" {
    # Подменяем системные вызовы: юнит-тест не должен трогать живой sshd
    systemctl() { return 0; }
    sshd() { return 0; }
    ssh_socket_active() { return 1; }
    disable_root_ssh 2222
    grep -qx "Port 2222" "$SSHD_DROPIN"
    grep -qx "PermitRootLogin no" "$SSHD_DROPIN"
    [ "$ROOT_SSH_DISABLED" -eq 1 ]
}

@test "confirm_new_access при --yes не спрашивает" {
    ASSUME_YES=1
    run confirm_new_access 203.0.113.10 2222 admin
    [ "$status" -eq 0 ]
}
