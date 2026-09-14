[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [ValidateRange(1024, 65535)]
    [int]$Port = 8091,
    [string]$DataRoot,
    [switch]$SkipAutoStart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:DataAclTightened = $false

Add-Type -AssemblyName System.Security
Import-Module (Join-Path $PSScriptRoot 'GPUmates.Telemetry.psm1') -Force

function Get-ObjectProperty {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [object]$DefaultValue = $null
    )

    if ($null -eq $InputObject) {
        return $DefaultValue
    }
    $Property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $Property) {
        return $DefaultValue
    }
    return $Property.Value
}

function Test-PrivateIPv4Text {
    param([Parameter(Mandatory)][string]$Text)

    $Address = $null
    if (-not [Net.IPAddress]::TryParse($Text, [ref]$Address) -or
        $Address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        return $false
    }
    $Bytes = $Address.GetAddressBytes()
    return $Bytes[0] -eq 10 -or
        ($Bytes[0] -eq 172 -and $Bytes[1] -ge 16 -and $Bytes[1] -le 31) -or
        ($Bytes[0] -eq 192 -and $Bytes[1] -eq 168)
}

function Get-UniquePrivateIPv4List {
    param(
        [AllowNull()][object[]]$Value,
        [string]$FieldName = 'IP address'
    )

    $Result = [Collections.Generic.List[string]]::new()
    foreach ($Item in @($Value)) {
        $Text = ([string]$Item).Trim()
        if ([string]::IsNullOrWhiteSpace($Text)) {
            continue
        }
        if (-not (Test-PrivateIPv4Text -Text $Text)) {
            throw "$FieldName must contain exact private IPv4 addresses. Invalid value: $Text"
        }
        $Canonical = ([Net.IPAddress]$Text).IPAddressToString
        if (-not $Result.Contains($Canonical)) {
            $Result.Add($Canonical)
        }
    }
    return @($Result)
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Value,
        [switch]$Backup
    )

    $FullPath = [IO.Path]::GetFullPath($Path)
    $Directory = Split-Path -Parent $FullPath
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    if ($Backup -and (Test-Path -LiteralPath $FullPath -PathType Leaf)) {
        $BackupPath = '{0}.backup-{1}' -f $FullPath, (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $FullPath -Destination $BackupPath -ErrorAction Stop
    }
    $TemporaryPath = Join-Path $Directory ('.{0}-{1}.tmp' -f ([IO.Path]::GetFileName($FullPath)), [Guid]::NewGuid().ToString('N'))
    try {
        $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $TemporaryPath -Encoding UTF8
        # Parse the temporary file before replacing a known-good configuration.
        Get-Content -LiteralPath $TemporaryPath -Raw | ConvertFrom-Json -ErrorAction Stop | Out-Null
        Move-Item -LiteralPath $TemporaryPath -Destination $FullPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $TemporaryPath) {
            Remove-Item -LiteralPath $TemporaryPath -Force
        }
    }
}

function Set-PrivateDataRootAcl {
    param([Parameter(Mandatory)][string]$Path)

    try {
        $CurrentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $Icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
        $Output = @(& $Icacls $Path '/inheritance:r' '/grant:r' "*$CurrentSid`:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw ($Output -join ' ')
        }
        $script:DataAclTightened = $true
    }
    catch {
        $script:DataAclTightened = $false
        Write-Warning "Could not tighten the coordinator data ACL: $($_.Exception.Message)"
    }
}

function New-CryptographicSecret {
    param([ValidateRange(24, 128)][int]$ByteCount = 32)

    $Bytes = [byte[]]::new($ByteCount)
    $Generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $Generator.GetBytes($Bytes)
        return [Convert]::ToBase64String($Bytes)
    }
    finally {
        $Generator.Dispose()
    }
}

function Get-SecretEntropy {
    $Sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return $Sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes('GPUmates Coordinator secrets schema 1'))
    }
    finally {
        $Sha256.Dispose()
    }
}

function Get-ControlSessionEntropy {
    $Sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return $Sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes('GPUmates Coordinator browser session schema 1'))
    }
    finally {
        $Sha256.Dispose()
    }
}

function Protect-ControlSessionToken {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][ValidateSet('CurrentUser', 'LocalMachineAcl')][string]$Scope
    )

    $ClearBytes = [Text.Encoding]::UTF8.GetBytes($Text)
    try {
        $ProtectionScope = if ($Scope -eq 'CurrentUser') {
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        }
        else {
            [Security.Cryptography.DataProtectionScope]::LocalMachine
        }
        $ProtectedBytes = [Security.Cryptography.ProtectedData]::Protect(
            $ClearBytes,
            (Get-ControlSessionEntropy),
            $ProtectionScope
        )
        return [Convert]::ToBase64String($ProtectedBytes)
    }
    finally {
        [Array]::Clear($ClearBytes, 0, $ClearBytes.Length)
    }
}

function Protect-SecretText {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][ValidateSet('CurrentUser', 'LocalMachineAcl')][string]$Scope
    )

    $ClearBytes = [Text.Encoding]::UTF8.GetBytes($Text)
    try {
        $ProtectionScope = if ($Scope -eq 'CurrentUser') {
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        }
        else {
            [Security.Cryptography.DataProtectionScope]::LocalMachine
        }
        $ProtectedBytes = [Security.Cryptography.ProtectedData]::Protect(
            $ClearBytes,
            (Get-SecretEntropy),
            $ProtectionScope
        )
        return [Convert]::ToBase64String($ProtectedBytes)
    }
    finally {
        [Array]::Clear($ClearBytes, 0, $ClearBytes.Length)
    }
}

function Unprotect-SecretText {
    param(
        [Parameter(Mandatory)][string]$ProtectedText,
        [Parameter(Mandatory)][ValidateSet('CurrentUser', 'LocalMachineAcl')][string]$Scope
    )

    $ProtectedBytes = [Convert]::FromBase64String($ProtectedText)
    $ProtectionScope = if ($Scope -eq 'CurrentUser') {
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    }
    else {
        [Security.Cryptography.DataProtectionScope]::LocalMachine
    }
    $ClearBytes = [Security.Cryptography.ProtectedData]::Unprotect(
        $ProtectedBytes,
        (Get-SecretEntropy),
        $ProtectionScope
    )
    try {
        return [Text.Encoding]::UTF8.GetString($ClearBytes)
    }
    finally {
        [Array]::Clear($ClearBytes, 0, $ClearBytes.Length)
    }
}

function Get-SavedSecrets {
    $Result = @{
        AgentKey   = $null
        DashboardKey = $null
        LlamaApiKey  = $null
    }
    if (-not (Test-Path -LiteralPath $script:SecretsPath -PathType Leaf)) {
        return $Result
    }

    try {
        $Stored = Get-Content -LiteralPath $script:SecretsPath -Raw | ConvertFrom-Json -ErrorAction Stop
        if ((Get-ObjectProperty -InputObject $Stored -Name 'schemaVersion') -ne 1) {
            throw 'Unsupported saved-secret version.'
        }
        $ProtectionScope = [string](Get-ObjectProperty -InputObject $Stored -Name 'protectionScope' -DefaultValue 'CurrentUser')
        if ($ProtectionScope -notin @('CurrentUser', 'LocalMachineAcl')) {
            throw 'Unsupported saved-secret protection scope.'
        }
        foreach ($Mapping in @(
                @('AgentKey', 'agentKey'),
                @('DashboardKey', 'dashboardKey'),
                @('LlamaApiKey', 'llamaApiKey')
            )) {
            $ProtectedValue = [string](Get-ObjectProperty -InputObject $Stored -Name $Mapping[1] -DefaultValue '')
            if (-not [string]::IsNullOrWhiteSpace($ProtectedValue)) {
                $Result[$Mapping[0]] = Unprotect-SecretText -ProtectedText $ProtectedValue -Scope $ProtectionScope
            }
        }
        return $Result
    }
    catch {
        throw "Saved coordinator keys cannot be decrypted by Windows user $env:USERNAME. Details: $($_.Exception.Message)"
    }
}

function Save-Secrets {
    param(
        [AllowNull()][string]$AgentKey,
        [AllowNull()][string]$DashboardKey,
        [AllowNull()][string]$LlamaApiKey
    )

    $Current = Get-SavedSecrets
    $Incoming = @{
        AgentKey     = $AgentKey
        DashboardKey = $DashboardKey
        LlamaApiKey  = $LlamaApiKey
    }
    foreach ($Name in @('AgentKey', 'DashboardKey', 'LlamaApiKey')) {
        if (-not [string]::IsNullOrWhiteSpace([string]$Incoming[$Name])) {
            if (([string]$Incoming[$Name]).Length -lt 24) {
                throw "$Name must contain at least 24 characters."
            }
            $Current[$Name] = [string]$Incoming[$Name]
        }
    }
    foreach ($Name in @('AgentKey', 'DashboardKey', 'LlamaApiKey')) {
        if ([string]::IsNullOrWhiteSpace([string]$Current[$Name])) {
            throw 'All three keys are required before GPUmates services can be managed.'
        }
    }

    $ProtectionScope = 'CurrentUser'
    try {
        $ProtectedAgentKey = Protect-SecretText -Text ([string]$Current.AgentKey) -Scope $ProtectionScope
        $ProtectedDashboardKey = Protect-SecretText -Text ([string]$Current.DashboardKey) -Scope $ProtectionScope
        $ProtectedLlamaApiKey = Protect-SecretText -Text ([string]$Current.LlamaApiKey) -Scope $ProtectionScope
    }
    catch {
        # Some managed/sandboxed Windows sessions do not load a CurrentUser
        # DPAPI profile. The data directory ACL still limits this fallback to
        # the current SID and SYSTEM.
        if (-not $script:DataAclTightened) {
            throw 'Windows could not protect the coordinator keys for this user, and the private data ACL was not available.'
        }
        $ProtectionScope = 'LocalMachineAcl'
        $ProtectedAgentKey = Protect-SecretText -Text ([string]$Current.AgentKey) -Scope $ProtectionScope
        $ProtectedDashboardKey = Protect-SecretText -Text ([string]$Current.DashboardKey) -Scope $ProtectionScope
        $ProtectedLlamaApiKey = Protect-SecretText -Text ([string]$Current.LlamaApiKey) -Scope $ProtectionScope
    }
    $Stored = [pscustomobject][ordered]@{
        schemaVersion   = 1
        protectionScope = $ProtectionScope
        agentKey        = $ProtectedAgentKey
        dashboardKey    = $ProtectedDashboardKey
        llamaApiKey     = $ProtectedLlamaApiKey
        savedAt         = [DateTimeOffset]::UtcNow.ToString('o')
    }
    Write-JsonAtomic -Path $script:SecretsPath -Value $Stored
    $Current.AgentKey = $null
    $Current.DashboardKey = $null
    $Current.LlamaApiKey = $null
}

function Read-NodeConfiguration {
    return Get-Content -LiteralPath $script:NodeConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
}

function Get-CoordinatorIPText {
    $Configuration = Read-NodeConfiguration
    $LocalNode = @(
        $Configuration.nodes |
            Where-Object { [bool](Get-ObjectProperty -InputObject $_ -Name 'local' -DefaultValue $false) }
    ) | Select-Object -First 1
    if ($null -eq $LocalNode) {
        throw 'The node configuration has no local coordinator entry.'
    }
    $AddressText = [string](Get-ObjectProperty -InputObject $LocalNode -Name 'displayIp' -DefaultValue $LocalNode.host)
    if (-not (Test-PrivateIPv4Text -Text $AddressText)) {
        throw 'The coordinator displayIp must be one private IPv4 address.'
    }
    return ([Net.IPAddress]$AddressText).IPAddressToString
}

function Get-RegisteredWorkerNodes {
    $Configuration = Read-NodeConfiguration
    return @(
        $Configuration.nodes |
            Where-Object { [string]$_.role -eq 'worker' } |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    name = [string]$_.name
                    ip   = ([Net.IPAddress]([string]$_.host)).IPAddressToString
                    port = [int]$_.port
                }
            }
    )
}

