[CmdletBinding()]
param(
    [Alias('Mode')]
    [ValidateSet('Status', 'Enable', 'Disable', 'Clear', 'ClearCache')]
    [string]$Action,

    [string]$ConfigPath,

    [switch]$ConfirmedClear,

    [switch]$ElevatedChild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-IsAccessDeniedError {
    param([Parameter(Mandatory)][Management.Automation.ErrorRecord]$ErrorRecord)

    $Exception = $ErrorRecord.Exception
    while ($null -ne $Exception) {
        if ($Exception -is [UnauthorizedAccessException] -or (($Exception.HResult -band 0xFFFF) -eq 5)) {
            return $true
        }
        $Exception = $Exception.InnerException
    }
    return $false
}

function Get-WorkerConfiguration {
    param([Parameter(Mandatory)][string]$Path)

    $Configuration = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($Configuration.schemaVersion -ne 1) {
        throw 'Unsupported GPUmates worker configuration version.'
    }
    return $Configuration
}

function Get-ConfiguredCacheState {
    param([Parameter(Mandatory)][object]$Configuration)

    $CacheProperty = $Configuration.PSObject.Properties['cacheEnabled']
    if ($null -eq $CacheProperty) {
        return $false
    }
    if ($CacheProperty.Value -isnot [bool]) {
        throw 'Invalid GPUmates worker configuration: cacheEnabled must be true or false.'
    }
    return [bool]$CacheProperty.Value
}

function Start-AtomicConfigurationWrite {
    param(
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][string]$Path
    )

    $Directory = Split-Path -Parent $Path
    $TemporaryPath = Join-Path $Directory ('.worker-settings-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    $BackupPath = Join-Path $Directory ('.worker-settings-{0}.bak' -f [Guid]::NewGuid().ToString('N'))
    $DestinationExisted = Test-Path -LiteralPath $Path -PathType Leaf

    try {
        $Json = $Configuration | ConvertTo-Json -Depth 20
        [IO.File]::WriteAllText(
            $TemporaryPath,
            $Json + [Environment]::NewLine,
            [Text.UTF8Encoding]::new($false)
        )
        Get-Content -LiteralPath $TemporaryPath -Raw | ConvertFrom-Json -ErrorAction Stop | Out-Null

        if ($DestinationExisted) {
            [IO.File]::Replace($TemporaryPath, $Path, $BackupPath, $true)
        }
        else {
            [IO.File]::Move($TemporaryPath, $Path)
        }

        return [pscustomobject]@{
            BackupPath        = $BackupPath
            DestinationExisted = $DestinationExisted
        }
    }
    catch {
        if (Test-Path -LiteralPath $TemporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $TemporaryPath -Force
        }
        if (Test-Path -LiteralPath $BackupPath -PathType Leaf) {
            Remove-Item -LiteralPath $BackupPath -Force
        }
        throw
    }
}

function Complete-AtomicConfigurationWrite {
    param([Parameter(Mandatory)][object]$Transaction)

    if (Test-Path -LiteralPath $Transaction.BackupPath -PathType Leaf) {
        Remove-Item -LiteralPath $Transaction.BackupPath -Force
    }
}

function Undo-AtomicConfigurationWrite {
    param(
        [Parameter(Mandatory)][object]$Transaction,
        [Parameter(Mandatory)][string]$Path
    )

    if ($Transaction.DestinationExisted) {
        if (-not (Test-Path -LiteralPath $Transaction.BackupPath -PathType Leaf)) {
            throw 'The original worker configuration backup is unavailable.'
        }
        $DiscardPath = Join-Path (Split-Path -Parent $Path) ('.worker-settings-{0}.discard' -f [Guid]::NewGuid().ToString('N'))
        try {
            [IO.File]::Replace($Transaction.BackupPath, $Path, $DiscardPath, $true)
        }
        finally {
            if (Test-Path -LiteralPath $DiscardPath -PathType Leaf) {
                Remove-Item -LiteralPath $DiscardPath -Force
            }
        }
    }
    elseif (Test-Path -LiteralPath $Path -PathType Leaf) {
        Remove-Item -LiteralPath $Path -Force
    }
}

function Set-InstalledCachePreference {
    param([Parameter(Mandatory)][bool]$Enabled)

    $RegistryView = if ([Environment]::Is64BitOperatingSystem) {
        [Microsoft.Win32.RegistryView]::Registry64
    }
    else {
        [Microsoft.Win32.RegistryView]::Registry32
    }

    $BaseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        $RegistryView
    )
    try {
        $WorkerKey = $BaseKey.CreateSubKey('Software\GPUmates\Worker', $true)
        if ($null -eq $WorkerKey) {
            throw 'Could not open the GPUmates Worker registry settings key for writing.'
        }
        try {
            $WorkerKey.SetValue(
                'CacheEnabled',
                $(if ($Enabled) { 1 } else { 0 }),
                [Microsoft.Win32.RegistryValueKind]::DWord
            )
        }
        finally {
            $WorkerKey.Dispose()
        }
    }
    finally {
        $BaseKey.Dispose()
    }
}

