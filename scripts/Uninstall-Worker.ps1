[CmdletBinding()]
param([string]$ConfigPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $env:ProgramData 'GPUmates\Worker\worker.json'
}

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$RpcExePath = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot 'runtime\ggml-rpc-server.exe'))
$WorkerLauncherPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Start-WorkerFromConfig.ps1'))
$TelemetryLauncherPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Start-TelemetryFromConfig.ps1'))

$Processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
foreach ($Process in $Processes) {
    $ShouldStop = $false
    if (-not [string]::IsNullOrWhiteSpace([string]$Process.ExecutablePath) -and
        [string]::Equals([System.IO.Path]::GetFullPath([string]$Process.ExecutablePath), $RpcExePath, [StringComparison]::OrdinalIgnoreCase)) {
        $ShouldStop = $true
    }
    elseif ($Process.Name -ieq 'powershell.exe' -and -not [string]::IsNullOrWhiteSpace([string]$Process.CommandLine)) {
        $ShouldStop = $Process.CommandLine.IndexOf($WorkerLauncherPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $Process.CommandLine.IndexOf($TelemetryLauncherPath, [StringComparison]::OrdinalIgnoreCase) -ge 0
    }

    if ($ShouldStop) {
        Stop-Process -Id ([int]$Process.ProcessId) -Force -ErrorAction SilentlyContinue
    }
}

$RpcPort = 50052
$TelemetryPort = 9835
if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    try {
        $Configuration = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $RpcPort = [int]$Configuration.rpcPort
        $TelemetryPort = [int]$Configuration.telemetryPort
    }
    catch {
        Write-Warning "Could not read worker configuration during uninstall: $($_.Exception.Message)"
    }
}

& (Join-Path $PSScriptRoot 'Configure-WorkerFirewall.ps1') -Port $RpcPort -Remove
& (Join-Path $PSScriptRoot 'Configure-MetricsFirewall.ps1') -Port $TelemetryPort -Remove

$CurrentUserSecret = Join-Path $env:LOCALAPPDATA 'GPUmates\Worker\agent-key.dpapi'
if (Test-Path -LiteralPath $CurrentUserSecret -PathType Leaf) {
    Remove-Item -LiteralPath $CurrentUserSecret -Force
    Write-Host "Removed the DPAPI-protected AgentKey for user $env:USERNAME."
}
Write-Host 'GPUmates worker processes and firewall rules were removed.'
