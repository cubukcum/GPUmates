[CmdletBinding(SupportsShouldProcess)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$SecretPath = Join-Path $env:LOCALAPPDATA 'GPUmates\Worker\agent-key.dpapi'

if (-not (Test-Path -LiteralPath $SecretPath -PathType Leaf)) {
    Write-Host 'No saved AgentKey exists for this Windows user.'
    return
}

if ($PSCmdlet.ShouldProcess($SecretPath, 'Delete the DPAPI-protected AgentKey')) {
    Remove-Item -LiteralPath $SecretPath -Force
    Write-Host 'The saved AgentKey was removed. It will be requested next time monitoring starts.'
}

