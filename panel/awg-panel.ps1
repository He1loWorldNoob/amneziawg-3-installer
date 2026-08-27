# awg-panel.ps1 — интерактивная панель управления AmneziaWG на VPS.
#
# Повторяет весь набор команд ~/awg/awg3.sh, но с локальной машины и с меню:
# список, статистика, создание и удаление ключей, скачивание conf+QR и ссылки
# vpn://, бэкап, перезапуск сервиса, генератор параметров.
#
# Работает на одном лишь ssh.exe из состава Windows — ни Python, ни сторонних
# библиотек не нужно. Всё общение с сервером идёт командами вида
# `ssh -F конфиг awg <команда>`, а разбор ответа остаётся здесь.
#
# Пароль панель не спрашивает и нигде не держит: он нужен только при
# добавлении сервера, и спрашивает его сам ssh — с клавиатуры, минуя
# PowerShell. Дальше вход идёт по ключу, и пароль не нужен вовсе.
#
# Каждое действие — отдельное SSH-подключение: панель не держит открытую
# сессию, поэтому забытое окно не оставляет висящего доступа к серверу.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Сервер отвечает в UTF-8, а ssh отдаёт его ответ байтами как есть. PowerShell
# декодирует вывод внешних программ по кодировке консоли, а она в русской
# Windows по умолчанию cp866 — без этого кириллица от awg3.sh превращается в
# мусор.
#
# ВАЖНО: именно UTF8Encoding с $false, а не [Text.Encoding]::UTF8. Последний
# включает BOM, и PowerShell дописывает три байта EF BB BF в начало всего, что
# уходит внешней программе.
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
try { [Console]::OutputEncoding = $utf8NoBom } catch { }
# InputEncoding не трогаем: пароль набирается в самом ssh, а он читает
# клавиатуру через консольный API — подмена кодировки ввода ему только мешает.
$OutputEncoding = $utf8NoBom

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
$HomeDir      = ''

# Интерфейс, с которым работает панель. Их на сервере может быть несколько, и
# они независимы: свой порт, своя подсеть, свои клиенты. awg0 — тот, что
# создаёт установщик; остальные заводятся вручную через awg3.sh server-init
# --iface. Пункт «Интерфейсы» переключает панель между ними.
$Iface = 'awg0'

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


# ── Каталоги ────────────────────────────────────────────────────────────────
#
# Состояние панели живёт в одном каталоге: отпечатки серверов, список профилей,
# ключ для входа и конфиг ssh. Пароль не хранится нигде — вместо него панель
# заводит SSH-ключ при добавлении сервера.

$PanelDir       = Join-Path $HOME '.awg-panel'
$KnownHostsPath = Join-Path $PanelDir 'known_hosts'
$ProfilesPath   = Join-Path $PanelDir 'servers.json'
$KeyPath        = Join-Path $PanelDir 'id_ed25519'
$SshConfigPath  = Join-Path $PanelDir 'ssh_config'

# Имя сервера внутри нашего конфига. Настоящие адрес, порт и логин лежат там
# же, поэтому в командную строку ssh они не попадают вовсе.
$SshAlias = 'awg-panel-target'

# ── Окружение ───────────────────────────────────────────────────────────────

