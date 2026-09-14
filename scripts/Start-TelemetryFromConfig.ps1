[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$AccessToken = $env:GPUMATES_AGENT_KEY
)

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

$SecretDirectory = Join-Path $env:LOCALAPPDATA 'GPUmates\Worker'
$SecretPath = Join-Path $SecretDirectory 'agent-key.dpapi'
$SecretWasLoaded = $false

if ([string]::IsNullOrWhiteSpace($AccessToken) -and (Test-Path -LiteralPath $SecretPath -PathType Leaf)) {
    try {
        $ProtectedText = (Get-Content -LiteralPath $SecretPath -Raw -ErrorAction Stop).Trim()
        $SecureToken = ConvertTo-SecureString -String $ProtectedText -ErrorAction Stop
        $AccessToken = [Net.NetworkCredential]::new('', $SecureToken).Password
        $SecretWasLoaded = $true
    }
    catch {
        throw "The saved AgentKey cannot be decrypted by this Windows user. Use the 'Forget saved AgentKey' shortcut, then try again."
    }
}

if ([string]::IsNullOrWhiteSpace($AccessToken)) {
    $SecureToken = Read-Host -AsSecureString 'Paste the GPUmates AgentKey supplied by the coordinator owner'
    $AccessToken = [Net.NetworkCredential]::new('', $SecureToken).Password
    if ([string]::IsNullOrWhiteSpace($AccessToken) -or $AccessToken.Length -lt 24) {
        throw 'AgentKey must contain at least 24 characters.'
    }

    New-Item -ItemType Directory -Path $SecretDirectory -Force | Out-Null
    $SecureToken | ConvertFrom-SecureString | Set-Content -LiteralPath $SecretPath -Encoding ASCII
    Write-Host "AgentKey saved with Windows DPAPI for user $env:USERNAME."
}
elseif ($AccessToken.Length -lt 24) {
    throw 'AgentKey must contain at least 24 characters.'
}

if ($SecretWasLoaded) {
    Write-Host "Using the DPAPI-protected AgentKey for user $env:USERNAME."
}

try {
    & (Join-Path $PSScriptRoot 'Start-TelemetryAgent.ps1') `
        -ListenIP ([System.Net.IPAddress]$Configuration.workerIP) `
        -AllowedClientIP ([System.Net.IPAddress]$Configuration.coordinatorIP) `
        -Port ([int]$Configuration.telemetryPort) `
        -NodeName ([string]$Configuration.nodeName) `
        -AccessToken $AccessToken
    exit $LASTEXITCODE
}
finally {
    $AccessToken = $null
    $SecureToken = $null
}

