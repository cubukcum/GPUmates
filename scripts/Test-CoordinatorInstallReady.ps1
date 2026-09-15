[CmdletBinding()]
param(
    [Parameter(Mandatory)][System.Net.IPAddress]$CoordinatorIP,
    [int]$RouterPort = 8080,
    [int]$DashboardPort = 8090,
    [int]$ControlPort = 8091,
    [string]$InstallRoot,
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

function Assert-CoordinatorProcessesStopped {
    param([Parameter(Mandatory)][string]$InstallRoot)

    $ResolvedRoot = [IO.Path]::GetFullPath($InstallRoot)
    $ExpectedRouter = [IO.Path]::GetFullPath((Join-Path $ResolvedRoot 'runtime\llama-server.exe'))
    $ScriptPatterns = @(
        @('Start-GPUmatesControlCenter.ps1', 'Start-GPUmatesDashboard.ps1', 'Start-ModelRouter.ps1', 'Start-ModelRouterFromControl.ps1', 'Start-Coordinator.ps1') |
            ForEach-Object {
                $ScriptPath = [regex]::Escape([IO.Path]::GetFullPath((Join-Path $ResolvedRoot "scripts\$_")))
                '(?i)(?:^|\s)-File\s+(?:"' + $ScriptPath + '"|' + $ScriptPath + ')(?=\s|$)'
            }
    )
    try {
        $Processes = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe' OR Name = 'llama-server.exe'" -ErrorAction Stop)
    }
    catch {
        throw 'Setup could not check for existing GPUmates processes. Close GPUmates and retry setup as Administrator.'
    }
    foreach ($Process in $Processes) {
        $Owned = $false
        if ($Process.Name -ieq 'llama-server.exe' -and -not [string]::IsNullOrWhiteSpace([string]$Process.ExecutablePath)) {
            $Owned = [string]::Equals(
                [IO.Path]::GetFullPath([string]$Process.ExecutablePath), $ExpectedRouter,
                [StringComparison]::OrdinalIgnoreCase
            )
        }
        elseif ($Process.Name -iin @('powershell.exe', 'pwsh.exe')) {
            foreach ($Pattern in $ScriptPatterns) {
                if ([string]$Process.CommandLine -match $Pattern) {
                    $Owned = $true
                    break
                }
            }
        }
        if ($Owned) {
            throw 'GPUmates is still running from this installation folder. Close its Control Center, dashboard, and router before retrying setup, including when changing their ports.'
        }
    }
}

function Assert-CoordinatorPortsAvailable {
    param(
        [Parameter(Mandatory)][System.Net.IPAddress]$CoordinatorIP,
        [int]$RouterPort = 8080,
        [int]$DashboardPort = 8090,
        [int]$ControlPort = 8091
    )
    $Ports = @($RouterPort, $DashboardPort, $ControlPort)
    if (@($Ports | Where-Object { $_ -lt 1024 -or $_ -gt 65535 }).Count -gt 0) {
        throw 'Each Coordinator TCP port must be a whole number from 1024 to 65535.'
    }
    if (@($Ports | Select-Object -Unique).Count -ne 3) {
        throw 'Chat, dashboard, and Control Center must use three different TCP ports.'
    }
    # Runtime ownership checks consider every interface, including IPv6.
    # Match that policy before accepting a port that can bind on the selected IP.
    foreach ($Endpoint in [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()) {
        if ($Endpoint.Port -in $Ports) {
            $ServiceName = if ($Endpoint.Port -eq $RouterPort) { 'Chat / inference API' }
                elseif ($Endpoint.Port -eq $DashboardPort) { 'Dashboard' }
                else { 'Control Center' }
            throw "$ServiceName TCP $($Endpoint.Address):$($Endpoint.Port) is already in use. Go back to Main PC TCP ports and choose another port, or close the app using it before retrying."
        }
    }
    $PortProbes = @(
        @([System.Net.IPAddress]::Loopback, $RouterPort, 'Chat / inference API'),
        @($CoordinatorIP, $RouterPort, 'Chat / inference API'),
        @($CoordinatorIP, $DashboardPort, 'Dashboard'),
        @([System.Net.IPAddress]::Loopback, $ControlPort, 'Control Center')
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
            throw "$($ProbeDefinition[2]) TCP $($ProbeAddress.IPAddressToString):$ProbePort is already in use or unavailable. Go back to Main PC TCP ports and choose another port, or close the app using it before retrying."
        }
        finally {
            $Probe.Stop()
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) {
    Assert-CoordinatorProcessesStopped -InstallRoot $InstallRoot
}
Assert-CoordinatorPortsAvailable -CoordinatorIP $CoordinatorIP -RouterPort $RouterPort -DashboardPort $DashboardPort -ControlPort $ControlPort

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