# Запуск внешней программы. Отдаёт её вывод (stdout и stderr вперемешку, как
# их видит пользователь), код возврата — в $LASTEXITCODE.
#
# Присваивание $ErrorActionPreference здесь ЛОКАЛЬНОЕ и потому обязательное.
# При 'Stop' PowerShell считает каждую строку, которую программа пишет в
# stderr, терминирующей ошибкой — но только если stderr перенаправлен
# (2>&1, 2>$null). А ssh пишет туда в самой обычной работе: и приглашение
# ввести пароль, и предупреждение о новом отпечатке, и сообщение об отказе.
# Без этой строки панель падала бы с NativeCommandError вместо того, чтобы
# показать человеку, что ответил сервер.
#
# Внутри функции значение живёт только до возврата и восстанавливается само —
# ни try/finally, ни ручного отката не нужно. Об успехе судим по коду
# возврата, единственному надёжному признаку для внешних программ; заодно это
# снимает $PSNativeCommandUseErrorActionPreference из PowerShell 7.3+, где
# ненулевой код бросает исключение и вовсе без перенаправления.
#
# 'SilentlyContinue', а не 'Continue': программа может и вовсе не запуститься
# (файла нет, нет прав), и тогда PowerShell пишет об этом своей ошибкой поверх
# нашего сообщения. Текст самой программы при этом не теряется — его забирает
# перенаправление 2>&1 в вывод, который возвращает функция.
#
# Interactive — для случая, когда ssh сам разговаривает с человеком: вывод
# тогда не перехватываем вовсе, иначе приглашение ввести пароль осталось бы в
# переменной, а человек смотрел бы на пустой экран.
function Invoke-Native {
    param([string] $Exe, [string[]] $ExeArgs, [switch] $Interactive)

    $ErrorActionPreference = 'SilentlyContinue'
    # Если программа не запустилась, кода возврата не будет вовсе и в
    # $LASTEXITCODE остался бы ответ прошлого вызова — возможно, нулевой.
    # Ставим заранее 127: общепринятое «команду выполнить не удалось».
    $global:LASTEXITCODE = 127

    if ($Interactive) {
        # Start-Process, а не обычный вызов: он отдаёт программе саму консоль и
        # не заводит канал между ней и PowerShell. Через канал приглашение
        # «введите пароль» не доходит вовсе: оно приходит строкой без перевода в
        # конце, а PowerShell отдаёт вывод на экран построчно и держит такую
        # строку у себя. Человек смотрит на пустой экран, а ssh ждёт ответа —
        # и оба ждут друг друга до конца времён. Заодно из канала не выбраться
        # и возвращаемому значению: вывод программы стал бы им, а не кодом.
        #
        # Аргументы собираем в строку сами: -ArgumentList склеивает массив через
        # пробел и ничего не заключает в кавычки, так что путь с пробелом
        # разъехался бы на два аргумента. Кавычки двойные — их командная строка
        # Windows как раз понимает, а внутри наших аргументов их нет ни одной
        # (см. Quote-Sh).
        $line = ($ExeArgs | ForEach-Object { '"' + $_ + '"' }) -join ' '
        $proc = Start-Process -FilePath $Exe -ArgumentList $line -NoNewWindow -Wait -PassThru
        if ($proc) { $global:LASTEXITCODE = $proc.ExitCode }
        return
    }
    return & $Exe @ExeArgs 2>&1
}

# Панели нужен только ssh — он входит в Windows 10 и 11 как «Клиент OpenSSH»
# и в свежих сборках стоит из коробки.
$ssh = (Get-Command ssh -ErrorAction SilentlyContinue).Source
if (-not $ssh) {
    Write-Err 'Не найден ssh.'
    Write-Dim 'Установите «Клиент OpenSSH»: Параметры → Приложения →'
    Write-Dim 'Дополнительные компоненты → Добавить компонент.'
    exit 1
}

# ── Вызовы сервера ──────────────────────────────────────────────────────────

# Одинарные кавычки для оболочки на сервере. Через неё проходит всё, что туда
# уезжает: имена клиентов панель проверяет регулярками, но пути и ключи берутся
# из настроек, и защита от пробела в них должна быть общей.
#
# Двойных кавычек в удалённой команде нет ни одной, и это правило: Windows
# PowerShell 5.1 портит их при передаче внешней программе, и строка доезжает до
# ssh разорванной. Одинарные он не трогает.
function Quote-Sh {
    param([string] $Value)
    return "'" + $Value.Replace("'", "'\''") + "'"
}

