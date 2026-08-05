# Доставка репозитория на тестовый стенд.
#
#   .\tools\sync.ps1 -Vm user@10.10.10.101
#
# Всё уходит ОДНИМ потоком через одно SSH-соединение. Отдельные scp на каждый
# файл упираются в `ufw limit 22/tcp`, который ставит установщик: больше шести
# подключений за 30 секунд с одного адреса — и вы блокируете сами себя.
#
# vendor/ и docs/ на стенде не нужны: 300 КБ чужого кода и документация только
# замедляют синхронизацию.

param(
    [Parameter(Mandatory = $true)][string]$Vm,
    [string]$Dest = 'awg3-deploy',
    [int]$Port = 22
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Push-Location $repo

try {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "awg3-sync-$PID.tar"
    tar -cf $tmp --exclude=.git --exclude=vendor --exclude=docs .
    if ($LASTEXITCODE -ne 0) { throw "tar не собрался" }

    # Одно соединение: распаковка, нормализация CRLF и права на исполнение.
    $remote = @"
rm -rf ~/$Dest && mkdir -p ~/$Dest && tar -xf - -C ~/$Dest &&
find ~/$Dest -type f \( -name '*.sh' -o -name '*.bats' -o -name '*.bash' \) -exec sed -i 's/\r`$//' {} + &&
find ~/$Dest -type f \( -name '*.sh' -o -name '*.bats' \) -exec chmod +x {} + &&
ls ~/$Dest | tr '\n' ' '
"@
    Get-Content -Path $tmp -AsByteStream -Raw | ssh -o BatchMode=yes -p $Port $Vm $remote
    if ($LASTEXITCODE -ne 0) { throw "доставка не удалась" }
}
finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
    Pop-Location
}
