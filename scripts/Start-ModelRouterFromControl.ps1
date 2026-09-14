[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RuntimeConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ResolvedRuntimeConfigPath = (Resolve-Path -LiteralPath $RuntimeConfigPath -ErrorAction Stop).Path
$RuntimeConfiguration = Get-Content -LiteralPath $ResolvedRuntimeConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
if ($RuntimeConfiguration.schemaVersion -ne 1) {
    throw 'Unsupported GPUmates router runtime configuration version.'
}

$WorkerAddresses = @(
    $RuntimeConfiguration.workerIps |
        ForEach-Object { [System.Net.IPAddress]$_ }
)
$RouterParameters = @{
    WorkerIP    = $WorkerAddresses
    ListenHost = [string]$RuntimeConfiguration.listenHost
    Port        = [int]$RuntimeConfiguration.port
    ContextSize = [int]$RuntimeConfiguration.contextSize
}

if (-not [string]::IsNullOrWhiteSpace([string]$RuntimeConfiguration.presetPath)) {
    $RouterParameters.PresetPath = [string]$RuntimeConfiguration.presetPath
}
if (-not [string]::IsNullOrWhiteSpace([string]$RuntimeConfiguration.tensorSplit)) {
    $RouterParameters.TensorSplit = [string]$RuntimeConfiguration.tensorSplit
}
if (-not [string]::IsNullOrWhiteSpace($env:GPUMATES_LLAMA_API_KEY)) {
    $RouterParameters.ApiKey = $env:GPUMATES_LLAMA_API_KEY
}

& (Join-Path $PSScriptRoot 'Start-ModelRouter.ps1') @RouterParameters
exit $LASTEXITCODE
