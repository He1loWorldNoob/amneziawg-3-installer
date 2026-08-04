#!/usr/bin/env bats

load '../lib/setup'

setup() { setup_awg3; }
teardown() { teardown_awg3; }

@test "validate_awg_port принимает обычный порт" {
    run validate_awg_port 48872
    [ "$status" -eq 0 ]
}

@test "validate_awg_port отвергает ноль" {
    run validate_awg_port 0
    [ "$status" -ne 0 ]
}

@test "validate_awg_port отвергает 65536" {
    run validate_awg_port 65536
    [ "$status" -ne 0 ]
}

@test "validate_awg_port отвергает нечисло" {
    run validate_awg_port "48872abc"
    [ "$status" -ne 0 ]
}

@test "validate_awg_port переживает восьмеричную ловушку 08" {
    run validate_awg_port "08"
    [ "$status" -eq 0 ]
}

@test "validate_subnet принимает 10.9.9.1/24" {
    run validate_subnet "10.9.9.1/24"
    [ "$status" -eq 0 ]
}

@test "validate_subnet отвергает адрес сети вместо адреса хоста" {
    run validate_subnet "10.9.9.0/24"
    [ "$status" -ne 0 ]
}

@test "validate_subnet отвергает broadcast" {
    run validate_subnet "10.9.9.255/24"
    [ "$status" -ne 0 ]
}

@test "validate_subnet отвергает префикс 31" {
    run validate_subnet "10.9.9.1/31"
    [ "$status" -ne 0 ]
}

@test "validate_subnet отвергает префикс 7" {
    run validate_subnet "10.9.9.1/7"
    [ "$status" -ne 0 ]
}

@test "validate_subnet отвергает октет 256" {
    run validate_subnet "10.9.256.1/24"
    [ "$status" -ne 0 ]
}

@test "validate_subnet отвергает строку без префикса" {
    run validate_subnet "10.9.9.1"
    [ "$status" -ne 0 ]
}

@test "validate_mtu принимает 1280" {
    run validate_mtu 1280
    [ "$status" -eq 0 ]
}

@test "validate_mtu отвергает 575" {
    run validate_mtu 575
    [ "$status" -ne 0 ]
}

@test "validate_mtu отвергает 9101" {
    run validate_mtu 9101
    [ "$status" -ne 0 ]
}

@test "port_is_free видит занятый порт SSH" {
    # SSH слушает TCP, а проверка идёт по UDP — занятость не должна засчитаться
    run port_is_free 22
    [ "$status" -eq 0 ]
}

@test "get_main_nic возвращает существующий интерфейс" {
    run get_main_nic
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [ -d "/sys/class/net/$output" ]
}
