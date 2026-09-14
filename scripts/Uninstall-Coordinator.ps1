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
            $Expected = -not [string]::IsNullOrWhiteSpace($CommandLine) -and
                $CommandLine.IndexOf((Join-Path $ProjectRoot 'scripts'), [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
                $CommandLine.IndexOf($Marker, [StringComparison]::OrdinalIgnoreCase) -ge 0
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

Stop-ExpectedListener -Port 8080 -Service router
Stop-ExpectedListener -Port 8090 -Service dashboard
Stop-ExpectedListener -Port 8091 -Service control

& (Join-Path $PSScriptRoot 'Configure-CoordinatorFirewall.ps1') -Remove
& (Join-Path $PSScriptRoot 'Configure-DashboardFirewall.ps1') -Remove
