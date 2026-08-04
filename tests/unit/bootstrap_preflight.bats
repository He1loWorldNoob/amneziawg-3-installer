#!/usr/bin/env bats

load '../lib/bootstrap'

setup() { setup_bootstrap; }
teardown() { teardown_bootstrap; }

@test "detect_os читает поля из os-release" {
    cat > "$TEST_TMP/os-release" <<'EOF'
ID=debian
VERSION_ID="13"
VERSION_CODENAME=trixie
EOF
    detect_os "$TEST_TMP/os-release"
    [ "$OS_ID" = "debian" ]
    [ "$OS_VERSION_ID" = "13" ]
    [ "$OS_CODENAME" = "trixie" ]
}

@test "detect_os отказывается на отсутствующем файле" {
    run detect_os "$TEST_TMP/nope"
    [ "$status" -ne 0 ]
}

@test "debian 13 поддерживается" {
    OS_ID=debian OS_VERSION_ID=13
    run os_supported
    [ "$status" -eq 0 ]
}

@test "debian 12 поддерживается" {
    OS_ID=debian OS_VERSION_ID=12
    run os_supported
    [ "$status" -eq 0 ]
}

@test "debian 11 не поддерживается" {
    OS_ID=debian OS_VERSION_ID=11
    run os_supported
    [ "$status" -ne 0 ]
}

@test "ubuntu 24.04 поддерживается" {
    OS_ID=ubuntu OS_VERSION_ID="24.04"
    run os_supported
    [ "$status" -eq 0 ]
}

@test "ubuntu 22.04 поддерживается" {
    OS_ID=ubuntu OS_VERSION_ID="22.04"
    run os_supported
    [ "$status" -eq 0 ]
}

@test "ubuntu 20.04 не поддерживается" {
    OS_ID=ubuntu OS_VERSION_ID="20.04"
    run os_supported
    [ "$status" -ne 0 ]
}

@test "fedora не поддерживается" {
    OS_ID=fedora OS_VERSION_ID=41
    run os_supported
    [ "$status" -ne 0 ]
}

@test "reboot_required видит файл-маркер" {
    run reboot_required "$TEST_TMP/reboot-required"
    [ "$status" -ne 0 ]
    touch "$TEST_TMP/reboot-required"
    run reboot_required "$TEST_TMP/reboot-required"
    [ "$status" -eq 0 ]
}

@test "текущая ОС стенда проходит проверку" {
    detect_os
    run os_supported
    [ "$status" -eq 0 ]
}