function Get-ControlConfiguration {
    $Workers = @(Get-RegisteredWorkerNodes)
    $WorkerIps = @($Workers | ForEach-Object ip)
    $NodeConfiguration = Read-NodeConfiguration
    $CoordinatorIP = Get-CoordinatorIPText
    $DefaultDashboardClients = @(
        @($NodeConfiguration.dashboard.allowedClientIps) |
            ForEach-Object { [string]$_ } |
            Where-Object { $_ -ne $CoordinatorIP }
    )
    $Raw = $null
    if (Test-Path -LiteralPath $script:ControlConfigPath -PathType Leaf) {
        $Raw = Get-Content -LiteralPath $script:ControlConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
        if ((Get-ObjectProperty -InputObject $Raw -Name 'schemaVersion') -ne 1) {
            throw 'Unsupported coordinator control configuration version.'
        }
    }
    $RawSharing = Get-ObjectProperty -InputObject $Raw -Name 'sharing'
    $RawSettings = Get-ObjectProperty -InputObject $Raw -Name 'settings'

    $Selected = Get-UniquePrivateIPv4List `
        -Value @(Get-ObjectProperty -InputObject $Raw -Name 'selectedWorkerIps' -DefaultValue $WorkerIps) `
        -FieldName 'selectedWorkerIps'
    $Selected = @($Selected | Where-Object { $_ -in $WorkerIps })
    $ChatClients = Get-UniquePrivateIPv4List `
        -Value @(Get-ObjectProperty -InputObject $RawSharing -Name 'chatClientIps' -DefaultValue $WorkerIps) `
        -FieldName 'chatClientIps'
    $DashboardClients = Get-UniquePrivateIPv4List `
        -Value @(Get-ObjectProperty -InputObject $RawSharing -Name 'dashboardClientIps' -DefaultValue $DefaultDashboardClients) `
        -FieldName 'dashboardClientIps'

    return [pscustomobject][ordered]@{
        schemaVersion      = 1
        coordinatorIP      = $CoordinatorIP
        selectedWorkerIps  = @($Selected)
        sharing            = [pscustomobject][ordered]@{
            lanChatEnabled     = [bool](Get-ObjectProperty -InputObject $RawSharing -Name 'lanChatEnabled' -DefaultValue $false)
            chatClientIps      = @($ChatClients)
            dashboardClientIps = @($DashboardClients)
        }
        settings           = [pscustomobject][ordered]@{
            autoStartRouter    = [bool](Get-ObjectProperty -InputObject $RawSettings -Name 'autoStartRouter' -DefaultValue $false)
            autoStartDashboard = [bool](Get-ObjectProperty -InputObject $RawSettings -Name 'autoStartDashboard' -DefaultValue $false)
            contextSize        = [int](Get-ObjectProperty -InputObject $RawSettings -Name 'contextSize' -DefaultValue 8192)
            tensorSplit        = [string](Get-ObjectProperty -InputObject $RawSettings -Name 'tensorSplit' -DefaultValue '')
        }
    }
}

function Save-ControlConfiguration {
    param([Parameter(Mandatory)][object]$Configuration)
    Write-JsonAtomic -Path $script:ControlConfigPath -Value $Configuration
}

function Initialize-ControlData {
    New-Item -ItemType Directory -Path $script:DataRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $script:ConfigRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $script:LogRoot -Force | Out-Null
    Set-PrivateDataRootAcl -Path $script:DataRoot

    if (-not (Test-Path -LiteralPath $script:NodeConfigPath -PathType Leaf)) {
        Copy-Item -LiteralPath (Join-Path $script:ProjectRoot 'config\telemetry-nodes.json') -Destination $script:NodeConfigPath
    }
    if (-not (Test-Path -LiteralPath $script:ModelPresetPath -PathType Leaf)) {
        Copy-Item -LiteralPath (Join-Path $script:ProjectRoot 'config\gpumates-models.ini') -Destination $script:ModelPresetPath
    }
    if (-not (Test-Path -LiteralPath $script:ControlConfigPath -PathType Leaf)) {
        Save-ControlConfiguration -Configuration (Get-ControlConfiguration)
    }
}

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$script:ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot -ErrorAction Stop).Path
if ([string]::IsNullOrWhiteSpace($DataRoot)) {
    $DataRoot = Join-Path $env:LOCALAPPDATA 'GPUmates\Coordinator'
}
$script:DataRoot = [IO.Path]::GetFullPath($DataRoot)
$script:ConfigRoot = Join-Path $script:DataRoot 'Config'
$script:LogRoot = Join-Path $script:DataRoot 'Logs'
$script:ControlConfigPath = Join-Path $script:ConfigRoot 'control.json'
$script:NodeConfigPath = Join-Path $script:ConfigRoot 'telemetry-nodes.json'
$script:ModelPresetPath = Join-Path $script:ConfigRoot 'gpumates-models.ini'
$script:SecretsPath = Join-Path $script:DataRoot 'secrets.dpapi.json'
$script:RouterRuntimeConfigPath = Join-Path $script:DataRoot 'router-runtime.json'
$script:ManagedStatePath = Join-Path $script:DataRoot 'managed-processes.json'
$script:ControlSessionPath = Join-Path $script:DataRoot 'control-session.dpapi'
$script:StaticRoot = (Resolve-Path -LiteralPath (Join-Path $script:ProjectRoot 'coordinator\static') -ErrorAction Stop).Path
$script:ManagedProcessIds = @{}
$script:LastError = $null
$script:KeepRunning = $true
$script:ControlToken = New-CryptographicSecret
$script:ControlSessionId = [Guid]::NewGuid().ToString('D')

Initialize-ControlData

function Save-ManagedProcessState {
    $Processes = [ordered]@{}
    foreach ($Name in @('router', 'dashboard')) {
        if ($script:ManagedProcessIds.ContainsKey($Name)) {
            $Processes[$Name] = $script:ManagedProcessIds[$Name]
        }
    }
    Write-JsonAtomic -Path $script:ManagedStatePath -Value ([pscustomobject][ordered]@{
            schemaVersion = 1
            processes     = [pscustomobject]$Processes
        })
}

function Import-ManagedProcessState {
    if (-not (Test-Path -LiteralPath $script:ManagedStatePath -PathType Leaf)) {
        return
    }
    try {
        $State = Get-Content -LiteralPath $script:ManagedStatePath -Raw | ConvertFrom-Json -ErrorAction Stop
        if ([int](Get-ObjectProperty -InputObject $State -Name 'schemaVersion' -DefaultValue 0) -ne 1) {
            throw 'Unsupported managed-process state version.'
        }
        $Processes = Get-ObjectProperty -InputObject $State -Name 'processes'
        foreach ($Name in @('router', 'dashboard')) {
            $Entry = Get-ObjectProperty -InputObject $Processes -Name $Name
            if ($null -ne $Entry -and
                $null -ne $Entry.PSObject.Properties['id'] -and
                $null -ne $Entry.PSObject.Properties['startTimeUtcTicks'] -and
                $null -ne $Entry.PSObject.Properties['scriptPath']) {
                $script:ManagedProcessIds[$Name] = $Entry
            }
        }
    }
    catch {
        $script:LastError = "Could not restore managed service identity: $($_.Exception.Message)"
    }
}

Import-ManagedProcessState

function Write-ControlSessionFile {
    $ProtectionScope = 'CurrentUser'
    try {
        $ProtectedToken = Protect-ControlSessionToken -Text $script:ControlToken -Scope $ProtectionScope
    }
    catch {
        if (-not $script:DataAclTightened) {
            throw 'Windows could not protect the browser session token for this user, and the private data ACL was not available.'
        }
        $ProtectionScope = 'LocalMachineAcl'
        $ProtectedToken = Protect-ControlSessionToken -Text $script:ControlToken -Scope $ProtectionScope
    }

    $TemporaryPath = Join-Path $script:DataRoot ('.control-session-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    try {
        $Utf8NoBom = [Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllLines($TemporaryPath, @(
                'GPUmatesControlSessionV1',
                $script:ControlSessionId,
                $ProtectionScope,
                $ProtectedToken
            ), $Utf8NoBom)
        Move-Item -LiteralPath $TemporaryPath -Destination $script:ControlSessionPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $TemporaryPath) {
            Remove-Item -LiteralPath $TemporaryPath -Force
        }
        $ProtectedToken = $null
    }
}

function Remove-ControlSessionFile {
    if (-not (Test-Path -LiteralPath $script:ControlSessionPath -PathType Leaf)) {
        return
    }
    try {
        $Lines = @([IO.File]::ReadAllLines($script:ControlSessionPath))
        if ($Lines.Count -ge 2 -and $Lines[0] -eq 'GPUmatesControlSessionV1' -and $Lines[1] -eq $script:ControlSessionId) {
            Remove-Item -LiteralPath $script:ControlSessionPath -Force
        }
    }
    catch {
        # A stale encrypted token is harmless and cannot authenticate a future session.
    }
}

