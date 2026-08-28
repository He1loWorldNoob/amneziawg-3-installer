#!/usr/bin/env bats
#
# Ссылка vpn:// собирается вручную: BE32-длина, zlib из gzip, base64url и два
# уровня JSON. Каждый шаг здесь и проверяется — как по известным векторам, так
# и обратной распаковкой готовой ссылки.

load '../lib/setup'

setup() {
    setup_awg3
    CLIENT_DIR="$AWG3_DIR/ivan"
    mkdir -p "$CLIENT_DIR"
    CONF="$CLIENT_DIR/ivan.conf"
    write_conf "$CONF"
}
teardown() { teardown_awg3; }

# Типовой конфиг клиента AWG 3.0 — тот же набор полей, что пишет
# render_client_conf.
write_conf() {
    cat > "$1" <<'EOF'
[Interface]
PrivateKey = qEHb6VNVYRe7Yqrhh5S9j+MHKtRQPQmC6/6zDVDVeVo=
Address = 10.9.9.2/32, fddd:2c4:2c4:2c4::2/128
DNS = 1.1.1.1, 1.0.0.1
MTU = 1280

S1 = 77
S2 = 134
S3 = 51
S4 = 22
H1 = 512345678-512356789
H2 = 1512345678-1512356789
H3 = 2512345678-2512356789
H4 = 3712345678-3712356789
HeaderProtectionKey = 3lM9kLwzCq7wF0nHXlNTVoJbW1Kk4qMLU1yE0kK1cVs=
ContentPaddingAddition = 33-97
Jc = 5
Jmin = 300
Jmax = 800
I1 = <b 0xc00000080000000000>
I2 = <r 40>
RekeyAfterTime = 110-135
RekeyTimeout = 5-8
RejectAfterTime = 175-200
KeepaliveTimeout = 12-18
MaxHandshakeAttempts = 14-20

[Peer]
PublicKey = xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=
Endpoint = vpn.example.com:48872
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 33
EOF
}

# Разбор JSON в тестах идёт питоном; проверяется не наличие команды, а
# работоспособность — в PATH попадаются заглушки, которые только советуют
# поставить интерпретатор.
have_python() { python3 -c 'import json, zlib, base64' >/dev/null 2>&1; }

# Обратная сборка ссылки. Своего распаковщика zlib в системе может не быть —
# тогда проверять содержимое JSON не на чем, и тест пропускается.
decoder() {
    if have_python; then
        echo python3
    elif perl -MCompress::Zlib -MMIME::Base64 -e '1' 2>/dev/null; then
        echo perl
    else
        skip "нет ни python3, ни perl с Compress::Zlib — распаковать ссылку нечем"
    fi
}

# decode_uri <ссылка> — печатает внешний JSON. Заодно сверяет объявленную
# длину с фактической: расхождение означает битый BE32-заголовок.
decode_uri() {
    local uri="$1" tool
    tool=$(decoder)
    if [[ "$tool" == python3 ]]; then
        URI="$uri" python3 -c '
import base64, os, struct, zlib
b = os.environ["URI"].strip()
assert b.startswith("vpn://"), b[:16]
b = b[6:]
raw = base64.urlsafe_b64decode(b + "=" * (-len(b) % 4))
n = struct.unpack(">I", raw[:4])[0]
out = zlib.decompress(raw[4:]).decode("utf-8")
assert n == len(out.encode("utf-8")), "длина в заголовке %d, распаковано %d" % (n, len(out))
print(out)
'
    else
        URI="$uri" perl -MCompress::Zlib -MMIME::Base64 -e '
my $b = $ENV{URI}; $b =~ s/\s+$//; $b =~ s{^vpn://}{} or die "нет префикса vpn://";
$b =~ tr|-_|+/|; $b .= "=" x ((4 - length($b) % 4) % 4);
my $raw = decode_base64($b);
my $n = unpack("N", substr($raw, 0, 4));
my $out = uncompress(substr($raw, 4)) or die "поток не разжался";
die "длина в заголовке $n, распаковано " . length($out) unless $n == length($out);
print $out;
'
    fi
}

# Значение поля внутреннего JSON (того, что лежит строкой в last_config).
inner_field() {
    local json="$1" key="$2"
    JSON="$json" KEY="$key" python3 -c '
import json, os
o = json.loads(os.environ["JSON"])
i = json.loads(o["containers"][0]["awg"]["last_config"])
v = i.get(os.environ["KEY"], "")
print(json.dumps(v) if isinstance(v, (list, dict)) else v)
'
}

@test "_adler32 совпадает с эталонными значениями" {
    [ "$(printf '' | _adler32)" = "00000001" ]
    [ "$(printf 'abc' | _adler32)" = "024d0127" ]
    [ "$(printf 'Wikipedia' | _adler32)" = "11e60398" ]
}

