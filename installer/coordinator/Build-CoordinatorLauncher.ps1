[CmdletBinding()]
param(
    [Parameter(DontShow)]
    [switch]$CompilerChild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WindowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $WindowsPowerShell -PathType Leaf)) {
    throw "Windows PowerShell was not found: $WindowsPowerShell"
}

if (-not $CompilerChild) {
    & $WindowsPowerShell `
        -NoLogo `
        -NoProfile `
        -NonInteractive `
        -ExecutionPolicy Bypass `
        -File $PSCommandPath `
        -CompilerChild

    if ($LASTEXITCODE -ne 0) {
        throw "Windows PowerShell failed to build the coordinator launcher (exit code $LASTEXITCODE)."
    }

    return
}

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'The compiler child must run in Windows PowerShell to target the built-in .NET Framework.'
}

$ProjectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$SourcePath = Join-Path $ProjectRoot 'coordinator\launcher\GPUmates.Coordinator.Launcher.cs'
$OutputDirectory = Join-Path $ProjectRoot 'dist\coordinator'
$OutputPath = Join-Path $OutputDirectory 'GPUmates-Coordinator.exe'

if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
    throw "Coordinator launcher source was not found: $SourcePath"
}

[void](New-Item -ItemType Directory -Path $OutputDirectory -Force)

$TemporaryDirectory = Join-Path $OutputDirectory (
    '.launcher-build-{0}' -f [Guid]::NewGuid().ToString('N')
)
$ExpectedTemporaryParent = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\') + '\'
$ResolvedTemporaryDirectory = [IO.Path]::GetFullPath($TemporaryDirectory)
if (-not $ResolvedTemporaryDirectory.StartsWith($ExpectedTemporaryParent, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to use a temporary build directory outside $OutputDirectory"
}

[void](New-Item -ItemType Directory -Path $ResolvedTemporaryDirectory)
$TemporaryOutputPath = Join-Path $ResolvedTemporaryDirectory 'GPUmates-Coordinator.exe'

try {
    $Source = Get-Content -LiteralPath $SourcePath -Raw
    $FrameworkDirectory = [Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
    $References = @(
        (Join-Path $FrameworkDirectory 'System.dll')
        (Join-Path $FrameworkDirectory 'System.Core.dll')
        (Join-Path $FrameworkDirectory 'System.Security.dll')
        (Join-Path $FrameworkDirectory 'System.Windows.Forms.dll')
    )

    foreach ($Reference in $References) {
        if (-not (Test-Path -LiteralPath $Reference -PathType Leaf)) {
            throw "Required .NET Framework assembly was not found: $Reference"
        }
    }

    $CompilerParameters = New-Object System.CodeDom.Compiler.CompilerParameters
    $CompilerParameters.CompilerOptions = '/optimize+ /warnaserror+ /platform:anycpu /target:winexe'
    $CompilerParameters.GenerateExecutable = $true
    $CompilerParameters.GenerateInMemory = $false
    $CompilerParameters.OutputAssembly = $TemporaryOutputPath
    foreach ($Reference in $References) {
        [void]$CompilerParameters.ReferencedAssemblies.Add($Reference)
    }

    Add-Type `
        -TypeDefinition $Source `
        -Language CSharp `
        -CompilerParameters $CompilerParameters

    if (-not (Test-Path -LiteralPath $TemporaryOutputPath -PathType Leaf)) {
        throw 'The compiler completed without producing the coordinator launcher.'
    }

    if (Test-Path -LiteralPath $OutputPath) {
        Remove-Item -LiteralPath $OutputPath -Force
    }

    Move-Item -LiteralPath $TemporaryOutputPath -Destination $OutputPath
}
finally {
    if (Test-Path -LiteralPath $ResolvedTemporaryDirectory) {
        Remove-Item -LiteralPath $ResolvedTemporaryDirectory -Recurse -Force
    }
}

$OutputFile = Get-Item -LiteralPath $OutputPath
Write-Host "Built Windows GUI launcher: $($OutputFile.FullName)"
Write-Host "Size: $($OutputFile.Length) bytes"
