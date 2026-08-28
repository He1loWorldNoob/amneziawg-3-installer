#!/usr/bin/env bats

load '../lib/setup'

setup() { setup_awg3; }
teardown() { teardown_awg3; }

@test "скрипт подключается как библиотека и не выполняет main" {
    [ "$SCRIPT_VERSION" = "1.2.0" ]
}

@test "пути уведены во временный каталог" {
    # AWG3_DIR задаёт корень, клиенты живут в подкаталоге интерфейса.
    [ "$AWG_ROOT" = "$TEST_TMP/awg" ]
    [ "$AWG_DIR" = "$TEST_TMP/awg/awg0" ]
    [ "$SERVER_CONF" = "$TEST_TMP/awg0.conf" ]
}

@test "rand_int возвращает значение внутри диапазона" {
    _rand_refill
    rand_int 5 7
    [ "$REPLY" -ge 5 ]
    [ "$REPLY" -le 7 ]
}

@test "rand_int с единичным диапазоном возвращает само значение" {
    _rand_refill
    rand_int 42 42
    [ "$REPLY" -eq 42 ]
}
