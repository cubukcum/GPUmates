[CmdletBinding()]
param(
    [Parameter(Mandatory)][System.Net.IPAddress]$CoordinatorIP,
    [string]$ErrorPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

trap {
    if (-not [string]::IsNullOrWhiteSpace($ErrorPath)) {
        [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($ErrorPath), $_.Exception.Message)
    }
    exit 1
}

if ($CoordinatorIP.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw 'CoordinatorIP must be one IPv4 address.'
}
$CoordinatorAddress = $CoordinatorIP.IPAddressToString
$LocalIPv4 = @(
    [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.OperationalStatus -eq [System.Net.NetworkInformation.OperationalStatus]::Up } |
        ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
        Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
        ForEach-Object { $_.Address.IPAddressToString }
)
if ($CoordinatorAddress -notin $LocalIPv4) {
    throw "Coordinator IP $CoordinatorAddress is not assigned to an active interface on this PC."
}

$PortProbes = @(
    @([System.Net.IPAddress]::Loopback, 8080),
    @($CoordinatorIP, 8080),
    @($CoordinatorIP, 8090),
    @([System.Net.IPAddress]::Loopback, 8091)
)
foreach ($ProbeDefinition in $PortProbes) {
    $ProbeAddress = [System.Net.IPAddress]$ProbeDefinition[0]
    $ProbePort = [int]$ProbeDefinition[1]
    $Probe = [System.Net.Sockets.TcpListener]::new($ProbeAddress, $ProbePort)
    try {
        $Probe.Server.ExclusiveAddressUse = $true
        $Probe.Start()
    }
    catch {
        throw "TCP $($ProbeAddress.IPAddressToString):$ProbePort is already in use. Stop the old GPUmates router, dashboard, or Control Center before setup."
    }
    finally {
        $Probe.Stop()
    }
}

$NvidiaSmi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
if ($null -eq $NvidiaSmi) {
    throw 'nvidia-smi.exe was not found. Install a current NVIDIA driver first.'
}
$GpuNames = @(& $NvidiaSmi.Source --query-gpu=name --format=csv,noheader 2>$null)
if ($LASTEXITCODE -ne 0 -or $GpuNames.Count -eq 0) {
    throw 'No usable NVIDIA GPU was reported by the installed driver.'
}

$MissingRuntime = @(
    @('MSVCP140.dll', 'VCRUNTIME140.dll', 'VCRUNTIME140_1.dll') |
        Where-Object { -not (Test-Path -LiteralPath (Join-Path $env:SystemRoot "System32\$_") -PathType Leaf) }
)
if ($MissingRuntime.Count -gt 0) {
    throw ('Microsoft Visual C++ v14 x64 runtime is missing ({0}). Install https://aka.ms/vc14/vc_redist.x64.exe and rerun setup.' -f ($MissingRuntime -join ', '))
}

Write-Host "Coordinator preflight passed for $CoordinatorAddress with GPU: $($GpuNames -join ', ')"
