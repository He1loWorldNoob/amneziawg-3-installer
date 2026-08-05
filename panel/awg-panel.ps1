# awg-panel.ps1 — интерактивная панель управления AmneziaWG на VPS.
#
# Повторяет весь набор команд ~/awg/awg3.sh, но с локальной машины и с меню:
# список, статистика, создание и удаление ключей, скачивание conf+QR,
# бэкап, перезапуск сервиса, генератор параметров.
#
# Данные подключения спрашиваются при входе по порядку: имя хоста, порт,
# пользователь и только потом пароль — ошибку в адресе видно до того, как
# набран пароль. Пароль нигде не сохраняется и передаётся помощнику через
# stdin, а не аргументом командной строки: иначе он был бы виден в списке
# процессов.
#
# Каждое действие — отдельное SSH-подключение: панель не держит открытую
# сессию, поэтому забытое окно не оставляет висящего доступа к серверу.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Сервер отвечает в UTF-8. PowerShell декодирует вывод внешних программ по
# кодировке консоли, а она в русской Windows по умолчанию cp866 — без этого
# кириллица из вывода Python превращается в мусор.
#
# ВАЖНО: именно UTF8Encoding с $false, а не [Text.Encoding]::UTF8. Последний
# включает BOM, и PowerShell дописывает три байта EF BB BF в начало всего,
# что уходит в stdin внешней программы, — пароль приезжает с невидимым
# префиксом и сервер отвечает «неверный пароль».
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
try { [Console]::OutputEncoding = $utf8NoBom } catch { }
# InputEncoding не трогаем: Read-Host -AsSecureString читает клавиатуру
# через консольный API, и подмена кодировки ввода ему только мешает.
$OutputEncoding = $utf8NoBom
# Python тоже должен писать в UTF-8, а не в кодировке локали Windows.
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'

# ── Куда ходим ──────────────────────────────────────────────────────────────
#
# Значения ниже — только подсказки при входе: адрес, порт и пользователя
# спрашиваем каждый раз, чтобы одной панелью обслуживать несколько серверов.
#
# Если ходите всегда на один сервер, впишите сюда его адрес и порт — тогда
# при входе достаточно будет жать Enter.

$DefaultHost = ''
$DefaultPort = 22
$DefaultUser = 'user'

$VpsHost      = $DefaultHost
$VpsPort      = $DefaultPort
$VpsUser      = $DefaultUser
$RemoteScript = ''
$RemoteDir    = ''

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ── Вывод ───────────────────────────────────────────────────────────────────

function Write-Head($text) {
    Write-Host ''
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host "  $('─' * [Math]::Min($text.Length, 70))" -ForegroundColor DarkCyan
}
function Write-Ok   ($text) { Write-Host "  [ OK ] $text"    -ForegroundColor Green }
function Write-Warn ($text) { Write-Host "  [ ! ]  $text"    -ForegroundColor Yellow }
function Write-Err  ($text) { Write-Host "  [ОШИБКА] $text"  -ForegroundColor Red }
function Write-Dim  ($text) { Write-Host "  $text"           -ForegroundColor DarkGray }

function Pause-Panel {
    Write-Host ''
    Write-Host '  Enter — назад в меню' -ForegroundColor DarkGray -NoNewline
    [void](Read-Host)
}

# ── Помощник на Python ──────────────────────────────────────────────────────
#
# Живёт во временном файле всё время работы панели и удаляется на выходе.
# stdin занят паролем, поэтому передать его через конвейер нельзя.

$helperCode = @'
import sys, os, base64, shlex, paramiko

# Первая строка stdin — пароль. При входе по ключу она пустая: пароль тогда
# не нужен вовсе, потому что sudo на сервере настроен через NOPASSWD именно
# для awg3.sh.
password = sys.stdin.readline().rstrip("\n")
host, port, user, mode = sys.argv[1:5]
rest = sys.argv[5:]

# Путь к приватному ключу передаётся через окружение, а не аргументом:
# аргументы видны в списке процессов, и хотя сам путь секретом не является,
# держать всё чувствительное вне командной строки — единое правило здесь.
keyfile = os.environ.get("AWG_PANEL_KEY") or None
if keyfile and not os.path.isfile(keyfile):
    keyfile = None

def fail(msg, code=1):
    sys.stderr.write(msg + "\n")
    sys.exit(code)

# Отпечаток сервера запоминается при первом подключении и сверяется дальше.
#
# Это не формальность: вход идёт по паролю, и при подмене сервера пароль
# уходит атакующему в первом же обмене — в отличие от ключей, где подмена
# стоит ему лишь провала аутентификации. Проверка отпечатка остаётся
# единственным, что удерживает пароль от утечки.
#
# load_host_keys, а не load_system_host_keys: только первый записывает файл
# обратно при close(), иначе ключ не запоминался бы между запусками и
# подмену не поймала бы даже вторая попытка.
hostkeys = os.path.join(os.path.expanduser("~"), ".awg-panel", "known_hosts")
os.makedirs(os.path.dirname(hostkeys), exist_ok=True)
open(hostkeys, "a").close()

client = paramiko.SSHClient()
client.load_host_keys(hostkeys)
client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
try:
    if keyfile:
        client.connect(host, port=int(port), username=user,
                       key_filename=keyfile, timeout=30,
                       look_for_keys=False, allow_agent=False)
    else:
        client.connect(host, port=int(port), username=user, password=password,
                       timeout=30, look_for_keys=False, allow_agent=False)