@test "_adler32 не переполняется на длинных данных" {
    local out
    out=$(head -c 200000 /dev/zero | tr '\0' 'x' | _adler32)
    [[ "$out" =~ ^[0-9a-f]{8}$ ]]
}

@test "_json_escape закрывает кавычки, слеши и перевод строки" {
    [ "$(_json_escape 'a"b')" = 'a\"b' ]
    [ "$(_json_escape 'a\b')" = 'a\\b' ]
    [ "$(_json_escape "$(printf 'a\nb')")" = 'a\nb' ]
}

@test "ссылка начинается с vpn:// и не содержит символов вне base64url" {
    run build_vpn_uri "$CONF"
    [ "$status" -eq 0 ]
    [[ "$output" == vpn://* ]]
    [[ "${output#vpn://}" =~ ^[A-Za-z0-9_-]+$ ]]
}

@test "ссылка распаковывается обратно в корректный JSON" {
    local uri json
    uri=$(build_vpn_uri "$CONF")
    json=$(decode_uri "$uri")
    [[ "$json" == *'"defaultContainer":"amnezia-awg"'* ]]
    [[ "$json" == *'"hostName":"vpn.example.com"'* ]]
    [[ "$json" == *'"dns1":"1.1.1.1"'* ]]
    [[ "$json" == *'"dns2":"1.0.0.1"'* ]]
    # Описание по умолчанию — хост: именно оно видно в списке серверов.
    [[ "$json" == *'"description":"vpn.example.com"'* ]]
    # Порт во внешнем слое строкой, во внутреннем — числом.
    [[ "$json" == *'"port":"48872"'* ]]
}

@test "внутренний JSON несёт ключи, адреса и параметры обфускации" {
    have_python || skip "нет рабочего python3 для разбора JSON"
    local json
    json=$(decode_uri "$(build_vpn_uri "$CONF")")
    [ "$(inner_field "$json" client_priv_key)" = "qEHb6VNVYRe7Yqrhh5S9j+MHKtRQPQmC6/6zDVDVeVo=" ]
    [ "$(inner_field "$json" server_pub_key)" = "xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=" ]
    [ "$(inner_field "$json" client_ip)" = "10.9.9.2" ]
    [ "$(inner_field "$json" client_ipv6)" = "fddd:2c4:2c4:2c4::2" ]
    [ "$(inner_field "$json" hostName)" = "vpn.example.com" ]
    [ "$(inner_field "$json" port)" = "48872" ]
    [ "$(inner_field "$json" mtu)" = "1280" ]
    [ "$(inner_field "$json" persistent_keep_alive)" = "33" ]
    [ "$(inner_field "$json" H1)" = "512345678-512356789" ]
    [ "$(inner_field "$json" S4)" = "22" ]
    [ "$(inner_field "$json" allowed_ips)" = '["0.0.0.0/0", "::/0"]' ]
}

@test "параметры 3.0 едут и отдельными полями, и внутри config" {
    have_python || skip "нет рабочего python3 для разбора JSON"
    local json conf_field
    json=$(decode_uri "$(build_vpn_uri "$CONF")")
    [ "$(inner_field "$json" HeaderProtectionKey)" = "3lM9kLwzCq7wF0nHXlNTVoJbW1Kk4qMLU1yE0kK1cVs=" ]
    [ "$(inner_field "$json" ContentPaddingAddition)" = "33-97" ]
    [ "$(inner_field "$json" MaxHandshakeAttempts)" = "14-20" ]
    conf_field=$(inner_field "$json" config)
    [[ "$conf_field" == *"HeaderProtectionKey = 3lM9kLwz"* ]]
    [[ "$conf_field" == *"[Peer]"* ]]
    [[ "$conf_field" == *"Endpoint = vpn.example.com:48872"* ]]
}

@test "параметры 3.1 едут отдельными полями" {
    # Приложение строит туннель по полям ссылки, а не по тексту в config: без
    # них клиент из ссылки оказался бы с выключенным RandomTrailers против
    # сервера с включённым — и туннель молча не встал бы.
    have_python || skip "нет рабочего python3 для разбора JSON"
    local json
    printf 'RandomTrailers = on
DisableCookies = on
' > "$TEST_TMP/extra"
    sed -i "/^MaxHandshakeAttempts = /r $TEST_TMP/extra" "$CONF"
    json=$(decode_uri "$(build_vpn_uri "$CONF")")
    [ "$(inner_field "$json" RandomTrailers)" = "on" ]
    [ "$(inner_field "$json" DisableCookies)" = "on" ]
}

@test "версия протокола в ссылке — 3.1" {
    # Ту же метку ставит официальное приложение (awgV3 в protocolConstants.h).
    have_python || skip "нет рабочего python3 для разбора JSON"
    local json
    json=$(decode_uri "$(build_vpn_uri "$CONF")")
    [[ "$json" == *'"protocol_version":"3.1"'* ]]
}

@test "пустых I2-I5 в ссылке нет" {
    have_python || skip "нет рабочего python3 для разбора JSON"
    local json
    sed -i '/^I2 = /d' "$CONF"
    json=$(decode_uri "$(build_vpn_uri "$CONF")")
    [ "$(inner_field "$json" I1)" = "<b 0xc00000080000000000>" ]
    [ -z "$(inner_field "$json" I2)" ]
    [ -z "$(inner_field "$json" I5)" ]
}

@test "PresharedKey попадает в psk_key, без него поля нет" {
    have_python || skip "нет рабочего python3 для разбора JSON"
    local json
    json=$(decode_uri "$(build_vpn_uri "$CONF")")
    [ -z "$(inner_field "$json" psk_key)" ]

    sed -i 's|^Endpoint = |PresharedKey = TjOaGjHeVDBOxaGLNsgeM3JVHhBUCXsZAsC4TDcSsBQ=\nEndpoint = |' "$CONF"
    json=$(decode_uri "$(build_vpn_uri "$CONF")")
    [ "$(inner_field "$json" psk_key)" = "TjOaGjHeVDBOxaGLNsgeM3JVHhBUCXsZAsC4TDcSsBQ=" ]
}

@test "IPv6-endpoint разбирается на адрес и порт" {
    have_python || skip "нет рабочего python3 для разбора JSON"
    local json
    sed -i 's|^Endpoint = .*|Endpoint = [2a01:4f8:1:2::3]:443|' "$CONF"
    json=$(decode_uri "$(build_vpn_uri "$CONF")")
    [ "$(inner_field "$json" hostName)" = "2a01:4f8:1:2::3" ]
    [ "$(inner_field "$json" port)" = "443" ]
}

@test "клиент без IPv6 получает пустой client_ipv6" {
    have_python || skip "нет рабочего python3 для разбора JSON"
    local json
    sed -i 's|^Address = .*|Address = 10.9.9.7/32|' "$CONF"
    json=$(decode_uri "$(build_vpn_uri "$CONF")")
    [ "$(inner_field "$json" client_ip)" = "10.9.9.7" ]
    [ -z "$(inner_field "$json" client_ipv6)" ]
}

@test "конфиг без Endpoint ссылку не даёт" {
    sed -i '/^Endpoint = /d' "$CONF"
    run build_vpn_uri "$CONF"
    [ "$status" -ne 0 ]
    [[ "$output" != vpn://* ]]
}

@test "нечисловой порт отвергается — иначе JSON вышел бы битым" {
    sed -i 's|^Endpoint = .*|Endpoint = vpn.example.com:порт|' "$CONF"
    run build_vpn_uri "$CONF"
    [ "$status" -ne 0 ]
}

@test "generate_link кладёт файл рядом с конфигом и закрывает права" {
    run generate_link ivan "$CONF"
    [ "$status" -eq 0 ]
    [ -f "$CLIENT_DIR/ivan.vpnuri" ]
    [ "$(stat -c '%a' "$CLIENT_DIR/ivan.vpnuri")" = "600" ]
    [[ "$(cat "$CLIENT_DIR/ivan.vpnuri")" == vpn://* ]]
}

@test "generate_link оставляет ссылку в LINK_LAST" {
    generate_link ivan "$CONF"
    [[ "$LINK_LAST" == vpn://* ]]
}

@test "временных файлов после генерации не остаётся" {
    generate_link ivan "$CONF"
    run find "$CLIENT_DIR" -name '*.uri.*' -o -name '*.gz' -o -name '*.tmp.*'
    [ -z "$output" ]
}

@test "--no-link отменяет создание файла" {
    MAKE_LINK=0
    run generate_link ivan "$CONF"
    [ "$status" -eq 0 ]
    [ ! -f "$CLIENT_DIR/ivan.vpnuri" ]
}

@test "cmd_link пересобирает ссылку по готовому конфигу и печатает её" {
    run cmd_link ivan
    [ "$status" -eq 0 ]
    [ -f "$CLIENT_DIR/ivan.vpnuri" ]
    [[ "$output" == *"vpn://"* ]]
}

@test "cmd_link без имён обходит всех клиентов" {
    mkdir -p "$AWG3_DIR/petr"
    write_conf "$AWG3_DIR/petr/petr.conf"
    run cmd_link
    [ "$status" -eq 0 ]
    [ -f "$CLIENT_DIR/ivan.vpnuri" ]
    [ -f "$AWG3_DIR/petr/petr.vpnuri" ]
    # Списком ссылки не печатаются: они по килобайту каждая.
    [[ "$output" != *"vpn://"* ]]
}

@test "cmd_link на несуществующем клиенте возвращает ошибку" {
    run cmd_link nosuchclient
    [ "$status" -ne 0 ]
}
