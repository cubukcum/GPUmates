[CmdletBinding()]
param(
    [System.Net.IPAddress]$CoordinatorIP,
    [Alias('ClientIPs')]
    [System.Net.IPAddress[]]$ClientIP,
    [ValidateRange(1024, 65535)]
    [int]$Port = 8090,
    [string]$ProgramPath,
    [switch]$Remove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'GPUmates.Network.psm1') -Force
if (-not $PSBoundParameters.ContainsKey('Port')) {
    $Port = (Get-GPUmatesNetworkConfiguration -ProjectRoot $ProjectRoot).dashboardPort
}
$RuleName = "GPUmates-Dashboard-$Port"

function Remove-DashboardFirewallRules {
    foreach ($ExistingRule in @(Get-NetFirewallRule -Name 'GPUmates-Dashboard-*' -ErrorAction SilentlyContinue)) {
        if ($ExistingRule.Name -match '^GPUmates-Dashboard-\d+$') {
            Remove-NetFirewallRule -Name $ExistingRule.Name
            Write-Host "Removed firewall rule $($ExistingRule.Name)."
        }
    }
}

function Assert-PrivateIPv4 {
    param(
        [Parameter(Mandatory)]
        [System.Net.IPAddress]$Address,
        [Parameter(Mandatory)]
        [string]$ParameterName
    )

    if ($Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "$ParameterName must be an IPv4 address."
    }

    $Bytes = $Address.GetAddressBytes()
    $IsPrivate =
        $Bytes[0] -eq 10 -or
        ($Bytes[0] -eq 172 -and $Bytes[1] -ge 16 -and $Bytes[1] -le 31) -or
        ($Bytes[0] -eq 192 -and $Bytes[1] -eq 168)

    if (-not $IsPrivate) {
        throw "$ParameterName must be an RFC1918 private LAN address (10/8, 172.16/12, or 192.168/16)."
    }
}

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from PowerShell opened as Administrator.'
}

if ($Remove) {
    Remove-DashboardFirewallRules
    return
}

if ($null -eq $CoordinatorIP -or $null -eq $ClientIP -or $ClientIP.Count -eq 0) {
    throw 'CoordinatorIP and at least one ClientIP are required unless -Remove is used.'
}

Assert-PrivateIPv4 -Address $CoordinatorIP -ParameterName 'CoordinatorIP'
foreach ($Address in $ClientIP) {
    Assert-PrivateIPv4 -Address $Address -ParameterName 'ClientIP'
}

$LocalAddress = $CoordinatorIP.IPAddressToString
$AssignedAddress = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $LocalAddress -ErrorAction SilentlyContinue
if (-not $AssignedAddress) {
    throw "CoordinatorIP $LocalAddress is not currently assigned to this PC. Check DHCP/IP settings before opening the firewall."
}

$ClientAddresses = @($ClientIP | ForEach-Object { $_.IPAddressToString })
$UniqueClientAddresses = @($ClientAddresses | Select-Object -Unique)
if ($UniqueClientAddresses.Count -ne $ClientAddresses.Count) {
    throw 'ClientIP contains a duplicate address.'
}

$RuleParameters = @{
    Name                = $RuleName
    DisplayName         = 'GPUmates dashboard - designated LAN clients only'
    Description         = 'Allows only explicitly listed LAN clients to reach the read-only GPUmates dashboard.'
    Direction           = 'Inbound'
    Action              = 'Allow'
    Protocol            = 'TCP'
    LocalAddress        = $LocalAddress
    LocalPort           = $Port
    RemoteAddress       = $ClientAddresses
    Profile             = 'Any'
    EdgeTraversalPolicy = 'Block'
}

if (-not [string]::IsNullOrWhiteSpace($ProgramPath)) {
    $ResolvedProgram = (Resolve-Path -LiteralPath $ProgramPath -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $ResolvedProgram -PathType Leaf)) {
        throw "ProgramPath is not a file: $ResolvedProgram"
    }
    $RuleParameters.Program = $ResolvedProgram
}

Remove-DashboardFirewallRules

New-NetFirewallRule @RuleParameters | Out-Null

Write-Host "Created ${RuleName}: $($ClientAddresses -join ', ') -> ${LocalAddress}:$Port"
if ($RuleParameters.ContainsKey('Program')) {
    Write-Host "Program: $($RuleParameters.Program)"
}
else {
    Write-Host 'Program: any (the rule is still restricted by exact local IP, port, and client IPs).'
}
Write-Host 'Keep the dashboard access token enabled as a second layer of protection.'