except paramiko.BadHostKeyException as exc:
    fail(
        "ОТПЕЧАТОК СЕРВЕРА ИЗМЕНИЛСЯ.\n"
        "\n"
        "Ожидался: %s\n"
        "Получен:  %s\n"
        "\n"
        "Так выглядит и переустановка сервера, и попытка перехвата: кто-то\n"
        "может выдавать себя за него, чтобы получить ваш пароль. Пароль НЕ\n"
        "был отправлен.\n"
        "\n"
        "Если сервер переустанавливали вы — удалите его строку из файла:\n"
        "  %s\n"
        "Если нет — не подключайтесь и разберитесь, что происходит."
        % (exc.expected_key.get_base64(), exc.key.get_base64(), hostkeys),
        4,
    )
except paramiko.AuthenticationException:
    fail("Неверный пароль или логин.", 2)
except Exception as exc:
    fail("Не удалось подключиться: %s" % exc, 3)

# При входе по ключу пароля нет вовсе, поэтому sudo должен работать без
# запроса — это обеспечивает правило NOPASSWD, которое ставит режим setup.
# -n вместо -S: пусть лучше честно упадёт с «требуется пароль», чем молча
# зависнет в ожидании ввода, которого никто не сделает.
SUDO = "sudo -n" if keyfile else "sudo -S -p ''"

def run(cmd):
    stdin, stdout, stderr = client.exec_command(cmd, timeout=300)
    if not keyfile:
        stdin.write(password + "\n")
        stdin.flush()
    out = stdout.read()
    err = stderr.read()
    return stdout.channel.recv_exit_status(), out, err

if mode == "setup":
    # Разовая настройка входа по ключу: публичная половина кладётся в
    # authorized_keys, а sudo получает право запускать ТОЛЬКО awg3.sh без
    # пароля. Узко намеренно: полный NOPASSWD: ALL отдал бы всю машину тому,
    # кто украдёт ключ, тогда как здесь потеря ограничена управлением VPN.
    pubkey, remote_script = rest[0], rest[1]

    rc, out, err = run(
        "install -d -m 700 ~/.ssh && touch ~/.ssh/authorized_keys && "
        "chmod 600 ~/.ssh/authorized_keys && "
        "{ grep -qxF %s ~/.ssh/authorized_keys || printf '%%s\\n' %s >> ~/.ssh/authorized_keys; }"
        % (shlex.quote(pubkey), shlex.quote(pubkey))
    )
    if rc != 0:
        fail("не удалось добавить ключ: %s" % err.decode("utf-8", "replace"), 5)

    # Имя файла в sudoers.d не может содержать точку — иначе он игнорируется.
    #
    # Весь блок уходит в ОДИН sudo -S: его stdin занят паролем, поэтому текст
    # правила нельзя подавать туда же через конвейер — sudo принял бы правило
    # за пароль и отказал с «no password was provided». По той же причине
    # sudo здесь ровно один, а не три подряд: пароль пишется в stdin однажды,
    # и второму вызову он бы уже не достался.
    # Правило сначала пишется во временный файл и проверяется visudo, и лишь
    # затем встаёт на место. Обратный порядок — запись в /etc/sudoers.d с
    # проверкой после — при любой ошибке оставил бы битый файл, а битый файл
    # в sudoers.d ломает sudo целиком: чинить было бы уже нечем.
    rule = "%s ALL=(root) NOPASSWD: %s" % (user, remote_script)
    inner = (
        "tmp=$(mktemp) && umask 077 && printf '%%s\\n' %s > \"$tmp\" && "
        "visudo -cf \"$tmp\" >/dev/null && "
        "install -m 440 -o root -g root \"$tmp\" /etc/sudoers.d/awg3-panel; "
        "rc=$?; rm -f \"$tmp\"; exit $rc"
        % shlex.quote(rule)
    )
    rc, out, err = run("sudo -S -p '' sh -c %s" % shlex.quote(inner))
    if rc != 0:
        fail("не удалось настроить sudo: %s" % err.decode("utf-8", "replace"), 6)

    client.close()
    print("Ключ добавлен, sudo настроен.")
    sys.exit(0)

elif mode == "run":
    # rest — уже разобранные аргументы awg3.sh; quote защищает от пробелов
    # и спецсимволов в именах.
    remote_script, args = rest[0], rest[1:]
    cmd = "%s %s %s" % (SUDO, remote_script, " ".join(shlex.quote(a) for a in args))
    rc, out, err = run(cmd)
    sys.stdout.write((out + err).decode("utf-8", "replace"))
    client.close()
    sys.exit(rc)

elif mode == "fetch":
    remote_dir, name, outdir = rest[0], rest[1], rest[2]
    os.makedirs(outdir, exist_ok=True)
    got = []
    # Обязателен только конфиг. QR может не собраться без qrencode, ссылки
    # vpn:// не будет у клиентов, созданных прежними версиями awg3.sh — на
    # обоих молчим, иначе каждое скачивание сыпало бы руганью на пустом месте.
    for suffix, required in ((".conf", True), (".png", False), (".vpnuri", False)):
        remote = "%s/%s/%s%s" % (remote_dir, name, name, suffix)
        # Сначала без sudo: каталог клиентов принадлежит самому пользователю,
        # и правило NOPASSWD выдано только на awg3.sh — sudo cat под ключом
        # просто не пройдёт. На sudo откатываемся ради root-установок, где
        # данные лежат в /root/awg.
        rc, out, err = run("cat %s | base64 -w0" % shlex.quote(remote))
        if rc != 0 or not out.strip():
            rc, out, err = run("%s cat %s | base64 -w0" % (SUDO, shlex.quote(remote)))
        if rc != 0 or not out.strip():
            if required:
                sys.stderr.write("нет файла: %s\n" % remote)
            continue
        local = os.path.join(outdir, name + suffix)
        with open(local, "wb") as fh:
            fh.write(base64.b64decode(out.strip()))
        got.append(local)
    client.close()
    if not any(p.endswith(".conf") for p in got):
        fail("Конфиг не скачался.")
    for p in got:
        print("СКАЧАНО: %s" % p)
    sys.exit(0)

