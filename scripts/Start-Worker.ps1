[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [System.Net.IPAddress]$WorkerIP,
    [ValidateRange(1024, 65535)]
    [int]$Port = 50052,
    [switch]$EnableCache,
    [switch]$DisableCache
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($WorkerIP.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw 'WorkerIP must be an IPv4 address.'
}

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$RpcExe = (Resolve-Path -LiteralPath (Join-Path $ProjectRoot 'runtime\ggml-rpc-server.exe')).Path
$WorkerAddress = $WorkerIP.IPAddressToString

if ($EnableCache -and $DisableCache) {
    throw 'Use either EnableCache or DisableCache, not both.'
}

$LocalIPv4 = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
    Where-Object { $_.OperationalStatus -eq [System.Net.NetworkInformation.OperationalStatus]::Up } |
    ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
    Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
    ForEach-Object { $_.Address.IPAddressToString }

if ($WorkerAddress -notin $LocalIPv4) {
    throw "$WorkerAddress is not assigned to an active local interface. Run Get-NetworkInfo.ps1 and use PC2's wired IPv4 address."
}

$RpcArguments = @('-H', $WorkerAddress, '-p', $Port, '-d', 'CUDA0')
$PreviousLlamaCache = $env:LLAMA_CACHE
if ($EnableCache) {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA is unavailable; the GPUmates tensor cache location cannot be resolved.'
    }
    # Keep GPUmates cache files separate from other llama.cpp installations and
    # namespace them by the pinned runtime build so upgrades cannot reuse an
    # incompatible tensor-cache format accidentally.
    $env:LLAMA_CACHE = Join-Path $env:LOCALAPPDATA 'GPUmates\Worker\TensorCache\b10488'
    $RpcArguments += '-c'
}

Write-Host "Starting llama.cpp RPC worker on $WorkerAddress`:$Port"
Write-Host 'This RPC endpoint is unauthenticated. Keep it LAN-only and never port-forward it.'
if ($EnableCache) {
    Write-Host 'Local RPC tensor caching is ENABLED. Cached data may remain on this PC.'
    Write-Host "Cache location: $env:LLAMA_CACHE\rpc"
}
else {
    Write-Host 'Local RPC tensor caching is disabled.'
}
Write-Host 'Press Ctrl+C to stop.'

try {
    & $RpcExe @RpcArguments
    $RpcExitCode = $LASTEXITCODE
}
finally {
    $env:LLAMA_CACHE = $PreviousLlamaCache
}
exit $RpcExitCode
