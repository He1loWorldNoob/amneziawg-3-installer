#!/usr/bin/env bats

load '../lib/setup'

setup() {
    setup_awg3
    _rand_refill
    gen_shared_params
    gen_sender_params
    OUT="$TEST_TMP/awg0.conf"
}
teardown() { teardown_awg3; }

# Часть тестов требует установленный awg — на голом стенде его ещё нет.
need_awg() {
    command -v awg >/dev/null 2>&1 || skip "awg не установлен"
}

@test "generate_server_keys создаёт обе части пары с правами 600" {
    need_awg
    run generate_server_keys
    [ "$status" -eq 0 ]
    [ -f "$AWG_DIR/server_private.key" ]
    [ -f "$AWG_DIR/server_public.key" ]
    [ "$(stat -c '%a' "$AWG_DIR/server_private.key")" = "600" ]
    [ "$(stat -c '%a' "$AWG_DIR/server_public.key")" = "600" ]
}

@test "публичный ключ выводится из приватного" {
    need_awg
    generate_server_keys
    local derived
    derived=$(awg pubkey < "$AWG_DIR/server_private.key")
    [ "$derived" = "$(cat "$AWG_DIR/server_public.key")" ]
}

@test "derive_ipv6_server_addr даёт первый адрес подсети" {
    run derive_ipv6_server_addr "fddd:2c4:2c4:2c4::/64"
    [ "$status" -eq 0 ]
    [ "$output" = "fddd:2c4:2c4:2c4::1/64" ]
}

@test "конфиг содержит все обязательные поля Interface" {
    render_server_conf "$OUT" "PRIVKEY" "10.9.9.1/24" 48872 1280 "PU" "PD"
    grep -qx "\[Interface\]" "$OUT"
    grep -qx "PrivateKey = PRIVKEY" "$OUT"
    grep -qx "Address = 10.9.9.1/24" "$OUT"
    grep -qx "ListenPort = 48872" "$OUT"
    grep -qx "MTU = 1280" "$OUT"
    grep -qx "PostUp = PU" "$OUT"
    grep -qx "PostDown = PD" "$OUT"
}

@test "конфиг содержит общие параметры 3.0" {
    render_server_conf "$OUT" "PRIVKEY" "10.9.9.1/24" 48872 1280 "PU" "PD"
    grep -qE "^S1 = [0-9]+$" "$OUT"
    grep -qE "^S4 = [0-9]+$" "$OUT"
    grep -qE "^H1 = [0-9]+-[0-9]+$" "$OUT"
    grep -qE "^H4 = [0-9]+-[0-9]+$" "$OUT"
    grep -qE "^HeaderProtectionKey = .{40,}$" "$OUT"
}

@test "конфиг содержит собственные sender-параметры сервера" {
    render_server_conf "$OUT" "PRIVKEY" "10.9.9.1/24" 48872 1280 "PU" "PD"
    grep -qE "^Jc = [0-9]+$" "$OUT"
    grep -qE "^Jmin = [0-9]+$" "$OUT"
    grep -qE "^Jmax = [0-9]+$" "$OUT"
    grep -qE "^I1 = .+$" "$OUT"
    grep -qE "^ContentPaddingAddition = [0-9]+-[0-9]+$" "$OUT"
}

@test "права на конфиг — 600" {
    render_server_conf "$OUT" "PRIVKEY" "10.9.9.1/24" 48872 1280 "PU" "PD"
    [ "$(stat -c '%a' "$OUT")" = "600" ]
}

@test "extract_peers достаёт оба блока Peer и не тащит Interface" {
    cat > "$TEST_TMP/old.conf" <<'EOF'
[Interface]
PrivateKey = OLD
ListenPort = 1

[Peer]
#_Name = alpha
PublicKey = AAA
AllowedIPs = 10.9.9.2/32

[Peer]
#_Name = beta
PublicKey = BBB
AllowedIPs = 10.9.9.3/32
EOF
    run extract_peers "$TEST_TMP/old.conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"#_Name = alpha"* ]]
    [[ "$output" == *"#_Name = beta"* ]]
    [[ "$output" != *"PrivateKey = OLD"* ]]
    [[ "$output" != *"ListenPort"* ]]
}

@test "extract_peers на файле без пиров возвращает пусто" {
    printf '[Interface]\nPrivateKey = X\n' > "$TEST_TMP/nopeers.conf"
    run extract_peers "$TEST_TMP/nopeers.conf"
    [ -z "$output" ]
}

@test "пиры переносятся в новый конфиг" {
    cat > "$TEST_TMP/old.conf" <<'EOF'
[Interface]
PrivateKey = OLD

[Peer]
#_Name = alpha
PublicKey = AAA
AllowedIPs = 10.9.9.2/32
EOF
    render_server_conf "$OUT" "PRIVKEY" "10.9.9.1/24" 48872 1280 "PU" "PD" "$TEST_TMP/old.conf"
    grep -qx "#_Name = alpha" "$OUT"
    grep -qx "PublicKey = AAA" "$OUT"
    grep -qx "PrivateKey = PRIVKEY" "$OUT"
    ! grep -qx "PrivateKey = OLD" "$OUT"
}

@test "без источника пиров секции Peer нет вовсе" {
    render_server_conf "$OUT" "PRIVKEY" "10.9.9.1/24" 48872 1280 "PU" "PD"
    ! grep -q "\[Peer\]" "$OUT"
}

@test "каталог конфига создаётся с правами 700" {
    local deep="$TEST_TMP/etc/amnezia/amneziawg/awg0.conf"
    render_server_conf "$deep" "PRIVKEY" "10.9.9.1/24" 48872 1280 "PU" "PD"
    [ -f "$deep" ]
    [ "$(stat -c '%a' "$(dirname "$deep")")" = "700" ]
}
