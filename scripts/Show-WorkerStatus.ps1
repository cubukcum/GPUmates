[CmdletBinding()]
param([string]$ConfigPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $env:ProgramData 'GPUmates\Worker\worker.json'
}
$ResolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).Path
$Configuration = Get-Content -LiteralPath $ResolvedConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
$CacheEnabled = $false
$CacheProperty = $Configuration.PSObject.Properties['cacheEnabled']
if ($null -ne $CacheProperty) {
    if ($CacheProperty.Value -isnot [bool]) {
        throw 'Invalid GPUmates worker configuration: cacheEnabled must be true or false.'
    }
    $CacheEnabled = [bool]$CacheProperty.Value
}
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$RpcExe = (Resolve-Path -LiteralPath (Join-Path $ProjectRoot 'runtime\ggml-rpc-server.exe')).Path
$TelemetryLauncher = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'Start-TelemetryFromConfig.ps1')).Path

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
        $Pattern = '^\s*TCP\s+\S+:' + [regex]::Escape([string]$Port) + '\s+\S+\s+LISTENING\s+(\d+)\s*$'
        return @(
            & (Join-Path $env:SystemRoot 'System32\netstat.exe') -ano -p tcp 2>$null |
                ForEach-Object {
                    if ($_ -match $Pattern) {
                        [int]$Matches[1]
                    }
                } |
                Select-Object -Unique
        )
    }
}

function Get-ListenerState {
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][ValidateSet('rpc', 'telemetry')][string]$Service,
        [Parameter(Mandatory)][string]$ExpectedPath
    )

    $OwnerIds = @(Get-ListeningOwnerIds -Port $Port)
    if ($OwnerIds.Count -eq 0) {
        return 'STOPPED'
    }

    foreach ($OwnerId in $OwnerIds) {
        if ($Service -eq 'rpc') {
            try {
                $ProcessPath = (Get-Process -Id $OwnerId -ErrorAction Stop).Path
                if ([string]::Equals([System.IO.Path]::GetFullPath($ProcessPath), $ExpectedPath, [StringComparison]::OrdinalIgnoreCase)) {
                    return 'RUNNING'
                }
            }
            catch {
                # Continue to the conflict result.
            }
        }
        else {
            try {
                $CommandLine = [string](Get-CimInstance Win32_Process -Filter "ProcessId = $OwnerId" -ErrorAction Stop).CommandLine
                if (-not [string]::IsNullOrWhiteSpace($CommandLine) -and
                    $CommandLine.IndexOf($ExpectedPath, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    return 'RUNNING'
                }
            }
            catch {
                # Continue to the conflict result.
            }
        }
    }
    return 'CONFLICT'
}

$Gpu = @(& nvidia-smi.exe --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits 2>$null)
$RpcState = Get-ListenerState -Port ([int]$Configuration.rpcPort) -Service rpc -ExpectedPath $RpcExe
$TelemetryState = Get-ListenerState -Port ([int]$Configuration.telemetryPort) -Service telemetry -ExpectedPath $TelemetryLauncher

Write-Host "GPUmates node: $($Configuration.nodeName)"
Write-Host "Worker address: $($Configuration.workerIP)"
Write-Host "Coordinator: $($Configuration.coordinatorIP)"
Write-Host "RPC $($Configuration.rpcPort): $RpcState"
Write-Host "Telemetry $($Configuration.telemetryPort): $TelemetryState"
Write-Host "RPC tensor caching: $(if ($CacheEnabled) { 'ENABLED' } else { 'disabled' })"
if ($Gpu.Count -gt 0) {
    Write-Host 'GPU index, name, utilization %, VRAM used MiB, VRAM total MiB, temperature C:'
    $Gpu | ForEach-Object { Write-Host "  $_" }
}
