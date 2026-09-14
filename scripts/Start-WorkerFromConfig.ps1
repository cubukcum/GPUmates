[CmdletBinding()]
param([string]$ConfigPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $env:ProgramData 'GPUmates\Worker\worker.json'
}
$ResolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).Path
$Configuration = Get-Content -LiteralPath $ResolvedConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
if ($Configuration.schemaVersion -ne 1) {
    throw 'Unsupported GPUmates worker configuration version.'
}

$CacheEnabled = $false
$CacheProperty = $Configuration.PSObject.Properties['cacheEnabled']
if ($null -ne $CacheProperty) {
    if ($CacheProperty.Value -isnot [bool]) {
        throw 'Invalid GPUmates worker configuration: cacheEnabled must be true or false.'
    }
    $CacheEnabled = [bool]$CacheProperty.Value
}

Write-Host "Node: $($Configuration.nodeName)"
Write-Host "Coordinator: $($Configuration.coordinatorIP)"
Write-Host "RPC tensor caching: $(if ($CacheEnabled) { 'ENABLED' } else { 'disabled' })"

$WorkerArguments = @{
    WorkerIP = [System.Net.IPAddress]$Configuration.workerIP
    Port     = [int]$Configuration.rpcPort
}
if ($CacheEnabled) {
    $WorkerArguments.EnableCache = $true
}
else {
    $WorkerArguments.DisableCache = $true
}

& (Join-Path $PSScriptRoot 'Start-Worker.ps1') @WorkerArguments
exit $LASTEXITCODE
