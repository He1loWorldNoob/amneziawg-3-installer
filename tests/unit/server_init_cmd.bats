#!/usr/bin/env bats

load '../lib/setup'

setup() { setup_awg3; }
teardown() { teardown_awg3; }

@test "sysctl-файл содержит форвардинг IPv4" {
    run enable_forwarding off "$TEST_TMP/99-awg3.conf"
    [ "$status" -eq 0 ]
    grep -qx "net.ipv4.ip_forward = 1" "$TEST_TMP/99-awg3.conf"
}

@test "без IPv6 форвардинг v6 не включается" {
    enable_forwarding off "$TEST_TMP/99-awg3.conf"
    ! grep -q "ipv6" "$TEST_TMP/99-awg3.conf"
}

@test "с IPv6 включается и форвардинг v6" {
    enable_forwarding on "$TEST_TMP/99-awg3.conf"
    grep -qx "net.ipv6.conf.all.forwarding = 1" "$TEST_TMP/99-awg3.conf"
}

@test "server-init отказывается работать при существующем конфиге" {
    printf '[Interface]' > "$SERVER_CONF"
    run guard_existing_server
    [ "$status" -ne 0 ]
    [[ "$output" == *"уже существует"* ]]
}

@test "отказ подсказывает дорогу: снести и создать" {
    # Обходного пути вроде --force больше нет намеренно: команда, которая
    # «пересоздаёт с переносом пиров», меняла и ключи сервера, и параметры
    # обфускации — перенесённые пиры были мёртвым списком.
    printf '[Interface]' > "$SERVER_CONF"
    run guard_existing_server
    [[ "$output" == *"iface remove"* ]]
    [[ "$output" == *"iface add"* ]]
    ! grep -q "SRV_FORCE" "$REPO_ROOT/awg3.sh"
}

@test "на чистой системе guard пропускает" {
    run guard_existing_server
    [ "$status" -eq 0 ]
}

@test "server-init есть в списке команд" {
    # Без привязки к соседям: список команд дополняется, и жёсткий якорь на
    # закрывающую скобку ломался при добавлении следующей команды.
    grep -qE '^\s+add\|remove\|.*\bserver-init\b' "$REPO_ROOT/awg3.sh"
}

@test "справка упоминает server-init" {
    run usage
    [[ "$output" == *"server-init"* ]]
}

@test "check_dependencies требует ip и iptables" {
    grep -qE 'for dep in .*\bip\b.*\biptables\b' "$REPO_ROOT/awg3.sh"
}