function Get-ListeningOwnerIds {
    param([Parameter(Mandatory)][int]$PortNumber)

    try {
        return @(
            Get-NetTCPConnection -State Listen -LocalPort $PortNumber -ErrorAction Stop |
                ForEach-Object { [int]$_.OwningProcess } |
                Select-Object -Unique
        )
    }
    catch {
        $Pattern = '^\s*TCP\s+\S+:' + [regex]::Escape([string]$PortNumber) + '\s+\S+\s+LISTENING\s+(\d+)\s*$'
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

function Get-ProcessCommandLine {
    param([Parameter(Mandatory)][int]$ProcessId)
    try {
        return [string](Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop).CommandLine
    }
    catch {
        return $null
    }
}

function Get-ManagedServiceState {
    param([Parameter(Mandatory)][ValidateSet('router', 'dashboard')][string]$Service)

    $PortNumber = if ($Service -eq 'router') { 8080 } else { 8090 }
    $OwnerIds = @(Get-ListeningOwnerIds -PortNumber $PortNumber)
    if ($OwnerIds.Count -eq 0) {
        return [pscustomobject][ordered]@{
            running  = $false
            conflict = $false
            pids     = @()
            error    = $null
        }
    }

    $ExpectedIds = [Collections.Generic.List[int]]::new()
    if ($Service -eq 'router') {
        $ExpectedPath = (Resolve-Path -LiteralPath (Join-Path $script:ProjectRoot 'runtime\llama-server.exe')).Path
        $TrackedRouter = if ($script:ManagedProcessIds.ContainsKey('router')) { $script:ManagedProcessIds['router'] } else { $null }
        $TrackedWrapper = $null
        $TrackedWrapperMatches = $false
        if ($null -ne $TrackedRouter) {
            try {
                $TrackedWrapper = Get-Process -Id ([int]$TrackedRouter.id) -ErrorAction Stop
                $TrackedWrapperMatches = $TrackedWrapper.ProcessName -eq 'powershell' -and
                    $TrackedWrapper.StartTime.ToUniversalTime().Ticks -eq [int64]$TrackedRouter.startTimeUtcTicks
            }
            catch {
                $TrackedWrapperMatches = $false
            }
        }
        foreach ($OwnerId in $OwnerIds) {
            try {
                $OwnerProcess = Get-Process -Id $OwnerId -ErrorAction Stop
                $PathMatches = [string]::Equals([IO.Path]::GetFullPath($OwnerProcess.Path), $ExpectedPath, [StringComparison]::OrdinalIgnoreCase)
                $ListenerIdProperty = if ($null -ne $TrackedRouter) { $TrackedRouter.PSObject.Properties['listenerId'] } else { $null }
                if ($PathMatches -and $null -ne $ListenerIdProperty) {
                    $ListenerTicksProperty = $TrackedRouter.PSObject.Properties['listenerStartTimeUtcTicks']
                    if ([int]$TrackedRouter.listenerId -eq $OwnerId -and
                        $null -ne $ListenerTicksProperty -and
                        $OwnerProcess.StartTime.ToUniversalTime().Ticks -eq [int64]$TrackedRouter.listenerStartTimeUtcTicks) {
                        $ExpectedIds.Add($OwnerId)
                    }
                }
                elseif ($PathMatches -and $TrackedWrapperMatches -and
                    $OwnerProcess.StartTime.ToUniversalTime() -ge $TrackedWrapper.StartTime.ToUniversalTime().AddSeconds(-1)) {
                    $TrackedRouter | Add-Member -NotePropertyName listenerId -NotePropertyValue ([int]$OwnerId) -Force
                    $TrackedRouter | Add-Member -NotePropertyName listenerStartTimeUtcTicks -NotePropertyValue ([int64]$OwnerProcess.StartTime.ToUniversalTime().Ticks) -Force
                    Save-ManagedProcessState
                    $ExpectedIds.Add($OwnerId)
                }
            }
            catch {
                # Unknown listeners are reported as conflicts below.
            }
        }
    }
    else {
        $ExpectedScript = (Resolve-Path -LiteralPath (Join-Path $script:ProjectRoot 'scripts\Start-GPUmatesDashboard.ps1')).Path
        foreach ($OwnerId in $OwnerIds) {
            $TrackedMatch = $false
            if ($script:ManagedProcessIds.ContainsKey('dashboard')) {
                $Tracked = $script:ManagedProcessIds['dashboard']
                if ([int]$Tracked.id -eq $OwnerId) {
                    try {
                        $TrackedProcess = Get-Process -Id $OwnerId -ErrorAction Stop
                        $TrackedMatch = $TrackedProcess.ProcessName -eq 'powershell' -and
                            $TrackedProcess.StartTime.ToUniversalTime().Ticks -eq [int64]$Tracked.startTimeUtcTicks
                    }
                    catch {
                        $TrackedMatch = $false
                    }
                }
            }
            $CommandLine = Get-ProcessCommandLine -ProcessId $OwnerId
            $CommandLineMatch = -not [string]::IsNullOrWhiteSpace($CommandLine) -and
                $CommandLine.IndexOf($ExpectedScript, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
                $CommandLine.IndexOf($script:NodeConfigPath, [StringComparison]::OrdinalIgnoreCase) -ge 0
            if ($TrackedMatch -or $CommandLineMatch) {
                $ExpectedIds.Add($OwnerId)
            }
        }
    }

    $Conflict = $ExpectedIds.Count -ne $OwnerIds.Count
    return [pscustomobject][ordered]@{
        running  = $ExpectedIds.Count -gt 0 -and -not $Conflict
        conflict = $Conflict
        pids     = @($ExpectedIds)
        error    = if ($Conflict) { "TCP $PortNumber is occupied by a process that is not this GPUmates $Service service." } else { $null }
    }
}

function Test-TcpEndpoint {
    param(
        [Parameter(Mandatory)][string]$HostAddress,
        [Parameter(Mandatory)][int]$PortNumber,
        [ValidateRange(100, 5000)][int]$TimeoutMilliseconds = 450
    )

    $Client = [Net.Sockets.TcpClient]::new()
    try {
        try {
            $Task = $Client.ConnectAsync($HostAddress, $PortNumber)
            return $Task.Wait($TimeoutMilliseconds) -and $Client.Connected
        }
        catch {
            return $false
        }
    }
    finally {
        $Client.Dispose()
    }
}

function Wait-ManagedServiceState {
    param(
        [Parameter(Mandatory)][ValidateSet('router', 'dashboard')][string]$Service,
        [Parameter(Mandatory)][bool]$Running,
        [ValidateRange(1, 30)][int]$TimeoutSeconds = 12
    )

    $Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $State = Get-ManagedServiceState -Service $Service
        if (-not $State.conflict -and $State.running -eq $Running) {
            return $true
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $Deadline)
    return $false
}

function Quote-PowerShellArgument {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value.Contains('"')) {
        throw 'A managed process argument contained an unsupported quote character.'
    }
    return '"{0}"' -f $Value
}

function Start-HiddenPowerShellScript {
    param(
        [Parameter(Mandatory)][ValidateSet('router', 'dashboard')][string]$Service,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$ScriptArguments,
        [hashtable]$EnvironmentVariable = @{}
    )

    $PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $OutputLog = Join-Path $script:LogRoot "$Service-$Timestamp.out.log"
    $ErrorLog = Join-Path $script:LogRoot "$Service-$Timestamp.err.log"
    $ArgumentLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File {0} {1}' -f `
        (Quote-PowerShellArgument -Value $ScriptPath), $ScriptArguments

    $PreviousEnvironment = @{}
    try {
        foreach ($Name in $EnvironmentVariable.Keys) {
            $PreviousEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name, 'Process')
            [Environment]::SetEnvironmentVariable($Name, [string]$EnvironmentVariable[$Name], 'Process')
        }
        $Process = Start-Process `
            -FilePath $PowerShellExe `
            -ArgumentList $ArgumentLine `
            -WindowStyle Hidden `
            -RedirectStandardOutput $OutputLog `
            -RedirectStandardError $ErrorLog `
            -PassThru
        $script:ManagedProcessIds[$Service] = [pscustomobject]@{
            id                = [int]$Process.Id
            startTimeUtcTicks = [int64]$Process.StartTime.ToUniversalTime().Ticks
            scriptPath        = $ScriptPath
        }
        Save-ManagedProcessState
        return [pscustomobject]@{
            process  = $Process
            outputLog = $OutputLog
            errorLog  = $ErrorLog
        }
    }
    finally {
        foreach ($Name in $EnvironmentVariable.Keys) {
            if ($null -eq $PreviousEnvironment[$Name]) {
                [Environment]::SetEnvironmentVariable($Name, $null, 'Process')
            }
            else {
                [Environment]::SetEnvironmentVariable($Name, [string]$PreviousEnvironment[$Name], 'Process')
            }
        }
    }
}

function Get-LogFailureText {
    param([Parameter(Mandatory)][object]$Launch)

    $Lines = @()
    foreach ($Path in @($Launch.errorLog, $Launch.outputLog)) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $Lines += @(Get-Content -LiteralPath $Path -Tail 20 -ErrorAction SilentlyContinue)
        }
    }
    $Text = ($Lines | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ' '
    if ($Text.Length -gt 1200) {
        $Text = $Text.Substring($Text.Length - 1200)
    }
    return $Text
}

function Stop-ManagedService {
    param([Parameter(Mandatory)][ValidateSet('router', 'dashboard')][string]$Service)

    $State = Get-ManagedServiceState -Service $Service
    if ($State.conflict) {
        throw $State.error
    }
    foreach ($ProcessId in @($State.pids)) {
        # Re-read the expected state immediately before stopping to reduce PID-reuse risk.
        $Current = Get-ManagedServiceState -Service $Service
        if ($ProcessId -notin @($Current.pids) -or $Current.conflict) {
            throw "The $Service process changed while it was being stopped. No process was terminated."
        }
        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
    }

    if ($script:ManagedProcessIds.ContainsKey($Service)) {
        $TrackedWrapper = $script:ManagedProcessIds[$Service]
        $WrapperId = [int]$TrackedWrapper.id
        $Wrapper = Get-Process -Id $WrapperId -ErrorAction SilentlyContinue
        if ($Wrapper) {
            $CommandLine = Get-ProcessCommandLine -ProcessId $WrapperId
            $ExpectedMarker = if ($Service -eq 'router') { 'Start-ModelRouterFromControl.ps1' } else { 'Start-GPUmatesDashboard.ps1' }
            $TrackedIdentityMatches = $Wrapper.StartTime.ToUniversalTime().Ticks -eq [int64]$TrackedWrapper.startTimeUtcTicks
            $CommandLineMatches = -not [string]::IsNullOrWhiteSpace($CommandLine) -and $CommandLine.IndexOf($ExpectedMarker, [StringComparison]::OrdinalIgnoreCase) -ge 0
            if ($TrackedIdentityMatches -and ($CommandLineMatches -or [string]$TrackedWrapper.scriptPath -like "*$ExpectedMarker")) {
                Stop-Process -Id $WrapperId -Force -ErrorAction SilentlyContinue
            }
        }
        $script:ManagedProcessIds.Remove($Service)
        Save-ManagedProcessState
    }
    if (-not (Wait-ManagedServiceState -Service $Service -Running $false -TimeoutSeconds 6)) {
        throw "The $Service listener did not stop within the expected time."
    }
}

function Start-RouterService {
    param(
        [AllowNull()][string[]]$WorkerIps,
        [switch]$WorkerSelectionSupplied
    )

    $Existing = Get-ManagedServiceState -Service router
    if ($Existing.conflict) {
        throw $Existing.error
    }
    if ($Existing.running) {
        return
    }

    $Configuration = Get-ControlConfiguration
    if ($WorkerSelectionSupplied) {
        $RequestedWorkers = Get-UniquePrivateIPv4List -Value @($WorkerIps) -FieldName 'workerIps'
        $RegisteredIps = @(Get-RegisteredWorkerNodes | ForEach-Object ip)
        foreach ($Address in $RequestedWorkers) {
            if ($Address -notin $RegisteredIps) {
                throw "Worker $Address is not registered. Add it before starting the router."
            }
        }
        $Configuration.selectedWorkerIps = @($RequestedWorkers)
        Save-ControlConfiguration -Configuration $Configuration
    }

    $OfflineWorkers = @(
        $Configuration.selectedWorkerIps |
            Where-Object { -not (Test-TcpEndpoint -HostAddress $_ -PortNumber 50052 -TimeoutMilliseconds 700) }
    )
    if ($OfflineWorkers.Count -gt 0) {
        throw "RPC is offline on: $($OfflineWorkers -join ', '). Start those workers or deselect them."
    }

    $Secrets = Get-SavedSecrets
    $ListenHost = if ($Configuration.sharing.lanChatEnabled) { $Configuration.coordinatorIP } else { '127.0.0.1' }
    if ($Configuration.sharing.lanChatEnabled -and [string]::IsNullOrWhiteSpace([string]$Secrets.LlamaApiKey)) {
        throw 'Save the llama API key before enabling LAN model access.'
    }

    $RuntimeConfiguration = [pscustomobject][ordered]@{
        schemaVersion = 1
        workerIps     = @($Configuration.selectedWorkerIps)
        listenHost    = $ListenHost
        port          = 8080
        contextSize   = [int]$Configuration.settings.contextSize
        presetPath    = $script:ModelPresetPath
        tensorSplit   = [string]$Configuration.settings.tensorSplit
    }
    Write-JsonAtomic -Path $script:RouterRuntimeConfigPath -Value $RuntimeConfiguration

    $Environment = @{}
    if ($Configuration.sharing.lanChatEnabled) {
        $Environment.GPUMATES_LLAMA_API_KEY = [string]$Secrets.LlamaApiKey
    }
    $Launch = Start-HiddenPowerShellScript `
        -Service router `
        -ScriptPath (Join-Path $script:ProjectRoot 'scripts\Start-ModelRouterFromControl.ps1') `
        -ScriptArguments ('-RuntimeConfigPath {0}' -f (Quote-PowerShellArgument -Value $script:RouterRuntimeConfigPath)) `
        -EnvironmentVariable $Environment

    $Secrets.AgentKey = $null
    $Secrets.DashboardKey = $null
    $Secrets.LlamaApiKey = $null
    if (-not (Wait-ManagedServiceState -Service router -Running $true -TimeoutSeconds 15)) {
        if (-not $Launch.process.HasExited) {
            Stop-Process -Id $Launch.process.Id -Force -ErrorAction SilentlyContinue
        }
        try { $Launch.process.WaitForExit(2000) | Out-Null } catch {}
        $Details = Get-LogFailureText -Launch $Launch
        throw "The model router did not start. $Details"
    }
}

