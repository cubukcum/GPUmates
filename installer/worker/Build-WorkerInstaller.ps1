[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$InstallerSource = Join-Path $PSScriptRoot 'GPUmatesWorker.iss'
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
    throw 'Could not read AppVersion from GPUmatesWorker.iss.'
}
$AppVersion = $VersionMatch.Matches[0].Groups[1].Value

& $Compiler $InstallerSource
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup compilation failed with exit code $LASTEXITCODE."
}

$OutputPath = Join-Path $ProjectRoot ("dist\installer\GPUmates-Worker-Setup-{0}.exe" -f $AppVersion)
$Hash = Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256
$ChecksumPath = "$OutputPath.sha256"
('{0}  {1}' -f $Hash.Hash, (Split-Path -Leaf $OutputPath)) | Set-Content -LiteralPath $ChecksumPath -Encoding ASCII

Write-Host "Built: $OutputPath"
Write-Host "SHA256: $($Hash.Hash)"
