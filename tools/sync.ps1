# Доставка репозитория на тестовый стенд.
#
#   .\tools\sync.ps1 -Vm user@10.10.10.101
#
# vendor/ и docs/ на стенде не нужны — это 300 КБ чужого кода и документация,
# которые только замедлят каждую синхронизацию.

param(
    [Parameter(Mandatory = $true)][string]$Vm,
    [string]$Dest = 'awg3-deploy'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$exclude = @('.git', 'vendor', 'docs')

ssh $Vm "rm -rf ~/$Dest && mkdir -p ~/$Dest"

Get-ChildItem -Path $repo -Force |
    Where-Object { $exclude -notcontains $_.Name } |
    ForEach-Object { scp -q -r $_.FullName "${Vm}:~/${Dest}/" }

# CRLF ломает shebang, а Windows-права теряют исполняемый бит.
ssh $Vm "find ~/$Dest -type f \( -name '*.sh' -o -name '*.bats' -o -name '*.bash' \) -exec sed -i 's/\r`$//' {} +"
ssh $Vm "find ~/$Dest -type f \( -name '*.sh' -o -name '*.bats' \) -exec chmod +x {} +"
ssh $Vm "ls -la ~/$Dest"
