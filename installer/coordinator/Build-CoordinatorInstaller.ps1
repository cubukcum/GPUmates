[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$LauncherBuild = Join-Path $PSScriptRoot 'Build-CoordinatorLauncher.ps1'
$InstallerSource = Join-Path $PSScriptRoot 'GPUmatesCoordinator.iss'
$StaticIndex = Join-Path $ProjectRoot 'coordinator\static\index.html'
$ControlSources = @(
    (Join-Path $ProjectRoot 'dashboard\control\index.html'),
    (Join-Path $ProjectRoot 'dashboard\control\main.tsx'),
    (Join-Path $ProjectRoot 'dashboard\control\styles.css'),
    (Join-Path $ProjectRoot 'dashboard\vite.control.config.ts')
)

& $LauncherBuild
if ($LASTEXITCODE -ne 0) {
    throw "Coordinator launcher build failed with exit code $LASTEXITCODE."
}
if (-not (Test-Path -LiteralPath $StaticIndex -PathType Leaf)) {
    throw 'The Control Center web build is missing. Run pnpm run build:control in dashboard first.'
}
$StaticBuildTime = (Get-Item -LiteralPath $StaticIndex).LastWriteTimeUtc
$NewerSources = @($ControlSources | Where-Object {
        -not (Test-Path -LiteralPath $_ -PathType Leaf) -or (Get-Item -LiteralPath $_).LastWriteTimeUtc -gt $StaticBuildTime
    })
if ($NewerSources.Count -gt 0) {
    throw "The Control Center web build is stale. Run pnpm run build:control in dashboard first. Newer or missing source: $($NewerSources -join ', ')"
}
$IndexText = Get-Content -LiteralPath $StaticIndex -Raw
if ($IndexText -match '__GPUMATES_CONTROL_TOKEN__|gpumates-control-token') {
    throw 'The Control Center index still contains the legacy unauthenticated token placeholder.'
}

$CompilerCandidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
)
$Compiler = $CompilerCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($Compiler)) {
    throw 'Inno Setup 6 command-line compiler (ISCC.exe) was not found.'
}

$VersionMatch = Select-String -LiteralPath $InstallerSource -Pattern '^#define\s+AppVersion\s+"([^"]+)"$' | Select-Object -First 1
if ($null -eq $VersionMatch) {
    throw 'Could not read AppVersion from GPUmatesCoordinator.iss.'
}
$AppVersion = $VersionMatch.Matches[0].Groups[1].Value

& $Compiler $InstallerSource
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup compilation failed with exit code $LASTEXITCODE."
}

$OutputPath = Join-Path $ProjectRoot ("dist\installer\GPUmates-Coordinator-Setup-{0}.exe" -f $AppVersion)
$Hash = Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256
$ChecksumPath = "$OutputPath.sha256"
('{0}  {1}' -f $Hash.Hash, (Split-Path -Leaf $OutputPath)) | Set-Content -LiteralPath $ChecksumPath -Encoding ASCII

Write-Host "Built: $OutputPath"
Write-Host "SHA256: $($Hash.Hash)"