else:
    fail("Неизвестный режим: %s" % mode)
'@

# ── Окружение ───────────────────────────────────────────────────────────────

$python = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $python) { $python = (Get-Command python3 -ErrorAction SilentlyContinue).Source }
if (-not $python) {
    Write-Err 'Не найден Python. Установите его с python.org и повторите.'
    exit 1
}

& $python -c 'import paramiko' 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host '  Ставлю библиотеку paramiko (нужна для SSH)...' -ForegroundColor Cyan
    & $python -m pip install --quiet paramiko
    if ($LASTEXITCODE -ne 0) { Write-Err 'Не удалось установить paramiko.'; exit 1 }
}

$helperPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awg-panel-{0}.py" -f [guid]::NewGuid())
Set-Content -LiteralPath $helperPath -Value $helperCode -Encoding utf8

# ── Вызовы сервера ──────────────────────────────────────────────────────────

$script:Password = $null

# Путь к ключу уходит помощнику через окружение: при подключении по ключу
# пароля нет вовсе, и помощник должен об этом знать. Пустое значение —
# признак входа по паролю.
function Set-AuthMode {
    param([bool] $UseKey)
    $env:AWG_PANEL_KEY = if ($UseKey) { $KeyPath } else { '' }
}

# Выполняет awg3.sh с аргументами. Возвращает строки вывода, код — в $script:LastRc.
function Invoke-Remote {
    # Не $Args: так называется автоматическая переменная PowerShell.
    param([string[]] $CmdArgs, [switch] $Quiet)

    $all = @($VpsHost, $VpsPort, $VpsUser, 'run', $RemoteScript) + $CmdArgs
    $out = $script:Password | & $python $helperPath @all 2>&1
    $script:LastRc = $LASTEXITCODE

    if (-not $Quiet) {
        foreach ($line in $out) { Write-Host "  $line" }
    }
    return $out
}

function Invoke-Fetch {
    param([string] $Name, [string] $OutDir, [switch] $Quiet)

    $all = @($VpsHost, $VpsPort, $VpsUser, 'fetch', $RemoteDir, $Name, $OutDir)
    $out = $script:Password | & $python $helperPath @all 2>&1
    $script:LastRc = $LASTEXITCODE
    if (-not $Quiet) {
        foreach ($line in $out) { Write-Host "  $line" }
    }
    return $script:LastRc
}

# Путь к скачанной ссылке vpn:// или $null.
#
# У клиентов, созданных прежними версиями awg3.sh, файла со ссылкой на
# сервере просто нет. Просим собрать его по готовому конфигу и качаем ещё
# раз: ключи и пир при этом не трогаются. На сервере со старым скриптом
# команда не найдётся — тогда остаёмся с конфигом и QR, это не ошибка.
function Get-ClientLink {
    param([string] $Name, [string] $OutDir)

    $link = Join-Path $OutDir "$Name.vpnuri"
    if (Test-Path $link) { return $link }

    Invoke-Remote -CmdArgs @('link', $Name) -Quiet | Out-Null
    if ($script:LastRc -ne 0) { return $null }

    Invoke-Fetch -Name $Name -OutDir $OutDir -Quiet | Out-Null
    if (Test-Path $link) { return $link }
    return $null
}

# Показывает ссылку и предлагает положить её в буфер обмена: вставить в
# приложение проще, чем возить файл.
function Show-ClientLink {
    param([string] $Name, [string] $OutDir)

    $link = Get-ClientLink -Name $Name -OutDir $OutDir
    if (-not $link) {
        Write-Dim 'Ссылки vpn:// нет: на сервере awg3.sh без команды link.'
        return
    }

    Write-Ok "Ссылка vpn://: $link"
    if (-not (Confirm-Action 'Скопировать ссылку в буфер обмена?')) { return }
    try {
        Set-Clipboard -Value (Get-Content -LiteralPath $link -Raw).Trim()
        Write-Ok 'Скопировано. В AmneziaVPN: «+» → «Ввести ключ вручную» → вставить.'
    } catch {
        Write-Warn "Буфер обмена недоступен, откройте файл: $link"
    }
}

