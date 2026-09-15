[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Exercise the production port checks without running setup, requiring a GPU,
# changing the firewall, or touching configuration/registry values.
$SourcePath = Join-Path $PSScriptRoot 'Test-CoordinatorInstallReady.ps1'
$Tokens = $null
$ParseErrors = $null
$Ast = [Management.Automation.Language.Parser]::ParseFile($SourcePath, [ref]$Tokens, [ref]$ParseErrors)
if ($ParseErrors.Count -gt 0) { throw ($ParseErrors | Out-String) }
$Checks = @($Ast.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $_.Name -in @('Assert-CoordinatorPortsAvailable', 'Assert-CoordinatorProcessesStopped')
})
if ($Checks.Count -ne 2) { throw 'Coordinator preflight functions were not found.' }
foreach ($Check in $Checks) { . ([scriptblock]::Create($Check.Extent.Text)) }

function Assert-Rejected {
    param([scriptblock]$Action, [string]$ExpectedMessage)
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike $ExpectedMessage) {
            throw "Unexpected rejection: $($_.Exception.Message)"
        }
        return
    }
    throw "Expected rejection matching: $ExpectedMessage"
}

$Loopback = [Net.IPAddress]::Loopback
$Reservations = @()
$Ports = @()
try {
    foreach ($Index in 0..2) {
        $Listener = [Net.Sockets.TcpListener]::new($Loopback, 0)
        $Listener.Server.ExclusiveAddressUse = $true
        $Listener.Start()
        $Reservations += $Listener
        $Ports += $Listener.LocalEndpoint.Port
    }
}
finally {
    foreach ($Listener in $Reservations) { $Listener.Stop() }
}
$Arguments = @{
    CoordinatorIP = $Loopback
    RouterPort = $Ports[0]
    DashboardPort = $Ports[1]
    ControlPort = $Ports[2]
}

Assert-CoordinatorPortsAvailable @Arguments
Write-Host '[PASS] Three custom free ports pass preflight.'

foreach ($Parameter in @('RouterPort', 'DashboardPort', 'ControlPort')) {
    foreach ($InvalidPort in @(0, 1023, 65536)) {
        $InvalidArguments = $Arguments.Clone()
        $InvalidArguments[$Parameter] = $InvalidPort
        Assert-Rejected { Assert-CoordinatorPortsAvailable @InvalidArguments } '*1024 to 65535*'
    }
}
foreach ($Pair in @(@('RouterPort', 'DashboardPort'), @('RouterPort', 'ControlPort'), @('DashboardPort', 'ControlPort'))) {
    $InvalidArguments = $Arguments.Clone()
    $InvalidArguments[$Pair[0]] = $InvalidArguments[$Pair[1]]
    Assert-Rejected { Assert-CoordinatorPortsAvailable @InvalidArguments } '*three different TCP ports*'
}
Write-Host '[PASS] Every port rejects invalid ranges and each duplicate pairing.'

foreach ($Index in 0..2) {
    $OccupiedPort = $Ports[$Index]
    $Listener = [Net.Sockets.TcpListener]::new($Loopback, $OccupiedPort)
    $Listener.Server.ExclusiveAddressUse = $true
    try {
        $Listener.Start()
        Assert-Rejected { Assert-CoordinatorPortsAvailable @Arguments } "*:$OccupiedPort*choose another port*"
    }
    finally { $Listener.Stop() }
    # Failed checks must release every successful probe so a retry can work.
    Assert-CoordinatorPortsAvailable @Arguments
}
Write-Host '[PASS] Occupied chat, dashboard, and Control Center ports identify the conflict; retry passes after release.'

foreach ($Index in 0..2) {
    $OccupiedPort = $Ports[$Index]
    $Listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse('127.0.0.2'), $OccupiedPort)
    $Listener.Server.ExclusiveAddressUse = $true
    try {
        $Listener.Start()
        Assert-Rejected { Assert-CoordinatorPortsAvailable @Arguments } "*127.0.0.2:$OccupiedPort*choose another port*"
    }
    finally { $Listener.Stop() }
}
Write-Host '[PASS] Listeners on another address cannot pass preflight for the same port.'

