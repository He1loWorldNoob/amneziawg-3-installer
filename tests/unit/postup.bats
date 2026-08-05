#!/usr/bin/env bats

load '../lib/setup'

setup() { setup_awg3; }
teardown() { teardown_awg3; }

@test "PostUp содержит MASQUERADE на указанном интерфейсе" {
    run build_postup eth0 1280 off off
    [ "$status" -eq 0 ]
    [[ "$output" == *"-t nat -A POSTROUTING -o eth0 -j MASQUERADE"* ]]
}

@test "PostUp разрешает форвард с туннеля" {
    run build_postup eth0 1280 off off
    [[ "$output" == *"iptables -I FORWARD -i %i -j ACCEPT"* ]]
}

@test "PostUp считает MSS как MTU минус 40" {
    run build_postup eth0 1280 off off
    [[ "$output" == *"--set-mss 1240"* ]]
}

@test "MSS пересчитывается при другом MTU" {
    run build_postup eth0 1420 off off
    [[ "$output" == *"--set-mss 1380"* ]]
}

@test "MSS-clamping вешается на оба направления" {
    run build_postup eth0 1280 off off
    [[ "$output" == *"-t mangle -A FORWARD -o %i -p tcp"* ]]
    [[ "$output" == *"-t mangle -A FORWARD -i %i -p tcp"* ]]
}

@test "без изоляции нет правила DROP между клиентами" {
    run build_postup eth0 1280 off off
    [[ "$output" != *"-i %i -o %i -j DROP"* ]]
}

@test "с изоляцией есть правило DROP между клиентами" {
    run build_postup eth0 1280 on off
    [[ "$output" == *"iptables -I FORWARD -i %i -o %i -j DROP"* ]]
}

@test "с изоляцией дубли снимаются циклом перед вставкой" {
    run build_postup eth0 1280 on off
    [[ "$output" == *"while iptables -D FORWARD -i %i -o %i -j DROP 2>/dev/null; do :; done"* ]]
}

@test "без IPv6 нет ip6tables" {
    run build_postup eth0 1280 off off
    [[ "$output" != *"ip6tables"* ]]
}

@test "с IPv6 есть MASQUERADE на ip6tables" {
    run build_postup eth0 1280 off on
    [[ "$output" == *"ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE"* ]]
}

@test "IPv6 MSS считается как MTU минус 60" {
    run build_postup eth0 1280 off on
    [[ "$output" == *"--set-mss 1220"* ]]
}

@test "изоляция с IPv6 добавляет DROP и на ip6tables" {
    run build_postup eth0 1280 on on
    [[ "$output" == *"ip6tables -I FORWARD -i %i -o %i -j DROP"* ]]
}

@test "PostDown удаляет ровно то, что PostUp добавил" {
    run build_postdown eth0 1280 on on
    [[ "$output" == *"iptables -D FORWARD -i %i -j ACCEPT"* ]]
    [[ "$output" == *"-t nat -D POSTROUTING -o eth0 -j MASQUERADE"* ]]
    [[ "$output" == *"iptables -D FORWARD -i %i -o %i -j DROP 2>/dev/null || true"* ]]
    [[ "$output" == *"ip6tables -D FORWARD -i %i -j ACCEPT"* ]]
}

@test "PostDown без изоляции не трогает правило DROP" {
    run build_postdown eth0 1280 off off
    [[ "$output" != *"-i %i -o %i -j DROP"* ]]
}

@test "PostUp однострочный: перевода строки внутри нет" {
    run build_postup eth0 1280 on on
    [ "${#lines[@]}" -eq 1 ]
}

@test "PostDown однострочный: перевода строки внутри нет" {
    run build_postdown eth0 1280 on on
    [ "${#lines[@]}" -eq 1 ]
}
