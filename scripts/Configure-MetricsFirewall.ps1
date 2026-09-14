[CmdletBinding()]
param(
    [System.Net.IPAddress]$CoordinatorIP,
    [Alias('WorkerIP', 'NodeIP')]
    [System.Net.IPAddress]$AgentIP,
    [ValidateRange(1024, 65535)]
    [int]$Port = 9835,
    [switch]$Remove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RuleName = "GPUmates-GPUMetrics-$Port"

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
    $ExistingRule = Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue
    if ($ExistingRule) {
        Remove-NetFirewallRule -Name $RuleName
        Write-Host "Removed firewall rule $RuleName."
    }
    else {
        Write-Host "Firewall rule $RuleName does not exist."
    }
    return
}

if ($null -eq $CoordinatorIP -or $null -eq $AgentIP) {
    throw 'CoordinatorIP and AgentIP are required unless -Remove is used.'
}

Assert-PrivateIPv4 -Address $CoordinatorIP -ParameterName 'CoordinatorIP'
Assert-PrivateIPv4 -Address $AgentIP -ParameterName 'AgentIP'

$LocalAddress = $AgentIP.IPAddressToString
$CoordinatorAddress = $CoordinatorIP.IPAddressToString
$AssignedAddress = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $LocalAddress -ErrorAction SilentlyContinue
if (-not $AssignedAddress) {
    throw "AgentIP $LocalAddress is not currently assigned to this PC. Check DHCP/IP settings before opening the firewall."
}

$ExistingRule = Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue
if ($ExistingRule) {
    Remove-NetFirewallRule -Name $RuleName
}

New-NetFirewallRule `
    -Name $RuleName `
    -DisplayName 'GPUmates GPU metrics - coordinator only' `
    -Description 'Allows only the designated GPUmates coordinator to read this node telemetry agent.' `
    -Direction Inbound `
    -Action Allow `
    -Protocol TCP `
    -LocalAddress $LocalAddress `
    -LocalPort $Port `
    -RemoteAddress $CoordinatorAddress `
    -Profile Any `
    -EdgeTraversalPolicy Block | Out-Null

Write-Host "Created ${RuleName}: $CoordinatorAddress -> ${LocalAddress}:$Port"
Write-Host 'No other LAN client is allowed through this rule. Keep the agent access token enabled too.'

