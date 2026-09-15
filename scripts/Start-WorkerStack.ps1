[CmdletBinding()]
param([string]$ConfigPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ProcessCommandLine {
    param([Parameter(Mandatory)][int]$ProcessId)
    try {
        return [string](Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop).CommandLine
    }
    catch {
        return $null
    }
}

function Get-ListeningOwnerIds {
    param([Parameter(Mandatory)][int]$Port)
    try {
        return @(
            Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop |
                ForEach-Object { [int]$_.OwningProcess } |
                Select-Object -Unique
        )
    }
    catch {
        $Pattern = '^\s*TCP\s+\S+:' + [regex]::Escape([string]$Port) + '\s+\S+\s+LISTENING\s+(\d+)\s*$'
        return @(
            & (Join-Path $env:SystemRoot 'System32\netstat.exe') -ano -p tcp 2>$null |
                ForEach-Object {
                    if ($_ -match $Pattern) {
                        [int]$Matches[1]
                    }
                } |
                Select-Object -Unique
        )
    }
}

function Test-ExpectedListener {
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][ValidateSet('rpc', 'telemetry')][string]$Service,
        [Parameter(Mandatory)][string]$ExpectedPath
    )

    $OwnerIds = @(Get-ListeningOwnerIds -Port $Port)
    if ($OwnerIds.Count -eq 0) {
        return $false
    }

    foreach ($OwnerId in $OwnerIds) {
        if ($Service -eq 'rpc') {
            try {
                $ProcessPath = (Get-Process -Id $OwnerId -ErrorAction Stop).Path
                if ([string]::Equals([System.IO.Path]::GetFullPath($ProcessPath), $ExpectedPath, [StringComparison]::OrdinalIgnoreCase)) {
                    return $true
                }
            }
            catch {
                # Report the listener as a conflict below.
            }
        }
        else {
            $CommandLine = Get-ProcessCommandLine -ProcessId $OwnerId
            if (-not [string]::IsNullOrWhiteSpace($CommandLine) -and
                $CommandLine.IndexOf($ExpectedPath, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return $true
            }
        }
    }

    throw "TCP port $Port is occupied by a process that is not this installed GPUmates $Service service. Stop the conflicting process and try again."
}

try {
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path $env:ProgramData 'GPUmates\Worker\worker.json'
    }
    $ResolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).Path
    $Configuration = Get-Content -LiteralPath $ResolvedConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $WorkerLauncher = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'Start-WorkerFromConfig.ps1')).Path
    $TelemetryLauncher = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'Start-TelemetryFromConfig.ps1')).Path
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
    $RpcExe = (Resolve-Path -LiteralPath (Join-Path $ProjectRoot 'runtime\ggml-rpc-server.exe')).Path

    # Validate both ports before starting either service so a conflict cannot
    # leave a partially started stack.
    $RpcAlreadyRunning = Test-ExpectedListener -Port ([int]$Configuration.rpcPort) -Service rpc -ExpectedPath $RpcExe
    $TelemetryAlreadyRunning = Test-ExpectedListener -Port ([int]$Configuration.telemetryPort) -Service telemetry -ExpectedPath $TelemetryLauncher

    if ($RpcAlreadyRunning) {
        Write-Host "The installed RPC worker is already running on port $($Configuration.rpcPort)."
    }
    else {
        $WorkerArguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -NoExit -File "{0}" -ConfigPath "{1}"' -f $WorkerLauncher, $ResolvedConfigPath
        Start-Process -FilePath $PowerShellExe -ArgumentList $WorkerArguments -WorkingDirectory $ProjectRoot -WindowStyle Normal | Out-Null
        Write-Host 'Started the visible RPC worker window.'
    }

    if ($TelemetryAlreadyRunning) {
        Write-Host "The installed telemetry agent is already running on port $($Configuration.telemetryPort)."
    }
    else {
        $TelemetryArguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -NoExit -File "{0}" -ConfigPath "{1}"' -f $TelemetryLauncher, $ResolvedConfigPath
        Start-Process -FilePath $PowerShellExe -ArgumentList $TelemetryArguments -WorkingDirectory $ProjectRoot -WindowStyle Normal | Out-Null
        Write-Host 'Started the visible telemetry window. The AgentKey is requested on first use or after changing the main PC.'
    }

    Write-Host 'Keep both service windows open while sharing this GPU. Use Ctrl+C in each window to stop.'
    Start-Sleep -Seconds 2
}
catch {
    Write-Host ''
    Write-Host "GPUmates Worker could not start: $($_.Exception.Message)" -ForegroundColor Red
    [void](Read-Host 'Press Enter to close')
    exit 1
}