# Конфиг ssh панель пишет сама и передаёт его через -F. Так у команды остаётся
# один короткий аргумент вместо десятка -o, а путь с пробелом (скажем,
# C:\Users\Иван Петров\.awg-panel) можно взять в кавычки: внутри файла их
# разбирает сам ssh, и порча кавычек в командной строке Windows нам уже не
# грозит.
#
# -F заодно отсекает ~/.ssh/config пользователя: панель должна ходить на сервер
# одинаково у всех, а не так, как человек однажды настроил себе что-то другое.
function Write-SshConfig {
    New-Item -ItemType Directory -Force -Path $PanelDir | Out-Null

    # HashKnownHosts no: пункт «забыть отпечаток» ищет строку по имени хоста,
    # а хешированную запись так не найти.
    # IdentitiesOnly yes: иначе ssh-agent успеет предложить свои ключи и
    # исчерпать лимит попыток раньше, чем дойдёт до нашего.
    $lines = @(
        '# Файл создаётся панелью заново при каждом подключении — править смысла нет.',
        "Host $SshAlias",
        "    HostName $VpsHost",
        "    Port $VpsPort",
        "    User $VpsUser",
        "    IdentityFile `"$KeyPath`"",
        "    UserKnownHostsFile `"$KnownHostsPath`"",
        '    IdentitiesOnly yes',
        '    HashKnownHosts no',
        '    ConnectTimeout 15',
        '    ServerAliveInterval 30',
        '    ServerAliveCountMax 3'
    )

    # WriteAllLines, а не Set-Content: у последнего в PowerShell 5.1 кодировка
    # utf8 означает «с BOM», а три лишних байта перед первой строкой ssh считает
    # неизвестной директивой и отказывается читать файл целиком.
    [System.IO.File]::WriteAllLines($SshConfigPath, $lines, $utf8NoBom)
}

# Базовый вызов. Возвращает строки вывода, код — в $script:LastRc.
#
# -n закрывает ssh ввод с клавиатуры: команда неинтерактивная и подвиснуть в
# ожидании ввода, которого никто не сделает, она не должна. BatchMode=yes — та
# же мысль про пароль: ключ либо принят, либо честная ошибка, а не приглашение
# к вводу в перехваченный поток, которого человек даже не увидит.
function Invoke-Ssh {
    param([string] $Command)

    $out = Invoke-Native $ssh @(
        '-F', $SshConfigPath,
        '-n',
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=yes',
        $SshAlias, $Command
    )
    $script:LastRc = $LASTEXITCODE
    return $out
}

# Отличает подмену отпечатка от обычного отказа: ssh в этом случае печатает
# заметный блок с этой строкой и не пробует подключиться дальше.
function Test-HostKeyChanged {
    param($Out)
    return [bool]($Out | Select-String -SimpleMatch -Quiet 'REMOTE HOST IDENTIFICATION HAS CHANGED')
}

# Переключает панель на интерфейс сервера. Каталог клиентов вычисляется по тем
# же правилам, что и в awg3.sh: awg0 живёт в ~/awg, остальные — в соседнем
# каталоге по имени интерфейса (~/awg1). Разъехаться эти два знания не должны,
# иначе панель скачивала бы файлы не того интерфейса, что показывает в списке.
function Set-Iface {
    param([string] $Name)
    $script:Iface = $Name
    $script:RemoteDir = if ($Name -eq 'awg0') { "$($script:HomeDir)/awg" }
                        else { "$($script:HomeDir)/$Name" }
}

# Выполняет awg3.sh с аргументами. Возвращает строки вывода, код — в
# $script:LastRc.
function Invoke-Remote {
    # Не $Args: так называется автоматическая переменная PowerShell.
    param([string[]] $CmdArgs, [switch] $Quiet)

    # sudo -n, а не -S: правило NOPASSWD выдано именно на awg3.sh, и если оно
    # почему-то не сработало, пусть будет честное «требуется пароль» вместо
    # молчаливого ожидания ввода, которого некому сделать.
    $remote = 'sudo -n ' + (Quote-Sh $RemoteScript)
    # --iface добавляется ТОЛЬКО для неосновного интерфейса. На сервере со
    # старым awg3.sh этого флага нет, и он принял бы его за имя команды; пока
    # панель работает с awg0, она остаётся совместимой с такими серверами.
    if ($script:Iface -and $script:Iface -ne 'awg0') {
        $remote += ' ' + (Quote-Sh '--iface') + ' ' + (Quote-Sh $script:Iface)
    }
    foreach ($arg in $CmdArgs) { $remote += ' ' + (Quote-Sh $arg) }

    $out = Invoke-Ssh $remote
    if (-not $Quiet) {
        foreach ($line in $out) { Write-Host "  $line" }
    }
    return $out
}