function Start-DashboardService {
    $Existing = Get-ManagedServiceState -Service dashboard
    if ($Existing.conflict) {
        throw $Existing.error
    }
    if ($Existing.running) {
        return
    }

    $Configuration = Get-ControlConfiguration
    $Secrets = Get-SavedSecrets
    if ([string]::IsNullOrWhiteSpace([string]$Secrets.AgentKey) -or
        [string]::IsNullOrWhiteSpace([string]$Secrets.DashboardKey)) {
        throw 'Save the AgentKey and DashboardKey before starting the node dashboard.'
    }
    $Environment = @{
        GPUMATES_AGENT_KEY = [string]$Secrets.AgentKey
        GPUMATES_DASHBOARD_KEY = [string]$Secrets.DashboardKey
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Secrets.LlamaApiKey)) {
        $Environment.GPUMATES_LLAMA_API_KEY = [string]$Secrets.LlamaApiKey
    }
    $DashboardScript = Join-Path $script:ProjectRoot 'scripts\Start-GPUmatesDashboard.ps1'
    $Arguments = '-ListenIP {0} -Port 8090 -NodeConfig {1}' -f `
        (Quote-PowerShellArgument -Value $Configuration.coordinatorIP),
        (Quote-PowerShellArgument -Value $script:NodeConfigPath)
    $Launch = Start-HiddenPowerShellScript `
        -Service dashboard `
        -ScriptPath $DashboardScript `
        -ScriptArguments $Arguments `
        -EnvironmentVariable $Environment

    $Secrets.AgentKey = $null
    $Secrets.DashboardKey = $null
    $Secrets.LlamaApiKey = $null
    if (-not (Wait-ManagedServiceState -Service dashboard -Running $true -TimeoutSeconds 12)) {
        if (-not $Launch.process.HasExited) {
            Stop-Process -Id $Launch.process.Id -Force -ErrorAction SilentlyContinue
        }
        try { $Launch.process.WaitForExit(2000) | Out-Null } catch {}
        $Details = Get-LogFailureText -Launch $Launch
        throw "The node dashboard did not start. $Details"
    }
}

function Get-RouterBaseUrl {
    $Configuration = Get-ControlConfiguration
    $HostAddress = if ($Configuration.sharing.lanChatEnabled) { $Configuration.coordinatorIP } else { '127.0.0.1' }
    return "http://$HostAddress`:8080"
}

function Invoke-RouterRequest {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST')][string]$Method,
        [Parameter(Mandatory)][ValidateSet('/models', '/models/load', '/models/unload')][string]$Path,
        [AllowNull()][object]$Body,
        [ValidateRange(1, 15)][int]$TimeoutSeconds = 5
    )

    $Uri = [uri]((Get-RouterBaseUrl) + $Path)
    $Request = [Net.HttpWebRequest]::Create($Uri)
    $Request.Method = $Method
    $Request.Timeout = $TimeoutSeconds * 1000
    $Request.ReadWriteTimeout = $TimeoutSeconds * 1000
    $Request.AllowAutoRedirect = $false
    $Request.KeepAlive = $false
    $Request.Proxy = $null
    $Request.UserAgent = 'GPUmates-Control/1.0'

    $Secrets = Get-SavedSecrets
    try {
        $Configuration = Get-ControlConfiguration
        if ($Configuration.sharing.lanChatEnabled) {
            if ([string]::IsNullOrWhiteSpace([string]$Secrets.LlamaApiKey)) {
                throw 'The llama API key is not configured.'
            }
            $Request.Headers.Add('Authorization', "Bearer $($Secrets.LlamaApiKey)")
        }
        if ($Method -eq 'POST') {
            $Request.ContentType = 'application/json; charset=utf-8'
            $BodyBytes = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 8 -Compress))
            $Request.ContentLength = $BodyBytes.Length
            $RequestStream = $Request.GetRequestStream()
            try {
                $RequestStream.Write($BodyBytes, 0, $BodyBytes.Length)
            }
            finally {
                $RequestStream.Dispose()
            }
        }

        $Response = [Net.HttpWebResponse]$Request.GetResponse()
        try {
            if ([int]$Response.StatusCode -lt 200 -or [int]$Response.StatusCode -ge 300) {
                throw "Router returned HTTP $([int]$Response.StatusCode)."
            }
            $Reader = [IO.StreamReader]::new($Response.GetResponseStream(), [Text.Encoding]::UTF8)
            try {
                $Text = $Reader.ReadToEnd()
                if ([string]::IsNullOrWhiteSpace($Text)) {
                    return [pscustomobject]@{}
                }
                return $Text | ConvertFrom-Json -ErrorAction Stop
            }
            finally {
                $Reader.Dispose()
            }
        }
        finally {
            $Response.Dispose()
        }
    }
    finally {
        $Secrets.AgentKey = $null
        $Secrets.DashboardKey = $null
        $Secrets.LlamaApiKey = $null
    }
}

function Read-ModelPresetText {
    if (-not (Test-Path -LiteralPath $script:ModelPresetPath -PathType Leaf)) {
        throw "The model preset file does not exist: $($script:ModelPresetPath)"
    }

    $Bytes = [IO.File]::ReadAllBytes($script:ModelPresetPath)
    $Offset = 0
    if ($Bytes.Length -ge 3 -and
        $Bytes[0] -eq 0xEF -and
        $Bytes[1] -eq 0xBB -and
        $Bytes[2] -eq 0xBF) {
        $Offset = 3
    }
    try {
        return [Text.UTF8Encoding]::new($false, $true).GetString($Bytes, $Offset, $Bytes.Length - $Offset)
    }
    catch {
        throw 'The model preset file is not valid UTF-8.'
    }
}

function Get-ModelPresetSections {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $HeaderMatches = [regex]::Matches(
        $Text,
        '(?m)^[\t ]*\[([^\]\r\n]+)\][\t ]*(?:\r\n|\n|\r|$)'
    )
    $Sections = [Collections.Generic.List[object]]::new()
    for ($Index = 0; $Index -lt $HeaderMatches.Count; $Index++) {
        $Header = $HeaderMatches[$Index]
        $EndIndex = if ($Index + 1 -lt $HeaderMatches.Count) {
            $HeaderMatches[$Index + 1].Index
        }
        else {
            $Text.Length
        }
        $BodyStart = $Header.Index + $Header.Length
        $Body = $Text.Substring($BodyStart, $EndIndex - $BodyStart)
        $ModelMatch = [regex]::Match(
            $Body,
            '(?im)^[\t ]*model[\t ]*=[\t ]*(.*?)[\t ]*$'
        )
        $ModelPath = $null
        if ($ModelMatch.Success) {
            $ModelPath = $ModelMatch.Groups[1].Value.Trim().Trim('"').Trim("'")
        }
        $Sections.Add([pscustomobject][ordered]@{
                id         = $Header.Groups[1].Value.Trim()
                startIndex = $Header.Index
                endIndex   = $EndIndex
                modelPath  = $ModelPath
            })
    }
    return @($Sections)
}

function Get-PresetModels {
    $Models = [Collections.Generic.List[object]]::new()
    $PresetText = Read-ModelPresetText
    foreach ($Section in @(Get-ModelPresetSections -Text $PresetText)) {
        if ([string]::IsNullOrWhiteSpace([string]$Section.modelPath)) {
            continue
        }
        $ModelPath = [string]$Section.modelPath
        $Exists = Test-Path -LiteralPath $ModelPath -PathType Leaf
        $SizeBytes = $null
        if ($Exists) {
            $SizeBytes = [int64](Get-Item -LiteralPath $ModelPath).Length
        }
        $Models.Add([pscustomobject][ordered]@{
                id        = [string]$Section.id
                path      = $ModelPath
                exists    = $Exists
                sizeBytes = $SizeBytes
                status    = 'unavailable'
            })
    }
    return @($Models)
}

function Resolve-FriendlyModelId {
    param([Parameter(Mandatory)][string]$ModelId)

    $Result = $ModelId.Trim()
    if ($Result.Length -lt 1 -or
        $Result.Length -gt 64 -or
        $Result -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$') {
        throw 'Model name must be 1-64 characters, start and end with a letter or number, and use only letters, numbers, dots, underscores, or hyphens.'
    }
    return $Result
}

function Resolve-LocalGgufFile {
    param([Parameter(Mandatory)][string]$Path)

    $Candidate = $Path.Trim().Trim('"').Trim("'")
    if ([string]::IsNullOrWhiteSpace($Candidate) -or $Candidate -notmatch '^[A-Za-z]:[\\/]') {
        throw 'Choose an absolute file path on a local drive of this coordinator PC.'
    }
    if ($Candidate.Length -gt 2 -and $Candidate.Substring(2).Contains(':')) {
        throw 'Alternate data streams are not valid model files.'
    }

    try {
        $FullPath = [IO.Path]::GetFullPath($Candidate)
        $Item = Get-Item -LiteralPath $FullPath -ErrorAction Stop
    }
    catch {
        throw "The selected model file does not exist on this coordinator PC: $Candidate"
    }
    if ($Item.PSIsContainer) {
        throw 'Choose a GGUF model file, not a folder.'
    }

    try {
        $Drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Item.FullName))
        if ($Drive.DriveType -eq [IO.DriveType]::Network) {
            throw 'Network-drive model files are not supported. Copy the GGUF file to this coordinator PC first.'
        }
    }
    catch {
        if ($_.Exception.Message -like 'Network-drive model files*') {
            throw
        }
        throw 'The selected model file is not on a usable local drive.'
    }

    $Stream = $null
    try {
        $Stream = [IO.File]::Open($Item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $Magic = [byte[]]::new(4)
        if ($Stream.Read($Magic, 0, $Magic.Length) -ne 4 -or
            $Magic[0] -ne 0x47 -or
            $Magic[1] -ne 0x47 -or
            $Magic[2] -ne 0x55 -or
            $Magic[3] -ne 0x46) {
            throw 'The selected file does not have a valid GGUF file signature.'
        }
    }
    finally {
        if ($null -ne $Stream) {
            $Stream.Dispose()
        }
    }
    return Get-Item -LiteralPath $Item.FullName
}

