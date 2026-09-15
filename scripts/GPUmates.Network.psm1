Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-GPUmatesNetworkConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $ConfigurationPath = Join-Path $ProjectRoot 'config\network.json'
    if (-not (Test-Path -LiteralPath $ConfigurationPath)) {
        return [pscustomobject][ordered]@{
            schemaVersion = 1
            routerPort = 8080
            dashboardPort = 8090
            controlPort = 8091
        }
    }

    try {
        $Json = Get-Content -LiteralPath $ConfigurationPath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($Json) -or -not $Json.TrimStart().StartsWith('{')) {
            throw 'Expected a JSON object.'
        }
        $Configuration = $Json | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $Configuration -or $Configuration -is [array]) {
            throw 'Expected a JSON object.'
        }
        $Version = $Configuration.PSObject.Properties['schemaVersion']
        if ($null -eq $Version -or ($Version.Value -isnot [int] -and $Version.Value -isnot [long]) -or $Version.Value -ne 1) {
            throw 'schemaVersion must be 1.'
        }
        $Ports = [ordered]@{ schemaVersion = 1 }
        foreach ($Name in @('routerPort', 'dashboardPort', 'controlPort')) {
            $Property = $Configuration.PSObject.Properties[$Name]
            if ($null -eq $Property -or ($Property.Value -isnot [int] -and $Property.Value -isnot [long]) -or
                $Property.Value -lt 1024 -or $Property.Value -gt 65535) {
                throw "$Name must be an integer between 1024 and 65535."
            }
            $Ports[$Name] = [int]$Property.Value
        }
        if (@(@($Ports.routerPort, $Ports.dashboardPort, $Ports.controlPort) | Select-Object -Unique).Count -ne 3) {
            throw 'Router, dashboard, and Control Center ports must be different.'
        }
        return [pscustomobject]$Ports
    }
    catch {
        throw "Invalid GPUmates network configuration at ${ConfigurationPath}: $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function Get-GPUmatesNetworkConfiguration
