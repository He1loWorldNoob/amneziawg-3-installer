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

@test "имя хоста читается из awg0.conf" {
    sed -i '1a #_Endpoint = vpn.example.com' "$SERVER_CONF"
    run server_endpoint_name
    [ "$output" = "vpn.example.com" ]
}

@test "без записи имя хоста пустое" {
    run server_endpoint_name
    [ -z "$output" ]
}

@test "имя хоста из конфига важнее автоопределения" {
    sed -i '1a #_Endpoint = vpn.example.com' "$SERVER_CONF"
    run resolve_endpoint
    [ "$output" = "vpn.example.com" ]
}

@test "флаг --endpoint важнее записи в конфиге" {
    sed -i '1a #_Endpoint = vpn.example.com' "$SERVER_CONF"
    ENDPOINT_OVERRIDE="other.example.net"
    run resolve_endpoint
    [ "$output" = "other.example.net" ]
}

@test "имя хоста ищется только в секции Interface" {
    printf '\n[Peer]\n#_Endpoint = ложное.имя\n' >> "$SERVER_CONF"
    run server_endpoint_name
    [ -z "$output" ]
}

@test "list показывает имя хоста" {
    sed -i '1a #_Endpoint = vpn.example.com' "$SERVER_CONF"
    run cmd_list
    [[ "$output" == *"имя хоста для клиентов: vpn.example.com"* ]]
}

@test "list сообщает, когда имя хоста не задано" {
    run cmd_list
    [[ "$output" == *"не задано"* ]]
}

@test "strip_ipv6_routes убирает ::/0, сохраняя IPv4" {
    run strip_ipv6_routes "0.0.0.0/0, ::/0"
    [ "$output" = "0.0.0.0/0" ]
}

@test "strip_ipv6_routes убирает все IPv6-подсети из списка" {
    run strip_ipv6_routes "10.0.0.0/8, fd00::/8, 192.168.0.0/16, 2001:db8::/32"
    [ "$output" = "10.0.0.0/8, 192.168.0.0/16" ]
}

@test "strip_ipv6_routes не трогает список без IPv6" {
    run strip_ipv6_routes "10.0.0.0/8, 192.168.0.0/16"
    [ "$output" = "10.0.0.0/8, 192.168.0.0/16" ]
}

@test "strip_ipv6_routes переживает лишние пробелы" {
    run strip_ipv6_routes "0.0.0.0/0 ,   ::/0 ,  10.0.0.0/8"
    [ "$output" = "0.0.0.0/0, 10.0.0.0/8" ]
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
