[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [System.Net.IPAddress]$CoordinatorIP,

    [Parameter(Mandatory)]
    [System.Net.IPAddress]$WorkerIP,

    [Parameter(Mandatory)]
    [ValidateLength(1, 64)]
    [string]$NodeName,

    [ValidateRange(1024, 65535)]
    [int]$RpcPort = 50052,

    [ValidateRange(1024, 65535)]
    [int]$TelemetryPort = 9835,

    [switch]$EnableCache,

    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-PrivateIPv4 {
    param([Parameter(Mandatory)][System.Net.IPAddress]$Address)

    if ($Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        return $false
    }

    $Bytes = $Address.GetAddressBytes()
    return $Bytes[0] -eq 10 -or
        ($Bytes[0] -eq 172 -and $Bytes[1] -ge 16 -and $Bytes[1] -le 31) -or
        ($Bytes[0] -eq 192 -and $Bytes[1] -eq 168)
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $env:ProgramData 'GPUmates\Worker\worker.json'
}

if (-not (Test-PrivateIPv4 -Address $CoordinatorIP)) {
    throw 'CoordinatorIP must be an RFC1918 private IPv4 address.'
}
if (-not (Test-PrivateIPv4 -Address $WorkerIP)) {
    throw 'WorkerIP must be an RFC1918 private IPv4 address.'
}
if ($CoordinatorIP.Equals($WorkerIP)) {
    throw 'CoordinatorIP and WorkerIP must be different addresses.'
}
if ($RpcPort -eq $TelemetryPort) {
    throw 'RPC and telemetry ports must be different.'
}

$NodeName = $NodeName.Trim()
if ([string]::IsNullOrWhiteSpace($NodeName) -or $NodeName -notmatch '^[\p{L}\p{N} ._-]+$') {
    throw 'NodeName may contain only letters, numbers, spaces, dots, underscores, and hyphens.'
}

$LocalIPv4 = @(
    [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.OperationalStatus -eq [System.Net.NetworkInformation.OperationalStatus]::Up } |
        ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
        Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
        ForEach-Object { $_.Address.IPAddressToString }
)
$WorkerAddress = $WorkerIP.IPAddressToString
if ($WorkerAddress -notin $LocalIPv4) {
    throw "WorkerIP $WorkerAddress is not assigned to an active interface on this PC."
}

foreach ($PortToCheck in @($RpcPort, $TelemetryPort)) {
    $Probe = [System.Net.Sockets.TcpListener]::new($WorkerIP, $PortToCheck)
    try {
        $Probe.Server.ExclusiveAddressUse = $true
        $Probe.Start()
    }
    catch {
        throw "TCP port $PortToCheck is already in use on $WorkerAddress. Stop the old GPUmates worker/telemetry windows and run setup again."
    }
    finally {
        $Probe.Stop()
    }
}

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$RpcExe = Join-Path $ProjectRoot 'runtime\ggml-rpc-server.exe'
if (-not (Test-Path -LiteralPath $RpcExe -PathType Leaf)) {
    throw "Missing llama.cpp RPC runtime: $RpcExe"
}

$NvidiaSmiCommand = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
$NvidiaSmiPath = if ($null -ne $NvidiaSmiCommand) { $NvidiaSmiCommand.Source } else { $null }
if ([string]::IsNullOrWhiteSpace($NvidiaSmiPath)) {
    $SystemNvidiaSmi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
    if (Test-Path -LiteralPath $SystemNvidiaSmi -PathType Leaf) {
        $NvidiaSmiPath = $SystemNvidiaSmi
    }
}
if ([string]::IsNullOrWhiteSpace($NvidiaSmiPath)) {
    throw 'nvidia-smi.exe was not found. Install a current NVIDIA driver first.'
}

$GpuNames = @(& $NvidiaSmiPath --query-gpu=name --format=csv,noheader 2>$null)
if ($LASTEXITCODE -ne 0 -or $GpuNames.Count -eq 0) {
    throw 'The NVIDIA driver is installed, but no usable NVIDIA GPU was reported.'
}

$ResolvedConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
$ConfigDirectory = Split-Path -Parent $ResolvedConfigPath
New-Item -ItemType Directory -Path $ConfigDirectory -Force | Out-Null

$Configuration = [ordered]@{
    schemaVersion  = 1
    nodeName       = $NodeName
    coordinatorIP  = $CoordinatorIP.IPAddressToString
    workerIP       = $WorkerAddress
    rpcPort        = $RpcPort
    telemetryPort  = $TelemetryPort
    cacheEnabled   = [bool]$EnableCache
}

$TemporaryPath = Join-Path $ConfigDirectory ('.worker-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
try {
    $Configuration | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $TemporaryPath -Encoding UTF8
    Move-Item -LiteralPath $TemporaryPath -Destination $ResolvedConfigPath -Force
}
finally {
    if (Test-Path -LiteralPath $TemporaryPath) {
        Remove-Item -LiteralPath $TemporaryPath -Force
    }
}

Write-Host "Configured GPUmates worker '$NodeName'."
Write-Host "Coordinator: $($CoordinatorIP.IPAddressToString)"
Write-Host "Worker: $WorkerAddress (RPC $RpcPort, telemetry $TelemetryPort)"
Write-Host "GPU: $($GpuNames -join ', ')"
Write-Host "Configuration: $ResolvedConfigPath"
if ($EnableCache) {
    Write-Host 'RPC tensor caching is ENABLED. Cached model tensors may remain on this PC.'
}
else {
    Write-Host 'RPC tensor caching is disabled.'
}
