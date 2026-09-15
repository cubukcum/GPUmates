[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$AccessToken = $env:GPUMATES_AGENT_KEY
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-WorkerAgentKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.IPAddress]$CoordinatorIP,
        [Parameter(Mandatory)][string]$SecretPath,
        [AllowNull()][AllowEmptyString()][string]$AccessToken
    )

    if ($CoordinatorIP.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        throw 'CoordinatorIP must be an IPv4 address.'
    }
    $CoordinatorAddress = $CoordinatorIP.IPAddressToString
    if (-not [string]::IsNullOrWhiteSpace($AccessToken)) {
        if ($AccessToken.Length -lt 24) { throw 'AgentKey must contain at least 24 characters.' }
        Write-Host "Using the supplied AgentKey for main PC $CoordinatorAddress. Saved credentials were not used."
        return $AccessToken
    }

    if (Test-Path -LiteralPath $SecretPath -PathType Leaf) {
        $SavedText = $null
        $SavedCredential = $null
        $SecureCredential = $null
        try {
            $ProtectedText = (Get-Content -LiteralPath $SecretPath -Raw -ErrorAction Stop).Trim()
            $SecureCredential = ConvertTo-SecureString -String $ProtectedText -ErrorAction Stop
            $SavedText = [Net.NetworkCredential]::new('', $SecureCredential).Password
            if ($SavedText.TrimStart().StartsWith('{')) {
                $SavedCredential = $SavedText | ConvertFrom-Json -ErrorAction Stop
                $VersionProperty = $SavedCredential.PSObject.Properties['schemaVersion']
                $CoordinatorProperty = $SavedCredential.PSObject.Properties['coordinatorIP']
                $KeyProperty = $SavedCredential.PSObject.Properties['agentKey']
                $SavedCoordinatorIP = $null
                if ($null -eq $VersionProperty -or $VersionProperty.Value -ne 1 -or
                    $null -eq $CoordinatorProperty -or $CoordinatorProperty.Value -isnot [string] -or
                    -not [Net.IPAddress]::TryParse($CoordinatorProperty.Value, [ref]$SavedCoordinatorIP) -or
                    $SavedCoordinatorIP.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
                    $null -eq $KeyProperty -or $KeyProperty.Value -isnot [string] -or
                    [string]::IsNullOrWhiteSpace($KeyProperty.Value) -or $KeyProperty.Value.Length -lt 24) {
                    throw 'The saved credential has an unsupported format.'
                }
                if ($SavedCoordinatorIP.Equals($CoordinatorIP)) {
                    Write-Host "Using the saved AgentKey for main PC $CoordinatorAddress."
                    return [string]$KeyProperty.Value
                }
                Write-Host "Main PC changed to $CoordinatorAddress. Enter its AgentKey to join this group."
            }
            else {
                # Old releases stored just a key, so its original group cannot be
                # identified safely after an upgrade or Coordinator change.
                Write-Host "The saved AgentKey has no main PC identity. Enter the AgentKey for $CoordinatorAddress once to confirm this group."
            }
        }
        catch {
            Write-Host "The saved AgentKey could not be read for this Windows user. Enter the AgentKey for main PC $CoordinatorAddress again."
        }
        finally {
            $SavedText = $null
            $SavedCredential = $null
            $SecureCredential = $null
            $KeyProperty = $null
        }
    }

    $PromptedSecret = Read-Host -AsSecureString "Paste the GPUmates AgentKey supplied by main PC $CoordinatorAddress"
    $Key = [Net.NetworkCredential]::new('', $PromptedSecret).Password
    if ([string]::IsNullOrWhiteSpace($Key) -or $Key.Length -lt 24) {
        throw 'AgentKey must contain at least 24 characters.'
    }

    $FullSecretPath = [IO.Path]::GetFullPath($SecretPath)
    $SecretDirectory = Split-Path -Parent $FullSecretPath
    New-Item -ItemType Directory -Path $SecretDirectory -Force | Out-Null
    $TemporaryPath = Join-Path $SecretDirectory ('.agent-key-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $CredentialJson = $null
    $SecureCredential = $null
    try {
        $CredentialJson = [ordered]@{
            schemaVersion = 1
            coordinatorIP = $CoordinatorAddress
            agentKey = $Key
        } | ConvertTo-Json -Compress
        $SecureCredential = ConvertTo-SecureString -String $CredentialJson -AsPlainText -Force
        $ProtectedText = $SecureCredential | ConvertFrom-SecureString
        [IO.File]::WriteAllText($TemporaryPath, $ProtectedText, [Text.Encoding]::ASCII)
        Move-Item -LiteralPath $TemporaryPath -Destination $FullSecretPath -Force
        Write-Host "AgentKey saved for main PC $CoordinatorAddress, protected for Windows user $env:USERNAME."
        return $Key
    }
    finally {
        $Key = $null
        $PromptedSecret = $null
        $CredentialJson = $null
        $SecureCredential = $null
        if (Test-Path -LiteralPath $TemporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $TemporaryPath -Force
        }
    }
}

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

try {
    $AccessToken = Get-WorkerAgentKey -CoordinatorIP ([System.Net.IPAddress]$Configuration.coordinatorIP) `
        -SecretPath $SecretPath -AccessToken $AccessToken
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
}