function Get-ClientNames {
    $out = Invoke-Remote -CmdArgs @('names') -Quiet
    if ($script:LastRc -ne 0) {
        Write-Err 'Не удалось получить список клиентов.'
        foreach ($line in $out) { Write-Host "  $line" }
        return @()
    }
    return @($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^[a-zA-Z0-9_-]+$' })
}

# Выбор клиента из пронумерованного списка. Возвращает имя или $null.
function Select-Client {
    param([string] $Title)

    $names = Get-ClientNames
    if ($names.Count -eq 0) { Write-Warn 'Клиентов нет.'; return $null }

    Write-Head $Title
    for ($i = 0; $i -lt $names.Count; $i++) {
        Write-Host ("   {0,2}  {1}" -f ($i + 1), $names[$i])
    }
    Write-Host '    0  отмена' -ForegroundColor DarkGray
    Write-Host ''
    $choice = Read-Host '  Номер'
    if ($choice -notmatch '^\d+$') { return $null }
    $idx = [int]$choice
    if ($idx -lt 1 -or $idx -gt $names.Count) { return $null }
    return $names[$idx - 1]
}

function Confirm-Action {
    param([string] $Question)
    Write-Host ''
    $answer = Read-Host "  $Question [y/N]"
    return ($answer -match '^[yYдД]')
}

# ── Профили серверов ────────────────────────────────────────────────────────
#
# Всё состояние панели живёт в одном каталоге: отпечатки серверов, список
# профилей и ключ для входа. Пароль не хранится нигде — вместо него панель
# заводит SSH-ключ при добавлении сервера.

$PanelDir       = Join-Path $HOME '.awg-panel'
$KnownHostsPath = Join-Path $PanelDir 'known_hosts'
$ProfilesPath   = Join-Path $PanelDir 'servers.json'
$KeyPath        = Join-Path $PanelDir 'id_ed25519'

function Get-Profiles {
    if (-not (Test-Path $ProfilesPath)) { return @() }
    try {
        return @(Get-Content $ProfilesPath -Raw | ConvertFrom-Json)
    } catch {
        Write-Warn "Файл профилей повреждён: $ProfilesPath"
        return @()
    }
}

function Save-Profiles {
    param([array] $Items)
    New-Item -ItemType Directory -Force -Path $PanelDir | Out-Null
    # ConvertTo-Json с одним элементом отдаёт объект, а не массив — на чтении
    # это ломает перечисление, поэтому глубина и явный массив обязательны.
    ,@($Items) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ProfilesPath
}

# Ключ создаётся один на все серверы: он нужен, чтобы не хранить пароль, а не
# чтобы разграничивать доступ между ними.
function Ensure-PanelKey {
    $keygen = (Get-Command ssh-keygen -ErrorAction SilentlyContinue).Source
    if (-not $keygen) {
        Write-Err 'Не найден ssh-keygen. Установите OpenSSH Client в компонентах Windows.'
        return $false
    }

    if (Test-Path $KeyPath) { return $true }

    New-Item -ItemType Directory -Force -Path $PanelDir | Out-Null
    # Именно "" (двойные), а не '""': одинарные кавычки в PowerShell дают
    # буквальные два символа кавычки, и они становятся ПАРОЛЬНОЙ ФРАЗОЙ.
    # Ключ тогда создаётся зашифрованным, а paramiko открыть его не может и
    # сообщает про неверный пароль — искать причину приходится долго.
    # Комментарий с именем машины: он же служит меткой при повторной
    # настройке — заменяем запись именно этого компьютера, не трогая ключи
    # других, с которых вы тоже могли подключаться.
    & $keygen -q -t ed25519 -f $KeyPath -N "" -C "awg-panel@$env:COMPUTERNAME" 2>&1 | Out-Null

    if (-not (Test-Path $KeyPath)) {
        Write-Err 'Не удалось создать ключ.'
        return $false
    }

    # Проверяем, что ключ действительно без фразы: иначе автовход молча не
    # заработает, а ошибка будет выглядеть как неверный пароль.
    & $keygen -y -P '' -f $KeyPath 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Remove-Item $KeyPath, "$KeyPath.pub" -Force -ErrorAction SilentlyContinue
        Write-Err 'Ключ создался с парольной фразой — так автовход не заработает.'
        Write-Dim "Создайте вручную: ssh-keygen -t ed25519 -f `"$KeyPath`" -N `"`""
        return $false
    }

    Write-Ok "Ключ панели создан: $KeyPath"
    return $true
}

# Убирает запись о сервере, чтобы следующий вход запомнил новый отпечаток.
# paramiko пишет "host" для порта 22 и "[host]:port" для остальных.
function Remove-KnownHost {
    param([string] $ServerHost, [int] $ServerPort)

    if (-not (Test-Path $KnownHostsPath)) { return $false }

    $keys = @("$ServerHost ", "[$ServerHost]:$ServerPort ")
    $before = @(Get-Content $KnownHostsPath)
    $after = $before | Where-Object {
        $line = $_
        -not ($keys | Where-Object { $line.StartsWith($_) })
    }

    if ($after.Count -eq $before.Count) { return $false }
    Set-Content -LiteralPath $KnownHostsPath -Value $after
    return $true
}

# ── Действия ────────────────────────────────────────────────────────────────

function Action-List {
    Write-Head 'Клиенты'
    Invoke-Remote -CmdArgs @('list') | Out-Null
}

function Action-Stats {
    Write-Head 'Трафик и активность'
    Invoke-Remote -CmdArgs @('stats') | Out-Null
}

