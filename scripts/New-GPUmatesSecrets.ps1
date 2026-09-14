[CmdletBinding()]
param(
    [ValidateRange(24, 128)]
    [int]$ByteCount = 32
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-CryptographicSecret {
    param([Parameter(Mandatory)][int]$Length)

    $Bytes = [byte[]]::new($Length)
    $Generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $Generator.GetBytes($Bytes)
        return [Convert]::ToBase64String($Bytes)
    }
    finally {
        $Generator.Dispose()
    }
}

[pscustomobject]@{
    AgentKey     = New-CryptographicSecret -Length $ByteCount
    DashboardKey = New-CryptographicSecret -Length $ByteCount
}
