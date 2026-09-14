[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Rows = foreach ($Interface in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
    if ($Interface.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) {
        continue
    }
    if ($Interface.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) {
        continue
    }

    $IPv4Addresses = $Interface.GetIPProperties().UnicastAddresses |
        Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork }

    foreach ($Address in $IPv4Addresses) {
        [pscustomobject]@{
            Name = $Interface.Name
            Description = $Interface.Description
            LinkSpeedGbps = [math]::Round($Interface.Speed / 1000000000, 2)
            IPv4 = $Address.Address.IPAddressToString
            PrefixLength = $Address.PrefixLength
        }
    }
}

$Rows | Format-Table -AutoSize

try {
    Write-Host "`nWindows network profile:"
    Get-NetConnectionProfile -ErrorAction Stop |
        Select-Object InterfaceAlias, Name, NetworkCategory, IPv4Connectivity |
        Format-Table -AutoSize
}
catch {
    Write-Warning "Could not read the Windows network profile: $($_.Exception.Message)"
}
