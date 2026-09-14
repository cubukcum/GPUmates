[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [System.Net.IPAddress]$CoordinatorIP,

    [Parameter(Mandatory)]
    [System.Net.IPAddress]$WorkerIP,

    [Parameter(Mandatory)]
    [string]$NodeName,

    [ValidateRange(1024, 65535)]
    [int]$RpcPort = 50052,

    [ValidateRange(1024, 65535)]
    [int]$TelemetryPort = 9835,

    [switch]$EnableCache
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Worker installation must run with Administrator privileges.'
}

$LogDirectory = Join-Path $env:ProgramData 'GPUmates\Worker\Logs'
New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
$LogPath = Join-Path $LogDirectory 'install.log'
Start-Transcript -LiteralPath $LogPath -Append | Out-Null
try {
    & (Join-Path $PSScriptRoot 'Set-WorkerConfiguration.ps1') `
        -CoordinatorIP $CoordinatorIP `
        -WorkerIP $WorkerIP `
        -NodeName $NodeName `
        -RpcPort $RpcPort `
        -TelemetryPort $TelemetryPort `
        -EnableCache:$EnableCache

    & (Join-Path $PSScriptRoot 'Configure-WorkerFirewall.ps1') `
        -CoordinatorIP $CoordinatorIP `
        -WorkerIP $WorkerIP `
        -Port $RpcPort

    & (Join-Path $PSScriptRoot 'Configure-MetricsFirewall.ps1') `
        -CoordinatorIP $CoordinatorIP `
        -AgentIP $WorkerIP `
        -Port $TelemetryPort

    Write-Host 'GPUmates Worker installation configuration completed.'
}
finally {
    Stop-Transcript | Out-Null
}
