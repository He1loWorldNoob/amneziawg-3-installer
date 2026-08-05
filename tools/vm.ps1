# Управление тестовым стендом в Proxmox.
#
#   .\tools\vm.ps1 -Action recreate -Id 1012    снести клон и создать заново
#   .\tools\vm.ps1 -Action status               что сейчас запущено
#   .\tools\vm.ps1 -Action destroy -Id 1012     снести клон
#
# Работает ТОЛЬКО с клонами шаблона 101 в диапазоне 1010-1019: остальные ВМ на
# гипервизоре рабочие, и трогать их нельзя.

param(
    [Parameter(Mandatory = $true)][ValidateSet('recreate', 'destroy', 'status', 'start', 'stop')]
    [string]$Action,
    [int]$Id = 1012,
    [string]$Host_ = 'root@proxmox',
    [string]$Vm = 'user@10.10.10.101',
    [int]$Template = 101
)

$ErrorActionPreference = 'Stop'

function Assert-Allowed {
    param([int]$VmId)
    if ($VmId -lt 1010 -or $VmId -gt 1019) {
        throw "VMID $VmId вне разрешённого диапазона 1010-1019"
    }
}

function Invoke-Pve {
    param([string]$Command)
    $out = ssh -o BatchMode=yes $Host_ $Command 2>&1
    if ($LASTEXITCODE -ne 0) { throw "на гипервизоре не выполнилось: $Command`n$out" }
    return $out
}

function Wait-Ssh {
    param([int]$TimeoutSec = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    ssh-keygen -R ($Vm -split '@')[1] 2>&1 | Out-Null
    while ((Get-Date) -lt $deadline) {
        ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 $Vm 'true' 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Seconds 5
    }
    return $false
}

switch ($Action) {
    'status' {
        Invoke-Pve 'qm list' | Where-Object { $_ -match '^\s+(101|10[0-1][0-9])\s' -or $_ -match 'VMID' }
    }
    'destroy' {
        Assert-Allowed $Id
        Invoke-Pve "qm stop $Id --skiplock 2>/dev/null; sleep 2; qm destroy $Id --purge --destroy-unreferenced-disks 1" | Out-Null
        Write-Host "клон $Id удалён"
    }
    'stop' {
        Assert-Allowed $Id
        Invoke-Pve "qm stop $Id" | Out-Null
        Write-Host "клон $Id остановлен"
    }
    'start' {
        Assert-Allowed $Id
        Invoke-Pve "qm start $Id" | Out-Null
        if (Wait-Ssh) { Write-Host "клон $Id поднят, SSH отвечает" } else { throw "SSH не поднялся" }
    }
    'recreate' {
        Assert-Allowed $Id
        # Клон наследует статический IP шаблона, поэтому одновременно может
        # работать только один — старые сносим перед созданием нового.
        $running = Invoke-Pve "qm list | awk '`$1 >= 1010 && `$1 <= 1019 {print `$1}'"
        foreach ($old in ($running -split "`n" | Where-Object { $_ -match '^\d+$' })) {
            Invoke-Pve "qm stop $old 2>/dev/null; sleep 2; qm destroy $old --purge --destroy-unreferenced-disks 1" | Out-Null
            Write-Host "снесён прежний клон $old"
        }
        Invoke-Pve "qm clone $Template $Id --name awg3-test-$Id" | Out-Null
        Invoke-Pve "qm start $Id" | Out-Null
        Write-Host "клон $Id создан и запущен, жду SSH..."
        if (-not (Wait-Ssh)) { throw "SSH не поднялся за 180 секунд" }
        Write-Host "стенд готов: $Vm"
    }
}
