[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'GPUmates role cleanup must run as Administrator.'
}

$InstallRoot = Split-Path -Parent $PSScriptRoot
$MarkerPath = Join-Path $InstallRoot 'install-role.txt'
$MarkerRole = $null
if (Test-Path -LiteralPath $MarkerPath -PathType Leaf) {
    $MarkerRole = (Get-Content -LiteralPath $MarkerPath -Raw).Trim().ToLowerInvariant()
}
$RegistryRole = $null
$RegistryState = Get-ItemProperty -LiteralPath 'HKLM:\Software\GPUmates\Unified' -ErrorAction SilentlyContinue
if ($null -ne $RegistryState) {
    $RegistryRoleProperty = $RegistryState.PSObject.Properties['InstallRole']
    if ($null -ne $RegistryRoleProperty -and
        -not [string]::IsNullOrWhiteSpace([string]$RegistryRoleProperty.Value)) {
        $RegistryRole = ([string]$RegistryRoleProperty.Value).Trim().ToLowerInvariant()
    }
}
$ValidRoles = @('coordinator', 'worker')
if ($null -ne $MarkerRole -and $MarkerRole -notin $ValidRoles) {
    throw "Unsupported GPUmates role marker '$MarkerRole'. No role-specific cleanup was attempted."
}
if ($null -ne $RegistryRole -and $RegistryRole -notin $ValidRoles) {
    throw "Unsupported GPUmates registry role '$RegistryRole'. No role-specific cleanup was attempted."
}
if ($null -ne $MarkerRole -and $null -ne $RegistryRole -and $MarkerRole -ne $RegistryRole) {
    throw "GPUmates role marker '$MarkerRole' does not match registry role '$RegistryRole'. No cleanup was attempted."
}
$Role = if ($null -ne $MarkerRole) { $MarkerRole } else { $RegistryRole }
if ($null -eq $Role) {
    throw 'GPUmates role identity is missing from both the install marker and protected registry state. No cleanup was attempted.'
}
switch ($Role) {
    'coordinator' {
        $Cleanup = Join-Path $PSScriptRoot 'Uninstall-Coordinator.ps1'
        if (-not (Test-Path -LiteralPath $Cleanup -PathType Leaf)) {
            throw 'Coordinator cleanup script is missing.'
        }
        & $Cleanup
    }
    'worker' {
        $Cleanup = Join-Path $PSScriptRoot 'Uninstall-Worker.ps1'
        if (-not (Test-Path -LiteralPath $Cleanup -PathType Leaf)) {
            throw 'Worker cleanup script is missing.'
        }
        & $Cleanup

        $ProgramDataRoot = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)).TrimEnd('\')
        $WorkerData = [IO.Path]::GetFullPath((Join-Path $ProgramDataRoot 'GPUmates\Worker')).TrimEnd('\')
        $ExpectedPrefix = $ProgramDataRoot + '\GPUmates\'
        if (-not $WorkerData.StartsWith($ExpectedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals((Split-Path -Leaf $WorkerData), 'Worker', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove unexpected worker data path: $WorkerData"
        }
        if (Test-Path -LiteralPath $WorkerData) {
            Remove-Item -LiteralPath $WorkerData -Recurse -Force
        }
    }
}