# Скачивание conf, QR и ссылки vpn://. Файлы приезжают строками base64 — так
# они идут по тому же текстовому каналу, что и остальной вывод, и не зависят от
# того, как ssh и PowerShell обойдутся с сырыми байтами и переводами строк.
#
# ВСЕ файлы забираются ОДНИМ подключением, и это не оптимизация. Установщик
# ставит на порт SSH `ufw limit`: шестое подключение с одного адреса за 30
# секунд молча уходит в DROP. Создание ключа — это уже add, затем скачивание, а
# следом бывает и link; по подключению на файл упиралось в лимит, и хвост
# набора пропадал с таймаутом вместо ошибки.
#
# Обязателен только конфиг: QR может не собраться без qrencode, а ссылки не
# будет у клиентов, созданных прежними версиями awg3.sh — про этих двоих молчим,
# иначе каждое скачивание сыпало бы руганью на пустом месте.
#
# Возвращает 0, если конфиг скачался.
function Invoke-Fetch {
    param([string] $Name, [string] $OutDir, [switch] $Quiet)

    $suffixes = @('.conf', '.png', '.vpnuri')

    # Каждый файл предваряется маркером — по нему ответ и разбирается. Сначала
    # cat без sudo: каталог клиентов принадлежит самому пользователю, а правило
    # NOPASSWD выдано только на awg3.sh, и sudo cat под ключом не пройдёт. На
    # sudo откатываемся ради root-установок, где данные лежат в /root/awg. Оба
    # потока ошибок глушим: их текст смешался бы с base64 и испортил его.
    $remote = ''
    foreach ($suffix in $suffixes) {
        $quoted = Quote-Sh "$RemoteDir/$Name/$Name$suffix"
        $marker = Quote-Sh ('@@' + $suffix + '@@')
        $remote += "printf '%s\n' $marker; " +
                   "{ cat $quoted 2>/dev/null || sudo -n cat $quoted 2>/dev/null; } | base64 -w0; " +
                   "printf '\n'; "
    }

    $out = Invoke-Ssh $remote
    if ($script:LastRc -ne 0) {
        Write-Err 'Файлы не скачались: сервер не ответил.'
        Write-Dim 'На порт SSH стоит ufw limit — после нескольких подключений подряд'
        Write-Dim 'он на полминуты перестаёт отвечать. Подождите и повторите.'
        return 1
    }

    # Разбор по маркерам: строка после маркера — либо base64, либо пусто, если
    # файла на сервере нет.
    $blocks = @{}
    $current = ''
    foreach ($line in @($out)) {
        $text = "$line".Trim()
        if ($text -match '^@@(\.[a-z]+)@@$') { $current = $Matches[1]; $blocks[$current] = ''; continue }
        if ($current -and $text) { $blocks[$current] += $text }
    }

    $got = @()
    foreach ($suffix in $suffixes) {
        $b64 = "$($blocks[$suffix])"
        # Проверяем алфавит base64, а не просто непустоту: любой посторонний
        # текст в ответе (баннер входа, предупреждение) иначе дошёл бы до
        # раскодировщика и уронил панель исключением.
        if ($b64 -notmatch '^[A-Za-z0-9+/=]+$') {
            if ($suffix -eq '.conf') { Write-Dim "нет файла: $RemoteDir/$Name/$Name$suffix" }
            continue
        }

        New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
        $local = Join-Path $OutDir ($Name + $suffix)
        [System.IO.File]::WriteAllBytes($local, [Convert]::FromBase64String($b64))
        if (-not $Quiet) { Write-Host "  СКАЧАНО: $local" }
        $got += $local
    }

    if (-not (@($got) | Where-Object { $_.EndsWith('.conf') })) {
        Write-Err 'Конфиг не скачался.'
        return 1
    }
    return 0
}

