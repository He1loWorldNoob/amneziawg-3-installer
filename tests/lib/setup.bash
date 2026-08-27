# Общий setup для bats-файлов, тестирующих awg3.sh.
#
# Скрипт подключается как библиотека: AWG3_LIB_ONLY=1 заставляет source-guard
# пропустить main, иначе awg3.sh запустился бы прямо внутри теста.
#
# AWG3_DIR и AWG3_SERVER_CONF уводят все пути во временный каталог — тест не
# может задеть реальную систему даже при ошибке в коде.

setup_awg3() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    export REPO_ROOT

    TEST_TMP="$(mktemp -d)"
    export TEST_TMP

    # AWG3_DIR — корень данных; клиенты живут в подкаталоге интерфейса.
    export AWG3_DIR="$TEST_TMP/awg"
    export AWG3_SERVER_CONF="$TEST_TMP/awg0.conf"
    mkdir -p "$AWG3_DIR/awg0"

    AWG3_LIB_ONLY=1 source "$REPO_ROOT/awg3.sh"
}

teardown_awg3() {
    if [[ -n "${TEST_TMP:-}" && "$TEST_TMP" == /tmp/* ]]; then
        rm -rf "$TEST_TMP"
    fi
}
