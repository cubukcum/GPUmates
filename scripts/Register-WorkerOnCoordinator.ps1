[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [System.Net.IPAddress]$WorkerIP,

    [Parameter(Mandatory)]
    [ValidateLength(1, 64)]
    [string]$NodeName,

    [ValidateRange(1024, 65535)]
    [int]$TelemetryPort = 9835,

    [string]$NodeConfig
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

if (-not (Test-PrivateIPv4 -Address $WorkerIP)) {
    throw 'WorkerIP must be an RFC1918 private IPv4 address.'
}
$NodeName = $NodeName.Trim()
if ([string]::IsNullOrWhiteSpace($NodeName) -or $NodeName -notmatch '^[\p{L}\p{N} ._-]+$') {
    throw 'NodeName may contain only letters, numbers, spaces, dots, underscores, and hyphens.'
}

$ProjectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($NodeConfig)) {
    $NodeConfig = Join-Path $ProjectRoot 'config\telemetry-nodes.json'
}
$ResolvedNodeConfig = (Resolve-Path -LiteralPath $NodeConfig -ErrorAction Stop).Path
$Configuration = Get-Content -LiteralPath $ResolvedNodeConfig -Raw | ConvertFrom-Json -ErrorAction Stop
if ($Configuration.schemaVersion -ne 1) {
    throw 'The telemetry configuration must use schemaVersion 1.'
}

$WorkerAddress = $WorkerIP.IPAddressToString
$LocalNode = @(
    $Configuration.nodes |
        Where-Object { $null -ne $_.PSObject.Properties['local'] -and $_.local -eq $true }
) | Select-Object -First 1
if ($null -eq $LocalNode -or [string]::IsNullOrWhiteSpace([string]$LocalNode.displayIp)) {
    throw 'Could not determine the coordinator displayIp from the local node entry.'
}
$CoordinatorIP = [System.Net.IPAddress]$LocalNode.displayIp
if (-not (Test-PrivateIPv4 -Address $CoordinatorIP)) {
    throw 'The coordinator displayIp is not a private IPv4 address.'
}
if ($CoordinatorIP.Equals($WorkerIP)) {
    throw 'WorkerIP cannot equal the coordinator IP.'
}

$SameName = @($Configuration.nodes | Where-Object { $_.name -ieq $NodeName -and $_.host -ne $WorkerAddress })
if ($SameName.Count -gt 0) {
    throw "A different node already uses the name '$NodeName'. Choose a unique name."
}

$ExistingNode = @($Configuration.nodes | Where-Object { $_.host -eq $WorkerAddress }) | Select-Object -First 1
if ($null -eq $ExistingNode) {
    $Configuration.nodes = @($Configuration.nodes) + [pscustomobject][ordered]@{
        name = $NodeName
        host = $WorkerAddress
        port = $TelemetryPort
        role = 'worker'
    }
}
else {
    $ExistingNode.name = $NodeName
    $ExistingNode.port = $TelemetryPort
    $ExistingNode.role = 'worker'
}

$AllowedClients = @($Configuration.dashboard.allowedClientIps | ForEach-Object { [string]$_ })
if ($WorkerAddress -notin $AllowedClients) {
    $Configuration.dashboard.allowedClientIps = @($AllowedClients + $WorkerAddress)
}

$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$BackupPath = "$ResolvedNodeConfig.backup-$Timestamp"
Copy-Item -LiteralPath $ResolvedNodeConfig -Destination $BackupPath -ErrorAction Stop
$TemporaryPath = Join-Path (Split-Path -Parent $ResolvedNodeConfig) ('.telemetry-nodes-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
try {
    $Configuration | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $TemporaryPath -Encoding UTF8
    Move-Item -LiteralPath $TemporaryPath -Destination $ResolvedNodeConfig -Force
}
finally {
    if (Test-Path -LiteralPath $TemporaryPath) {
        Remove-Item -LiteralPath $TemporaryPath -Force
    }
}

$WorkerAddresses = @(
    $Configuration.nodes |
        Where-Object { $_.role -eq 'worker' -and -not [string]::IsNullOrWhiteSpace([string]$_.host) } |
        ForEach-Object { [string]$_.host } |
        Select-Object -Unique
)
$AllowedClientAddresses = @($Configuration.dashboard.allowedClientIps | ForEach-Object { [string]$_ } | Select-Object -Unique)
$RouterList = $WorkerAddresses -join ','
$AllowedList = $AllowedClientAddresses -join ','

Write-Host "Registered $NodeName at $WorkerAddress."
Write-Host "Backup: $BackupPath"
Write-Host 'Restart the GPU dashboard to load the new node.'
Write-Host ''
Write-Host 'Router command (one line):'
Write-Host "& '.\scripts\Start-ModelRouter.ps1' -WorkerIP $RouterList"
Write-Host ''
Write-Host 'Administrator dashboard-firewall command (one line, full client list):'
Write-Host "& '.\scripts\Configure-DashboardFirewall.ps1' -CoordinatorIP $($CoordinatorIP.IPAddressToString) -ClientIP $AllowedList"
