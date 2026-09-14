[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-PrivateIPv4Text {
    param([Parameter(Mandatory)][string]$Text)
    $Address = $null
    if (-not [System.Net.IPAddress]::TryParse($Text, [ref]$Address) -or
        $Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        return $false
    }
    $Bytes = $Address.GetAddressBytes()
    return $Bytes[0] -eq 10 -or
        ($Bytes[0] -eq 172 -and $Bytes[1] -ge 16 -and $Bytes[1] -le 31) -or
        ($Bytes[0] -eq 192 -and $Bytes[1] -eq 168)
}

$Candidates = @()
try {
    $Candidates = @(
        Get-NetIPConfiguration -ErrorAction Stop |
            Where-Object { $_.NetAdapter.Status -eq 'Up' } |
            ForEach-Object {
                $Configuration = $_
                foreach ($Address in @($Configuration.IPv4Address)) {
                    if (Test-PrivateIPv4Text -Text $Address.IPAddress) {
                        [pscustomobject]@{
                            IPAddress       = $Address.IPAddress
                            HasGateway      = $null -ne $Configuration.IPv4DefaultGateway
                            InterfaceMetric = [int]$Configuration.NetIPv4Interface.InterfaceMetric
                        }
                    }
                }
            } |
            Sort-Object @{ Expression = 'HasGateway'; Descending = $true }, InterfaceMetric
    )
}
catch {
    # CIM-backed network cmdlets may be restricted. The .NET fallback is read-only.
    $Candidates = @(
        [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
            Where-Object { $_.OperationalStatus -eq [System.Net.NetworkInformation.OperationalStatus]::Up } |
            ForEach-Object {
                $Properties = $_.GetIPProperties()
                foreach ($Address in $Properties.UnicastAddresses) {
                    $Text = $Address.Address.IPAddressToString
                    if (Test-PrivateIPv4Text -Text $Text) {
                        [pscustomobject]@{
                            IPAddress       = $Text
                            HasGateway      = @($Properties.GatewayAddresses).Count -gt 0
                            InterfaceMetric = 2147483647
                        }
                    }
                }
            } |
            Sort-Object @{ Expression = 'HasGateway'; Descending = $true }, IPAddress
    )
}

$DetectedAddress = if ($Candidates.Count -gt 0) { [string]$Candidates[0].IPAddress } else { '' }
[System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($OutputPath), $DetectedAddress)
