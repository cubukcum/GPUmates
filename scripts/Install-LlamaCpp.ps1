[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}

$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$DownloadRoot = Join-Path $ProjectRoot 'downloads'
$RuntimeRoot = Join-Path $ProjectRoot 'runtime'
$ReleaseBase = 'https://github.com/ggml-org/llama.cpp/releases/download/b10488'

$Assets = @(
    [pscustomobject]@{
        Name = 'llama-b10488-bin-win-cuda-13.3-x64.zip'
        Uri = "$ReleaseBase/llama-b10488-bin-win-cuda-13.3-x64.zip"
        Sha256 = 'f4ea53c2e7f3d295cb9fd092515d50af4969266b4cdae01f03a1cbaa8b4d9af0'
    },
    [pscustomobject]@{
        Name = 'cudart-llama-bin-win-cuda-13.3-x64.zip'
        Uri = "$ReleaseBase/cudart-llama-bin-win-cuda-13.3-x64.zip"
        Sha256 = '1462a050eb4c684921ba51dcc4cc488a036674c3e73e9945ee705b854808d03e'
    }
)

$ExecutableNames = @(
    'llama-server.exe',
    'llama-bench.exe',
    'ggml-rpc-server.exe'
)

$RequiredFiles = @(
    'llama-server.exe',
    'llama-bench.exe',
    'ggml-rpc-server.exe',
    'ggml-cuda.dll',
    'ggml-rpc.dll',
    'cudart64_13.dll',
    'cublas64_13.dll',
    'cublasLt64_13.dll'
)

New-Item -ItemType Directory -Force -Path $DownloadRoot | Out-Null

foreach ($Asset in $Assets) {
    $ArchivePath = Join-Path $DownloadRoot $Asset.Name

    if (Test-Path -LiteralPath $ArchivePath) {
        $CurrentHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($CurrentHash -ne $Asset.Sha256) {
            if (-not $Force) {
                throw "Hash mismatch for $ArchivePath. Re-run with -Force to preserve it as .invalid and download a clean copy."
            }

            $Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            Move-Item -LiteralPath $ArchivePath -Destination "$ArchivePath.invalid-$Timestamp"
        }
    }

    if (-not (Test-Path -LiteralPath $ArchivePath)) {
        Write-Host "Downloading $($Asset.Name)..."
        Invoke-WebRequest -Uri $Asset.Uri -OutFile $ArchivePath -UseBasicParsing
    }

    $DownloadedHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($DownloadedHash -ne $Asset.Sha256) {
        throw "Downloaded hash mismatch for $ArchivePath. Expected $($Asset.Sha256), received $DownloadedHash."
    }
}

$StagingRoot = Join-Path $ProjectRoot ('.runtime-staging-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $StagingRoot | Out-Null

try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    foreach ($Asset in $Assets) {
        $ArchivePath = Join-Path $DownloadRoot $Asset.Name
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)

        try {
            foreach ($Entry in $Archive.Entries) {
                $LeafName = [System.IO.Path]::GetFileName($Entry.FullName)
                if ([string]::IsNullOrWhiteSpace($LeafName)) {
                    continue
                }

                $IsRequiredExecutable = $LeafName -in $ExecutableNames
                $IsRuntimeLibrary = [System.IO.Path]::GetExtension($LeafName) -eq '.dll'
                if (-not ($IsRequiredExecutable -or $IsRuntimeLibrary)) {
                    continue
                }

                $DestinationPath = Join-Path $StagingRoot $LeafName
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile(
                    $Entry,
                    $DestinationPath,
                    $true
                )
            }
        }
        finally {
            $Archive.Dispose()
        }
    }

    foreach ($RequiredFile in $RequiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $StagingRoot $RequiredFile))) {
            throw "The release archives did not contain required file: $RequiredFile"
        }
    }

    New-Item -ItemType Directory -Force -Path $RuntimeRoot | Out-Null

    # The official archive contains many unrelated command-line utilities. This
    # two-PC kit needs only the server, benchmark, RPC worker, and their DLLs.
    # Keeping the portable runtime narrow also avoids copying tools that endpoint
    # security products may classify as dual-use utilities.
    Get-ChildItem -LiteralPath $StagingRoot -File |
        Where-Object { $_.Extension -eq '.dll' -or $_.Name -in $ExecutableNames } |
        Copy-Item -Destination $RuntimeRoot -Force
}
finally {
    if (Test-Path -LiteralPath $StagingRoot) {
        Remove-Item -LiteralPath $StagingRoot -Recurse -Force
    }
}

$VersionOutput = & (Join-Path $RuntimeRoot 'llama-server.exe') --version 2>&1
if ($LASTEXITCODE -ne 0 -or ($VersionOutput -join "`n") -notmatch 'build 10488') {
    throw "llama-server validation failed: $($VersionOutput -join ' ')"
}

Write-Host ($VersionOutput -join "`n")
Write-Host "Installed and verified llama.cpp b10488 at $RuntimeRoot"