function Get-SuggestedModelId {
    param([Parameter(Mandatory)][string]$Path)

    $Suggestion = [IO.Path]::GetFileNameWithoutExtension($Path).ToLowerInvariant()
    $Suggestion = ($Suggestion -replace '[^a-z0-9._-]+', '-') -replace '-{2,}', '-'
    $Suggestion = $Suggestion.Trim('.', '_', '-')
    if ([string]::IsNullOrWhiteSpace($Suggestion)) {
        $Suggestion = 'model'
    }
    if ($Suggestion.Length -gt 64) {
        $Suggestion = $Suggestion.Substring(0, 64).TrimEnd('.', '_', '-')
    }

    $ExistingIds = @((Get-ModelPresetSections -Text (Read-ModelPresetText)) | ForEach-Object { [string]$_.id })
    $Base = $Suggestion
    $SuffixNumber = 2
    while (@($ExistingIds | Where-Object { [string]::Equals($_, $Suggestion, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
        $Suffix = "-$SuffixNumber"
        $MaximumBaseLength = 64 - $Suffix.Length
        $ShortBase = if ($Base.Length -gt $MaximumBaseLength) {
            $Base.Substring(0, $MaximumBaseLength).TrimEnd('.', '_', '-')
        }
        else {
            $Base
        }
        $Suggestion = $ShortBase + $Suffix
        $SuffixNumber++
    }
    return $Suggestion
}

function Show-GgufFilePicker {
    Assert-ModelLibraryEditable
    if (-not [Environment]::UserInteractive) {
        throw 'The native model file picker requires an interactive Windows session.'
    }

    Add-Type -AssemblyName System.Windows.Forms
    $Dialog = [Windows.Forms.OpenFileDialog]::new()
    $Owner = [Windows.Forms.Form]::new()
    try {
        $Dialog.Title = 'Add a GGUF model to GPUmates'
        $Dialog.Filter = 'GGUF model files (*.gguf)|*.gguf|All files (*.*)|*.*'
        $Dialog.FilterIndex = 1
        $Dialog.Multiselect = $false
        $Dialog.CheckFileExists = $true
        $Dialog.CheckPathExists = $true
        $Dialog.DereferenceLinks = $true
        $Dialog.AddExtension = $false
        $Dialog.RestoreDirectory = $true
        $DownloadsPath = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'
        if (Test-Path -LiteralPath $DownloadsPath -PathType Container) {
            $Dialog.InitialDirectory = $DownloadsPath
        }

        # The controller itself has a hidden window. A transparent topmost owner
        # keeps the native picker in front of the browser that requested it.
        $Owner.ShowInTaskbar = $false
        $Owner.TopMost = $true
        $Owner.Opacity = 0
        $Owner.Width = 1
        $Owner.Height = 1
        $Owner.Show()
        $Result = $Dialog.ShowDialog($Owner)
        if ($Result -ne [Windows.Forms.DialogResult]::OK) {
            return [pscustomobject][ordered]@{
                ok            = $true
                cancelled     = $true
                path          = $null
                suggestedName = $null
                sizeBytes     = $null
                message       = 'No model file was selected.'
            }
        }

        $File = Resolve-LocalGgufFile -Path $Dialog.FileName
        return [pscustomobject][ordered]@{
            ok            = $true
            cancelled     = $false
            path          = $File.FullName
            suggestedName = Get-SuggestedModelId -Path $File.FullName
            sizeBytes     = [int64]$File.Length
            message       = 'GGUF model file selected. Confirm its model name to add it.'
        }
    }
    finally {
        $Dialog.Dispose()
        $Owner.Close()
        $Owner.Dispose()
    }
}

function Assert-ModelLibraryEditable {
    $RouterState = Get-ManagedServiceState -Service router
    if ($RouterState.running) {
        throw 'Stop the model router (which unloads its active model) before changing the model library.'
    }
    if ($RouterState.conflict) {
        throw 'TCP 8080 is occupied by another process. Stop that router or listener before changing the model library.'
    }
}

function Write-ModelPresetTextAtomic {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $FullPath = [IO.Path]::GetFullPath($script:ModelPresetPath)
    $Directory = Split-Path -Parent $FullPath
    $TemporaryPath = Join-Path $Directory ('.{0}-{1}.tmp' -f ([IO.Path]::GetFileName($FullPath)), [Guid]::NewGuid().ToString('N'))
    $BackupPath = '{0}.backup-{1}-{2}' -f $FullPath, (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $Bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    $FileStream = $null
    try {
        $FileStream = [IO.FileStream]::new(
            $TemporaryPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough
        )
        $FileStream.Write($Bytes, 0, $Bytes.Length)
        $FileStream.Flush($true)
        $FileStream.Dispose()
        $FileStream = $null

        # Re-read and parse the candidate before atomically replacing the
        # current known-good file. File.Replace creates the exact backup.
        $CandidateBytes = [IO.File]::ReadAllBytes($TemporaryPath)
        if ($CandidateBytes.Length -ge 3 -and
            $CandidateBytes[0] -eq 0xEF -and
            $CandidateBytes[1] -eq 0xBB -and
            $CandidateBytes[2] -eq 0xBF) {
            throw 'The candidate preset unexpectedly contains a UTF-8 byte-order mark.'
        }
        $CandidateText = [Text.UTF8Encoding]::new($false, $true).GetString($CandidateBytes)
        Get-ModelPresetSections -Text $CandidateText | Out-Null
        [IO.File]::Replace($TemporaryPath, $FullPath, $BackupPath, $true)
        return $BackupPath
    }
    finally {
        if ($null -ne $FileStream) {
            $FileStream.Dispose()
        }
        if (Test-Path -LiteralPath $TemporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $TemporaryPath -Force
        }
    }
}

function Add-ModelPreset {
    param(
        [Parameter(Mandatory)][string]$ModelId,
        [Parameter(Mandatory)][string]$Path
    )

    Assert-ModelLibraryEditable
    $ResolvedId = Resolve-FriendlyModelId -ModelId $ModelId
    $File = Resolve-LocalGgufFile -Path $Path
    $PresetText = Read-ModelPresetText
    $Sections = @(Get-ModelPresetSections -Text $PresetText)
    if (@($Sections | Where-Object { [string]::Equals([string]$_.id, $ResolvedId, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
        throw "A model named '$ResolvedId' is already configured. Choose a unique name."
    }
    foreach ($Section in @($Sections | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.modelPath) })) {
        try {
            $ExistingFullPath = [IO.Path]::GetFullPath([string]$Section.modelPath)
            if ([string]::Equals($ExistingFullPath, $File.FullName, [StringComparison]::OrdinalIgnoreCase)) {
                throw "This GGUF file is already configured as '$($Section.id)'."
            }
        }
        catch {
            if ($_.Exception.Message -like 'This GGUF file is already configured*') {
                throw
            }
            # A malformed legacy path remains visible as unavailable and does
            # not prevent a different valid local model from being added.
        }
    }

    $LineEnding = if ($PresetText.Contains("`r`n")) { "`r`n" } elseif ($PresetText.Contains("`n")) { "`n" } else { [Environment]::NewLine }
    $UpdatedText = $PresetText
    if ($UpdatedText.Length -gt 0 -and -not ($UpdatedText.EndsWith("`r") -or $UpdatedText.EndsWith("`n"))) {
        $UpdatedText += $LineEnding
    }
    if ($UpdatedText.Length -gt 0 -and -not $UpdatedText.EndsWith($LineEnding + $LineEnding)) {
        $UpdatedText += $LineEnding
    }
    $StoredPath = $File.FullName.Replace('\', '/')
    $UpdatedText += "[$ResolvedId]$LineEnding"
    $UpdatedText += "model = $StoredPath$LineEnding"
    $UpdatedText += "load-on-startup = false$LineEnding"
    $UpdatedText += "stop-timeout = 30$LineEnding"

    $UpdatedSections = @(Get-ModelPresetSections -Text $UpdatedText)
    if (@($UpdatedSections | Where-Object { [string]::Equals([string]$_.id, $ResolvedId, [StringComparison]::OrdinalIgnoreCase) }).Count -ne 1) {
        throw 'The updated model preset could not be validated.'
    }
    $BackupPath = Write-ModelPresetTextAtomic -Text $UpdatedText
    $AddedModel = @(Get-PresetModels | Where-Object { [string]::Equals([string]$_.id, $ResolvedId, [StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
    return [pscustomobject][ordered]@{
        ok         = $true
        message    = "Model '$ResolvedId' was added. Start the router when you are ready to load it."
        model      = $AddedModel
        models     = @(Get-PresetModels)
        backupPath = $BackupPath
    }
}

function Remove-ModelPreset {
    param([Parameter(Mandatory)][string]$ModelId)

    Assert-ModelLibraryEditable
    $ResolvedId = Resolve-FriendlyModelId -ModelId $ModelId
    $PresetText = Read-ModelPresetText
    $Sections = @(Get-ModelPresetSections -Text $PresetText)
    $Matches = @($Sections | Where-Object { [string]::Equals([string]$_.id, $ResolvedId, [StringComparison]::OrdinalIgnoreCase) })
    if ($Matches.Count -eq 0) {
        throw "Model '$ResolvedId' is not configured."
    }
    if ($Matches.Count -ne 1) {
        throw "Model '$ResolvedId' appears more than once in the preset file. Resolve the duplicate sections manually before removing it."
    }
    $Target = $Matches[0]
    if ([string]::IsNullOrWhiteSpace([string]$Target.modelPath)) {
        throw "Section '$ResolvedId' is not a model preset and cannot be removed here."
    }
    $RemovedModel = @(Get-PresetModels | Where-Object { [string]::Equals([string]$_.id, [string]$Target.id, [StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
    $UpdatedText = $PresetText.Remove([int]$Target.startIndex, [int]$Target.endIndex - [int]$Target.startIndex)
    if (@((Get-ModelPresetSections -Text $UpdatedText) | Where-Object { [string]::Equals([string]$_.id, $ResolvedId, [StringComparison]::OrdinalIgnoreCase) }).Count -ne 0) {
        throw 'The updated model preset could not be validated.'
    }
    $BackupPath = Write-ModelPresetTextAtomic -Text $UpdatedText
    return [pscustomobject][ordered]@{
        ok           = $true
        message      = "Model '$($Target.id)' was removed from the library. Its GGUF file was not deleted."
        removedModel = $RemovedModel
        models       = @(Get-PresetModels)
        backupPath   = $BackupPath
    }
}

function Get-RouterModelStatus {
    param([Parameter(Mandatory)][object[]]$PresetModels)

    $ActiveModel = $null
    $RouterState = Get-ManagedServiceState -Service router
    if (-not $RouterState.running) {
        return [pscustomobject]@{
            activeModel = $null
            models      = @($PresetModels)
        }
    }

    try {
        $Response = Invoke-RouterRequest -Method GET -Path '/models' -Body $null -TimeoutSeconds 3
        $RawModels = Get-ObjectProperty -InputObject $Response -Name 'data' -DefaultValue $Response
        foreach ($Preset in $PresetModels) {
            $Match = @($RawModels | Where-Object {
                    [string](Get-ObjectProperty -InputObject $_ -Name 'id' -DefaultValue (Get-ObjectProperty -InputObject $_ -Name 'name')) -eq $Preset.id
                }) | Select-Object -First 1
            if ($null -ne $Match) {
                $RawStatus = Get-ObjectProperty -InputObject $Match -Name 'status' -DefaultValue 'unknown'
                if ($null -ne $RawStatus -and $null -ne $RawStatus.PSObject.Properties['value']) {
                    $RawStatus = $RawStatus.value
                }
                $Preset.status = [string]$RawStatus
                if ($Preset.status -eq 'loaded') {
                    $ActiveModel = $Preset.id
                }
            }
            else {
                $Preset.status = 'unloaded'
            }
        }
    }
    catch {
        foreach ($Preset in $PresetModels) {
            $Preset.status = 'unknown'
        }
    }
    return [pscustomobject]@{
        activeModel = $ActiveModel
        models      = @($PresetModels)
    }
}

function Set-ModelLoadedState {
    param(
        [Parameter(Mandatory)][string]$ModelId,
        [Parameter(Mandatory)][ValidateSet('load', 'unload')][string]$Action
    )

    $Models = @(Get-PresetModels)
    $Known = $Models | Where-Object { $_.id -eq $ModelId } | Select-Object -First 1
    if ($null -eq $Known) {
        throw 'The requested model is not one of the configured presets.'
    }
    if (-not $Known.exists) {
        throw "The configured GGUF file does not exist: $($Known.path)"
    }
    $RouterState = Get-ManagedServiceState -Service router
    if (-not $RouterState.running) {
        throw 'Start the model router before loading or unloading a model.'
    }
    $Path = if ($Action -eq 'load') { '/models/load' } else { '/models/unload' }
    Invoke-RouterRequest -Method POST -Path $Path -Body ([pscustomobject]@{ model = $ModelId }) -TimeoutSeconds 15 | Out-Null
}

function Get-WorkerStatus {
    $Configuration = Get-ControlConfiguration
    return @(
        Get-RegisteredWorkerNodes |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    name            = $_.name
                    ip              = $_.ip
                    rpcOnline       = Test-TcpEndpoint -HostAddress $_.ip -PortNumber 50052
                    telemetryOnline = Test-TcpEndpoint -HostAddress $_.ip -PortNumber $_.port
                    selected        = $_.ip -in @($Configuration.selectedWorkerIps)
                }
            }
    )
}

function Add-WorkerNode {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$IPAddress
    )

    $Name = $Name.Trim()
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 64 -or $Name -notmatch '^[\p{L}\p{N} ._-]+$') {
        throw 'Worker name may contain only letters, numbers, spaces, dots, underscores, and hyphens.'
    }
    if (-not (Test-PrivateIPv4Text -Text $IPAddress)) {
        throw 'Worker IP must be one exact private IPv4 address.'
    }
    $CanonicalIP = ([Net.IPAddress]$IPAddress).IPAddressToString
    $RegistrationScript = Join-Path $script:ProjectRoot 'scripts\Register-WorkerOnCoordinator.ps1'
    & $RegistrationScript -WorkerIP ([Net.IPAddress]$CanonicalIP) -NodeName $Name -NodeConfig $script:NodeConfigPath | Out-Null

    $Configuration = Get-ControlConfiguration
    $Configuration.selectedWorkerIps = @($Configuration.selectedWorkerIps + $CanonicalIP | Select-Object -Unique)
    $Configuration.sharing.chatClientIps = @($Configuration.sharing.chatClientIps + $CanonicalIP | Select-Object -Unique)
    $Configuration.sharing.dashboardClientIps = @($Configuration.sharing.dashboardClientIps + $CanonicalIP | Select-Object -Unique)
    Save-ControlConfiguration -Configuration $Configuration
}

function Remove-WorkerNode {
    param([Parameter(Mandatory)][string]$IPAddress)

    if (-not (Test-PrivateIPv4Text -Text $IPAddress)) {
        throw 'Worker IP must be one exact private IPv4 address.'
    }
    $CanonicalIP = ([Net.IPAddress]$IPAddress).IPAddressToString
    $NodeConfiguration = Read-NodeConfiguration
    $BeforeCount = @($NodeConfiguration.nodes).Count
    $NodeConfiguration.nodes = @($NodeConfiguration.nodes | Where-Object {
            [bool](Get-ObjectProperty -InputObject $_ -Name 'local' -DefaultValue $false) -or [string]$_.host -ne $CanonicalIP
        })
    if (@($NodeConfiguration.nodes).Count -eq $BeforeCount) {
        throw "Worker $CanonicalIP is not registered."
    }
    $NodeConfiguration.dashboard.allowedClientIps = @(
        $NodeConfiguration.dashboard.allowedClientIps |
            Where-Object { [string]$_ -ne $CanonicalIP }
    )
    Write-JsonAtomic -Path $script:NodeConfigPath -Value $NodeConfiguration -Backup

    $Configuration = Get-ControlConfiguration
    $Configuration.selectedWorkerIps = @($Configuration.selectedWorkerIps | Where-Object { $_ -ne $CanonicalIP })
    $Configuration.sharing.chatClientIps = @($Configuration.sharing.chatClientIps | Where-Object { $_ -ne $CanonicalIP })
    $Configuration.sharing.dashboardClientIps = @($Configuration.sharing.dashboardClientIps | Where-Object { $_ -ne $CanonicalIP })
    Save-ControlConfiguration -Configuration $Configuration
}

function Set-DashboardLlamaConfiguration {
    param(
        [Parameter(Mandatory)][bool]$LanChatEnabled,
        [Parameter(Mandatory)][string[]]$DashboardClientIps
    )

    $NodeConfiguration = Read-NodeConfiguration
    $CoordinatorIP = Get-CoordinatorIPText
    $NodeConfiguration.dashboard.allowedClientIps = @(
        @($CoordinatorIP) + @($DashboardClientIps) | Select-Object -Unique
    )
    $Llama = Get-ObjectProperty -InputObject $NodeConfiguration -Name 'llama'
    if ($null -eq $Llama) {
        $Llama = [pscustomobject][ordered]@{ enabled = $true; baseUrl = 'http://127.0.0.1:8080' }
        $NodeConfiguration | Add-Member -NotePropertyName llama -NotePropertyValue $Llama
    }
    $Llama.enabled = $true
    if ($LanChatEnabled) {
        $Llama.baseUrl = "http://$CoordinatorIP`:8080"
        if ($null -eq $Llama.PSObject.Properties['publicUrl']) {
            $Llama | Add-Member -NotePropertyName publicUrl -NotePropertyValue "http://$CoordinatorIP`:8080"
        }
        else {
            $Llama.publicUrl = "http://$CoordinatorIP`:8080"
        }
    }
    else {
        $Llama.baseUrl = 'http://127.0.0.1:8080'
        if ($null -ne $Llama.PSObject.Properties['publicUrl']) {
            $Llama.PSObject.Properties.Remove('publicUrl')
        }
    }
    Write-JsonAtomic -Path $script:NodeConfigPath -Value $NodeConfiguration -Backup
}

function Invoke-ElevatedSharingHelper {
    param(
        [Parameter(Mandatory)][bool]$LanChatEnabled,
        [Parameter(Mandatory)][string[]]$ChatClientIps,
        [Parameter(Mandatory)][string[]]$DashboardClientIps
    )

    $Request = [pscustomobject][ordered]@{
        schemaVersion      = 1
        projectRoot        = $script:ProjectRoot
        coordinatorIP      = Get-CoordinatorIPText
        lanChatEnabled     = $LanChatEnabled
        chatClientIps      = @($ChatClientIps)
        dashboardClientIps = @($DashboardClientIps)
    }
    $RequestJson = $Request | ConvertTo-Json -Depth 8 -Compress
    $RequestBytes = [Text.Encoding]::UTF8.GetBytes($RequestJson)
    try {
        $RequestBase64 = [Convert]::ToBase64String($RequestBytes)
        if ($RequestBase64.Length -gt 24000) {
            throw 'The sharing client lists are too large for the elevated firewall handoff.'
        }
        $PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $HelperPath = Join-Path $script:ProjectRoot 'scripts\Apply-CoordinatorSharing.ps1'
        $Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File {0} -RequestBase64 {1}' -f `
            (Quote-PowerShellArgument -Value $HelperPath),
            (Quote-PowerShellArgument -Value $RequestBase64)
        try {
            $Process = Start-Process -FilePath $PowerShellExe -ArgumentList $Arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru
        }
        catch {
            throw 'Windows Administrator approval was canceled or could not be opened.'
        }
        if ($Process.ExitCode -ne 0) {
            throw "The elevated firewall helper failed with exit code $($Process.ExitCode). Verify the coordinator IP and Windows Firewall service."
        }
        return 'Windows Firewall sharing rules were updated.'
    }
    finally {
        [Array]::Clear($RequestBytes, 0, $RequestBytes.Length)
        $RequestJson = $null
        $RequestBase64 = $null
    }
}

function Apply-SharingConfiguration {
    param(
        [Parameter(Mandatory)][bool]$Enabled,
        [AllowNull()][object[]]$ChatClientIps,
        [AllowNull()][object[]]$DashboardClientIps
    )

    $ChatClients = Get-UniquePrivateIPv4List -Value $ChatClientIps -FieldName 'chatClientIps'
    $DashboardClients = Get-UniquePrivateIPv4List -Value $DashboardClientIps -FieldName 'dashboardClientIps'
    $RouterWasRunning = (Get-ManagedServiceState -Service router).running
    $DashboardWasRunning = (Get-ManagedServiceState -Service dashboard).running

    $Message = Invoke-ElevatedSharingHelper `
        -LanChatEnabled $Enabled `
        -ChatClientIps $ChatClients `
        -DashboardClientIps $DashboardClients

    if ($RouterWasRunning) {
        Stop-ManagedService -Service router
    }
    if ($DashboardWasRunning) {
        Stop-ManagedService -Service dashboard
    }

    $Configuration = Get-ControlConfiguration
    $Configuration.sharing.lanChatEnabled = $Enabled
    $Configuration.sharing.chatClientIps = @($ChatClients)
    $Configuration.sharing.dashboardClientIps = @($DashboardClients)
    Save-ControlConfiguration -Configuration $Configuration
    Set-DashboardLlamaConfiguration -LanChatEnabled $Enabled -DashboardClientIps $DashboardClients

    if ($DashboardWasRunning) {
        Start-DashboardService
    }
    if ($RouterWasRunning) {
        Start-RouterService -WorkerIps $null
    }
    return $Message
}

function Save-ControlSettings {
    param([Parameter(Mandatory)][object]$Body)

    $Configuration = Get-ControlConfiguration
    $SettingsBody = Get-ObjectProperty -InputObject $Body -Name 'settings' -DefaultValue $Body
    $SelectedValue = Get-ObjectProperty -InputObject $SettingsBody -Name 'selectedWorkerIps' -DefaultValue (Get-ObjectProperty -InputObject $Body -Name 'selectedWorkerIps' -DefaultValue $Configuration.selectedWorkerIps)
    $Selected = Get-UniquePrivateIPv4List -Value @($SelectedValue) -FieldName 'selectedWorkerIps'
    $Registered = @(Get-RegisteredWorkerNodes | ForEach-Object ip)
    foreach ($Address in $Selected) {
        if ($Address -notin $Registered) {
            throw "Selected worker $Address is not registered."
        }
    }
    $Configuration.selectedWorkerIps = @($Selected)
    $Configuration.settings.autoStartRouter = [bool](Get-ObjectProperty -InputObject $SettingsBody -Name 'autoStartRouter' -DefaultValue $Configuration.settings.autoStartRouter)
    $Configuration.settings.autoStartDashboard = [bool](Get-ObjectProperty -InputObject $SettingsBody -Name 'autoStartDashboard' -DefaultValue $Configuration.settings.autoStartDashboard)
    $ContextSize = [int](Get-ObjectProperty -InputObject $SettingsBody -Name 'contextSize' -DefaultValue $Configuration.settings.contextSize)
    if ($ContextSize -lt 512 -or $ContextSize -gt 1048576) {
        throw 'Context size must be between 512 and 1048576.'
    }
    $Configuration.settings.contextSize = $ContextSize
    $TensorSplit = [string](Get-ObjectProperty -InputObject $SettingsBody -Name 'tensorSplit' -DefaultValue $Configuration.settings.tensorSplit)
    $TensorSplit = $TensorSplit.Trim()
    if (-not [string]::IsNullOrWhiteSpace($TensorSplit) -and $TensorSplit -notmatch '^\d+(?:\.\d+)?(?:,\d+(?:\.\d+)?)*$') {
        throw 'Tensor split must be comma-separated nonnegative numbers, for example 1,1,2.'
    }
    $Configuration.settings.tensorSplit = $TensorSplit
    foreach ($FixedPort in @(
            @('rpcPort', 50052),
            @('routerPort', 8080),
            @('dashboardPort', 8090)
        )) {
        $RequestedPort = Get-ObjectProperty -InputObject $SettingsBody -Name $FixedPort[0] -DefaultValue $FixedPort[1]
        if ([int]$RequestedPort -ne [int]$FixedPort[1]) {
            throw "$($FixedPort[0]) is fixed at $($FixedPort[1]) in this release."
        }
    }
    Save-ControlConfiguration -Configuration $Configuration
}

function Get-CoordinatorDisplayName {
    $NodeConfiguration = Read-NodeConfiguration
    $LocalNode = @($NodeConfiguration.nodes | Where-Object {
            [bool](Get-ObjectProperty -InputObject $_ -Name 'local' -DefaultValue $false)
        }) | Select-Object -First 1
    if ($LocalNode -and -not [string]::IsNullOrWhiteSpace([string]$LocalNode.name)) {
        return [string]$LocalNode.name
    }
    return $env:COMPUTERNAME
}

function Get-ControlStatus {
    $Configuration = Get-ControlConfiguration
    $RouterState = Get-ManagedServiceState -Service router
    $DashboardState = Get-ManagedServiceState -Service dashboard
    $PresetModels = @(Get-PresetModels)
    $ModelStatus = Get-RouterModelStatus -PresetModels $PresetModels
    $SecretsConfigured = @{
        AgentKey = $false
        DashboardKey = $false
        LlamaApiKey = $false
    }
    try {
        $Secrets = Get-SavedSecrets
        foreach ($Name in @('AgentKey', 'DashboardKey', 'LlamaApiKey')) {
            $SecretsConfigured[$Name] = -not [string]::IsNullOrWhiteSpace([string]$Secrets[$Name])
            $Secrets[$Name] = $null
        }
    }
    catch {
        $script:LastError = $_.Exception.Message
    }

    $ChatHost = if ($Configuration.sharing.lanChatEnabled) { $Configuration.coordinatorIP } else { '127.0.0.1' }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        coordinator   = [pscustomobject][ordered]@{
            name = Get-CoordinatorDisplayName
            ip   = $Configuration.coordinatorIP
        }
        services      = [pscustomobject][ordered]@{
            router    = [pscustomobject][ordered]@{
                running     = [bool]$RouterState.running
                state       = if ($RouterState.running) { 'running' } elseif ($RouterState.conflict) { 'conflict' } else { 'stopped' }
                mode        = if ($Configuration.sharing.lanChatEnabled) { 'lan' } else { 'local' }
                activeModel = $ModelStatus.activeModel
                url         = if ($RouterState.running) { "http://$ChatHost`:8080" } else { $null }
                error       = $RouterState.error
            }
            dashboard = [pscustomobject][ordered]@{
                running = [bool]$DashboardState.running
                state   = if ($DashboardState.running) { 'running' } elseif ($DashboardState.conflict) { 'conflict' } else { 'stopped' }
                url     = if ($DashboardState.running) { "http://$($Configuration.coordinatorIP):8090" } else { $null }
                error   = $DashboardState.error
            }
        }
        setup         = [pscustomobject][ordered]@{
            agentKeySaved     = [bool]$SecretsConfigured.AgentKey
            dashboardKeySaved = [bool]$SecretsConfigured.DashboardKey
            llamaApiKeySaved  = [bool]$SecretsConfigured.LlamaApiKey
            complete           = [bool]($SecretsConfigured.AgentKey -and $SecretsConfigured.DashboardKey -and $SecretsConfigured.LlamaApiKey)
        }
        workers       = @(Get-WorkerStatus)
        models        = @($ModelStatus.models)
        sharing       = [pscustomobject][ordered]@{
            enabled            = [bool]$Configuration.sharing.lanChatEnabled
            lanAccess          = [bool]$Configuration.sharing.lanChatEnabled
            chatClientIps      = @($Configuration.sharing.chatClientIps)
            dashboardClientIps = @($Configuration.sharing.dashboardClientIps)
        }
        settings      = [pscustomobject][ordered]@{
            contextSize        = [int]$Configuration.settings.contextSize
            tensorSplit        = Get-ObjectProperty -InputObject $Configuration.settings -Name 'tensorSplit'
            rpcPort             = 50052
            routerPort          = 8080
            dashboardPort       = 8090
            autoStartRouter     = [bool]$Configuration.settings.autoStartRouter
            autoStartDashboard  = [bool]$Configuration.settings.autoStartDashboard
        }
        urls          = [pscustomobject][ordered]@{
            chat     = if ($RouterState.running) { "http://$ChatHost`:8080" } else { $null }
            dashboard = if ($DashboardState.running) { "http://$($Configuration.coordinatorIP):8090" } else { $null }
            control  = "http://127.0.0.1`:$Port"
        }
        lastError     = $script:LastError
    }
}

function Read-ControlHttpRequest {
    param(
        [Parameter(Mandatory)][Net.Sockets.NetworkStream]$Stream,
        [ValidateRange(1024, 65536)][int]$MaximumHeaderBytes = 16384,
        [ValidateRange(1024, 262144)][int]$MaximumBodyBytes = 65536
    )

    $Bytes = [Collections.Generic.List[byte]]::new()
    $Terminator = [byte[]](13, 10, 13, 10)
    [int]$Matched = 0
    while ($Bytes.Count -lt $MaximumHeaderBytes) {
        $Value = $Stream.ReadByte()
        if ($Value -lt 0) {
            break
        }
        $Byte = [byte]$Value
        $Bytes.Add($Byte)
        if ($Byte -eq $Terminator[$Matched]) {
            $Matched++
            if ($Matched -eq 4) {
                break
            }
        }
        else {
            $Matched = if ($Byte -eq 13) { 1 } else { 0 }
        }
    }
    if ($Matched -ne 4) {
        throw 'HTTP headers were incomplete or too large.'
    }

    $HeaderText = [Text.Encoding]::ASCII.GetString($Bytes.ToArray())
    $Lines = @($HeaderText -split "\r\n")
    if ($Lines.Count -lt 1 -or $Lines[0] -notmatch '^(GET|HEAD|POST) (/[^ ]*) HTTP/(1\.0|1\.1)$') {
        throw 'The request line is invalid.'
    }
    $Method = $Matches[1]
    $Target = $Matches[2]
    if ($Target.Length -gt 2048 -or $Target.Contains('#')) {
        throw 'The request target is invalid.'
    }

    $Headers = @{}
    for ($Index = 1; $Index -lt $Lines.Count; $Index++) {
        $Line = $Lines[$Index]
        if ([string]::IsNullOrEmpty($Line)) {
            continue
        }
        $ColonIndex = $Line.IndexOf(':')
        if ($ColonIndex -le 0) {
            throw 'A malformed HTTP header was received.'
        }
        $Name = $Line.Substring(0, $ColonIndex).Trim().ToLowerInvariant()
        $Value = $Line.Substring($ColonIndex + 1).Trim()
        if ($Headers.ContainsKey($Name)) {
            throw "Duplicate HTTP header is not allowed: $Name"
        }
        $Headers[$Name] = $Value
    }
    if ($Headers.ContainsKey('transfer-encoding')) {
        throw 'Transfer-Encoding is not supported.'
    }

    [int]$ContentLength = 0
    if ($Headers.ContainsKey('content-length')) {
        if (-not [int]::TryParse([string]$Headers['content-length'], [ref]$ContentLength) -or
            $ContentLength -lt 0 -or $ContentLength -gt $MaximumBodyBytes) {
            throw 'Content-Length is invalid or too large.'
        }
    }
    if ($Method -eq 'POST' -and -not $Headers.ContainsKey('content-length')) {
        throw 'POST requests require Content-Length.'
    }
    if ($Method -ne 'POST' -and $ContentLength -ne 0) {
        throw 'GET and HEAD requests cannot contain a body.'
    }

    $BodyBytes = [byte[]]::new($ContentLength)
    [int]$Offset = 0
    while ($Offset -lt $ContentLength) {
        $Read = $Stream.Read($BodyBytes, $Offset, $ContentLength - $Offset)
        if ($Read -le 0) {
            throw 'The HTTP body ended before Content-Length bytes were received.'
        }
        $Offset += $Read
    }

    $PathText = ($Target -split '\?', 2)[0]
    try {
        $DecodedPath = [uri]::UnescapeDataString($PathText)
    }
    catch {
        throw 'The request path contains invalid percent encoding.'
    }
    return [pscustomobject][ordered]@{
        method   = $Method
        target   = $Target
        path     = $DecodedPath
        headers  = $Headers
        bodyText = if ($ContentLength -gt 0) { [Text.Encoding]::UTF8.GetString($BodyBytes) } else { '' }
    }
}

function Write-ControlHttpResponse {
    param(
        [Parameter(Mandatory)][Net.Sockets.NetworkStream]$Stream,
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter(Mandatory)][string]$ReasonPhrase,
        [Parameter(Mandatory)][byte[]]$Body,
        [string]$ContentType = 'application/json; charset=utf-8',
        [switch]$HeadOnly
    )

    $Headers = @(
        "HTTP/1.1 $StatusCode $ReasonPhrase",
        "Date: $([DateTime]::UtcNow.ToString('R'))",
        'Server: GPUmates-Control',
        "Content-Type: $ContentType",
        "Content-Length: $($Body.Length)",
        'Cache-Control: no-store',
        'X-Content-Type-Options: nosniff',
        'Referrer-Policy: no-referrer',
        'X-Frame-Options: DENY',
        "Content-Security-Policy: default-src 'self'; connect-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
        'Permissions-Policy: camera=(), microphone=(), geolocation=()',
        'Cross-Origin-Resource-Policy: same-origin',
        'Connection: close',
        '',
        ''
    )
    $HeaderBytes = [Text.Encoding]::ASCII.GetBytes($Headers -join "`r`n")
    $Stream.Write($HeaderBytes, 0, $HeaderBytes.Length)
    if (-not $HeadOnly -and $Body.Length -gt 0) {
        $Stream.Write($Body, 0, $Body.Length)
    }
    $Stream.Flush()
}

function ConvertTo-ControlJsonBytes {
    param([Parameter(Mandatory)][object]$Value)
    return [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 30 -Compress))
}

function Write-ControlJson {
    param(
        [Parameter(Mandatory)][Net.Sockets.NetworkStream]$Stream,
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter(Mandatory)][string]$ReasonPhrase,
        [Parameter(Mandatory)][object]$Value,
        [switch]$HeadOnly
    )
    Write-ControlHttpResponse `
        -Stream $Stream `
        -StatusCode $StatusCode `
        -ReasonPhrase $ReasonPhrase `
        -Body (ConvertTo-ControlJsonBytes -Value $Value) `
        -HeadOnly:$HeadOnly
}

function Get-StaticContentType {
    param([Parameter(Mandatory)][string]$Path)
    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.html' { return 'text/html; charset=utf-8' }
        '.css'  { return 'text/css; charset=utf-8' }
        '.js'   { return 'text/javascript; charset=utf-8' }
        '.png'  { return 'image/png' }
        '.ico'  { return 'image/x-icon' }
        '.woff' { return 'font/woff' }
        '.woff2' { return 'font/woff2' }
        default { return 'application/octet-stream' }
    }
}

function Resolve-ControlStaticFile {
    param([Parameter(Mandatory)][string]$RequestPath)

    if ($RequestPath.Contains('\') -or $RequestPath.Contains(':') -or $RequestPath.IndexOf([char]0) -ge 0) {
        return $null
    }
    $Relative = $RequestPath.TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($Relative)) {
        $Relative = 'index.html'
    }
    if ($Relative -split '/' -contains '..') {
        return $null
    }
    $Candidate = [IO.Path]::GetFullPath((Join-Path $script:StaticRoot ($Relative -replace '/', '\')))
    $RootPrefix = $script:StaticRoot.TrimEnd('\') + '\'
    if (-not $Candidate.StartsWith($RootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }
    if (Test-Path -LiteralPath $Candidate -PathType Leaf) {
        return $Candidate
    }
    return $null
}

function Assert-ControlRequestAuthorization {
    param(
        [Parameter(Mandatory)][object]$Request,
        [switch]$Mutation
    )

    $ExpectedHost = "127.0.0.1`:$Port"
    if (-not $Request.headers.ContainsKey('host') -or [string]$Request.headers.host -ne $ExpectedHost) {
        throw [UnauthorizedAccessException]::new('The control Host header was rejected.')
    }
    if (-not $Request.headers.ContainsKey('x-gpumates-control-token') -or
        -not (Test-GPUmatesAccessToken -Expected $script:ControlToken -Presented ([string]$Request.headers['x-gpumates-control-token']))) {
        throw [UnauthorizedAccessException]::new('The control token was rejected.')
    }
    if ($Mutation) {
        if (-not $Request.headers.ContainsKey('x-gpumates-control') -or [string]$Request.headers['x-gpumates-control'] -ne '1') {
            throw [UnauthorizedAccessException]::new('The mutation header was rejected.')
        }
        $ExpectedOrigin = "http://127.0.0.1`:$Port"
        if (-not $Request.headers.ContainsKey('origin') -or [string]$Request.headers.origin -ne $ExpectedOrigin) {
            throw [UnauthorizedAccessException]::new('The request Origin was rejected.')
        }
        if (-not $Request.headers.ContainsKey('content-type') -or [string]$Request.headers['content-type'] -notmatch '^application/json(?:;|$)') {
            throw 'Mutations require application/json.'
        }
    }
}

function Read-ControlJsonBody {
    param([Parameter(Mandatory)][object]$Request)
    if ([string]::IsNullOrWhiteSpace([string]$Request.bodyText)) {
        return [pscustomobject]@{}
    }
    return $Request.bodyText | ConvertFrom-Json -ErrorAction Stop
}

$IdentitySid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -replace '[^A-Za-z0-9_-]', '_'
$MutexCreated = $false
$ControlMutex = [Threading.Mutex]::new($true, "Local\GPUmates-Coordinator-Control-$IdentitySid", [ref]$MutexCreated)
if (-not $MutexCreated) {
    $ControlMutex.Dispose()
    exit 0
}

$Listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
$Listener.Server.ExclusiveAddressUse = $true

try {
    $Listener.Start()
    Write-ControlSessionFile
    Write-Host "GPUmates Control Center: http://127.0.0.1`:$Port"
    Write-Host "Coordinator data: $($script:DataRoot)"

    if (-not $SkipAutoStart) {
        try {
            $AutoConfiguration = Get-ControlConfiguration
            if ($AutoConfiguration.settings.autoStartDashboard) {
                Start-DashboardService
            }
            if ($AutoConfiguration.settings.autoStartRouter) {
                Start-RouterService -WorkerIps $null
            }
        }
        catch {
            $script:LastError = "Automatic startup did not complete: $($_.Exception.Message)"
        }
    }

    while ($script:KeepRunning) {
        $Client = $null
        $Stream = $null
        try {
            $Client = $Listener.AcceptTcpClient()
            $RemoteEndpoint = [Net.IPEndPoint]$Client.Client.RemoteEndPoint
            if (-not $RemoteEndpoint.Address.Equals([Net.IPAddress]::Loopback)) {
                $Client.Dispose()
                continue
            }
            $Client.ReceiveTimeout = 5000
            $Client.SendTimeout = 10000
            $Client.NoDelay = $true
            $Stream = $Client.GetStream()

            try {
                $Request = Read-ControlHttpRequest -Stream $Stream
            }
            catch {
                Write-ControlJson -Stream $Stream -StatusCode 400 -ReasonPhrase 'Bad Request' -Value ([pscustomobject]@{ error = 'bad_request'; message = $_.Exception.Message })
                continue
            }

            $ExpectedHost = "127.0.0.1`:$Port"
            if (-not $Request.headers.ContainsKey('host') -or [string]$Request.headers.host -ne $ExpectedHost) {
                Write-ControlJson -Stream $Stream -StatusCode 403 -ReasonPhrase 'Forbidden' -Value ([pscustomobject]@{ error = 'forbidden'; message = 'Host rejected.' }) -HeadOnly:($Request.method -eq 'HEAD')
                continue
            }

            if ($Request.method -in @('GET', 'HEAD') -and $Request.path -eq '/health') {
                Write-ControlJson -Stream $Stream -StatusCode 200 -ReasonPhrase 'OK' -Value ([pscustomobject]@{
                        status = 'ok'; schemaVersion = 1; sessionId = $script:ControlSessionId; timestamp = [DateTimeOffset]::UtcNow.ToString('o')
                    }) -HeadOnly:($Request.method -eq 'HEAD')
                continue
            }

            if ($Request.method -eq 'GET' -and $Request.path -eq '/api/v1/status') {
                try {
                    Assert-ControlRequestAuthorization -Request $Request
                    Write-ControlJson -Stream $Stream -StatusCode 200 -ReasonPhrase 'OK' -Value (Get-ControlStatus)
                }
                catch [UnauthorizedAccessException] {
                    Write-ControlJson -Stream $Stream -StatusCode 403 -ReasonPhrase 'Forbidden' -Value ([pscustomobject]@{ error = 'forbidden'; message = $_.Exception.Message })
                }
                catch {
                    $script:LastError = $_.Exception.Message
                    Write-ControlJson -Stream $Stream -StatusCode 500 -ReasonPhrase 'Internal Server Error' -Value ([pscustomobject]@{ error = 'status_failed'; message = $_.Exception.Message })
                }
                continue
            }

            if ($Request.method -eq 'POST' -and $Request.path.StartsWith('/api/v1/')) {
                try {
                    Assert-ControlRequestAuthorization -Request $Request -Mutation
                    $Body = Read-ControlJsonBody -Request $Request
                    $Message = 'Action completed.'
                    $ResponseValue = $null

                    switch ($Request.path) {
                        '/api/v1/secrets/generate' {
                            # Keys are generated in the local browser with Web Crypto so plaintext
                            # never needs to be returned from the controller.
                            $Message = 'Generate the three keys in this local browser, then save them.'
                        }
                        '/api/v1/secrets/save' {
                            if ((Get-ManagedServiceState -Service router).running -or
                                (Get-ManagedServiceState -Service dashboard).running) {
                                throw 'Stop the model router and node dashboard before replacing access keys.'
                            }
                            Save-Secrets `
                                -AgentKey ([string](Get-ObjectProperty -InputObject $Body -Name 'agentKey' -DefaultValue '')) `
                                -DashboardKey ([string](Get-ObjectProperty -InputObject $Body -Name 'dashboardKey' -DefaultValue '')) `
                                -LlamaApiKey ([string](Get-ObjectProperty -InputObject $Body -Name 'llamaApiKey' -DefaultValue ''))
                            $Message = 'Keys were protected for this Windows user.'
                        }
                        '/api/v1/router/start' {
                            $WorkerProperty = $Body.PSObject.Properties['workerIps']
                            $WorkerIps = if ($null -eq $WorkerProperty) { $null } else { @($WorkerProperty.Value | ForEach-Object { [string]$_ }) }
                            Start-RouterService -WorkerIps $WorkerIps -WorkerSelectionSupplied:($null -ne $WorkerProperty)
                            $Message = 'Model router started.'
                        }
                        '/api/v1/router/stop' {
                            if ((Get-ManagedServiceState -Service router).running) {
                                Stop-ManagedService -Service router
                            }
                            $Message = 'Model router stopped.'
                        }
                        '/api/v1/models/load' {
                            Set-ModelLoadedState -ModelId ([string](Get-ObjectProperty -InputObject $Body -Name 'model' -DefaultValue '')) -Action load
                            $Message = 'Model load requested.'
                        }
                        '/api/v1/models/unload' {
                            Set-ModelLoadedState -ModelId ([string](Get-ObjectProperty -InputObject $Body -Name 'model' -DefaultValue '')) -Action unload
                            $Message = 'Model unload requested.'
                        }
                        '/api/v1/models/pick' {
                            $ResponseValue = Show-GgufFilePicker
                        }
                        '/api/v1/models/add' {
                            $ResponseValue = Add-ModelPreset `
                                -ModelId ([string](Get-ObjectProperty -InputObject $Body -Name 'model' -DefaultValue '')) `
                                -Path ([string](Get-ObjectProperty -InputObject $Body -Name 'path' -DefaultValue ''))
                        }
                        '/api/v1/models/remove' {
                            $ResponseValue = Remove-ModelPreset `
                                -ModelId ([string](Get-ObjectProperty -InputObject $Body -Name 'model' -DefaultValue ''))
                        }
                        '/api/v1/dashboard/start' {
                            Start-DashboardService
                            $Message = 'Node dashboard started.'
                        }
                        '/api/v1/dashboard/stop' {
                            if ((Get-ManagedServiceState -Service dashboard).running) {
                                Stop-ManagedService -Service dashboard
                            }
                            $Message = 'Node dashboard stopped.'
                        }
                        '/api/v1/workers/add' {
                            Add-WorkerNode `
                                -Name ([string](Get-ObjectProperty -InputObject $Body -Name 'name' -DefaultValue '')) `
                                -IPAddress ([string](Get-ObjectProperty -InputObject $Body -Name 'ip' -DefaultValue ''))
                            $Message = 'Worker registered on PC1. Start it on the worker PC, then apply sharing if needed.'
                        }
                        '/api/v1/workers/remove' {
                            Remove-WorkerNode -IPAddress ([string](Get-ObjectProperty -InputObject $Body -Name 'ip' -DefaultValue ''))
                            $Message = 'Worker removed from PC1 configuration. Apply sharing once to revoke any existing firewall access for that IP.'
                        }
                        '/api/v1/sharing/apply' {
                            $Enabled = [bool](Get-ObjectProperty -InputObject $Body -Name 'enabled' -DefaultValue $false)
                            $ChatClients = @(Get-ObjectProperty -InputObject $Body -Name 'chatClientIps' -DefaultValue @())
                            $DashboardClients = @(Get-ObjectProperty -InputObject $Body -Name 'dashboardClientIps' -DefaultValue @())
                            $Message = Apply-SharingConfiguration `
                                -Enabled $Enabled `
                                -ChatClientIps $ChatClients `
                                -DashboardClientIps $DashboardClients
                        }
                        '/api/v1/settings/save' {
                            Save-ControlSettings -Body $Body
                            $Message = 'Coordinator defaults saved for the next service start.'
                        }
                        '/api/v1/shutdown' {
                            $script:KeepRunning = $false
                            $Message = 'GPUmates Control Center is shutting down. Router and dashboard state are unchanged.'
                        }
                        default {
                            Write-ControlJson -Stream $Stream -StatusCode 404 -ReasonPhrase 'Not Found' -Value ([pscustomobject]@{ error = 'not_found'; message = 'Unknown control action.' })
                            continue
                        }
                    }

                    $script:LastError = $null
                    if ($null -eq $ResponseValue) {
                        $ResponseValue = [pscustomobject][ordered]@{ ok = $true; message = $Message }
                    }
                    Write-ControlJson -Stream $Stream -StatusCode 200 -ReasonPhrase 'OK' -Value $ResponseValue
                }
                catch [UnauthorizedAccessException] {
                    Write-ControlJson -Stream $Stream -StatusCode 403 -ReasonPhrase 'Forbidden' -Value ([pscustomobject]@{ error = 'forbidden'; message = $_.Exception.Message })
                }
                catch {
                    $script:LastError = $_.Exception.Message
                    Write-ControlJson -Stream $Stream -StatusCode 400 -ReasonPhrase 'Bad Request' -Value ([pscustomobject]@{ error = 'action_failed'; message = $_.Exception.Message })
                }
                continue
            }

            if ($Request.method -in @('GET', 'HEAD')) {
                $StaticFile = Resolve-ControlStaticFile -RequestPath $Request.path
                if ($null -eq $StaticFile) {
                    Write-ControlJson -Stream $Stream -StatusCode 404 -ReasonPhrase 'Not Found' -Value ([pscustomobject]@{ error = 'not_found' }) -HeadOnly:($Request.method -eq 'HEAD')
                    continue
                }
                if ([IO.Path]::GetFileName($StaticFile) -ieq 'index.html') {
                    $IndexText = Get-Content -LiteralPath $StaticFile -Raw
                    if ($IndexText.IndexOf('__GPUMATES_CONTROL_TOKEN__', [StringComparison]::Ordinal) -ge 0 -or
                        $IndexText.IndexOf('gpumates-control-token', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        throw 'The control-center index contains a legacy unauthenticated token placeholder.'
                    }
                    $BodyBytes = [Text.Encoding]::UTF8.GetBytes($IndexText)
                }
                else {
                    $BodyBytes = [IO.File]::ReadAllBytes($StaticFile)
                }
                Write-ControlHttpResponse `
                    -Stream $Stream `
                    -StatusCode 200 `
                    -ReasonPhrase 'OK' `
                    -Body $BodyBytes `
                    -ContentType (Get-StaticContentType -Path $StaticFile) `
                    -HeadOnly:($Request.method -eq 'HEAD')
                continue
            }

            Write-ControlJson -Stream $Stream -StatusCode 405 -ReasonPhrase 'Method Not Allowed' -Value ([pscustomobject]@{ error = 'method_not_allowed' })
        }
        catch {
            if ($Stream) {
                try {
                    Write-ControlJson -Stream $Stream -StatusCode 500 -ReasonPhrase 'Internal Server Error' -Value ([pscustomobject]@{ error = 'internal_error'; message = $_.Exception.Message })
                }
                catch {
                    # The client may already have disconnected.
                }
            }
        }
        finally {
            if ($Stream) {
                $Stream.Dispose()
            }
            if ($Client) {
                $Client.Dispose()
            }
        }
    }
}
finally {
    $Listener.Stop()
    Remove-ControlSessionFile
    if ($MutexCreated) {
        try { $ControlMutex.ReleaseMutex() } catch {}
    }
    $ControlMutex.Dispose()
}
