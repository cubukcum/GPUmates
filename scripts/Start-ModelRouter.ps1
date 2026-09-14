[CmdletBinding()]
param(
    [Alias('WorkerIPs')]
    [System.Net.IPAddress[]]$WorkerIP = @(),
    [string]$PresetPath,
    [int]$ContextSize = 8192,
    [int]$RpcPort = 50052,
    [string]$ListenHost = '127.0.0.1',
    [int]$Port = 8080,
    [string]$ApiKey,
    [string]$TensorSplit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

$LoopbackHosts = @('127.0.0.1', 'localhost', '::1')
if ($ListenHost -notin $LoopbackHosts -and [string]::IsNullOrWhiteSpace($ApiKey)) {
    throw 'ApiKey is required whenever ListenHost is not loopback.'
}

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ServerExe = (Resolve-Path -LiteralPath (Join-Path $ProjectRoot 'runtime\llama-server.exe')).Path

if ([string]::IsNullOrWhiteSpace($PresetPath)) {
    $PresetPath = Join-Path $ProjectRoot 'config\gpumates-models.ini'
}
$PresetPath = (Resolve-Path -LiteralPath $PresetPath).Path

$PresetLines = Get-Content -LiteralPath $PresetPath
$ModelPaths = @(
    $PresetLines |
        Where-Object { $_ -match '^\s*model\s*=\s*(.+?)\s*$' } |
        ForEach-Object { $Matches[1].Trim().Trim('"').Trim("'") }
)
if ($ModelPaths.Count -eq 0) {
    throw "No model entries were found in preset: $PresetPath"
}
$MissingModelPaths = @($ModelPaths | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
if ($MissingModelPaths.Count -gt 0) {
    Write-Warning "Some preset model files are missing and cannot be loaded: $($MissingModelPaths -join ', ')"
}

$RpcEndpoints = @(
    $WorkerAddresses | ForEach-Object { '{0}:{1}' -f $_, $RpcPort }
)
$RpcEndpointList = $RpcEndpoints -join ','

if ($WorkerAddresses.Count -gt 0) {
    foreach ($Index in 0..($WorkerAddresses.Count - 1)) {
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
    throw "Ollama currently has a model loaded ($LoadedNames). Unload it before starting the router."
}

# Windows PowerShell 5.1 writes `-Encoding UTF8` files with a BOM. The
# llama.cpp router preset parser rejects that marker, so accept and normalize
# legacy GPUmates presets through a short-lived BOM-free copy.
$ServerPresetPath = $PresetPath
$NormalizedPresetPath = $null
$PresetBytes = [IO.File]::ReadAllBytes($PresetPath)
if ($PresetBytes.Length -ge 3 -and
    $PresetBytes[0] -eq 0xEF -and
    $PresetBytes[1] -eq 0xBB -and
    $PresetBytes[2] -eq 0xBF) {
    $NormalizedPresetPath = Join-Path `
        ([IO.Path]::GetTempPath()) `
        ('gpumates-models-{0}-{1}.ini' -f $PID, [Guid]::NewGuid().ToString('N'))
    $PresetText = [Text.Encoding]::UTF8.GetString($PresetBytes, 3, $PresetBytes.Length - 3)
    [IO.File]::WriteAllText(
        $NormalizedPresetPath,
        $PresetText,
        [Text.UTF8Encoding]::new($false)
    )
    $ServerPresetPath = $NormalizedPresetPath
}

$ServerArguments = @(
    '--models-preset', $ServerPresetPath,
    '--models-max', '1',
    '--models-autoload',
    '-ngl', 'all',
    '-c', $ContextSize,
    '-np', '1',
    '--fit', 'on',
    '--fit-target', '2048',
    '--split-mode', 'layer',
    '--cache-ram', '0',
    '--host', $ListenHost,
    '--port', $Port,
    '--metrics',
    '--ui'
)

if ($RpcEndpoints.Count -gt 0) {
    $ServerArguments += @('--rpc', $RpcEndpointList)
}

if (-not [string]::IsNullOrWhiteSpace($TensorSplit)) {
    $ServerArguments += @('--tensor-split', $TensorSplit)
}
if ($ListenHost -in $LoopbackHosts) {
    $ServerArguments += @('--cors-origins', 'localhost')
}
else {
    $ServerArguments += @('--cors-origins', "http://$ListenHost`:$Port")
}

$PresetNames = @(
    $PresetLines |
        Where-Object { $_ -match '^\s*\[([^*][^]]*)\]\s*$' } |
        ForEach-Object { $Matches[1] }
)

if ($RpcEndpoints.Count -gt 0) {
    Write-Host "Starting model-router UI with RPC workers: $RpcEndpointList"
}
else {
    Write-Host 'Starting model-router UI with the coordinator GPU only.'
}
Write-Host "Models: $($PresetNames -join ', ')"
Write-Host "UI/API: http://$ListenHost`:$Port"
Write-Host 'Only one model can be loaded at a time. Press Ctrl+C to stop.'

$PreviousLlamaApiKey = $env:LLAMA_API_KEY
try {
    if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
        # llama.cpp reads LLAMA_API_KEY directly. Keeping the key out of the
        # llama-server command line prevents it from appearing in process lists.
        $env:LLAMA_API_KEY = $ApiKey
    }
    & $ServerExe @ServerArguments
    exit $LASTEXITCODE
}
finally {
    if ($null -eq $PreviousLlamaApiKey) {
        Remove-Item Env:LLAMA_API_KEY -ErrorAction SilentlyContinue
    }
    else {
        $env:LLAMA_API_KEY = $PreviousLlamaApiKey
    }
    if (-not [string]::IsNullOrWhiteSpace($NormalizedPresetPath) -and
        (Test-Path -LiteralPath $NormalizedPresetPath -PathType Leaf)) {
        Remove-Item -LiteralPath $NormalizedPresetPath -Force -ErrorAction SilentlyContinue
    }
}
