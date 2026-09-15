[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ListeningOwnerIds {
    param([Parameter(Mandatory)][int]$Port)
    try {
        return @(
            Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop |
                ForEach-Object { [int]$_.OwningProcess } |
                Select-Object -Unique
        )
    }
    catch {
        return @()
    }
}

function Get-CommandLine {
    param([Parameter(Mandatory)][int]$ProcessId)
    try {
        return [string](Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop).CommandLine
    }
    catch {
        return $null
    }
}

function Stop-ExpectedListener {
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][ValidateSet('router', 'dashboard', 'control')][string]$Service
    )

    $ProjectRoot = Split-Path -Parent $PSScriptRoot
    foreach ($ProcessId in @(Get-ListeningOwnerIds -Port $Port)) {
        $Expected = $false
        if ($Service -eq 'router') {
            try {
                $ActualPath = (Get-Process -Id $ProcessId -ErrorAction Stop).Path
                $ExpectedPath = (Resolve-Path -LiteralPath (Join-Path $ProjectRoot 'runtime\llama-server.exe')).Path
                $Expected = [string]::Equals([IO.Path]::GetFullPath($ActualPath), $ExpectedPath, [StringComparison]::OrdinalIgnoreCase)
            }
            catch {
                $Expected = $false
            }
        }
        else {
            $Marker = if ($Service -eq 'dashboard') { 'Start-GPUmatesDashboard.ps1' } else { 'Start-GPUmatesControlCenter.ps1' }
            $CommandLine = Get-CommandLine -ProcessId $ProcessId
            $ExpectedScript = [regex]::Escape((Join-Path $ProjectRoot "scripts\$Marker"))
            $Expected = -not [string]::IsNullOrWhiteSpace($CommandLine) -and
                $CommandLine -match ('(?i)(?:^|\s)-File\s+(?:"' + $ExpectedScript + '"|' + $ExpectedScript + ')(?=\s|$)')
        }

        if ($Expected) {
            Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
}

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Coordinator cleanup must run as Administrator.'
}

$ProjectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'GPUmates.Network.psm1') -Force
$Network = Get-GPUmatesNetworkConfiguration -ProjectRoot $ProjectRoot

Stop-ExpectedListener -Port $Network.routerPort -Service router
Stop-ExpectedListener -Port $Network.dashboardPort -Service dashboard
Stop-ExpectedListener -Port $Network.controlPort -Service control

& (Join-Path $PSScriptRoot 'Configure-CoordinatorFirewall.ps1') -Port $Network.routerPort -Remove
& (Join-Path $PSScriptRoot 'Configure-DashboardFirewall.ps1') -Port $Network.dashboardPort -Remove
