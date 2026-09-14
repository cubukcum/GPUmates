[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RequestBase64
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

try {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
    if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'The sharing helper must be approved in the Windows Administrator prompt.'
    }

    $RequestBytes = [Convert]::FromBase64String($RequestBase64)
    try {
        $RequestJson = [Text.Encoding]::UTF8.GetString($RequestBytes)
        $Request = $RequestJson | ConvertFrom-Json -ErrorAction Stop
    }
    finally {
        [Array]::Clear($RequestBytes, 0, $RequestBytes.Length)
        $RequestJson = $null
    }
    if ($Request.schemaVersion -ne 1) {
        throw 'Unsupported sharing request version.'
    }

    $ProjectRoot = (Resolve-Path -LiteralPath ([string]$Request.projectRoot) -ErrorAction Stop).Path
    $ExpectedHelper = (Resolve-Path -LiteralPath (Join-Path $ProjectRoot 'scripts\Apply-CoordinatorSharing.ps1') -ErrorAction Stop).Path
    if (-not [string]::Equals($ExpectedHelper, $PSCommandPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The sharing request does not belong to this GPUmates installation.'
    }

    $CoordinatorIP = [System.Net.IPAddress]([string]$Request.coordinatorIP)
    if (-not (Test-PrivateIPv4 -Address $CoordinatorIP)) {
        throw 'CoordinatorIP must be a private IPv4 address.'
    }
    $AssignedCoordinatorIP = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $CoordinatorIP.IPAddressToString -ErrorAction SilentlyContinue
    if (-not $AssignedCoordinatorIP) {
        throw "CoordinatorIP $($CoordinatorIP.IPAddressToString) is not assigned to this PC."
    }

    $ChatClients = @($Request.chatClientIps | ForEach-Object { [System.Net.IPAddress]$_ })
    $DashboardClients = @($Request.dashboardClientIps | ForEach-Object { [System.Net.IPAddress]$_ })
    foreach ($Address in @($ChatClients + $DashboardClients)) {
        if (-not (Test-PrivateIPv4 -Address $Address)) {
            throw 'Every client must be one exact private IPv4 address.'
        }
    }

    $CoordinatorFirewall = Join-Path $ProjectRoot 'scripts\Configure-CoordinatorFirewall.ps1'
    $DashboardFirewall = Join-Path $ProjectRoot 'scripts\Configure-DashboardFirewall.ps1'

    if ([bool]$Request.lanChatEnabled -and $ChatClients.Count -gt 0) {
        & $CoordinatorFirewall -CoordinatorIP $CoordinatorIP -ClientIP $ChatClients
    }
    else {
        & $CoordinatorFirewall -Remove
    }

    if ($DashboardClients.Count -gt 0) {
        & $DashboardFirewall -CoordinatorIP $CoordinatorIP -ClientIP $DashboardClients
    }
    else {
        & $DashboardFirewall -Remove
    }

    Write-Output 'Windows Firewall sharing rules were updated.'
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
