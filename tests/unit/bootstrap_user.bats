#!/usr/bin/env bats

load '../lib/bootstrap'

setup() { setup_bootstrap; }
teardown() { teardown_bootstrap; }

@test "обычное имя принимается" {
    run validate_username admin
    [ "$status" -eq 0 ]
}

@test "имя с дефисом и цифрами принимается" {
    run validate_username vpn-adm1n
    [ "$status" -eq 0 ]
}

@test "имя с заглавной буквы отвергается" {
    run validate_username Admin
    [ "$status" -ne 0 ]
}

@test "имя, начинающееся с цифры, отвергается" {
    run validate_username 1admin
    [ "$status" -ne 0 ]
}

@test "root отвергается" {
    run validate_username root
    [ "$status" -ne 0 ]
}

@test "пустое имя отвергается" {
    run validate_username ""
    [ "$status" -ne 0 ]
}

@test "имя длиннее 32 символов отвергается" {
    run validate_username "$(printf 'a%.0s' {1..33})"
    [ "$status" -ne 0 ]
}

@test "имя с пробелом отвергается" {
    run validate_username "my user"
    [ "$status" -ne 0 ]
}

@test "пароль короче 8 символов отвергается" {
    run validate_password "short12"
    [ "$status" -ne 0 ]
}

@test "пароль из 8 символов принимается" {
    run validate_password "longeno1"
    [ "$status" -eq 0 ]
}

@test "пароль с двоеточием отвергается: ломает формат chpasswd" {
    run validate_password "pass:word1"
    [ "$status" -ne 0 ]
}

@test "user_exists видит root и не видит несуществующего" {
    run user_exists root
    [ "$status" -eq 0 ]
    run user_exists nosuchuser_qwerty
    [ "$status" -ne 0 ]
}

@test "sudoers с правилом %sudo распознаётся" {
    printf '%%sudo\tALL=(ALL:ALL) ALL\n' > "$TEST_TMP/sudoers"
    run sudo_group_enabled "$TEST_TMP/sudoers"
    [ "$status" -eq 0 ]
}

@test "sudoers без правила %sudo отвергается" {
    printf 'root\tALL=(ALL:ALL) ALL\n' > "$TEST_TMP/sudoers"
    run sudo_group_enabled "$TEST_TMP/sudoers"
    [ "$status" -ne 0 ]
}

@test "закомментированное правило %sudo не засчитывается" {
    printf '# %%sudo\tALL=(ALL:ALL) ALL\n' > "$TEST_TMP/sudoers"
    run sudo_group_enabled "$TEST_TMP/sudoers"
    [ "$status" -ne 0 ]
}

@test "группа sudo включена в sudoers на этой системе" {
    # /etc/sudoers имеет права 440 root:root — под обычным юзером не прочитать
    [ "$EUID" -eq 0 ] || skip "требует root"
    run sudo_group_enabled
    [ "$status" -eq 0 ]
}

@test "в Ubuntu группа admin существует до создания пользователя" {
    # Регрессия: useradd по умолчанию создаёт одноимённую группу и падает с
    # «group admin exists». На дефолтном --user admin установка ломалась.
    if [ "$(. /etc/os-release; echo "$ID")" != "ubuntu" ]; then
        skip "проверка специфична для Ubuntu"
    fi
    run getent group admin
    [ "$status" -eq 0 ]
}

@test "create_sudo_user передаёт -g, когда группа уже существует" {
    grep -q 'getent group "\$name"' "$REPO_ROOT/bootstrap.sh"
    grep -q 'useradd_opts+=(-g "\$name")' "$REPO_ROOT/bootstrap.sh"
}

@test "read_password берёт первую строку файла" {
    printf 'secret123\nмусор\n' > "$TEST_TMP/pw"
    PASSWORD_FILE="$TEST_TMP/pw"
    read_password
    [ "$NEW_PASSWORD" = "secret123" ]
}

@test "read_password отвергает слишком короткий пароль из файла" {
    printf 'short\n' > "$TEST_TMP/pw"
    PASSWORD_FILE="$TEST_TMP/pw"
    run read_password
    [ "$status" -ne 0 ]
}
