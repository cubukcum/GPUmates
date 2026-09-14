[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Coordinator', 'Agent')]
    [string]$Role,
    [Parameter(Mandatory)]
    [System.Net.IPAddress]$ListenIP,
    [System.Net.IPAddress]$CoordinatorIP = '172.25.50.14',
    [System.Net.IPAddress[]]$ClientIP,
    [ValidateRange(1024, 65535)]
    [int]$DashboardPort = 8090,
    [ValidateRange(1024, 65535)]
    [int]$MetricsPort = 9835,
    [string]$NodeConfig,
    [switch]$SkipHttp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Results = [System.Collections.Generic.List[object]]::new()
if ([string]::IsNullOrWhiteSpace($NodeConfig)) {
    $NodeConfig = Join-Path (Split-Path -Parent $PSScriptRoot) 'config\telemetry-nodes.json'
}

function Add-CheckResult {
    param(
        [string]$Check,
        [bool]$Passed,
        [string]$Details
    )

    $Results.Add([pscustomobject]@{
        Check   = $Check
        Result  = $(if ($Passed) { 'PASS' } else { 'FAIL' })
        Details = $Details
    })
}

function Test-ExpectedFirewallRule {
    param(
        [string]$RuleName,
        [string]$ExpectedLocalAddress,
        [string[]]$ExpectedRemoteAddress,
        [int]$ExpectedPort
    )

    $Rule = Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue
    if (-not $Rule) {
        Add-CheckResult -Check 'Firewall rule' -Passed $false -Details "Missing rule $RuleName."
        return
    }

    $PortFilter = $Rule | Get-NetFirewallPortFilter
    $AddressFilter = $Rule | Get-NetFirewallAddressFilter
    $ActualRemoteAddress = @($AddressFilter.RemoteAddress | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $WantedRemoteAddress = @($ExpectedRemoteAddress | Sort-Object -Unique)
    $RemoteMatches = ($ActualRemoteAddress.Count -eq $WantedRemoteAddress.Count) -and
        -not (Compare-Object -ReferenceObject $WantedRemoteAddress -DifferenceObject $ActualRemoteAddress)
    $LocalMatches = @($AddressFilter.LocalAddress) -contains $ExpectedLocalAddress
    $RuleShapeMatches =
        $Rule.Enabled -eq 'True' -and
        $Rule.Direction -eq 'Inbound' -and
        $Rule.Action -eq 'Allow' -and
        $Rule.EdgeTraversalPolicy -eq 'Block' -and
        $PortFilter.Protocol -eq 'TCP' -and
        @($PortFilter.LocalPort) -contains [string]$ExpectedPort -and
        $LocalMatches -and
        $RemoteMatches

    $Summary = "local=$($AddressFilter.LocalAddress -join ','); remote=$($ActualRemoteAddress -join ','); port=$($PortFilter.LocalPort -join ',')"
    Add-CheckResult -Check 'Firewall rule' -Passed $RuleShapeMatches -Details $Summary
}

function Get-HttpStatusWithoutThrowing {
    param(
        [string]$Uri,
        [hashtable]$Headers = @{}
    )

    try {
        $Response = Invoke-WebRequest -UseBasicParsing -Uri $Uri -Headers $Headers -TimeoutSec 4
        return [int]$Response.StatusCode
    }
    catch {
        if ($null -ne $_.Exception.Response) {
            return [int]$_.Exception.Response.StatusCode
        }
        return 0
    }
}

if ($ListenIP.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw 'ListenIP must be IPv4.'
}
if ($CoordinatorIP.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw 'CoordinatorIP must be IPv4.'
}

$ListenAddress = $ListenIP.IPAddressToString
$AssignedAddress = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $ListenAddress -ErrorAction SilentlyContinue
Add-CheckResult `
    -Check 'Listen IP assigned locally' `
    -Passed ($null -ne $AssignedAddress) `
    -Details $ListenAddress

if ($Role -eq 'Coordinator') {
    if ($null -eq $ClientIP -or $ClientIP.Count -eq 0) {
        throw 'ClientIP is required when Role is Coordinator.'
    }
    $ExpectedClients = @($ClientIP | ForEach-Object { $_.IPAddressToString })
    Test-ExpectedFirewallRule `
        -RuleName "GPUmates-Dashboard-$DashboardPort" `
        -ExpectedLocalAddress $ListenAddress `
        -ExpectedRemoteAddress $ExpectedClients `
        -ExpectedPort $DashboardPort

    $Configuration = Get-Content -LiteralPath (Resolve-Path -LiteralPath $NodeConfig).Path -Raw | ConvertFrom-Json
    $ConfiguredClients = @($Configuration.dashboard.allowedClientIps | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $ExpectedApplicationClients = @($ExpectedClients + $ListenAddress | Sort-Object -Unique)
    $ApplicationListMatches = ($ConfiguredClients.Count -eq $ExpectedApplicationClients.Count) -and
        -not (Compare-Object -ReferenceObject $ExpectedApplicationClients -DifferenceObject $ConfiguredClients)
    Add-CheckResult `
        -Check 'Dashboard application IP allowlist' `
        -Passed $ApplicationListMatches `
        -Details "configured=$($ConfiguredClients -join ',')"

    if (-not $SkipHttp) {
        $ApiUri = "http://${ListenAddress}:$DashboardPort/api/v1/cluster"
        $AnonymousStatus = Get-HttpStatusWithoutThrowing -Uri $ApiUri
        Add-CheckResult `
            -Check 'Dashboard API rejects anonymous requests' `
            -Passed ($AnonymousStatus -in @(401, 403)) `
            -Details "HTTP $AnonymousStatus"

        $DashboardKey = [Environment]::GetEnvironmentVariable('GPUMATES_DASHBOARD_KEY', 'Process')
        if ([string]::IsNullOrWhiteSpace($DashboardKey)) {
            Add-CheckResult -Check 'Authorized dashboard request' -Passed $false -Details 'GPUMATES_DASHBOARD_KEY is not set in this process.'
        }
        else {
            $AuthorizedStatus = Get-HttpStatusWithoutThrowing -Uri $ApiUri -Headers @{ 'X-GPUmates-Key' = $DashboardKey }
            Add-CheckResult -Check 'Authorized dashboard request' -Passed ($AuthorizedStatus -eq 200) -Details "HTTP $AuthorizedStatus"
        }
    }
}
else {
    Test-ExpectedFirewallRule `
        -RuleName "GPUmates-GPUMetrics-$MetricsPort" `
        -ExpectedLocalAddress $ListenAddress `
        -ExpectedRemoteAddress @($CoordinatorIP.IPAddressToString) `
        -ExpectedPort $MetricsPort

    if (-not $SkipHttp) {
        $MetricsUri = "http://${ListenAddress}:$MetricsPort/api/v1/metrics"
        $AnonymousStatus = Get-HttpStatusWithoutThrowing -Uri $MetricsUri
        Add-CheckResult `
            -Check 'Metrics agent rejects anonymous requests' `
            -Passed ($AnonymousStatus -in @(401, 403)) `
            -Details "HTTP $AnonymousStatus"

        $AgentKey = [Environment]::GetEnvironmentVariable('GPUMATES_AGENT_KEY', 'Process')
        if ([string]::IsNullOrWhiteSpace($AgentKey)) {
            Add-CheckResult -Check 'Authorized metrics request' -Passed $false -Details 'GPUMATES_AGENT_KEY is not set in this process.'
        }
        elseif ($AnonymousStatus -eq 403) {
            Add-CheckResult `
                -Check 'Agent source-IP restriction' `
                -Passed $true `
                -Details 'This local worker is not the coordinator, so the agent correctly refused the connection before token authentication.'
        }
        else {
            $AuthorizedStatus = Get-HttpStatusWithoutThrowing -Uri $MetricsUri -Headers @{ 'X-GPUmates-Agent-Key' = $AgentKey }
            Add-CheckResult -Check 'Authorized metrics request' -Passed ($AuthorizedStatus -eq 200) -Details "HTTP $AuthorizedStatus"
        }
    }
}

$Results | Format-Table -AutoSize
$FailedResults = @($Results | Where-Object Result -eq 'FAIL')
if ($FailedResults.Count -gt 0) {
    throw "$($FailedResults.Count) dashboard security check(s) failed."
}

Write-Host 'All requested dashboard security checks passed.'
