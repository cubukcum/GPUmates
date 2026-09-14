[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [Alias('WorkerIPs')]
    [System.Net.IPAddress[]]$WorkerIP,
    [string]$ModelPath = 'C:\Users\mcubukcu\.ollama\models\blobs\sha256-1278394b693672ac2799eadc9a83fd98259a6a88a40acfb1dcaa6c6fc895a606',
    [int]$RpcPort = 50052
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($WorkerIP.Count -eq 0) {
    throw 'At least one WorkerIP is required.'
}
foreach ($Address in $WorkerIP) {
    if ($Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw 'Every WorkerIP must be an IPv4 address.'
    }
}
$WorkerAddresses = @($WorkerIP | ForEach-Object { $_.IPAddressToString })
$UniqueWorkerAddresses = @($WorkerAddresses | Select-Object -Unique)
if ($UniqueWorkerAddresses.Count -ne $WorkerAddresses.Count) {
    throw 'WorkerIP contains a duplicate address.'
}
if (-not (Test-Path -LiteralPath $ModelPath -PathType Leaf)) {
    throw "Model file not found: $ModelPath"
}

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$BenchExe = (Resolve-Path -LiteralPath (Join-Path $ProjectRoot 'runtime\llama-bench.exe')).Path
$ResultsRoot = Join-Path $ProjectRoot 'results'
New-Item -ItemType Directory -Force -Path $ResultsRoot | Out-Null
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$RpcEndpoints = @(
    $WorkerAddresses | ForEach-Object { '{0}:{1}' -f $_, $RpcPort }
)
$RpcEndpointList = $RpcEndpoints -join ','

foreach ($Index in 0..($WorkerIP.Count - 1)) {
    $WorkerAddress = $WorkerAddresses[$Index]
    $RpcEndpoint = $RpcEndpoints[$Index]
    $TcpClient = [System.Net.Sockets.TcpClient]::new()

    try {
        try {
            $ConnectTask = $TcpClient.ConnectAsync($WorkerAddress, $RpcPort)
            if (-not $ConnectTask.Wait(3000) -or -not $TcpClient.Connected) {
                throw 'Connection timed out.'
            }
        }
        catch {
            $ConnectionError = $_.Exception.GetBaseException().Message
            throw "Cannot connect to RPC worker at $RpcEndpoint. Start that worker and verify its firewall rule. Details: $ConnectionError"
        }
    }
    finally {
        $TcpClient.Dispose()
    }
}

$CommonArguments = @('-m', $ModelPath, '-ngl', '999', '-p', '128', '-n', '32', '-r', '1', '-o', 'md')

Write-Host "Running local-only baseline..."
& $BenchExe @CommonArguments 2>&1 |
    Tee-Object -FilePath (Join-Path $ResultsRoot "$Timestamp-local.md")
if ($LASTEXITCODE -ne 0) {
    throw 'Local benchmark failed.'
}

Write-Host "`nRunning local + RPC benchmark against $RpcEndpointList..."
$RpcArguments = $CommonArguments + @('--rpc', $RpcEndpointList)
& $BenchExe @RpcArguments 2>&1 |
    Tee-Object -FilePath (Join-Path $ResultsRoot "$Timestamp-rpc.md")
if ($LASTEXITCODE -ne 0) {
    throw 'RPC benchmark failed.'
}

Write-Host "`nSaved benchmark logs under $ResultsRoot"
