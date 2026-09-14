[CmdletBinding()]
param([string]$ChatRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ChatRoot)) { $ChatRoot = $PSScriptRoot }
$RebuildHint = 'Run chat\Build-ChatUi.ps1 before building the installer.'
$ResolvedChatRoot = (Resolve-Path -LiteralPath $ChatRoot -ErrorAction Stop).Path
$StaticRoot = Join-Path $ResolvedChatRoot 'static'
$ManifestPath = Join-Path $StaticRoot 'gpumates-build.json'
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "The GPUmates chat build manifest is missing. $RebuildHint"
}
try {
    $Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($Manifest.schemaVersion -ne 1 -or $null -eq $Manifest.sources -or $null -eq $Manifest.files) {
        throw 'Unsupported manifest schema.'
    }
}
catch { throw "The GPUmates chat build manifest is invalid. $RebuildHint" }

function Assert-BuildHash {
    param([string]$Path, [string]$ExpectedHash, [string]$Label)
    if ($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$' -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "The GPUmates chat build is incomplete: $Label. $RebuildHint"
    }
    $ActualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($ActualHash -ne $ExpectedHash) {
        throw "The GPUmates chat build is stale or changed: $Label. $RebuildHint"
    }
}

foreach ($SourceName in @('gpu-bar.js', 'gpu-bar.css', 'Build-ChatUi.ps1')) {
    $SourceProperty = $Manifest.sources.PSObject.Properties[$SourceName]
    if ($null -eq $SourceProperty) { throw "Missing chat source hash: $SourceName. $RebuildHint" }
    Assert-BuildHash -Path (Join-Path $ResolvedChatRoot $SourceName) -ExpectedHash ([string]$SourceProperty.Value) -Label $SourceName
}

$StaticPrefix = [IO.Path]::GetFullPath($StaticRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$ManifestFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($Entry in @($Manifest.files)) {
    $RelativePath = [string]$Entry.path
    if ($RelativePath -notmatch '^[A-Za-z0-9_][A-Za-z0-9_./-]*$' -or
        @($RelativePath.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0 -or
        -not $ManifestFiles.Add($RelativePath)) {
        throw "The GPUmates chat manifest contains an invalid or repeated asset path. $RebuildHint"
    }
    $AssetPath = [IO.Path]::GetFullPath((Join-Path $StaticRoot $RelativePath))
    if (-not $AssetPath.StartsWith($StaticPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "A GPUmates chat asset resolves outside the bundle. $RebuildHint"
    }
    Assert-BuildHash -Path $AssetPath -ExpectedHash ([string]$Entry.sha256) -Label $RelativePath
}
foreach ($RequiredAsset in @('index.html', 'sw.js')) {
    if (-not $ManifestFiles.Contains($RequiredAsset)) { throw "The chat manifest is missing $RequiredAsset. $RebuildHint" }
}
foreach ($Asset in Get-ChildItem -LiteralPath $StaticRoot -Recurse -Force) {
    if (($Asset.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Chat assets cannot contain symbolic links or junctions. $RebuildHint"
    }
    if ($Asset.PSIsContainer) { continue }
    $RelativePath = $Asset.FullName.Substring($StaticPrefix.Length).Replace('\', '/')
    if ($RelativePath -ne 'gpumates-build.json' -and -not $ManifestFiles.Contains($RelativePath)) {
        throw "Untracked asset in GPUmates chat bundle: $RelativePath. $RebuildHint"
    }
}
Write-Host "GPUmates chat build verified: 3 source hashes and $($ManifestFiles.Count) asset hashes."
