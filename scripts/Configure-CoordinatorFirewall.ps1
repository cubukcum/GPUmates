[CmdletBinding()]
param(
    [System.Net.IPAddress]$CoordinatorIP,
    [Alias('ClientIPs')]
    [System.Net.IPAddress[]]$ClientIP,
    [int]$Port = 8080,
    [switch]$Remove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RuleName = 'GPUmates-LlamaAPI-8080'

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

if ($null -eq $CoordinatorIP -or $null -eq $ClientIP -or $ClientIP.Count -eq 0) {
    throw 'CoordinatorIP and ClientIP are required unless -Remove is used.'
}
if ($CoordinatorIP.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw 'CoordinatorIP must be an IPv4 address.'
}
foreach ($Address in $ClientIP) {
    if ($Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw 'Every ClientIP must be an IPv4 address.'
    }
}

$ClientAddresses = @($ClientIP | ForEach-Object { $_.IPAddressToString })
$UniqueClientAddresses = @($ClientAddresses | Select-Object -Unique)
if ($UniqueClientAddresses.Count -ne $ClientAddresses.Count) {
    throw 'ClientIP contains a duplicate address.'
}

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ServerExe = (Resolve-Path -LiteralPath (Join-Path $ProjectRoot 'runtime\llama-server.exe')).Path

$ExistingRule = Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue
if ($ExistingRule) {
    Remove-NetFirewallRule -Name $RuleName
}

New-NetFirewallRule `
    -Name $RuleName `
    -DisplayName 'GPUmates llama-server API - designated clients only' `
    -Description 'Allows only the designated GPUmates clients to reach the shared llama-server API.' `
    -Direction Inbound `
    -Action Allow `
    -Protocol TCP `
    -LocalAddress $CoordinatorIP.IPAddressToString `
    -LocalPort $Port `
    -RemoteAddress $ClientAddresses `
    -Profile Any `
    -Program $ServerExe `
    -EdgeTraversalPolicy Block | Out-Null

Write-Host "Created ${RuleName}: $($ClientAddresses -join ', ') -> $($CoordinatorIP.IPAddressToString):$Port"
Write-Host "Program: $ServerExe"
