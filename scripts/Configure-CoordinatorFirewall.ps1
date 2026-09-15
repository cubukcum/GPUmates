[CmdletBinding()]
param(
    [System.Net.IPAddress]$CoordinatorIP,
    [Alias('ClientIPs')]
    [System.Net.IPAddress[]]$ClientIP,
    [ValidateRange(1024, 65535)][int]$Port = 8080,
    [switch]$Remove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'GPUmates.Network.psm1') -Force
if (-not $PSBoundParameters.ContainsKey('Port')) {
    $Port = (Get-GPUmatesNetworkConfiguration -ProjectRoot $ProjectRoot).routerPort
}
$RuleName = "GPUmates-LlamaAPI-$Port"
$ExpectedProgram = [IO.Path]::GetFullPath((Join-Path $ProjectRoot 'runtime\llama-server.exe'))

function Remove-InstallationFirewallRules {
    # The executable path keeps other GPUmates installations' rules untouched.
    # Remove the entire numeric rule family so changing custom ports revokes the
    # previous port as well as installations' legacy 8080 rule.
    $ExistingRules = @(Get-NetFirewallRule -Name 'GPUmates-LlamaAPI-*' -ErrorAction SilentlyContinue)
    foreach ($ExistingRule in $ExistingRules) {
        if ($ExistingRule.Name -notmatch '^GPUmates-LlamaAPI-\d+$') { continue }
        $Applications = @(Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $ExistingRule -ErrorAction Stop)
        foreach ($Application in $Applications) {
            if ([string]::Equals([string]$Application.Program, $ExpectedProgram, [StringComparison]::OrdinalIgnoreCase)) {
                Remove-NetFirewallRule -Name $ExistingRule.Name
                Write-Host "Removed firewall rule $($ExistingRule.Name)."
                break
            }
        }
    }
}

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from PowerShell opened as Administrator.'
}

if ($Remove) {
    Remove-InstallationFirewallRules
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

$ServerExe = (Resolve-Path -LiteralPath (Join-Path $ProjectRoot 'runtime\llama-server.exe')).Path

Remove-InstallationFirewallRules

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