# Process enumeration is mocked: no existing application is inspected or stopped.
$script:ProcessSnapshot = @()
$script:EnumerationFails = $false
function Get-CimInstance {
    param([string]$ClassName, [string]$Filter, [string]$ErrorAction)
    if ($script:EnumerationFails) { throw 'Mock process enumeration failure.' }
    return $script:ProcessSnapshot
}
$TestInstallRoot = Join-Path ([IO.Path]::GetTempPath()) 'GPUmates port preflight test'
Assert-CoordinatorProcessesStopped -InstallRoot $TestInstallRoot
foreach ($ScriptName in @('Start-GPUmatesControlCenter.ps1', 'Start-GPUmatesDashboard.ps1', 'Start-ModelRouter.ps1', 'Start-ModelRouterFromControl.ps1', 'Start-Coordinator.ps1')) {
    $ExpectedScript = Join-Path $TestInstallRoot "scripts\$ScriptName"
    $script:ProcessSnapshot = @([pscustomobject]@{
        Name = 'powershell.exe'; ExecutablePath = $null
        CommandLine = 'powershell.exe -NoProfile -File "' + $ExpectedScript.ToUpperInvariant() + '" -Port 18091'
    })
    Assert-Rejected { Assert-CoordinatorProcessesStopped -InstallRoot $TestInstallRoot } '*still running*including when changing their ports*'
}
$UnquotedRoot = Join-Path ([IO.Path]::GetPathRoot($PSScriptRoot)) 'GPUmates-Port-Preflight-Test'
$script:ProcessSnapshot = @([pscustomobject]@{
    Name = 'pwsh.exe'; ExecutablePath = $null
    CommandLine = 'pwsh.exe -File ' + (Join-Path $UnquotedRoot 'scripts\Start-GPUmatesControlCenter.ps1')
})
Assert-Rejected { Assert-CoordinatorProcessesStopped -InstallRoot $UnquotedRoot } '*still running*'
$script:ProcessSnapshot = @([pscustomobject]@{
    Name = 'llama-server.exe'; CommandLine = $null
    ExecutablePath = (Join-Path $TestInstallRoot 'runtime\llama-server.exe').ToUpperInvariant()
})
Assert-Rejected { Assert-CoordinatorProcessesStopped -InstallRoot $TestInstallRoot } '*still running*'
Write-Host '[PASS] Existing owned Coordinator processes block upgrade regardless of their ports; quoted/unquoted and case-insensitive paths match.'

$script:ProcessSnapshot = @(
    [pscustomobject]@{
        Name = 'llama-server.exe'; CommandLine = $null
        ExecutablePath = Join-Path ($TestInstallRoot + '-other') 'runtime\llama-server.exe'
    },
    [pscustomobject]@{
        Name = 'powershell.exe'; ExecutablePath = $null
        CommandLine = 'powershell.exe -File "' + (Join-Path ($TestInstallRoot + '-other') 'scripts\Start-GPUmatesControlCenter.ps1') + '"'
    },
    [pscustomobject]@{
        Name = 'powershell.exe'; ExecutablePath = $null
        CommandLine = 'powershell.exe -File "' + (Join-Path $TestInstallRoot 'scripts\Start-GPUmatesControlCenter.ps1.backup') + '"'
    }
)
Assert-CoordinatorProcessesStopped -InstallRoot $TestInstallRoot
Write-Host '[PASS] Other installation paths and similarly named scripts do not block setup.'
$script:EnumerationFails = $true
Assert-Rejected { Assert-CoordinatorProcessesStopped -InstallRoot $TestInstallRoot } '*could not check for existing GPUmates processes*'
Write-Host '[PASS] Process enumeration failure produces an actionable preflight error.'
