[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Helper = Join-Path $PSScriptRoot 'Prepare-GPUmatesChatUi.ps1'
$TemporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$TestRoot = [IO.Path]::GetFullPath((Join-Path $TemporaryParent ('gpumates-chat-ui-' + [Guid]::NewGuid().ToString('N'))))
if (-not $TestRoot.StartsWith($TemporaryParent, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test directory must stay inside the temporary directory.'
}
$TemplateRoot = Join-Path $TestRoot 'templates'
$OutputRoot = Join-Path $TestRoot 'prepared'
$Utf8 = [Text.UTF8Encoding]::new($false)

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

try {
    New-Item -ItemType Directory -Path (Join-Path $TemplateRoot 'assets') -Force | Out-Null
    $IndexTemplate = '<meta name="gpumates-dashboard-url" content="__GPUMATES_DASHBOARD_URL__"><main>Chat</main>'
    $WorkerTemplate = 'const revision = "__GPUMATES_INDEX_REVISION__";'
    [IO.File]::WriteAllText((Join-Path $TemplateRoot 'index.html'), $IndexTemplate, $Utf8)
    [IO.File]::WriteAllText((Join-Path $TemplateRoot 'sw.js'), $WorkerTemplate, $Utf8)
    [IO.File]::WriteAllText((Join-Path $TemplateRoot 'gpumates-build.json'), '{}', $Utf8)
    $SourceAsset = Join-Path $TemplateRoot 'assets\chat.js'
    [IO.File]::WriteAllText($SourceAsset, 'initial asset', $Utf8)

    $Prepared = & $Helper -DashboardPort 8090 -TemplateRoot $TemplateRoot -OutputRoot $OutputRoot -DashboardBaseUrl 'http://192.168.1.14:8090/'
    Assert-Condition ($Prepared -eq $OutputRoot) 'Helper must return its dedicated output directory.'
    $IndexPath = Join-Path $OutputRoot 'index.html'
    $WorkerPath = Join-Path $OutputRoot 'sw.js'
    $AssetPath = Join-Path $OutputRoot 'assets\chat.js'
    Assert-Condition ([IO.File]::ReadAllText($IndexPath).Contains('content="http://192.168.1.14:8090"')) 'The index must contain the normalized dashboard URL.'
    Assert-Condition ([IO.File]::ReadAllText((Join-Path $TemplateRoot 'index.html')) -eq $IndexTemplate) 'Preparing chat must not modify the installed index template.'
    Assert-Condition ([IO.File]::ReadAllText((Join-Path $TemplateRoot 'sw.js')) -eq $WorkerTemplate) 'Preparing chat must not modify the installed service worker.'
    $InitialHash = (Get-FileHash -LiteralPath $IndexPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Condition ([IO.File]::ReadAllText($WorkerPath).Contains($InitialHash)) 'The service worker must use the generated index hash.'

    # Lock the unchanged asset against writes. A repeat launch must skip copying it.
    $LockedAsset = [IO.File]::Open($AssetPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        & $Helper -DashboardPort 8090 -TemplateRoot $TemplateRoot -OutputRoot $OutputRoot -DashboardBaseUrl 'http://10.0.0.14:8090' | Out-Null
    }
    finally { $LockedAsset.Dispose() }
    $UpdatedHash = (Get-FileHash -LiteralPath $IndexPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Condition ($UpdatedHash -ne $InitialHash) 'Changing dashboard address must regenerate the index.'
    Assert-Condition ([IO.File]::ReadAllText($WorkerPath).Contains($UpdatedHash)) 'Changing dashboard address must update the cached index revision.'

    [IO.File]::WriteAllText($SourceAsset, 'updated asset with different length', $Utf8)
    & $Helper -DashboardPort 8090 -TemplateRoot $TemplateRoot -OutputRoot $OutputRoot -DashboardBaseUrl 'http://localhost:8090' | Out-Null
    Assert-Condition ([IO.File]::ReadAllText($AssetPath) -eq 'updated asset with different length') 'Updated build assets must replace prepared copies.'

    foreach ($Address in @('http://127.0.0.1:8090', 'http://172.16.0.1:8090', 'http://172.31.255.254:8090')) {
        & $Helper -DashboardPort 8090 -TemplateRoot $TemplateRoot -OutputRoot $OutputRoot -DashboardBaseUrl $Address | Out-Null
    }
    $RejectedUrls = @(
        'https://192.168.1.14:8090', 'http://8.8.8.8:8090', 'http://0.0.0.0:8090',
        'http://172.32.0.1:8090', 'http://192.168.1.14:8080', 'http://127.1:8090',
        'http://[::1]:8090', 'http://user@192.168.1.14:8090', 'http://192.168.1.14:8090/path',
        'http://192.168.1.14:8090/?key=value', 'http://192.168.1.14:8090/#fragment',
        'http://192.168.1.14:8090/" onload="bad', 'http://999.168.1.14:8090'
    )
    foreach ($Address in $RejectedUrls) {
        $Rejected = $false
        try { & $Helper -DashboardPort 8090 -TemplateRoot $TemplateRoot -OutputRoot $OutputRoot -DashboardBaseUrl $Address | Out-Null }
        catch { $Rejected = $true }
        Assert-Condition $Rejected "Dashboard URL should be rejected: $Address"
    }
    $DefaultPortHash = (Get-FileHash -LiteralPath $IndexPath -Algorithm SHA256).Hash
    & $Helper -DashboardPort 18090 -TemplateRoot $TemplateRoot -OutputRoot $OutputRoot -DashboardBaseUrl 'http://127.0.0.1:18090/' | Out-Null
    $CustomPortHash = (Get-FileHash -LiteralPath $IndexPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Condition ([IO.File]::ReadAllText($IndexPath).Contains('content="http://127.0.0.1:18090"')) 'A selected custom dashboard port must reach the chat index.'
    Assert-Condition ($CustomPortHash -ne $DefaultPortHash -and [IO.File]::ReadAllText($WorkerPath).Contains($CustomPortHash)) 'A changed dashboard port must refresh the cached index revision.'
    foreach ($Address in @('http://127.0.0.1:8090', 'http://127.0.0.1:18091', 'http://8.8.8.8:18090', 'http://user@127.0.0.1:18090', 'http://127.0.0.1:18090/path')) {
        $Rejected = $false
        try { & $Helper -DashboardPort 18090 -TemplateRoot $TemplateRoot -OutputRoot $OutputRoot -DashboardBaseUrl $Address | Out-Null }
        catch { $Rejected = $true }
        Assert-Condition $Rejected "Custom dashboard configuration must reject unselected ports and unsafe URLs: $Address"
    }
    foreach ($UnsafeOutput in @($TemplateRoot, (Join-Path $TemplateRoot 'nested'), $TestRoot)) {
        $Rejected = $false
        try { & $Helper -DashboardPort 8090 -TemplateRoot $TemplateRoot -OutputRoot $UnsafeOutput -DashboardBaseUrl 'http://127.0.0.1:8090' | Out-Null }
        catch { $Rejected = $true }
        Assert-Condition $Rejected 'Overlapping template and output directories must be rejected.'
    }
    Write-Host 'Chat UI preparation checks passed: URL validation, template preservation, incremental asset copies, index revision refresh, and directory isolation.'
}
finally {
    if ((Test-Path -LiteralPath $TestRoot) -and $TestRoot.StartsWith($TemporaryParent, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force
    }
}
