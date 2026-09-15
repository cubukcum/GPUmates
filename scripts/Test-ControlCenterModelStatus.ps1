[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'GPUmates.Network.psm1') -Force
$script:NetworkConfiguration = Get-GPUmatesNetworkConfiguration -ProjectRoot (Split-Path -Parent $PSScriptRoot)

# Load the real functions without starting a server or touching installed state.
$SourcePath = Join-Path $PSScriptRoot 'Start-GPUmatesControlCenter.ps1'
$Tokens = $null
$ParseErrors = $null
$Ast = [Management.Automation.Language.Parser]::ParseFile($SourcePath, [ref]$Tokens, [ref]$ParseErrors)
if ($ParseErrors.Count -gt 0) {
    throw ($ParseErrors | Out-String)
}
foreach ($Statement in $Ast.EndBlock.Statements) {
    if ($Statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($Statement.Extent.Text))
    }
}

# Model and configuration parsing stay real; only external services are stubbed.
$script:RouterRunning = $false
$script:RouterFails = $false
function Get-ManagedServiceState {
    param([string]$Service)
    return [pscustomobject]@{
        running = $Service -eq 'router' -and $script:RouterRunning
        conflict = $false
        error = $null
    }
}
function Invoke-RouterRequest {
    param($Method, $Path, $Body, $TimeoutSeconds)
    if ($script:RouterFails) { throw 'Router unavailable during test.' }
    return [pscustomobject]@{
        data = @([pscustomobject]@{ id = 'test-model'; status = 'loaded' })
    }
}
function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('gpumates-model-status-' + [Guid]::NewGuid().ToString('N'))
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
$ExpectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not $TestRoot.StartsWith($ExpectedParent, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test directory must be inside the temporary directory.'
}
New-Item -ItemType Directory -Path $TestRoot | Out-Null
try {
    $script:NodeConfigPath = Join-Path $TestRoot 'telemetry-nodes.json'
    $script:ControlConfigPath = Join-Path $TestRoot 'control.json'
    $script:ModelPresetPath = Join-Path $TestRoot 'gpumates-models.ini'
    $script:SecretsPath = Join-Path $TestRoot 'secrets.dpapi.json'
    $script:LastError = $null
    $Port = 8091
    @{
        schemaVersion = 1
        dashboard = @{ allowedClientIps = @('192.168.50.10') }
        nodes = @(@{
            name = 'Fresh Coordinator'; host = '127.0.0.1'; displayIp = '192.168.50.10'
            local = $true; port = 9835; role = 'coordinator'
        })
        llama = @{ enabled = $true; baseUrl = 'http://127.0.0.1:8080' }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:NodeConfigPath -Encoding UTF8

    foreach ($PresetText in @('', "version = 1`r`n", "; No models registered`r`nversion = 1`r`n", "version = 1`r`n[*]`r`nload-on-startup = false`r`n")) {
        [IO.File]::WriteAllText($script:ModelPresetPath, $PresetText)
        foreach ($Running in @($false, $true)) {
            $script:RouterRunning = $Running
            $Status = Get-ControlStatus | ConvertTo-Json -Depth 12 | ConvertFrom-Json
            Assert-Condition ($Status.models -is [array] -and $Status.models.Count -eq 0) 'Empty library must serialize as models: [].'
            Assert-Condition ($null -eq $Status.services.router.activeModel) 'Empty library must have no active model.'
            Assert-Condition (-not $Status.setup.complete) 'First-run setup must remain available without saved keys.'
            Assert-Condition ($Status.workers -is [array] -and $Status.workers.Count -eq 0) 'First-run status must support no workers.'
            Assert-Condition ($null -eq $Status.lastError) 'An empty model library must not create a coordinator error.'
        }
    }
    Write-Host '[PASS] First-run status with empty, version-only, commented, and defaults-only presets.'

    $ModelPath = Join-Path $TestRoot 'test.gguf'
    [IO.File]::WriteAllText($ModelPath, 'GGUF')
    [IO.File]::WriteAllText($script:ModelPresetPath, "version = 1`r`n[test-model]`r`nmodel = $ModelPath`r`n")
    $script:RouterRunning = $false
    $Status = Get-ControlStatus
    Assert-Condition ($Status.models.Count -eq 1 -and $Status.models[0].status -eq 'unavailable') 'Stopped router must retain registered models.'
    $script:RouterRunning = $true
    $Status = Get-ControlStatus
    Assert-Condition ($Status.models[0].status -eq 'loaded' -and $Status.services.router.activeModel -eq 'test-model') 'Running router must still report the loaded model.'
    $script:RouterFails = $true
    $Status = Get-ControlStatus
    Assert-Condition ($Status.models[0].status -eq 'unknown' -and $null -eq $Status.services.router.activeModel) 'Router failure must retain the existing fallback.'
    Write-Host '[PASS] Registered model status with stopped, running, and unavailable routers.'

    # Removing the final model returns an established coordinator to an empty library.
    [IO.File]::WriteAllText($script:ModelPresetPath, "version = 1`r`n")
    $Status = Get-ControlStatus
    Assert-Condition ($Status.models.Count -eq 0 -and $null -eq $Status.services.router.activeModel) 'Removing the last model must keep status available.'
    Write-Host '[PASS] Status remains available after the final model is removed.'
}
finally {
    Remove-Item -LiteralPath $TestRoot -Recurse -Force
}
