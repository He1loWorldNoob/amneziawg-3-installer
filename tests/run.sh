#!/usr/bin/env bash
#
# Прогон проверок на тестовом стенде: статика + юнит-тесты.
#
#   ./tests/run.sh            все тесты
#   ./tests/run.sh smoke      только tests/unit/smoke.bats

set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "=== shellcheck ==="
# Уровень warning: замечания info носят стилистический характер (SC2015 про
# `A && B || C`) и в существующем коде осознаны.
#
# SC1091 — не резолвится source по переменной пути, это ожидаемо.
# SC2317 — код после source-guard считается недостижимым, что неверно.
# SC2034 — поля распаковки `read -r pk psk ep aips hs rx tx ka` объявлены ради
#          позиционирования, часть из них по смыслу не используется.
shellcheck --severity=warning -e SC1091 -e SC2317 -e SC2034 ./*.sh tests/run.sh

echo "=== bats ==="
if [[ $# -gt 0 ]]; then
    bats "tests/unit/$1.bats"
else
    bats tests/unit/
fi