function Action-Add {
    Write-Head 'Новый ключ'
    $name = (Read-Host '  Имя ключа (латиница, цифры, дефис)').Trim()
    if ($name -notmatch '^[a-zA-Z0-9_-]{1,32}$') {
        Write-Err 'Недопустимое имя: разрешены латинские буквы, цифры, дефис и подчёркивание, до 32 символов.'
        return
    }

    Write-Dim 'Профиль мимикрии: quic (по умолчанию), tls, dtls, sip, dns, noise'
    $profile = (Read-Host '  Профиль [quic]').Trim()
    if (-not $profile) { $profile = 'quic' }
    if ($profile -notin @('quic', 'tls', 'dtls', 'sip', 'dns', 'noise')) {
        Write-Err "Неизвестный профиль '$profile'."
        return
    }

    $intensity = (Read-Host '  Интенсивность low/medium/high [medium]').Trim()
    if (-not $intensity) { $intensity = 'medium' }
    if ($intensity -notin @('low', 'medium', 'high')) {
        Write-Err "Неизвестная интенсивность '$intensity'."
        return
    }

    # Адрес, который попадёт клиенту в Endpoint. По умолчанию — тот, по
    # которому подключились мы сами: раз он работает отсюда, скорее всего
    # заработает и у клиента. Но у сервера может быть отдельное DNS-имя,
    # поэтому даём заменить.
    Write-Host ''
    Write-Dim "Адрес в конфиге клиента (Endpoint). Сейчас подключение идёт по: $VpsHost"
    $endpoint = (Read-Host "  Имя хоста для клиента [$VpsHost]").Trim()
    if (-not $endpoint) { $endpoint = $VpsHost }
    if ($endpoint -notmatch '^[a-zA-Z0-9._-]+$') {
        Write-Err "Недопустимое имя хоста '$endpoint'."
        return
    }

    $outDir = Join-Path $ScriptDir $name
    if (Test-Path $outDir) {
        Write-Err "Папка '$outDir' уже существует — выберите другое имя или уберите её."
        return
    }

    Write-Host ''
    Invoke-Remote -CmdArgs @('add', $name, '-p', $profile, '-i', $intensity,
                             '--endpoint', $endpoint) | Out-Null
    if ($script:LastRc -ne 0) { Write-Err 'Ключ не создан.'; return }

    Write-Host ''
    if ((Invoke-Fetch -Name $name -OutDir $outDir) -eq 0) {
        Write-Ok "Файлы здесь: $outDir"
        Show-ClientLink -Name $name -OutDir $outDir
    } else {
        Write-Warn "Ключ на сервере создан, но файлы не скачались. Попробуйте пункт «Скачать ключ»."
        if (Test-Path $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Action-Download {
    $name = Select-Client 'Какой ключ скачать'
    if (-not $name) { return }

    $outDir = Join-Path $ScriptDir $name
    if (Test-Path $outDir) {
        if (-not (Confirm-Action "Папка '$name' уже есть. Перезаписать файлы в ней?")) { return }
    }
    Write-Host ''
    if ((Invoke-Fetch -Name $name -OutDir $outDir) -eq 0) {
        Write-Ok "Файлы здесь: $outDir"
        Show-ClientLink -Name $name -OutDir $outDir
        if (Confirm-Action 'Показать QR-код?') {
            $png = Join-Path $outDir "$name.png"
            if (Test-Path $png) { Start-Process $png }
        }
    }
}

function Action-Remove {
    $name = Select-Client 'Какой ключ удалить'
    if (-not $name) { return }

    Write-Host ''
    Write-Warn "Будет удалён ключ '$name': пир на сервере, конфиг, QR и ключи."
    Write-Dim  'Клиент потеряет доступ немедленно. Отменить это нельзя.'
    if (-not (Confirm-Action "Точно удалить '$name'?")) { Write-Dim 'Отменено.'; return }

    Write-Host ''
    Invoke-Remote -CmdArgs @('remove', $name, '-y') | Out-Null
    if ($script:LastRc -eq 0) {
        Write-Ok "'$name' удалён на сервере."
        $localDir = Join-Path $ScriptDir $name
        if (Test-Path $localDir) {
            if (Confirm-Action "Удалить и локальную папку '$localDir'?") {
                Remove-Item -LiteralPath $localDir -Recurse -Force -ErrorAction SilentlyContinue
                Write-Ok 'Локальная папка удалена.'
            }
        }
    }
}

function Action-Show {
    Write-Head 'Состояние сервера'
    Invoke-Remote -CmdArgs @('show') | Out-Null
}

function Action-Restart {
    Write-Head 'Перезапуск сервиса'
    Write-Warn 'Все текущие подключения оборвутся на несколько секунд.'
    if (-not (Confirm-Action 'Перезапустить awg-quick@awg0?')) { Write-Dim 'Отменено.'; return }
    Write-Host ''
    Invoke-Remote -CmdArgs @('restart') | Out-Null
}

function Action-Backup {
    Write-Head 'Резервная копия'
    Write-Dim 'Архив с конфигами и ключами останется на сервере в ~/awg/backups.'
    $keep = (Read-Host '  Сколько последних архивов оставить (Enter — ничего не удалять)').Trim()

    $cmdArgs = @('backup')
    if ($keep) {
        if ($keep -notmatch '^\d+$' -or [int]$keep -lt 1) {
            Write-Err 'Нужно целое число не меньше 1.'
            return
        }
        Write-Warn "Архивы старше $keep последних будут удалены на сервере."
        if (-not (Confirm-Action 'Продолжить?')) { return }
        $cmdArgs += @('--prune', $keep, '-y')
    }
    Write-Host ''
    Invoke-Remote -CmdArgs $cmdArgs | Out-Null
}

function Action-Gen {
    Write-Head 'Генератор параметров AWG 3.0'
    Write-Dim 'Просто показывает готовый набор — сервер и клиенты не меняются.'
    Write-Host ''
    Invoke-Remote -CmdArgs @('gen') | Out-Null
}

function Action-Migrate {
    Write-Head 'Раскладка файлов по каталогам'
    Invoke-Remote -CmdArgs @('migrate', '-y') | Out-Null
}

function Action-Endpoint {
    Write-Head 'Имя хоста для клиентов'

    # Текущее значение показываем из list: там оно уже разобрано и заодно
    # видно, откуда берётся адрес, если имя не задано.
    $out = Invoke-Remote -CmdArgs @('list') -Quiet
    $current = ($out | Select-String 'имя хоста для клиентов:').ToString()
    if ($current) { Write-Dim ($current.Trim()) }

    Write-Host ''
    Write-Dim 'Этот адрес попадёт в Endpoint новых конфигов. DNS-имя лучше IP:'
    Write-Dim 'при смене адреса сервера выданные конфиги продолжат работать.'
    Write-Host ''
    $name = (Read-Host '  Новое имя хоста (Enter — отмена)').Trim()
    if (-not $name) { Write-Dim 'Отменено.'; return }
    if ($name -notmatch '^[a-zA-Z0-9._-]+$') {
        Write-Err "Недопустимое имя хоста '$name'."
        return
    }

    Write-Host ''
    Invoke-Remote -CmdArgs @('set-endpoint', $name) | Out-Null
    if ($script:LastRc -eq 0) {
        Write-Ok 'Готово. Уже выданные конфиги продолжат работать по прежнему адресу.'
    }
}

function Action-ServerRekey {
    Write-Head 'Смена общих параметров сервера'
    Write-Warn 'ЭТО ОТКЛЮЧИТ ВСЕХ КЛИЕНТОВ РАЗОМ.'
    Write-Dim 'Сервер получит новые S1-S4, H1-H4 и HeaderProtectionKey. Старые конфиги'
    Write-Dim 'перестанут подключаться: каждого клиента придётся удалить и создать заново.'
    Write-Host ''
    $word = Read-Host '  Наберите СМЕНИТЬ заглавными, чтобы подтвердить'
    if ($word -cne 'СМЕНИТЬ') { Write-Dim 'Отменено.'; return }

    Write-Host ''
    Invoke-Remote -CmdArgs @('server-upgrade', '-y') | Out-Null
    if ($script:LastRc -eq 0) {
        Write-Warn 'Теперь пересоздайте клиентов и раздайте им новые конфиги.'
    }
}

# ── Вход ────────────────────────────────────────────────────────────────────

# Данные подключения спрашиваются по порядку: адрес, порт, пользователь и
# только потом пароль. Пароль последним не случайно — если ошиблись в адресе
# или порте, ошибку видно до того, как он набран.
function Read-Connection {
    Write-Host ''
    Write-Host '  Куда подключаемся' -ForegroundColor Cyan
    Write-Host ''

    # Пустой $DefaultHost — обычное дело: подставлять чужой адрес по умолчанию
    # незачем, поэтому при отсутствии подсказки просто требуем ввод.
    while ($true) {
        $prompt = if ($DefaultHost) { "  Имя хоста или IP [$DefaultHost]" } else { '  Имя хоста или IP' }
        $answer = (Read-Host $prompt).Trim()
        if ($answer) { $script:VpsHost = $answer; break }
        if ($DefaultHost) { $script:VpsHost = $DefaultHost; break }
        Write-Err 'Адрес сервера обязателен.'
    }

    while ($true) {
        $answer = (Read-Host "  Порт SSH [$DefaultPort]").Trim()
        if (-not $answer) { $script:VpsPort = $DefaultPort; break }
        if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le 65535) {
            $script:VpsPort = [int]$answer; break
        }
        Write-Err 'Порт должен быть числом от 1 до 65535.'
    }

    # Как и с адресом: без подсказки просто требуем ввод.
    while ($true) {
        $prompt = if ($DefaultUser) { "  Пользователь [$DefaultUser]" } else { '  Пользователь' }
        $answer = (Read-Host $prompt).Trim()
        if ($answer) { $script:VpsUser = $answer; break }
        if ($DefaultUser) { $script:VpsUser = $DefaultUser; break }
        Write-Err 'Имя пользователя обязательно.'
    }

    # Каталог данных лежит в домашнем каталоге пользователя — так его кладёт
    # install-awg3.sh. У root домашний каталог не в /home.
    $home_ = if ($script:VpsUser -eq 'root') { '/root' } else { "/home/$($script:VpsUser)" }
    $script:RemoteDir    = "$home_/awg"
    $script:RemoteScript = "$home_/awg/awg3.sh"
}

# Применяет профиль к переменным подключения.
function Use-Profile {
    param($Item)
    $script:VpsHost = $Item.host
    $script:VpsPort = [int]$Item.port
    $script:VpsUser = $Item.user
    $home_ = if ($Item.user -eq 'root') { '/root' } else { "/home/$($Item.user)" }
    $script:RemoteDir    = "$home_/awg"
    $script:RemoteScript = "$home_/awg/awg3.sh"
}

# Добавление сервера: один раз спрашиваем пароль, кладём ключ и настраиваем
# sudo — дальше вход без вопросов.
function New-ServerProfile {
    Write-Head 'Новый сервер'
    Read-Connection
    Use-Profile ([pscustomobject]@{ host = $VpsHost; port = $VpsPort; user = $VpsUser })

    if (-not (Ensure-PanelKey)) { return $false }

    $script:Password = Read-Password
    if (-not $script:Password) { Write-Err 'Пароль не введён.'; return $false }

    Write-Host ''
    Write-Host '  Настраиваю вход по ключу...' -ForegroundColor DarkGray
    Set-AuthMode $false

    $pub = (Get-Content "$KeyPath.pub" -Raw).Trim()
    $all = @($VpsHost, $VpsPort, $VpsUser, 'setup', $pub, $RemoteScript)
    $out = $script:Password | & $python $helperPath @all 2>&1
    $rc = $LASTEXITCODE

    if ($rc -eq 4) {
        foreach ($line in $out) { Write-Host "  $line" -ForegroundColor Yellow }
        return $false
    }
    if ($rc -ne 0) {
        foreach ($line in $out) { Write-Host "  $line" -ForegroundColor Red }
        Write-Err 'Не удалось настроить вход по ключу.'
        if ($rc -eq 2) { Write-Warn 'Проверьте пароль и имя пользователя.' }
        return $false
    }
    Write-Ok 'Ключ добавлен, sudo настроен.'

    # Пароль больше не нужен: дальше только ключ. Забываем его из памяти.
    $script:Password = ''
    Set-AuthMode $true

    Write-Host '  Проверяю вход по ключу...' -ForegroundColor DarkGray
    Invoke-Remote -CmdArgs @('names') -Quiet | Out-Null
    if ($script:LastRc -ne 0) {
        Write-Err 'Вход по ключу не заработал — профиль не сохранён.'
        return $false
    }

    $name = (Read-Host "  Название для этого сервера [$VpsHost]").Trim()
    if (-not $name) { $name = $VpsHost }

    $items = @(Get-Profiles | Where-Object { $_.name -ne $name })
    $items += [pscustomobject]@{
        name = $name; host = $VpsHost; port = $VpsPort; user = $VpsUser
    }
    Save-Profiles $items
    Write-Ok "Сервер '$name' сохранён. Дальше вход без вопросов."
    return $true
}

function Remove-ServerProfile {
    $items = @(Get-Profiles)
    if ($items.Count -eq 0) { Write-Warn 'Сохранённых серверов нет.'; return }

    Write-Head 'Удалить сервер из списка'
    for ($i = 0; $i -lt $items.Count; $i++) {
        Write-Host ("   {0,2}  {1}" -f ($i + 1), $items[$i].name)
    }
    Write-Host '    0  отмена' -ForegroundColor DarkGray
    $choice = Read-Host '  Номер'
    if ($choice -notmatch '^\d+$') { return }
    $idx = [int]$choice
    if ($idx -lt 1 -or $idx -gt $items.Count) { return }

    $victim = $items[$idx - 1]
    Write-Dim "Запись удаляется только здесь: ключ на сервере останется в"
    Write-Dim "~/.ssh/authorized_keys, уберите его там, если он больше не нужен."
    if (-not (Confirm-Action "Удалить '$($victim.name)' из списка?")) { return }

    Save-Profiles @($items | Where-Object { $_.name -ne $victim.name })
    Write-Ok "'$($victim.name)' удалён из списка."
}

# Стартовый выбор: сохранённые серверы плюс действия над списком.
function Select-Server {
    while ($true) {
        $items = @(Get-Profiles)

        Write-Host ''
        Write-Host '  Куда подключаемся' -ForegroundColor Cyan
        Write-Host ''
        if ($items.Count -gt 0) {
            for ($i = 0; $i -lt $items.Count; $i++) {
                Write-Host ("   {0,2}  {1}" -f ($i + 1), $items[$i].name) -NoNewline
                Write-Host ("   {0}@{1}:{2}" -f $items[$i].user, $items[$i].host, $items[$i].port) -ForegroundColor DarkGray
            }
            Write-Host ''
        } else {
            Write-Dim 'Сохранённых серверов пока нет.'
            Write-Host ''
        }
        Write-Host '    N  добавить новый' -ForegroundColor DarkCyan
        if ($items.Count -gt 0) { Write-Host '    D  удалить из списка' -ForegroundColor DarkCyan }
        Write-Host '    Q  выход' -ForegroundColor DarkGray
        Write-Host ''

        $choice = (Read-Host '  Выберите').Trim()

        switch -Regex ($choice) {
            '^[Qq]$' { return $false }
            '^[Nn]$' { if (New-ServerProfile) { return $true } }
            '^[Dd]$' { Remove-ServerProfile }
            '^\d+$'  {
                $idx = [int]$choice
                if ($idx -ge 1 -and $idx -le $items.Count) {
                    Use-Profile $items[$idx - 1]
                    $script:Password = ''
                    Set-AuthMode $true
                    return $true
                }
                Write-Err 'Нет такого номера.'
            }
            default { Write-Err 'Не понял. Введите номер, N, D или Q.' }
        }
    }
}

function Read-Password {
    Write-Host ''
    Write-Host "  Сервер: $VpsUser@$VpsHost`:$VpsPort" -ForegroundColor DarkGray
    $secure = Read-Host "  Пароль администратора ($VpsUser)" -AsSecureString

    # Enter на пустом поле или Ctrl+C: Read-Host отдаёт $null либо пустой
    # SecureString, а ConvertFrom-SecureString на таком падает руганью
    # «value of argument "SecureString" is not valid» поверх уже закрытой
    # панели. Пустой ввод — это отказ от пароля, а не сбой.
    if ($null -eq $secure -or $secure.Length -eq 0) { return '' }

    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $plain = ConvertFrom-SecureString $secure -AsPlainText
    } else {
        # Windows PowerShell 5.1: у ConvertFrom-SecureString нет -AsPlainText.
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try   { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    return $plain
}

function Show-Banner {
    Clear-Host
    Write-Host ''
    Write-Host '   ╔══════════════════════════════════════════════╗' -ForegroundColor Cyan
    Write-Host '   ║        AmneziaWG — панель управления         ║' -ForegroundColor Cyan
    Write-Host '   ╚══════════════════════════════════════════════╝' -ForegroundColor Cyan
    if ($VpsHost) { Write-Host "        $VpsUser@$VpsHost`:$VpsPort" -ForegroundColor DarkGray }
}

function Show-Menu {
    Write-Host ''
    Write-Host '   КЛЮЧИ' -ForegroundColor DarkCyan
    Write-Host '    1  Список клиентов'
    Write-Host '    2  Трафик и активность'
    Write-Host '    3  Создать ключ'
    Write-Host '    4  Скачать ключ (conf + QR + ссылка vpn://)'
    Write-Host '    5  Удалить ключ'
    Write-Host ''
    Write-Host '   СЕРВЕР' -ForegroundColor DarkCyan
    Write-Host '    6  Состояние (awg show)'
    Write-Host '    7  Перезапустить сервис'
    Write-Host '    8  Резервная копия'
    Write-Host '    9  Имя хоста для клиентов'
    Write-Host ''
    Write-Host '   ПРОЧЕЕ' -ForegroundColor DarkCyan
    Write-Host '    G  Показать набор параметров обфускации'
    Write-Host '    M  Разложить файлы по каталогам'
    Write-Host '    S  Сменить общие параметры сервера' -ForegroundColor DarkYellow
    Write-Host ''
    Write-Host '    Q  Выход' -ForegroundColor DarkGray
    Write-Host ''
}

try {
    Show-Banner
    if (-not (Select-Server)) { exit 0 }
    Show-Banner

    Write-Host ''
    Write-Host '  Проверяю доступ...' -ForegroundColor DarkGray
    $probe = Invoke-Remote -CmdArgs @('names') -Quiet

    # Смена отпечатка — не сбой входа, а предупреждение о возможной подмене
    # сервера. Предлагаем забыть старый ключ, но подтверждение строгое:
    # ответ «yes» целиком, как и при отключении root в bootstrap.sh. Беглое
    # «y» здесь означало бы отдать пароль тому, кто выдаёт себя за сервер.
    if ($script:LastRc -eq 4) {
        Write-Host ''
        foreach ($line in $probe) { Write-Host "  $line" -ForegroundColor Yellow }
        Write-Host ''
        Write-Warn 'Соглашайтесь ТОЛЬКО если сервер переустанавливали вы сами.'
        $answer = Read-Host '  Забыть прежний отпечаток и подключиться? Введите yes целиком'
        if ($answer -ne 'yes') {
            Write-Err 'Отменено. Прежний отпечаток сохранён.'
            exit 4
        }
        if (Remove-KnownHost -ServerHost $VpsHost -ServerPort $VpsPort) {
            Write-Ok 'Прежний отпечаток удалён, подключаюсь заново...'
        } else {
            Write-Warn "Запись не найдена в $KnownHostsPath — возможно, файл правили вручную."
        }
        $probe = Invoke-Remote -CmdArgs @('names') -Quiet
    }

    if ($script:LastRc -ne 0) {
        Write-Host ''
        foreach ($line in $probe) { Write-Host "  $line" -ForegroundColor Red }
        Write-Err 'Вход не удался.'
        # На сервере включён fail2ban: несколько неверных попыток подряд
        # заблокируют этот IP, и сервер просто перестанет отвечать.
        if ($script:LastRc -eq 2) {
            Write-Warn 'Проверьте пароль. Несколько неверных попыток подряд — и fail2ban'
            Write-Warn 'заблокирует ваш IP примерно на 10 минут.'
        }
        exit 1
    }
    Write-Ok ("Подключение есть. Клиентов на сервере: {0}" -f @($probe | Where-Object { "$_".Trim() }).Count)

    while ($true) {
        Show-Menu
        $choice = (Read-Host '  Выберите пункт').Trim()

        switch -Regex ($choice) {
            '^1$'    { Action-List;        Pause-Panel }
            '^2$'    { Action-Stats;       Pause-Panel }
            '^3$'    { Action-Add;         Pause-Panel }
            '^4$'    { Action-Download;    Pause-Panel }
            '^5$'    { Action-Remove;      Pause-Panel }
            '^6$'    { Action-Show;        Pause-Panel }
            '^7$'    { Action-Restart;     Pause-Panel }
            '^8$'    { Action-Backup;      Pause-Panel }
            '^9$'    { Action-Endpoint;    Pause-Panel }
            '^[gG]$' { Action-Gen;         Pause-Panel }
            '^[mM]$' { Action-Migrate;     Pause-Panel }
            '^[sS]$' { Action-ServerRekey; Pause-Panel }
            '^[qQ]$' { return }
            default  { Write-Warn 'Нет такого пункта.'; Start-Sleep -Milliseconds 700 }
        }
        Show-Banner
    }
}
finally {
    # Ни пароль, ни помощник не должны пережить выход из панели.
    Remove-Item -LiteralPath $helperPath -Force -ErrorAction SilentlyContinue
    $script:Password = $null
    [System.GC]::Collect()
    Write-Host ''
    Write-Host '  Панель закрыта, пароль из памяти убран.' -ForegroundColor DarkGray
}




