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

password = sys.stdin.readline().rstrip("\n")
host, port, user, mode = sys.argv[1:5]
rest = sys.argv[5:]

def fail(msg, code=1):
    sys.stderr.write(msg + "\n")
    sys.exit(code)

client = paramiko.SSHClient()
client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
try:
    client.connect(host, port=int(port), username=user, password=password,
                   timeout=30, look_for_keys=False, allow_agent=False)
except paramiko.AuthenticationException:
    fail("Неверный пароль или логин.", 2)
except Exception as exc:
    fail("Не удалось подключиться: %s" % exc, 3)

def run(cmd):
    stdin, stdout, stderr = client.exec_command(cmd, timeout=300)
    stdin.write(password + "\n")
    stdin.flush()
    out = stdout.read()
    err = stderr.read()
    return stdout.channel.recv_exit_status(), out, err

if mode == "run":
    # rest — уже разобранные аргументы awg3.sh; quote защищает от пробелов
    # и спецсимволов в именах.
    remote_script, args = rest[0], rest[1:]
    cmd = "sudo -S -p '' %s %s" % (remote_script, " ".join(shlex.quote(a) for a in args))
    rc, out, err = run(cmd)
    sys.stdout.write((out + err).decode("utf-8", "replace"))
    client.close()
    sys.exit(rc)

elif mode == "fetch":
    remote_dir, name, outdir = rest[0], rest[1], rest[2]
    os.makedirs(outdir, exist_ok=True)
    got = []
    for suffix in (".conf", ".png"):
        remote = "%s/%s/%s%s" % (remote_dir, name, name, suffix)
        rc, out, err = run("sudo -S -p '' cat %s | base64 -w0" % shlex.quote(remote))
        if rc != 0 or not out.strip():
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
    param([string] $Name, [string] $OutDir)

    $all = @($VpsHost, $VpsPort, $VpsUser, 'fetch', $RemoteDir, $Name, $OutDir)
    $out = $script:Password | & $python $helperPath @all 2>&1
    $script:LastRc = $LASTEXITCODE
    foreach ($line in $out) { Write-Host "  $line" }
    return $script:LastRc
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

function Read-Password {
    Write-Host ''
    Write-Host "  Сервер: $VpsUser@$VpsHost`:$VpsPort" -ForegroundColor DarkGray
    $secure = Read-Host "  Пароль администратора ($VpsUser)" -AsSecureString

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
    Write-Host '    4  Скачать ключ (conf + QR)'
    Write-Host '    5  Удалить ключ'
    Write-Host ''
    Write-Host '   СЕРВЕР' -ForegroundColor DarkCyan
    Write-Host '    6  Состояние (awg show)'
    Write-Host '    7  Перезапустить сервис'
    Write-Host '    8  Резервная копия'
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
    Read-Connection
    $script:Password = Read-Password
    if (-not $script:Password) { Write-Err 'Пароль не введён.'; exit 1 }

    Write-Host ''
    Write-Host '  Проверяю доступ...' -ForegroundColor DarkGray
    $probe = Invoke-Remote -CmdArgs @('names') -Quiet
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




