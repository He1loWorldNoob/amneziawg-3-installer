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
    printf '[Interface]\n' > "$SERVER_CONF"
    SRV_FORCE=0
    run guard_existing_server
    [ "$status" -ne 0 ]
    [[ "$output" == *"уже существует"* ]]
}

@test "с --force существующий конфиг не блокирует" {
    printf '[Interface]\n' > "$SERVER_CONF"
    SRV_FORCE=1
    run guard_existing_server
    [ "$status" -eq 0 ]
}

@test "на чистой системе guard пропускает" {
    SRV_FORCE=0
    run guard_existing_server
    [ "$status" -eq 0 ]
}

@test "server-init есть в списке команд" {
    grep -qE '^\s+add\|remove\|.*server-init\)' "$REPO_ROOT/awg3.sh"
}

@test "справка упоминает server-init" {
    run usage
    [[ "$output" == *"server-init"* ]]
}

@test "check_dependencies требует ip и iptables" {
    grep -qE 'for dep in .*\bip\b.*\biptables\b' "$REPO_ROOT/awg3.sh"
}
