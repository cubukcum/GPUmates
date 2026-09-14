[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [Alias('WorkerIPs')]
    [System.Net.IPAddress[]]$WorkerIP,
    [string]$ModelPath = 'C:\Users\mcubukcu\.ollama\models\blobs\sha256-1278394b693672ac2799eadc9a83fd98259a6a88a40acfb1dcaa6c6fc895a606',
    [int]$ContextSize = 8192,
    [int]$RpcPort = 50052,
    [string]$ListenHost = '127.0.0.1',
    [int]$Port = 8080,
    [string]$ApiKey,
    [string]$TensorSplit
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

$LoopbackHosts = @('127.0.0.1', 'localhost', '::1')
if ($ListenHost -notin $LoopbackHosts -and [string]::IsNullOrWhiteSpace($ApiKey)) {
    throw 'ApiKey is required whenever ListenHost is not loopback.'
}

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ServerExe = (Resolve-Path -LiteralPath (Join-Path $ProjectRoot 'runtime\llama-server.exe')).Path
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

$OllamaState = $null
try {
    $OllamaState = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/ps' -TimeoutSec 2
}
catch {
    # Ollama is not running, which is fine.
}
if ($null -ne $OllamaState -and $OllamaState.models.Count -gt 0) {
    $LoadedNames = ($OllamaState.models | ForEach-Object name) -join ', '
    throw "Ollama currently has a model loaded ($LoadedNames). Unload it before starting the coordinator."
}

$ServerArguments = @(
    '-m', $ModelPath,
    '-ngl', '999',
    '-c', $ContextSize,
    '-np', '1',
    '--fit', 'on',
    '--split-mode', 'layer',
    '--rpc', $RpcEndpointList,
    '--cache-ram', '0',
    '--host', $ListenHost,
    '--port', $Port,
    '--alias', 'gpumates-model'
)

if (-not [string]::IsNullOrWhiteSpace($TensorSplit)) {
    $ServerArguments += @('--tensor-split', $TensorSplit)
}
if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
    $ServerArguments += @('--api-key', $ApiKey)
}
if ($ListenHost -in $LoopbackHosts) {
    $ServerArguments += @('--cors-origins', 'localhost')
}
else {
    $ServerArguments += @('--cors-origins', "http://$ListenHost`:$Port")
}

Write-Host "Starting coordinator with local CUDA0 plus RPC workers: $RpcEndpointList"
Write-Host "Model: $ModelPath"
Write-Host "UI/API: http://$ListenHost`:$Port"
Write-Host 'Press Ctrl+C to stop.'

& $ServerExe @ServerArguments
exit $LASTEXITCODE