function Set-WorkerCacheState {
    param([Parameter(Mandatory)][bool]$Enabled)

    $Configuration = Get-WorkerConfiguration -Path $script:ResolvedConfigPath
    $CacheProperty = $Configuration.PSObject.Properties['cacheEnabled']
    if ($null -eq $CacheProperty) {
        $Configuration | Add-Member -NotePropertyName cacheEnabled -NotePropertyValue $Enabled
    }
    else {
        $CacheProperty.Value = $Enabled
    }

    $Transaction = Start-AtomicConfigurationWrite -Configuration $Configuration -Path $script:ResolvedConfigPath
    try {
        if ($script:IsInstalledConfiguration) {
            Set-InstalledCachePreference -Enabled $Enabled
        }
        Complete-AtomicConfigurationWrite -Transaction $Transaction
    }
    catch {
        $UpdateError = $_
        try {
            Undo-AtomicConfigurationWrite -Transaction $Transaction -Path $script:ResolvedConfigPath
        }
        catch {
            throw "The cache preference could not be saved, and the previous worker configuration could not be restored: $($_.Exception.Message)"
        }
        throw $UpdateError
    }
}

function Get-CacheStatistics {
    if (-not (Test-Path -LiteralPath $script:CacheRoot -PathType Container)) {
        return [pscustomobject]@{ Bytes = [int64]0; Files = 0; Inaccessible = $false }
    }

    $Bytes = [int64]0
    $Files = 0
    $Inaccessible = $false
    $PendingDirectories = [Collections.Generic.Stack[string]]::new()
    $PendingDirectories.Push($script:CacheRoot)

    while ($PendingDirectories.Count -gt 0) {
        $CurrentDirectory = $PendingDirectories.Pop()
        try {
            $Entries = @([IO.Directory]::EnumerateFileSystemEntries($CurrentDirectory))
        }
        catch {
            $Inaccessible = $true
            continue
        }

        foreach ($Entry in $Entries) {
            try {
                $Attributes = [IO.File]::GetAttributes($Entry)
                if (($Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    continue
                }
                if (($Attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                    $PendingDirectories.Push($Entry)
                }
                else {
                    $Bytes += ([IO.FileInfo]$Entry).Length
                    $Files++
                }
            }
            catch {
                $Inaccessible = $true
            }
        }
    }

    return [pscustomobject]@{ Bytes = $Bytes; Files = $Files; Inaccessible = $Inaccessible }
}

function Format-ByteCount {
    param([Parameter(Mandatory)][int64]$Bytes)

    if ($Bytes -ge 1TB) { return '{0:N2} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N1} KB' -f ($Bytes / 1KB) }
    return "$Bytes bytes"
}

function Get-CacheSummary {
    $Statistics = Get-CacheStatistics
    $Suffix = if ($Statistics.Inaccessible) { ' (some files could not be measured)' } else { '' }
    return "$(Format-ByteCount -Bytes $Statistics.Bytes) in $($Statistics.Files) file(s)$Suffix"
}

function Test-RpcWorkerRunning {
    return @(Get-Process -Name 'ggml-rpc-server' -ErrorAction SilentlyContinue).Count -gt 0
}

function Assert-SafeCacheRoot {
    $LocalAppDataPrefix = $script:LocalAppDataRoot.TrimEnd('\') + '\'
    if (-not $script:CacheRoot.StartsWith($LocalAppDataPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to clear a cache outside the current user LocalAppData directory.'
    }
    if (Test-Path -LiteralPath $script:CacheRoot) {
        $RootAttributes = [IO.File]::GetAttributes($script:CacheRoot)
        if (($RootAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Refusing to clear the RPC cache because its directory is a reparse point.'
        }
    }
}

function Test-CacheContainsReparsePoint {
    if (-not (Test-Path -LiteralPath $script:CacheRoot -PathType Container)) {
        return $false
    }

    $PendingDirectories = [Collections.Generic.Stack[string]]::new()
    $PendingDirectories.Push($script:CacheRoot)
    while ($PendingDirectories.Count -gt 0) {
        $CurrentDirectory = $PendingDirectories.Pop()
        foreach ($Entry in @([IO.Directory]::EnumerateFileSystemEntries($CurrentDirectory))) {
            $Attributes = [IO.File]::GetAttributes($Entry)
            if (($Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                return $true
            }
            if (($Attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                $PendingDirectories.Push($Entry)
            }
        }
    }
    return $false
}

function Clear-WorkerTensorCache {
    Assert-SafeCacheRoot
    if (Test-RpcWorkerRunning) {
        throw 'The RPC worker is running. Stop the GPUmates Worker window, clear the cache, and then start the worker again.'
    }
    if (-not (Test-Path -LiteralPath $script:CacheRoot -PathType Container)) {
        return
    }
    if (Test-CacheContainsReparsePoint) {
        throw 'The cache contains a reparse point. It was not cleared automatically; inspect the cache directory manually.'
    }

    $CacheRootPrefix = $script:CacheRoot.TrimEnd('\') + '\'
    foreach ($Item in @(Get-ChildItem -LiteralPath $script:CacheRoot -Force -ErrorAction Stop)) {
        $ResolvedTarget = (Resolve-Path -LiteralPath $Item.FullName -ErrorAction Stop).Path
        $FullTarget = [IO.Path]::GetFullPath($ResolvedTarget)
        $VolumeRoot = [IO.Path]::GetPathRoot($FullTarget).TrimEnd('\')
        if (-not $FullTarget.StartsWith($CacheRootPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($FullTarget, $script:CacheRoot, [StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($FullTarget.TrimEnd('\'), $script:LocalAppDataRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($FullTarget.TrimEnd('\'), $VolumeRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to delete an unsafe RPC cache target: $FullTarget"
        }
        Remove-Item -LiteralPath $FullTarget -Recurse -Force -ErrorAction Stop
    }
}

function Invoke-ElevatedSettingsAction {
    param(
        [Parameter(Mandatory)][ValidateSet('Enable', 'Disable', 'ClearCache')][string]$RequestedAction,
        [switch]$ClearWasConfirmed
    )

    foreach ($PathValue in @($PSCommandPath, $script:ResolvedConfigPath)) {
        if ($PathValue.IndexOf('"') -ge 0) {
            throw 'A settings path contains an unsupported quote character.'
        }
    }

    $PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $ArgumentParts = @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath),
        '-Action', $RequestedAction,
        '-ConfigPath', ('"{0}"' -f $script:ResolvedConfigPath),
        '-ElevatedChild'
    )
    if ($ClearWasConfirmed) {
        $ArgumentParts += '-ConfirmedClear'
    }

    try {
        $Process = Start-Process -FilePath $PowerShellExe `
            -ArgumentList ($ArgumentParts -join ' ') `
            -Verb RunAs `
            -WindowStyle Hidden `
            -Wait `
            -PassThru
    }
    catch {
        throw "Administrator approval was cancelled or could not be started: $($_.Exception.Message)"
    }
    if ($Process.ExitCode -ne 0) {
        throw 'The elevated GPUmates Worker settings update failed.'
    }
}

function Invoke-SettingsAction {
    param(
        [Parameter(Mandatory)][ValidateSet('Enable', 'Disable', 'ClearCache')][string]$RequestedAction,
        [switch]$ClearWasConfirmed
    )

    if ($RequestedAction -eq 'ClearCache') {
        if (Test-RpcWorkerRunning) {
            throw 'The RPC worker is running. Stop the GPUmates Worker window before clearing its tensor cache.'
        }
        try {
            Clear-WorkerTensorCache
        }
        catch {
            if (-not (Test-IsAdministrator) -and (Test-IsAccessDeniedError -ErrorRecord $_)) {
                Invoke-ElevatedSettingsAction -RequestedAction ClearCache -ClearWasConfirmed:$ClearWasConfirmed
                return
            }
            throw
        }
        return
    }

    if ($script:IsInstalledConfiguration -and -not (Test-IsAdministrator)) {
        Invoke-ElevatedSettingsAction -RequestedAction $RequestedAction
        return
    }

    try {
        Set-WorkerCacheState -Enabled ($RequestedAction -eq 'Enable')
    }
    catch {
        if (-not (Test-IsAdministrator) -and (Test-IsAccessDeniedError -ErrorRecord $_)) {
            Invoke-ElevatedSettingsAction -RequestedAction $RequestedAction
            return
        }
        throw
    }
}

function Confirm-ConsoleCacheClear {
    $Summary = Get-CacheSummary
    Write-Host "Cache location: $script:CacheRoot"
    Write-Host "Cache size: $Summary"
    Write-Host 'Clearing it makes the next model load transfer tensor data over the network again.'
    $Response = Read-Host 'Type CLEAR to permanently delete the cached tensor data'
    return [string]::Equals($Response, 'CLEAR', [StringComparison]::Ordinal)
}

function Show-WorkerCacheStatus {
    $Configuration = Get-WorkerConfiguration -Path $script:ResolvedConfigPath
    $CurrentState = Get-ConfiguredCacheState -Configuration $Configuration
    Write-Host "RPC tensor caching: $(if ($CurrentState) { 'ENABLED' } else { 'disabled' })"
    Write-Host "Cache location: $script:CacheRoot"
    Write-Host "Cache size: $(Get-CacheSummary)"
    Write-Host "RPC worker: $(if (Test-RpcWorkerRunning) { 'RUNNING' } else { 'stopped' })"
}

function Show-ConsoleSettings {
    Show-WorkerCacheStatus
    Write-Host ''
    Write-Host '[E] Enable caching   [D] Disable caching   [C] Clear cached data   [Q] Quit'
    $Choice = (Read-Host 'Choose an action').Trim().ToUpperInvariant()
    switch ($Choice) {
        'E' {
            Invoke-SettingsAction -RequestedAction Enable
            Write-Host 'Caching was enabled. Restart the GPUmates Worker for the change to take effect.'
        }
        'D' {
            Invoke-SettingsAction -RequestedAction Disable
            Write-Host 'Caching was disabled. Existing cached files were kept. Restart the GPUmates Worker for the change to take effect.'
        }
        'C' {
            if (Confirm-ConsoleCacheClear) {
                Invoke-SettingsAction -RequestedAction ClearCache -ClearWasConfirmed
                Write-Host 'The local RPC tensor cache was cleared.'
            }
            else {
                Write-Host 'Cache clear cancelled.'
            }
        }
        default { Write-Host 'No changes were made.' }
    }
}

function Show-WorkerSettingsWindow {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $Configuration = Get-WorkerConfiguration -Path $script:ResolvedConfigPath
    $CurrentState = Get-ConfiguredCacheState -Configuration $Configuration

    $Form = [Windows.Forms.Form]::new()
    $Form.Text = 'GPUmates Worker Settings'
    $Form.ClientSize = [Drawing.Size]::new(610, 350)
    $Form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
    $Form.MaximizeBox = $false
    $Form.MinimizeBox = $false
    $Form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
    $Form.Font = [Drawing.Font]::new('Segoe UI', 9)

    $Title = [Windows.Forms.Label]::new()
    $Title.Text = 'Model tensor cache'
    $Title.Font = [Drawing.Font]::new('Segoe UI Semibold', 13)
    $Title.AutoSize = $true
    $Title.Location = [Drawing.Point]::new(20, 18)
    $Form.Controls.Add($Title)

    $Description = [Windows.Forms.Label]::new()
    $Description.Text = "Keep model tensor data on this worker's SSD so repeated model loads do not transfer it over the network again. Cached tensors can use several gigabytes of disk space."
    $Description.Location = [Drawing.Point]::new(22, 53)
    $Description.Size = [Drawing.Size]::new(565, 48)
    $Form.Controls.Add($Description)

    $CacheCheckBox = [Windows.Forms.CheckBox]::new()
    $CacheCheckBox.Text = 'Enable persistent RPC tensor caching'
    $CacheCheckBox.Checked = $CurrentState
    $CacheCheckBox.AutoSize = $true
    $CacheCheckBox.Location = [Drawing.Point]::new(25, 105)
    $Form.Controls.Add($CacheCheckBox)

    $RestartLabel = [Windows.Forms.Label]::new()
    $RestartLabel.Text = 'Saving this setting requires the GPUmates RPC worker to be restarted.'
    $RestartLabel.ForeColor = [Drawing.Color]::FromArgb(150, 80, 0)
    $RestartLabel.Location = [Drawing.Point]::new(42, 133)
    $RestartLabel.Size = [Drawing.Size]::new(530, 23)
    $Form.Controls.Add($RestartLabel)

    $LocationLabel = [Windows.Forms.Label]::new()
    $LocationLabel.Text = 'Cache location:'
    $LocationLabel.AutoSize = $true
    $LocationLabel.Location = [Drawing.Point]::new(22, 170)
    $Form.Controls.Add($LocationLabel)

    $LocationBox = [Windows.Forms.TextBox]::new()
    $LocationBox.Text = $script:CacheRoot
    $LocationBox.ReadOnly = $true
    $LocationBox.Location = [Drawing.Point]::new(120, 167)
    $LocationBox.Size = [Drawing.Size]::new(467, 23)
    $Form.Controls.Add($LocationBox)

    $SizeCaption = [Windows.Forms.Label]::new()
    $SizeCaption.Text = 'Cache size:'
    $SizeCaption.AutoSize = $true
    $SizeCaption.Location = [Drawing.Point]::new(22, 204)
    $Form.Controls.Add($SizeCaption)

    $SizeValue = [Windows.Forms.Label]::new()
    $SizeValue.Text = Get-CacheSummary
    $SizeValue.AutoSize = $true
    $SizeValue.Location = [Drawing.Point]::new(120, 204)
    $Form.Controls.Add($SizeValue)

    $WorkerStateLabel = [Windows.Forms.Label]::new()
    $WorkerStateLabel.Text = if (Test-RpcWorkerRunning) {
        'The RPC worker is running. Stop it before clearing cached data.'
    }
    else {
        'The RPC worker is stopped; cached data can be cleared.'
    }
    $WorkerStateLabel.Location = [Drawing.Point]::new(22, 235)
    $WorkerStateLabel.Size = [Drawing.Size]::new(565, 22)
    $Form.Controls.Add($WorkerStateLabel)

    $ClearButton = [Windows.Forms.Button]::new()
    $ClearButton.Text = 'Clear cache...'
    $ClearButton.Location = [Drawing.Point]::new(22, 282)
    $ClearButton.Size = [Drawing.Size]::new(112, 32)
    $Form.Controls.Add($ClearButton)

    $CancelButton = [Windows.Forms.Button]::new()
    $CancelButton.Text = 'Cancel'
    $CancelButton.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $CancelButton.Location = [Drawing.Point]::new(486, 282)
    $CancelButton.Size = [Drawing.Size]::new(100, 32)
    $Form.Controls.Add($CancelButton)

    $SaveButton = [Windows.Forms.Button]::new()
    $SaveButton.Text = 'Save setting'
    $SaveButton.Location = [Drawing.Point]::new(368, 282)
    $SaveButton.Size = [Drawing.Size]::new(108, 32)
    $Form.Controls.Add($SaveButton)
    $Form.AcceptButton = $SaveButton
    $Form.CancelButton = $CancelButton

    $SaveButton.Add_Click({
        try {
            $RequestedAction = if ($CacheCheckBox.Checked) { 'Enable' } else { 'Disable' }
            Invoke-SettingsAction -RequestedAction $RequestedAction
            [void][Windows.Forms.MessageBox]::Show(
                $Form,
                'The cache setting was saved. Restart the GPUmates RPC worker for the change to take effect.',
                'GPUmates Worker Settings',
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Information
            )
            $Form.DialogResult = [Windows.Forms.DialogResult]::OK
            $Form.Close()
        }
        catch {
            [void][Windows.Forms.MessageBox]::Show(
                $Form,
                $_.Exception.Message,
                'Could not save worker settings',
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Error
            )
        }
    })

    $ClearButton.Add_Click({
        try {
            if (Test-RpcWorkerRunning) {
                throw 'The RPC worker is running. Stop the GPUmates Worker window before clearing its tensor cache.'
            }
            $Summary = Get-CacheSummary
            $Confirmation = [Windows.Forms.MessageBox]::Show(
                $Form,
                "Delete $Summary from:`r`n$script:CacheRoot`r`n`r`nThe next model load will transfer tensor data over the network again.",
                'Clear RPC tensor cache?',
                [Windows.Forms.MessageBoxButtons]::YesNo,
                [Windows.Forms.MessageBoxIcon]::Warning,
                [Windows.Forms.MessageBoxDefaultButton]::Button2
            )
            if ($Confirmation -ne [Windows.Forms.DialogResult]::Yes) {
                return
            }
            Invoke-SettingsAction -RequestedAction ClearCache -ClearWasConfirmed
            $SizeValue.Text = Get-CacheSummary
            [void][Windows.Forms.MessageBox]::Show(
                $Form,
                'The local RPC tensor cache was cleared. The cache preference itself was not changed.',
                'GPUmates Worker Settings',
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Information
            )
        }
        catch {
            [void][Windows.Forms.MessageBox]::Show(
                $Form,
                $_.Exception.Message,
                'Could not clear cache',
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Error
            )
        }
    })

    [void]$Form.ShowDialog()
    $Form.Dispose()
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $env:ProgramData 'GPUmates\Worker\worker.json'
}
$script:ResolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).Path
$DefaultConfigPath = [IO.Path]::GetFullPath((Join-Path $env:ProgramData 'GPUmates\Worker\worker.json'))
$script:IsInstalledConfiguration = [string]::Equals(
    $script:ResolvedConfigPath,
    $DefaultConfigPath,
    [StringComparison]::OrdinalIgnoreCase
)

if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    throw 'LOCALAPPDATA is unavailable; the llama.cpp RPC cache location cannot be resolved.'
}
$script:LocalAppDataRoot = [IO.Path]::GetFullPath($env:LOCALAPPDATA)
$script:CacheRoot = [IO.Path]::GetFullPath((Join-Path $script:LocalAppDataRoot 'GPUmates\Worker\TensorCache\b10488\rpc'))
Assert-SafeCacheRoot

try {
    if (-not [string]::IsNullOrWhiteSpace($Action)) {
        $RequestedAction = if ($Action -eq 'Clear') { 'ClearCache' } else { $Action }
        if ($RequestedAction -eq 'Status') {
            Show-WorkerCacheStatus
            return
        }
        $ClearWasConfirmed = [bool]$ConfirmedClear
        if ($RequestedAction -eq 'ClearCache' -and -not $ClearWasConfirmed) {
            if (-not (Confirm-ConsoleCacheClear)) {
                Write-Host 'Cache clear cancelled.'
                return
            }
            $ClearWasConfirmed = $true
        }
        Invoke-SettingsAction -RequestedAction $RequestedAction -ClearWasConfirmed:$ClearWasConfirmed
        if ($RequestedAction -eq 'ClearCache') {
            Write-Host 'The local RPC tensor cache was cleared.'
        }
        else {
            Write-Host "RPC tensor caching was $($RequestedAction.ToLowerInvariant())d."
            Write-Host 'Restart the GPUmates RPC worker for the change to take effect.'
        }
    }
    else {
        try {
            Show-WorkerSettingsWindow
        }
        catch [System.IO.FileNotFoundException] {
            Show-ConsoleSettings
        }
        catch [System.TypeInitializationException] {
            Show-ConsoleSettings
        }
    }
}
catch {
    if ($ElevatedChild) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [void][Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                'GPUmates Worker settings failed',
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Error
            )
        }
        catch {
            # The elevated console is hidden; the calling process reports the failure.
        }
    }
    throw
}
