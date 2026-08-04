#!/usr/bin/env bats

load '../lib/setup'

setup() {
    setup_awg3
    cat > "$SERVER_CONF" <<'EOF'
[Interface]
PrivateKey = X
Address = 10.9.9.1/24
ListenPort = 48872
MTU = 1280
PostUp = iptables -I FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT
S1 = 20
S2 = 21
S3 = 22
S4 = 23
H1 = 100-200
H2 = 300-400
H3 = 500-600
H4 = 700-800
HeaderProtectionKey = KEY
EOF
}
teardown() { teardown_awg3; }

@test "изоляция определяется как off, когда правила DROP нет" {
    run server_isolation_state
    [ "$output" = "off" ]
}

@test "изоляция определяется как on, когда правило DROP есть" {
    sed -i 's|MASQUERADE|MASQUERADE; iptables -I FORWARD -i %i -o %i -j DROP|' "$SERVER_CONF"
    run server_isolation_state
    [ "$output" = "on" ]
}

@test "IPv6 определяется как off без ip6tables" {
    run server_ipv6_state
    [ "$output" = "off" ]
}

@test "IPv6 определяется как on при наличии ip6tables" {
    sed -i 's|MASQUERADE|MASQUERADE; ip6tables -I FORWARD -i %i -j ACCEPT|' "$SERVER_CONF"
    run server_ipv6_state
    [ "$output" = "on" ]
}

@test "list показывает порт, подсеть и состояние изоляции" {
    run cmd_list
    [ "$status" -eq 0 ]
    [[ "$output" == *"48872/udp"* ]]
    [[ "$output" == *"10.9.9.1/24"* ]]
    [[ "$output" == *"изоляция клиентов: off"* ]]
    [[ "$output" == *"IPv6: off"* ]]
}

@test "чтения awgsetup_cfg.init в скрипте не осталось" {
    ! grep -q "awgsetup_cfg.init" "$REPO_ROOT/awg3.sh"
}

@test "endpoint определяется без init-файла: из конфига клиента" {
    mkdir -p "$AWG_DIR/alpha"
    cat > "$AWG_DIR/alpha/alpha.conf" <<'EOF'
[Interface]
Address = 10.9.9.2/32

[Peer]
Endpoint = 203.0.113.10:48872
EOF
    run resolve_endpoint
    [ "$status" -eq 0 ]
    [ "$output" = "203.0.113.10" ]
}
