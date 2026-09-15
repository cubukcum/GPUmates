[CmdletBinding()]
param([switch]$FrameworkChild)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $FrameworkChild) {
    $WindowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $WindowsPowerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath -FrameworkChild
    if ($LASTEXITCODE -ne 0) { throw 'Coordinator launcher network tests failed.' }
    return
}
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Launcher tests require Windows PowerShell and .NET Framework.' }

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$ProjectRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $ProjectRoot 'installer\coordinator\Build-CoordinatorLauncher.ps1')
$Assembly = [Reflection.Assembly]::LoadFile((Join-Path $ProjectRoot 'dist\coordinator\GPUmates-Coordinator.exe'))
$Program = $Assembly.GetType('GPUmates.Coordinator.Launcher.Program', $true)
$Flags = [Reflection.BindingFlags]'Static,NonPublic'
$ReadPort = $Program.GetMethod('ReadControlCenterPort', $Flags)
$ControlPortField = $Program.GetField('ControlCenterPort', $Flags)
$CreateStartInfo = $Program.GetMethod('CreateControlCenterStartInfo', $Flags)
$TemporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$TestRoot = [IO.Path]::GetFullPath((Join-Path $TemporaryParent ('gpumates-launcher-network-' + [Guid]::NewGuid().ToString('N'))))
if (-not $TestRoot.StartsWith($TemporaryParent, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test directory must stay inside the temporary directory.'
}
try {
    New-Item -ItemType Directory -Path (Join-Path $TestRoot 'config') -Force | Out-Null
    $NetworkPath = Join-Path $TestRoot 'config\network.json'
    Assert-Condition ($ReadPort.Invoke($null, @($TestRoot)) -eq 8091) 'Launcher must retain legacy default without saved config.'
    $ValidJson = '{"schemaVersion":1,"routerPort":18080,"dashboardPort":18090,"controlPort":18091}'
    [IO.File]::WriteAllText($NetworkPath, $ValidJson)
    $Port = $ReadPort.Invoke($null, @($TestRoot))
    Assert-Condition ($Port -eq 18091) 'Launcher must load the chosen Control Center port.'
    $ControlPortField.SetValue($null, $Port)
    Assert-Condition ($Program.GetProperty('HealthUrl', $Flags).GetValue($null, $null) -eq 'http://127.0.0.1:18091/health') 'Launcher health probes must use the chosen port.'
    Assert-Condition ($Program.GetProperty('ControlCenterUrl', $Flags).GetValue($null, $null) -eq 'http://127.0.0.1:18091/') 'Launcher browser links must use the chosen port.'
    $StartInfo = $CreateStartInfo.Invoke($null, @($TestRoot))
    Assert-Condition ($StartInfo.Arguments.EndsWith(' -Port 18091')) 'Launcher must pass the chosen port to PowerShell.'
    Assert-Condition ($StartInfo.CreateNoWindow -and $StartInfo.WindowStyle -eq [Diagnostics.ProcessWindowStyle]::Hidden) 'Launcher must retain hidden startup.'
    foreach ($InvalidJson in @(
        'not JSON', 'null', '[]', '{}',
        ('[' + $ValidJson + ']'),
        $ValidJson.Replace('"schemaVersion":1', '"schemaVersion":2'),
        $ValidJson.Replace('"schemaVersion":1', '"schemaVersion":"1"'),
        $ValidJson.Replace(',"controlPort":18091', ''),
        $ValidJson.Replace('18091', '1023'),
        $ValidJson.Replace('18091', '65536'),
        $ValidJson.Replace('18091', '"18091"'),
        $ValidJson.Replace('18091', '18091.5'),
        $ValidJson.Replace('18091', 'true'),
        $ValidJson.Replace('18091', 'null'),
        $ValidJson.Replace('18091', '18090')
    )) {
        [IO.File]::WriteAllText($NetworkPath, $InvalidJson)
        $Rejected = $false
        try { $ReadPort.Invoke($null, @($TestRoot)) | Out-Null }
        catch { $Rejected = $true }
        Assert-Condition $Rejected "Launcher must reject invalid config: $InvalidJson"
    }
    Write-Host '[PASS] Compiled launcher config validation, fallback, health/browser URLs, and hidden startup port arguments. No process or browser was started.'
}
finally {
    if ((Test-Path -LiteralPath $TestRoot) -and $TestRoot.StartsWith($TemporaryParent, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force
    }
}
