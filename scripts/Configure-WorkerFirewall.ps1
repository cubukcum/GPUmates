[CmdletBinding()]
param(
    [System.Net.IPAddress]$CoordinatorIP,
    [System.Net.IPAddress]$WorkerIP,
    [ValidateRange(1024, 65535)]
    [int]$Port = 50052,
    [switch]$Remove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RuleName = "GPUmates-LlamaRPC-$Port"

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
    $IsPrivate = $Bytes[0] -eq 10 -or
        ($Bytes[0] -eq 172 -and $Bytes[1] -ge 16 -and $Bytes[1] -le 31) -or
        ($Bytes[0] -eq 192 -and $Bytes[1] -eq 168)
    if (-not $IsPrivate) {
        throw "$ParameterName must be an RFC1918 private LAN address."
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

if ($null -eq $CoordinatorIP -or $null -eq $WorkerIP) {
    throw 'CoordinatorIP and WorkerIP are required unless -Remove is used.'
}
Assert-PrivateIPv4 -Address $CoordinatorIP -ParameterName 'CoordinatorIP'
Assert-PrivateIPv4 -Address $WorkerIP -ParameterName 'WorkerIP'
if ($CoordinatorIP.Equals($WorkerIP)) {
    throw 'CoordinatorIP and WorkerIP must be different addresses.'
}

$WorkerAddress = $WorkerIP.IPAddressToString
$AssignedAddress = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $WorkerAddress -ErrorAction SilentlyContinue
if (-not $AssignedAddress) {
    throw "WorkerIP $WorkerAddress is not currently assigned to this PC."
}

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$RpcExe = (Resolve-Path -LiteralPath (Join-Path $ProjectRoot 'runtime\ggml-rpc-server.exe')).Path

$ExistingRule = Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue
if ($ExistingRule) {
    Remove-NetFirewallRule -Name $RuleName
}

New-NetFirewallRule `
    -Name $RuleName `
    -DisplayName 'GPUmates llama.cpp RPC - coordinator only' `
    -Description 'Allows only the designated GPUmates coordinator to reach this llama.cpp RPC worker.' `
    -Direction Inbound `
    -Action Allow `
    -Protocol TCP `
    -LocalAddress $WorkerAddress `
    -LocalPort $Port `
    -RemoteAddress $CoordinatorIP.IPAddressToString `
    -Profile Any `
    -Program $RpcExe `
    -EdgeTraversalPolicy Block | Out-Null

Write-Host "Created ${RuleName}: $($CoordinatorIP.IPAddressToString) -> ${WorkerAddress}:$Port"
Write-Host "Program: $RpcExe"
