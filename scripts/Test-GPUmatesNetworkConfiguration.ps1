[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'GPUmates.Network.psm1') -Force

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Read-ScriptAst {
    param([string]$Path)
    $Tokens = $null
    $ParseErrors = $null
    $Ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$ParseErrors)
    if ($ParseErrors.Count -gt 0) { throw ($ParseErrors | Out-String) }
    return $Ast
}

$TemporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$TestRoot = [IO.Path]::GetFullPath((Join-Path $TemporaryParent ('gpumates-network-' + [Guid]::NewGuid().ToString('N'))))
if (-not $TestRoot.StartsWith($TemporaryParent, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test directory must stay inside the temporary directory.'
}
$Utf8 = [Text.UTF8Encoding]::new($false)
try {
    New-Item -ItemType Directory -Path (Join-Path $TestRoot 'config') -Force | Out-Null
    $NetworkPath = Join-Path $TestRoot 'config\network.json'
    $Defaults = Get-GPUmatesNetworkConfiguration -ProjectRoot $TestRoot
    Assert-Condition ($Defaults.routerPort -eq 8080 -and $Defaults.dashboardPort -eq 8090 -and $Defaults.controlPort -eq 8091) 'Existing installations without network.json must keep the default ports.'

    $ValidJson = '{"schemaVersion":1,"routerPort":18080,"dashboardPort":18090,"controlPort":18091}'
    [IO.File]::WriteAllText($NetworkPath, $ValidJson, $Utf8)
    $Network = Get-GPUmatesNetworkConfiguration -ProjectRoot $TestRoot
    Assert-Condition ($Network.routerPort -eq 18080 -and $Network.dashboardPort -eq 18090 -and $Network.controlPort -eq 18091) 'All three configured ports must load.'

    foreach ($InvalidJson in @(
        'not JSON', 'null', '[]', '{}',
        ('[' + $ValidJson + ']'),
        $ValidJson.Replace('"schemaVersion":1', '"schemaVersion":2'),
        $ValidJson.Replace('"schemaVersion":1', '"schemaVersion":"1"'),
        $ValidJson.Replace(',"controlPort":18091', ''),
        $ValidJson.Replace('18080', '1023'),
        $ValidJson.Replace('18080', '65536'),
        $ValidJson.Replace('18080', '"18080"'),
        $ValidJson.Replace('18080', '18080.5'),
        $ValidJson.Replace('18080', 'true'),
        $ValidJson.Replace('18080', 'null'),
        $ValidJson.Replace('18091', '18090')
    )) {
        [IO.File]::WriteAllText($NetworkPath, $InvalidJson, $Utf8)
        $Rejected = $false
        try { Get-GPUmatesNetworkConfiguration -ProjectRoot $TestRoot | Out-Null }
        catch { $Rejected = $true }
        Assert-Condition $Rejected "Invalid network configuration must fail: $InvalidJson"
    }
    [IO.File]::WriteAllText($NetworkPath, $ValidJson, $Utf8)
    Write-Host '[PASS] Saved port loading, default compatibility, and invalid configuration rejection.'

    # Exercise only the real installer's seed-writing statements against a temporary
    # project. Administrator checks, interface checks, and installation never run.
    $InstallAst = Read-ScriptAst -Path (Join-Path $PSScriptRoot 'Install-Coordinator.ps1')
    $SeedStatements = [Collections.Generic.List[string]]::new()
    $InSeed = $false
    foreach ($Statement in $InstallAst.EndBlock.Statements) {
        if ($Statement.Extent.Text.StartsWith('$ResolvedInstallRoot =')) { $InSeed = $true }
        if ($Statement.Extent.Text.StartsWith('if (Test-Path -LiteralPath $ModelPresetPath')) { break }
        if ($InSeed) { $SeedStatements.Add($Statement.Extent.Text) }
    }
    Assert-Condition ($SeedStatements.Count -gt 10) 'The install seed test must locate the actual configuration-writing block.'
    $SeedBlock = [scriptblock]::Create($InstallAst.ParamBlock.Extent.Text + [Environment]::NewLine +
        ('$PSScriptRoot = ''' + $PSScriptRoot.Replace("'", "''") + '''') + [Environment]::NewLine +
        '$CoordinatorAddress = $CoordinatorIP.IPAddressToString' + [Environment]::NewLine + ($SeedStatements -join [Environment]::NewLine))
    & $SeedBlock -CoordinatorIP '127.0.0.1' -NodeName 'Network Test' -InstallRoot $TestRoot -RouterPort 28080 -DashboardPort 28090 -ControlPort 28091
    $Network = Get-GPUmatesNetworkConfiguration -ProjectRoot $TestRoot
    $Telemetry = Get-Content -LiteralPath (Join-Path $TestRoot 'config\telemetry-nodes.json') -Raw | ConvertFrom-Json
    Assert-Condition ($Network.routerPort -eq 28080 -and $Network.dashboardPort -eq 28090 -and $Network.controlPort -eq 28091) 'Installation must persist the selected ports.'
    Assert-Condition ($Telemetry.llama.baseUrl -eq 'http://127.0.0.1:28080') 'Telemetry must use the installed router port.'
    Assert-Condition ($Telemetry.network.routerPort -eq 28080 -and $Telemetry.network.dashboardPort -eq 28090 -and $Telemetry.network.controlPort -eq 28091) 'Telemetry must expose the installed network ports to its direct consumers.'
    & $SeedBlock -CoordinatorIP '127.0.0.1' -NodeName 'Network Test' -InstallRoot $TestRoot
    $Network = Get-GPUmatesNetworkConfiguration -ProjectRoot $TestRoot
    Assert-Condition ($Network.routerPort -eq 28080 -and $Network.dashboardPort -eq 28090 -and $Network.controlPort -eq 28091) 'Omitted reinstall options must preserve saved ports.'
    $Rejected = $false
    try { & $SeedBlock -CoordinatorIP '127.0.0.1' -NodeName 'Network Test' -InstallRoot $TestRoot -RouterPort 28090 }
    catch { $Rejected = $true }
    Assert-Condition $Rejected 'Install must reject a port duplicated by a saved setting.'
    Write-Host '[PASS] Install seed persistence, telemetry URL, reinstall preservation, and duplicate prevention.'

    # Firewall cmdlets are mocked. Remove only the admin-check AST statements from
    # the fixture copy; run the actual selection, validation, and rule arguments.
    $FixtureScripts = Join-Path $TestRoot 'scripts'
    New-Item -ItemType Directory -Path $FixtureScripts -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $TestRoot 'runtime') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $TestRoot 'runtime\llama-server.exe'), '', $Utf8)
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'GPUmates.Network.psm1') -Destination $FixtureScripts
    $FirewallAst = Read-ScriptAst -Path (Join-Path $PSScriptRoot 'Configure-CoordinatorFirewall.ps1')
    $FirewallStatements = @($FirewallAst.EndBlock.Statements | Where-Object {
        $_.Extent.Text -notmatch '^\$(Identity|Principal)\s*=' -and
        $_.Extent.Text -notmatch '^if \(-not \$Principal\.IsInRole'
    } | ForEach-Object { $_.Extent.Text })
    $FirewallFixture = Join-Path $FixtureScripts 'Configure-CoordinatorFirewall.ps1'
    [IO.File]::WriteAllText($FirewallFixture, $FirewallAst.ParamBlock.Extent.Text + [Environment]::NewLine + ($FirewallStatements -join [Environment]::NewLine), $Utf8)
    $FirewallTestState = @{
        CreatedRules = @()
        RemovedRules = @()
        ExistingRuleNames = @('GPUmates-LlamaAPI-8080', 'GPUmates-LlamaAPI-18080', 'GPUmates-LlamaAPI-28080', 'GPUmates-LlamaAPI-38080', 'GPUmates-LlamaAPI-custom')
    }
    function Get-NetFirewallRule {
        param($Name, $ErrorAction)
        return @($FirewallTestState.ExistingRuleNames | Where-Object { $_ -like $Name } | ForEach-Object { [pscustomobject]@{ Name = $_ } })
    }
    function Get-NetFirewallApplicationFilter {
        param($AssociatedNetFirewallRule, $ErrorAction)
        $Program = if ($AssociatedNetFirewallRule.Name -eq 'GPUmates-LlamaAPI-38080') { 'C:\AnotherInstallation\llama-server.exe' } else { Join-Path $TestRoot 'runtime\llama-server.exe' }
        return [pscustomobject]@{ Program = $Program }
    }
    function Remove-NetFirewallRule { param($Name) $FirewallTestState.RemovedRules += $Name }
    function New-NetFirewallRule {
        param($Name, $DisplayName, $Description, $Direction, $Action, $Protocol, $LocalAddress, $LocalPort, $RemoteAddress, $Profile, $Program, $EdgeTraversalPolicy)
        $FirewallTestState.CreatedRules += [pscustomobject]$PSBoundParameters
    }
    & $FirewallFixture -CoordinatorIP '192.168.1.10' -ClientIP '192.168.1.20'
    Assert-Condition ($FirewallTestState.CreatedRules.Count -eq 1 -and $FirewallTestState.CreatedRules[0].Name -eq 'GPUmates-LlamaAPI-28080' -and $FirewallTestState.CreatedRules[0].LocalPort -eq 28080) 'Firewall must use the saved router port in its name and local port.'
    Assert-Condition ($FirewallTestState.CreatedRules[0].RemoteAddress.Count -eq 1 -and $FirewallTestState.CreatedRules[0].RemoteAddress[0] -eq '192.168.1.20') 'Firewall must retain exact designated-client restrictions.'
    Assert-Condition ($FirewallTestState.RemovedRules -contains 'GPUmates-LlamaAPI-8080') 'Moving from the old default must remove the legacy 8080 rule.'
    Assert-Condition ($FirewallTestState.RemovedRules -contains 'GPUmates-LlamaAPI-18080') 'Moving between custom ports must remove the previous custom port rule.'
    Assert-Condition ($FirewallTestState.RemovedRules -notcontains 'GPUmates-LlamaAPI-38080' -and $FirewallTestState.RemovedRules -notcontains 'GPUmates-LlamaAPI-custom') 'Cleanup must preserve another installation and names outside the numeric rule family.'
    $FirewallTestState.RemovedRules = @()
    & $FirewallFixture -Remove
    Assert-Condition ($FirewallTestState.RemovedRules -contains 'GPUmates-LlamaAPI-28080') 'Disable sharing must remove the configured rule.'
    Write-Host '[PASS] Mocked firewall port, allowed client, legacy-rule replacement, and removal checks.'

    $DashboardAst = Read-ScriptAst -Path (Join-Path $PSScriptRoot 'Configure-DashboardFirewall.ps1')
    $DashboardStatements = @($DashboardAst.EndBlock.Statements | Where-Object {
        $_.Extent.Text -notmatch '^\$(Identity|Principal)\s*=' -and
        $_.Extent.Text -notmatch '^if \(-not \$Principal\.IsInRole'
    } | ForEach-Object { $_.Extent.Text })
    $DashboardFixture = Join-Path $FixtureScripts 'Configure-DashboardFirewall.ps1'
    [IO.File]::WriteAllText($DashboardFixture, $DashboardAst.ParamBlock.Extent.Text + [Environment]::NewLine + ($DashboardStatements -join [Environment]::NewLine), $Utf8)
    function Get-NetIPAddress { param($AddressFamily, $IPAddress, $ErrorAction) return [pscustomobject]@{ IPAddress = $IPAddress } }
    $FirewallTestState.ExistingRuleNames = @('GPUmates-Dashboard-8090', 'GPUmates-Dashboard-18090', 'GPUmates-Dashboard-28090', 'GPUmates-Dashboard-custom')
    $FirewallTestState.CreatedRules = @()
    $FirewallTestState.RemovedRules = @()
    & $DashboardFixture -CoordinatorIP '192.168.1.10' -ClientIP '192.168.1.20'
    Assert-Condition ($FirewallTestState.CreatedRules.Count -eq 1 -and $FirewallTestState.CreatedRules[0].LocalPort -eq 28090) 'Dashboard firewall must use the configured port.'
    Assert-Condition ($FirewallTestState.RemovedRules -contains 'GPUmates-Dashboard-8090' -and $FirewallTestState.RemovedRules -contains 'GPUmates-Dashboard-18090') 'Dashboard port changes must revoke default and previous custom rules.'
    Assert-Condition ($FirewallTestState.RemovedRules -notcontains 'GPUmates-Dashboard-custom') 'Dashboard cleanup must match only the numeric rule family.'
    $FirewallTestState.RemovedRules = @()
    & $DashboardFixture -Remove
    Assert-Condition ($FirewallTestState.RemovedRules -contains 'GPUmates-Dashboard-28090') 'Disabling dashboard sharing must remove its saved-port rule.'
    Write-Host '[PASS] Mocked dashboard firewall configured port and old-port cleanup.'

    # Load only uninstall functions and replace process lookups/stops with stubs.
    $UninstallAst = Read-ScriptAst -Path (Join-Path $PSScriptRoot 'Uninstall-Coordinator.ps1')
    foreach ($Statement in $UninstallAst.EndBlock.Statements) {
        if ($Statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
            . ([scriptblock]::Create($Statement.Extent.Text.Replace('$PSScriptRoot', ("'" + $PSScriptRoot.Replace("'", "''") + "'"))))
        }
    }
    $ExpectedProjectRoot = Split-Path -Parent $PSScriptRoot
    $ExpectedControlScript = Join-Path $ExpectedProjectRoot 'scripts\Start-GPUmatesControlCenter.ps1'
    $ExpectedRouterExe = Join-Path $ExpectedProjectRoot 'runtime\llama-server.exe'
    $UninstallTestState = @{ StoppedIds = @() }
    function Get-ListeningOwnerIds { param($Port) return @(101, 102, 103) }
    function Get-CommandLine {
        param($ProcessId)
        switch ($ProcessId) {
            101 { return ('powershell.exe -File "' + $ExpectedControlScript + '" -Port 28091') }
            102 { return ('powershell.exe -File "' + $ExpectedControlScript + '.unrelated.ps1"') }
            103 { return ('powershell.exe -Command "Write-Output ' + $ExpectedControlScript + '"') }
        }
    }
    function Stop-Process { param($Id, [switch]$Force, $ErrorAction) $UninstallTestState.StoppedIds += $Id }
    Stop-ExpectedListener -Port 28091 -Service control
    Assert-Condition ($UninstallTestState.StoppedIds.Count -eq 1 -and $UninstallTestState.StoppedIds[0] -eq 101) 'Uninstall must stop only an exact Control Center script invocation.'
    function Resolve-Path { param($LiteralPath) return [pscustomobject]@{ Path = [IO.Path]::GetFullPath($LiteralPath) } }
    function Get-Process {
        param($Id, $ErrorAction)
        return [pscustomobject]@{ Path = $(if ($Id -eq 101) { $ExpectedRouterExe } else { 'C:\AnotherApp\llama-server.exe' }) }
    }
    $UninstallTestState.StoppedIds = @()
    Stop-ExpectedListener -Port 28080 -Service router
    Assert-Condition ($UninstallTestState.StoppedIds.Count -eq 1 -and $UninstallTestState.StoppedIds[0] -eq 101) 'Uninstall must not stop unrelated applications on a selected port.'
    Write-Host '[PASS] Mocked uninstall ownership checks preserve unrelated processes.'
}
finally {
    if ((Test-Path -LiteralPath $TestRoot) -and $TestRoot.StartsWith($TemporaryParent, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force
    }
}
