[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Exercise the real controller functions with temporary configuration and stubbed
# process launches. This test never starts inference or changes Windows Firewall.
$Tokens = $null
$ParseErrors = $null
$Ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'Start-GPUmatesControlCenter.ps1'), [ref]$Tokens, [ref]$ParseErrors)
if ($ParseErrors.Count -gt 0) { throw ($ParseErrors | Out-String) }
foreach ($Statement in $Ast.EndBlock.Statements) {
    if ($Statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($Statement.Extent.Text))
    }
}
function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$TestRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('gpumates-control-ports-' + [Guid]::NewGuid().ToString('N'))))
$ExpectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not $TestRoot.StartsWith($ExpectedParent, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test directory must be inside the temporary directory.'
}
New-Item -ItemType Directory -Path $TestRoot | Out-Null
try {
    $script:ProjectRoot = $TestRoot
    $script:NodeConfigPath = Join-Path $TestRoot 'telemetry-nodes.json'
    $script:ControlConfigPath = Join-Path $TestRoot 'control.json'
    $script:ModelPresetPath = Join-Path $TestRoot 'gpumates-models.ini'
    $script:RouterRuntimeConfigPath = Join-Path $TestRoot 'router-runtime.json'
    $script:LastError = $null
    $script:NetworkConfiguration = [pscustomobject]@{ schemaVersion = 1; routerPort = 18080; dashboardPort = 18090; controlPort = 18091 }
    $Port = 18091
    $CoordinatorIP = '192.168.50.10'
    @{
        schemaVersion = 1
        dashboard = @{ allowedClientIps = @($CoordinatorIP) }
        nodes = @(@{ name = 'Test'; host = '127.0.0.1'; displayIp = $CoordinatorIP; local = $true; port = 9835; role = 'coordinator' })
        llama = @{ enabled = $true; baseUrl = 'http://127.0.0.1:8080' }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:NodeConfigPath -Encoding UTF8
    [IO.File]::WriteAllText($script:ModelPresetPath, "version = 1`r`n")

    $script:ProbedPorts = @()
    function Get-ListeningOwnerIds {
        param([int]$PortNumber)
        $script:ProbedPorts += $PortNumber
        return @()
    }
    Get-ManagedServiceState -Service router | Out-Null
    Get-ManagedServiceState -Service dashboard | Out-Null
    Assert-Condition (($script:ProbedPorts -join ',') -eq '18080,18090') 'Service detection must probe the selected ports.'

    $script:ServicesRunning = $false
    function Get-ManagedServiceState {
        param([string]$Service)
        return [pscustomobject]@{ running = $script:ServicesRunning; conflict = $false; pids = @(); error = $null }
    }
    function Get-SavedSecrets { return @{ AgentKey = 'test-agent'; DashboardKey = 'test-dashboard'; LlamaApiKey = 'test-llama' } }
    function Wait-ManagedServiceState { param($Service, $Running, $TimeoutSeconds) return $true }
    $script:Launches = @{}
    function Start-HiddenPowerShellScript {
        param($Service, $ScriptPath, $ScriptArguments, $EnvironmentVariable)
        $script:Launches[$Service] = $ScriptArguments
        return $null
    }

    Set-DashboardLlamaConfiguration -LanChatEnabled $false -DashboardClientIps @()
    $Nodes = Read-NodeConfiguration
    Assert-Condition ($Nodes.llama.baseUrl -eq 'http://127.0.0.1:18080') 'Existing telemetry must migrate to the selected local chat port.'
    Assert-Condition ($Nodes.network.dashboardPort -eq 18090) 'Telemetry must carry the selected network configuration.'
    Assert-Condition (@($Nodes.dashboard.allowedClientIps).Count -eq 1) 'Empty sharing must keep the coordinator address.'
    Start-RouterService -WorkerIps $null
    $Runtime = Get-Content -LiteralPath $script:RouterRuntimeConfigPath -Raw | ConvertFrom-Json
    Assert-Condition ($Runtime.port -eq 18080 -and $Runtime.listenHost -eq '127.0.0.1') 'Local router startup must use the selected port.'
    Assert-Condition ($Runtime.dashboardBaseUrl -eq 'http://192.168.50.10:18090') 'Chat GPU statistics must target the selected dashboard port.'
    Start-DashboardService
    Assert-Condition ($script:Launches.dashboard -match '-Port 18090(?:\s|$)') 'Dashboard process arguments must include the selected port.'
    Assert-Condition ((Get-RouterBaseUrl) -eq 'http://127.0.0.1:18080') 'Local model API calls must use the selected port.'

    $Configuration = Get-ControlConfiguration
    $Configuration.sharing.lanChatEnabled = $true
    Save-ControlConfiguration -Configuration $Configuration
    Set-DashboardLlamaConfiguration -LanChatEnabled $true -DashboardClientIps @('192.168.50.20')
    $Nodes = Read-NodeConfiguration
    Assert-Condition ($Nodes.llama.baseUrl -eq 'http://192.168.50.10:18080' -and $Nodes.llama.publicUrl -eq $Nodes.llama.baseUrl) 'LAN URLs must use the selected port.'
    Start-RouterService -WorkerIps $null
    $Runtime = Get-Content -LiteralPath $script:RouterRuntimeConfigPath -Raw | ConvertFrom-Json
    Assert-Condition ($Runtime.port -eq 18080 -and $Runtime.listenHost -eq $CoordinatorIP) 'LAN router startup must retain the selected port.'
    $script:ServicesRunning = $true
    $Status = Get-ControlStatus
    Assert-Condition $Status.sharing.firewallUpdateRequired 'A port change must flag the need to reapply firewall rules.'
    Assert-Condition ($Status.urls.chat -eq 'http://192.168.50.10:18080' -and $Status.services.router.url -eq $Status.urls.chat) 'Status must advertise the selected chat URL.'
    Assert-Condition ($Status.urls.dashboard -eq 'http://192.168.50.10:18090' -and $Status.services.dashboard.url -eq $Status.urls.dashboard) 'Status must advertise the selected dashboard URL.'
    Assert-Condition ($Status.urls.control -eq 'http://127.0.0.1:18091' -and $Status.settings.controlPort -eq 18091) 'Administration must remain loopback on its selected port.'
    Save-ControlSettings -Body ([pscustomobject]@{ routerPort = 18080; dashboardPort = 18090 })
    $Rejected = $false
    try { Save-ControlSettings -Body ([pscustomobject]@{ routerPort = 8080 }) }
    catch { $Rejected = $_.Exception.Message -match 'rerunning Setup' }
    Assert-Condition $Rejected 'Settings must reject a stale port with instructions to rerun Setup.'
    function Invoke-ElevatedSharingHelper {
        param($LanChatEnabled, $ChatClientIps, $DashboardClientIps)
        return 'Simulated firewall success.'
    }
    $script:ServicesRunning = $false
    Apply-SharingConfiguration -Enabled $true -ChatClientIps @('192.168.50.20') -DashboardClientIps @('192.168.50.20') | Out-Null
    Assert-Condition (-not (Get-ControlStatus).sharing.firewallUpdateRequired) 'Successful Apply must record the new firewall ports and clear the warning.'
    Set-DashboardLlamaConfiguration -LanChatEnabled $false -DashboardClientIps @()
    $Nodes = Read-NodeConfiguration
    Assert-Condition ($null -eq $Nodes.llama.PSObject.Properties['publicUrl'] -and $Nodes.llama.baseUrl -eq 'http://127.0.0.1:18080') 'Disabling sharing must remove the public URL and keep the chosen local port.'
    Write-Host '[PASS] Selected ports propagate through service detection, startup, model API, telemetry, LAN sharing, status URLs, and settings.'
}
finally {
    Remove-Item -LiteralPath $TestRoot -Recurse -Force
}