# Путь к скачанной ссылке vpn:// или $null.
#
# У клиентов, созданных прежними версиями awg3.sh, файла со ссылкой на сервере
# нет. Просим собрать его по готовому конфигу и забираем: ключи и пир при этом
# не трогаются, ссылка целиком производна от конфига. На сервере со старым
# скриптом команда не найдётся — тогда остаёмся с конфигом и QR, это не ошибка.
#
# Сборка и выдача — одной командой в одном подключении: лишнее подключение
# приближает `ufw limit` на сервере, а с ним и молчаливые таймауты.
function Get-ClientLink {
    param([string] $Name, [string] $OutDir)

    $link = Join-Path $OutDir "$Name.vpnuri"
    if (Test-Path $link) { return $link }

    $script_ = Quote-Sh $RemoteScript
    $quoted  = Quote-Sh "$RemoteDir/$Name/$Name.vpnuri"
    $quotedName = Quote-Sh $Name
    $out = Invoke-Ssh "sudo -n $script_ link $quotedName >/dev/null 2>&1; " +
                      "{ cat $quoted 2>/dev/null || sudo -n cat $quoted 2>/dev/null; } | base64 -w0"
    if ($script:LastRc -ne 0) { return $null }

    $b64 = (@($out | ForEach-Object { "$_".Trim() }) -join '')
    if ($b64 -notmatch '^[A-Za-z0-9+/=]+$') { return $null }

    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    [System.IO.File]::WriteAllBytes($link, [Convert]::FromBase64String($b64))
    return $link
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

# Разовая настройка сервера: открытая половина ключа уходит в authorized_keys, а
# sudo получает право запускать без пароля ТОЛЬКО awg3.sh. Узко намеренно:
# полный NOPASSWD: ALL отдал бы всю машину тому, кто украдёт ключ, тогда как
# здесь потеря ограничена управлением VPN.
#
# Единственное место, где нужен пароль, — и спрашивает его сам ssh. Поэтому
# вывод не перехватываем: приглашения и предупреждение о новом отпечатке должны
# дойти до человека как есть. -t даёт удалённой стороне терминал, без него sudo
# не сможет спросить пароль, а PubkeyAuthentication=no не даёт ssh тратить
# попытки на ключ, которого на сервере ещё нет.
function Invoke-Setup {
    param([string] $PubKey)

    # Имя файла в sudoers.d не может содержать точку — иначе он игнорируется.
    #
    # Правило сначала пишется во временный файл и проверяется visudo, и лишь
    # затем встаёт на место. Обратный порядок — запись в /etc/sudoers.d с
    # проверкой после — при любой ошибке оставил бы битый файл, а битый файл в
    # sudoers.d ломает sudo целиком: чинить было бы уже нечем.
    #
    # Путь временного файла уходит внутрь sudo аргументом ($1), а не подстановкой
    # в текст правила: подставлять пришлось бы в двойных кавычках, а их в этой
    # команде нет ни одной (см. Quote-Sh). Само правило пробелы содержит, но оно
    # уже завёрнуто в одинарные кавычки здесь, на нашей стороне.
    $pub   = Quote-Sh $PubKey
    $rule  = Quote-Sh ('{0} ALL=(root) NOPASSWD: {1}' -f $VpsUser, $RemoteScript)
    $inner = Quote-Sh 'visudo -cf $1 >/dev/null && install -m 440 -o root -g root $1 /etc/sudoers.d/awg3-panel'
    $keys  = '$HOME/.ssh/authorized_keys'

    $remote = @(
        'umask 077',
        'install -d -m 700 $HOME/.ssh',
        "touch $keys",
        "chmod 600 $keys",
        "{ grep -qxF $pub $keys || printf '%s\n' $pub >> $keys; }",
        't=$(mktemp)',
        # trap, а не rm в конце: на приглашении sudo человек может передумать и
        # нажать Ctrl+C, и тогда оболочка на сервере умрёт, не дойдя до уборки.
        # Ловим и обрыв связи (HUP), и Ctrl+C (INT), и обычный выход.
        "trap 'rm -f `$t' EXIT HUP INT TERM",
        "printf '%s\n' $rule > `$t",
        "sudo sh -c $inner _ `$t"
    ) -join ' && '

    Invoke-Native $ssh @(
        '-F', $SshConfigPath,
        '-t',
        '-o', 'PubkeyAuthentication=no',
        '-o', 'StrictHostKeyChecking=ask',
        $SshAlias, $remote
    ) -Interactive
    return $LASTEXITCODE
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
# Запуск ssh-keygen со строкой аргументов целиком.
#
# Пустой аргумент — а «-N ""» означает «ключ без парольной фразы» — Windows
# PowerShell 5.1 по дороге ВЫБРАСЫВАЕТ: ssh-keygen получает «-N -C», считает
# комментарий парольной фразой, упирается в лишний аргумент и падает с «Too
# many arguments», не создав ключа. Под pwsh 7 тот же код работает, поэтому
# поломка видна только на машинах со встроенной PowerShell — то есть у всех,
# кто не ставил семёрку.
#
# Start-Process принимает аргументы одной строкой и ничего из неё не
# выбрасывает. Вывод отправляем в файл: -y печатает открытый ключ в stdout, и
# без перенаправления он высыпался бы в меню панели.
function Invoke-Keygen {
    param([string] $Exe, [string] $ArgLine)

    $log = Join-Path ([System.IO.Path]::GetTempPath()) ("awg-keygen-{0}.log" -f [guid]::NewGuid())
    try {
        $proc = Start-Process -FilePath $Exe -ArgumentList $ArgLine -NoNewWindow -Wait -PassThru `
                              -RedirectStandardOutput $log -RedirectStandardError "$log.err"
        if ($proc) { return $proc.ExitCode }
        return 127
    } catch {
        return 127
    } finally {
        Remove-Item $log, "$log.err" -Force -ErrorAction SilentlyContinue
    }
}

function Ensure-PanelKey {
    $ErrorActionPreference = 'Continue'

    $keygen = (Get-Command ssh-keygen -ErrorAction SilentlyContinue).Source
    if (-not $keygen) {
        Write-Err 'Не найден ssh-keygen. Установите OpenSSH Client в компонентах Windows.'
        return $false
    }

    if (Test-Path $KeyPath) { return $true }

    New-Item -ItemType Directory -Force -Path $PanelDir | Out-Null
    # Кавычки вокруг путей: каталог панели лежит в домашнем, а он бывает и
    # «C:\Users\Иван Петров». Комментарий с именем машины служит меткой при
    # повторной настройке — заменяем запись именно этого компьютера, не трогая
    # ключи других, с которых вы тоже могли подключаться.
    $rc = Invoke-Keygen $keygen ('-q -t ed25519 -f "{0}" -N "" -C "awg-panel@{1}"' -f $KeyPath, $env:COMPUTERNAME)

    if ($rc -ne 0 -or -not (Test-Path $KeyPath)) {
        Write-Err 'Не удалось создать ключ.'
        Write-Dim "Создайте вручную: ssh-keygen -t ed25519 -f `"$KeyPath`" -N `"`""
        return $false
    }

    # Проверяем, что ключ действительно без фразы: иначе автовход молча не
    # заработает, а ошибка будет выглядеть как неверный пароль.
    if ((Invoke-Keygen $keygen ('-y -P "" -f "{0}"' -f $KeyPath)) -ne 0) {
        Remove-Item $KeyPath, "$KeyPath.pub" -Force -ErrorAction SilentlyContinue
        Write-Err 'Ключ создался с парольной фразой — так автовход не заработает.'
        Write-Dim "Создайте вручную: ssh-keygen -t ed25519 -f `"$KeyPath`" -N `"`""
        return $false
    }

    Write-Ok "Ключ панели создан: $KeyPath"
    return $true
}

# Убирает запись о сервере, чтобы следующий вход запомнил новый отпечаток.
# ssh пишет "host" для порта 22 и "[host]:port" для остальных; хеширование
# имён отключено в нашем конфиге, иначе искать было бы нечего.
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

# ── Интерфейсы ──────────────────────────────────────────────────────────────
#
# Разбор вывода `awg3.sh ifaces`: колонки разделены табуляцией именно ради
# этого места. Возвращает массив массивов ячеек или пустой массив.
function Get-Ifaces {
    $out = Invoke-Remote -CmdArgs @('ifaces') -Quiet
    if ($script:LastRc -ne 0) {
        foreach ($line in $out) { Write-Host "  $line" }
        Write-Err 'Список интерфейсов не получен.'
        Write-Dim 'Похоже, на сервере awg3.sh без команды ifaces — обновите его.'
        return @()
    }

    $rows = @()
    foreach ($line in @($out)) {
        $text = "$line"
        if ($text -notmatch "`t") { continue }
        $cells = $text -split "`t"
        if ($cells[0] -eq 'ИНТЕРФЕЙС') { continue }
        if ($cells.Count -lt 6) { continue }
        $rows += , $cells
    }
    return $rows
}

function Action-Ifaces {
    Write-Head 'Интерфейсы сервера'

    $rows = @(Get-Ifaces)
    if ($rows.Count -eq 0) { return }

    Write-Host ''
    Write-Host ('   {0,2}  {1,-8} {2,-6} {3,-18} {4,-22} {5,-8} {6}' -f `
        '', 'ИМЯ', 'ПОРТ', 'ПОДСЕТЬ', 'ВЕРСИЯ', 'КЛИЕНТОВ', 'СЕРВИС') -ForegroundColor DarkCyan
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $r = $rows[$i]
        # Версию считает сам awg3.sh: интерфейс без RandomTrailers создан до
        # 3.1, и в этой колонке приезжает не число, а «нужен server-rekey».
        $line = ('   {0,2}  {1,-8} {2,-6} {3,-18} {4,-22} {5,-8} {6}' -f `
            ($i + 1), $r[0], $r[1], $r[2], $r[3], $r[4], $r[5])
        if ($r[0] -eq $script:Iface) {
            Write-Host "$line  <- текущий" -ForegroundColor Green
        } else {
            Write-Host $line
        }
    }

    Write-Host ''
    Write-Dim 'Интерфейсы независимы: свой порт, своя подсеть, свои клиенты.'
    Write-Host ''
    $choice = (Read-Host '  Номер интерфейса для работы (Enter — оставить текущий)').Trim()
    if (-not $choice) { return }
    if ($choice -notmatch '^\d+$') { Write-Warn 'Нет такого пункта.'; return }
    $idx = [int]$choice
    if ($idx -lt 1 -or $idx -gt $rows.Count) { Write-Warn 'Нет такого пункта.'; return }

    Set-Iface $rows[$idx - 1][0]
    Write-Ok "Панель работает с интерфейсом $script:Iface (клиенты в $script:RemoteDir)."
}

function Action-MigrateClient {
    Write-Head 'Переезд клиента на другой интерфейс'
    Write-Dim "Сейчас панель работает с интерфейсом $script:Iface."
    Write-Dim 'Клиент заводится на целевом интерфейсе с ТЕМ ЖЕ ключом, а на текущем'
    Write-Dim 'остаётся. Прежняя ссылка продолжает работать, пока человек не импортирует'
    Write-Dim 'новую, — поэтому переезд не отключает его ни на секунду.'

    $rows = @(Get-Ifaces)
    if ($rows.Count -lt 2) {
        Write-Host ''
        Write-Warn 'Переезжать некуда: на сервере только один интерфейс.'
        return
    }

    $name = Select-Client 'Кого переселяем'
    if (-not $name) { Write-Dim 'Отменено.'; return }

    $targets = @($rows | Where-Object { $_[0] -ne $script:Iface })
    Write-Head "Куда переселяем '$name'"
    for ($i = 0; $i -lt $targets.Count; $i++) {
        $t = $targets[$i]
        Write-Host ("   {0,2}  {1,-8} порт {2}, подсеть {3}" -f ($i + 1), $t[0], $t[1], $t[2])
    }
    Write-Host '    0  отмена' -ForegroundColor DarkGray
    Write-Host ''
    $choice = (Read-Host '  Номер').Trim()
    if ($choice -notmatch '^\d+$') { Write-Dim 'Отменено.'; return }
    $idx = [int]$choice
    if ($idx -lt 1 -or $idx -gt $targets.Count) { Write-Dim 'Отменено.'; return }
    $target = $targets[$idx - 1][0]

    Write-Host ''
    Invoke-Remote -CmdArgs @('migrate-client', $name, '--to', $target) | Out-Null
    if ($script:LastRc -ne 0) { return }

    $from = $script:Iface
    Write-Host ''
    Write-Ok "'$name' заведён на $target."
    Write-Dim "На $from он остался — прежняя ссылка продолжает работать."
    Write-Dim "Когда человек импортирует новую, вернитесь на $from (пункт I) и удалите там ключ."

    if (Confirm-Action "Переключить панель на $target и скачать новый набор?") {
        Set-Iface $target
        Invoke-Fetch -Name $name -OutDir (Join-Path $ScriptDir $name) | Out-Null
        Show-ClientLink -Name $name
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
    Invoke-Remote -CmdArgs @('server-rekey', '-y') | Out-Null
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
    $script:HomeDir      = $home_
    $script:RemoteScript = "$home_/awg/awg3.sh"
    Set-Iface 'awg0'
}

# Применяет профиль к переменным подключения. Конфиг ssh переписываем здесь же:
# это единственное место, после которого меняется, куда пойдёт следующая
# команда, и разъехаться эти два знания не должны.
function Use-Profile {
    param($Item)
    $script:VpsHost = $Item.host
    $script:VpsPort = [int]$Item.port
    $script:VpsUser = $Item.user
    $home_ = if ($Item.user -eq 'root') { '/root' } else { "/home/$($Item.user)" }
    $script:HomeDir      = $home_
    $script:RemoteScript = "$home_/awg/awg3.sh"
    Set-Iface 'awg0'
    Write-SshConfig
}

# Добавление сервера: кладём ключ и настраиваем sudo — дальше вход без
# вопросов. Пароль спрашивает сам ssh, и это единственный раз, когда он вообще
# нужен.
function New-ServerProfile {
    Write-Head 'Новый сервер'
    Read-Connection
    Use-Profile ([pscustomobject]@{ host = $VpsHost; port = $VpsPort; user = $VpsUser })

    if (-not (Ensure-PanelKey)) { return $false }

    Write-Host ''
    Write-Dim 'Дальше спрашивает сам ssh — панель пароль не видит и не хранит:'
    Write-Dim '  • отпечаток сервера, если подключаемся к нему впервые (ответ yes);'
    Write-Dim '  • пароль пользователя — для входа;'
    Write-Dim '  • его же ещё раз — для sudo на сервере.'
    Write-Host ''

    $pub = (Get-Content "$KeyPath.pub" -Raw).Trim()
    $rc = Invoke-Setup -PubKey $pub

    if ($rc -ne 0) {
        Write-Host ''
        Write-Err 'Не удалось настроить вход по ключу.'
        # 255 — код самого ssh: до выполнения команды дело не дошло.
        if ($rc -eq 255) {
            Write-Warn 'Проверьте адрес, порт, логин и пароль. Несколько неверных попыток'
            Write-Warn 'подряд — и fail2ban заблокирует ваш IP примерно на 10 минут.'
        }
        return $false
    }
    Write-Ok 'Ключ добавлен, sudo настроен.'

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
                    return $true
                }
                Write-Err 'Нет такого номера.'
            }
            default { Write-Err 'Не понял. Введите номер, N, D или Q.' }
        }
    }
}

