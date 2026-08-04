# Общий setup для bats-файлов, тестирующих bootstrap.sh.
#
# BOOTSTRAP_LIB_ONLY=1 заставляет source-guard пропустить main. Пути к
# системным файлам переопределяются на временный каталог, чтобы тест не мог
# тронуть живой sshd даже при ошибке в коде.

setup_bootstrap() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    export REPO_ROOT

    TEST_TMP="$(mktemp -d)"
    export TEST_TMP

    BOOTSTRAP_LIB_ONLY=1 source "$REPO_ROOT/bootstrap.sh"

    SSHD_DROPIN="$TEST_TMP/99-awg3-hardening.conf"
    SSH_SOCKET_DROPIN="$TEST_TMP/ssh.socket.d/99-awg3-port.conf"
}

teardown_bootstrap() {
    if [[ -n "${TEST_TMP:-}" && "$TEST_TMP" == /tmp/* ]]; then
        rm -rf "$TEST_TMP"
    fi
}
