#!/usr/bin/env bash
#
# awg3-apply.sh — переносит набор обфускации AmneziaWG 3.0 в существующие
# конфиги, созданные установщиком уровня 2.0 (bivlked/amneziawg-installer).
#
#   ./awg3-apply.sh params.conf /etc/amnezia/amneziawg/awg0.conf /root/awg/*.conf
#
# params.conf — вывод `awg-gen.sh -v 3.0` (AmneziaWG-Architect) или любой
# другой файл, где нужные ключи лежат как `Key = value`.
#
# Общие ключи (S1-S4, H1-H4, HeaderProtectionKey, ContentPaddingAddition)
# уходят во ВСЕ цели. Отправительские (Jc/Jmin/Jmax, I1-I5, тайминги) — только
# в клиентские: цель считается серверной, если в [Interface] есть ListenPort.
#
# Скрипт идемпотентен: старые значения этих ключей удаляются перед вставкой.
# Ключи, адреса, PostUp/PostDown, [Peer] и всё остальное не трогаются.

set -euo pipefail

SHARED_KEYS="S1 S2 S3 S4 H1 H2 H3 H4 HeaderProtectionKey ContentPaddingAddition"
SENDER_KEYS="Jc Jmin Jmax I1 I2 I3 I4 I5 RekeyAfterTime RekeyTimeout RejectAfterTime KeepaliveTimeout MaxHandshakeAttempts"

die() { echo "ошибка: $*" >&2; exit 1; }

[[ $# -ge 2 ]] || die "использование: $0 <params.conf> <target.conf> [target.conf ...]"

PARAMS="$1"; shift
[[ -r "$PARAMS" ]] || die "не читается $PARAMS"

# Достаёт значение ключа из params-файла (без учёта закомментированных строк).
param() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$PARAMS" | tail -1 | sed 's/[[:space:]]*$//'
}

# --- проверка порога nonce -------------------------------------------------
# При заданном HeaderProtectionKey любой S1-S4 меньше 12 отвергается и
# amneziawg-go (device/uapi.go), и модулем ядра (netlink.c, -EINVAL).
if [[ -n "$(param HeaderProtectionKey)" ]]; then
    for s in S1 S2 S3 S4; do
        v="$(param "$s")"
        [[ -n "$v" ]] || die "$s не задан в $PARAMS, а HeaderProtectionKey есть"
        [[ "$v" =~ ^[0-9]+$ ]] || die "$s='$v' — ожидалось целое"
        (( v >= 12 )) || die "$s=$v < 12: с защитой заголовков конфиг будет отвергнут"
    done
fi

# --- сборка блоков ---------------------------------------------------------
build_block() {
    local k v
    for k in $1; do
        v="$(param "$k")"
        [[ -n "$v" ]] && printf '%s = %s\n' "$k" "$v"
    done
}

SHARED_BLOCK="$(build_block "$SHARED_KEYS")"
SENDER_BLOCK="$(build_block "$SENDER_KEYS")"
[[ -n "$SHARED_BLOCK" ]] || die "в $PARAMS не нашлось ни одного общего ключа"

ALL_KEYS="$SHARED_KEYS $SENDER_KEYS"
STAMP="$(date +%Y%m%d%H%M%S)"

for target in "$@"; do
    [[ -f "$target" ]] || { echo "пропуск: нет файла $target" >&2; continue; }

    if grep -qiE '^[[:space:]]*ListenPort[[:space:]]*=' "$target"; then
        role="сервер"; block="$SHARED_BLOCK"
    else
        role="клиент"; block="$SHARED_BLOCK"$'\n'"$SENDER_BLOCK"
    fi

    cp -p "$target" "$target.bak-$STAMP"

    tmp="$(mktemp "${target}.XXXXXX")"
    awk -v keys="$ALL_KEYS" -v block="$block" '
        BEGIN {
            n = split(keys, a, " ")
            for (i = 1; i <= n; i++) drop[tolower(a[i])] = 1
            in_iface = 0; done = 0
        }
        # начало новой секции
        /^[[:space:]]*\[/ {
            if (in_iface && !done) { print block; done = 1 }
            in_iface = (tolower($0) ~ /^[[:space:]]*\[interface\]/)
            print; next
        }
        {
            if (in_iface) {
                line = $0
                sub(/^[[:space:]]+/, "", line)
                split(line, kv, "=")
                key = kv[1]
                sub(/[[:space:]]+$/, "", key)
                if (line !~ /^[#;]/ && tolower(key) in drop) next
            }
            print
        }
        END { if (in_iface && !done) print block }
    ' "$target" > "$tmp"

    chmod --reference="$target" "$tmp" 2>/dev/null || chmod 600 "$tmp"
    mv "$tmp" "$target"
    echo "обновлён ($role): $target   [бэкап: $target.bak-$STAMP]"
done

cat <<'EOF'

Дальше:
  awg-quick down awg0 && awg-quick up awg0     # применить на сервере
  awg show awg0                                 # убедиться, что интерфейс поднялся
Клиентские .conf раздать заново — старые с новым сервером не сойдутся.
EOF