function Show-Banner {
    Clear-Host
    Write-Host ''
    Write-Host '   ╔══════════════════════════════════════════════╗' -ForegroundColor Cyan
    Write-Host '   ║        AmneziaWG — панель управления         ║' -ForegroundColor Cyan
    Write-Host '   ╚══════════════════════════════════════════════╝' -ForegroundColor Cyan
    if ($VpsHost) {
        $where = "        $VpsUser@$VpsHost`:$VpsPort"
        if ($script:Iface -and $script:Iface -ne 'awg0') { $where += "  [$($script:Iface)]" }
        Write-Host $where -ForegroundColor DarkGray
    }
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
    Write-Host '   ИНТЕРФЕЙСЫ' -ForegroundColor DarkCyan
    Write-Host ("    I  Интерфейсы сервера (сейчас: {0})" -f $script:Iface)
    Write-Host '    T  Переезд клиента на другой интерфейс'
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
    # «y» здесь означало бы согласиться разговаривать с тем, кто выдаёт себя
    # за ваш сервер.
    if (Test-HostKeyChanged $probe) {
        Write-Host ''
        foreach ($line in $probe) { Write-Host "  $line" -ForegroundColor Yellow }
        Write-Host ''
        Write-Warn 'Так выглядит и переустановка сервера, и попытка подмены.'
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
        # 255 — код самого ssh: до запуска awg3.sh дело не дошло. Причина почти
        # всегда одна из двух: сервер не отвечает или не принял наш ключ.
        if ($script:LastRc -eq 255) {
            Write-Warn 'Сервер не ответил или не принял ключ панели. Если сервер'
            Write-Warn 'переустанавливали, добавьте его заново — пункт N в списке.'
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
            '^[iI]$' { Action-Ifaces;      Pause-Panel }
            '^[tT]$' { Action-MigrateClient; Pause-Panel }
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
    # Панель не держит ни пароля, ни открытой сессии: чистить на выходе нечего,
    # а сообщение нужно на любом пути выхода — в том числе через exit.
    Write-Host ''
    Write-Host '  Панель закрыта.' -ForegroundColor DarkGray
}




