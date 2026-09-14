[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [System.Net.IPAddress]$ListenIP,

    [ValidateRange(1024, 65535)]
    [int]$Port = 8090,

    [string]$NodeConfig,

    [string]$DashboardRoot,

    [string]$DashboardAccessToken = $env:GPUMATES_DASHBOARD_KEY,

    [string]$AgentAccessToken = $env:GPUMATES_AGENT_KEY,

    [string]$LlamaApiKey = $env:GPUMATES_LLAMA_API_KEY,

    [ValidateRange(250, 10000)]
    [int]$NodeTimeoutMilliseconds = 1800,

    [ValidateRange(1, 30)]
    [int]$CacheSeconds = 2,

    [switch]$AllowUnauthenticatedDashboard,

    [switch]$AllowUnauthenticatedAgents
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'GPUmates.Telemetry.psm1') -Force
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($NodeConfig)) {
    $NodeConfig = Join-Path $ProjectRoot 'config\telemetry-nodes.json'
}

function Get-ConfigProperty {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$InputObject,
        [Parameter(Mandatory)]
        [string]$Name,
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

function Test-PrivateOrLoopbackIPv4 {
    param([Parameter(Mandatory)][Net.IPAddress]$Address)

    if ($Address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        return $false
    }
    $Bytes = $Address.GetAddressBytes()
    return $Bytes[0] -eq 127 -or
        $Bytes[0] -eq 10 -or
        ($Bytes[0] -eq 172 -and $Bytes[1] -ge 16 -and $Bytes[1] -le 31) -or
        ($Bytes[0] -eq 192 -and $Bytes[1] -eq 168)
}

function Invoke-GPUmatesHttpGet {
    param(
        [Parameter(Mandatory)]
        [uri]$Uri,
        [hashtable]$Header = @{},
        [int]$TimeoutMilliseconds = 1800,
        [switch]$ReturnText
    )

    $Request = [Net.HttpWebRequest]::Create($Uri)
    $Request.Method = 'GET'
    $Request.Timeout = $TimeoutMilliseconds
    $Request.ReadWriteTimeout = $TimeoutMilliseconds
    $Request.AllowAutoRedirect = $false
    $Request.KeepAlive = $false
    $Request.Proxy = $null
    $Request.UserAgent = 'GPUmates-Dashboard/1.0'
    foreach ($Name in $Header.Keys) {
        $Request.Headers.Add([string]$Name, [string]$Header[$Name])
    }

    $Response = $null
    $Reader = $null
    try {
        $Response = [Net.HttpWebResponse]$Request.GetResponse()
        if ([int]$Response.StatusCode -ne 200) {
            throw "HTTP $([int]$Response.StatusCode)"
        }
        $Reader = [IO.StreamReader]::new($Response.GetResponseStream(), [Text.Encoding]::UTF8)
        $Text = $Reader.ReadToEnd()
        if ($ReturnText) {
            return $Text
        }
        return $Text | ConvertFrom-Json -ErrorAction Stop
    }
    finally {
        if ($Reader) {
            $Reader.Dispose()
        }
        if ($Response) {
            $Response.Dispose()
        }
    }
}

function Get-SafeFetchError {
    param([Parameter(Mandatory)][Management.Automation.ErrorRecord]$ErrorRecord)

    $Exception = $ErrorRecord.Exception
    while ($null -ne $Exception) {
        if ($Exception -is [Net.WebException]) {
            switch ($Exception.Status) {
                ([Net.WebExceptionStatus]::Timeout) { return 'timeout' }
                ([Net.WebExceptionStatus]::ConnectFailure) { return 'unreachable' }
                ([Net.WebExceptionStatus]::NameResolutionFailure) { return 'unreachable' }
                ([Net.WebExceptionStatus]::ProtocolError) {
                    $ProtocolResponse = $Exception.Response
                    if ($ProtocolResponse -and [int]$ProtocolResponse.StatusCode -eq 401) {
                        return 'unauthorized'
                    }
                    return 'http_error'
                }
            }
        }
        $Exception = $Exception.InnerException
    }
    return 'invalid_response'
}

function ConvertTo-SafeLlamaModels {
    param([AllowNull()][object[]]$Model)

    return @($Model | ForEach-Object {
            $StatusObject = Get-ConfigProperty -InputObject $_ -Name 'status'
            $MetaObject = Get-ConfigProperty -InputObject $_ -Name 'meta'
            $ArchitectureObject = Get-ConfigProperty -InputObject $_ -Name 'architecture'
            [ordered]@{
                id               = [string](Get-ConfigProperty -InputObject $_ -Name 'id' -DefaultValue 'unknown')
                status           = [string](Get-ConfigProperty -InputObject $StatusObject -Name 'value' -DefaultValue 'unknown')
                source           = [string](Get-ConfigProperty -InputObject $_ -Name 'source' -DefaultValue 'unknown')
                contextSize      = Get-ConfigProperty -InputObject $MetaObject -Name 'n_ctx'
                trainedContextSize = Get-ConfigProperty -InputObject $MetaObject -Name 'n_ctx_train'
                parameterCount   = Get-ConfigProperty -InputObject $MetaObject -Name 'n_params'
                sizeBytes        = Get-ConfigProperty -InputObject $MetaObject -Name 'size'
                quantization     = Get-ConfigProperty -InputObject $MetaObject -Name 'ftype'
                inputModalities  = @(Get-ConfigProperty -InputObject $ArchitectureObject -Name 'input_modalities' -DefaultValue @())
                outputModalities = @(Get-ConfigProperty -InputObject $ArchitectureObject -Name 'output_modalities' -DefaultValue @())
            }
        })
}

function Get-OfflineNode {
    param(
        [Parameter(Mandatory)][object]$Node,
        [Parameter(Mandatory)][string]$ErrorCode
    )

    $DisplayIP = [string](Get-ConfigProperty -InputObject $Node -Name 'displayIp' -DefaultValue $Node.host)
    return [ordered]@{
        schemaVersion = 1
        node          = [ordered]@{
            name = [string](Get-ConfigProperty -InputObject $Node -Name 'name' -DefaultValue $Node.host)
            ip   = $DisplayIP
            role = [string](Get-ConfigProperty -InputObject $Node -Name 'role' -DefaultValue 'worker')
        }
        timestamp     = [DateTimeOffset]::UtcNow.ToString('o')
        online        = $false
        error         = $ErrorCode
        gpu           = @()
        system        = $null
        agent         = $null
    }
}

function Get-RemoteNodeSnapshot {
    param(
        [Parameter(Mandatory)][object]$Node,
        [string]$Token,
        [bool]$UseAuthentication,
        [int]$TimeoutMilliseconds
    )

    $IsLocal = [bool](Get-ConfigProperty -InputObject $Node -Name 'local' -DefaultValue $false)
    if ($IsLocal) {
        try {
            $LocalNodeIP = [Net.IPAddress]::Parse(
                [string](Get-ConfigProperty -InputObject $Node -Name 'displayIp' -DefaultValue $Node.host)
            )
            return Get-GPUmatesTelemetrySnapshot `
                -NodeName ([string](Get-ConfigProperty -InputObject $Node -Name 'name' -DefaultValue $env:COMPUTERNAME)) `
                -NodeIP $LocalNodeIP `
                -Role ([string](Get-ConfigProperty -InputObject $Node -Name 'role' -DefaultValue 'coordinator')) `
                -SampleIntervalSeconds 2
        }
        catch {
            return Get-OfflineNode -Node $Node -ErrorCode 'telemetry_unavailable'
        }
    }

    $Header = @{}
    if ($UseAuthentication) {
        $Header['X-GPUmates-Agent-Key'] = $Token
    }
    $Uri = [uri]"http://$($Node.host):$($Node.port)/api/v1/metrics"
    try {
        $Snapshot = Invoke-GPUmatesHttpGet -Uri $Uri -Header $Header -TimeoutMilliseconds $TimeoutMilliseconds
        $SchemaVersion = Get-ConfigProperty -InputObject $Snapshot -Name 'schemaVersion'
        $Online = Get-ConfigProperty -InputObject $Snapshot -Name 'online' -DefaultValue $false
        $NodeObject = Get-ConfigProperty -InputObject $Snapshot -Name 'node'
        $Gpu = Get-ConfigProperty -InputObject $Snapshot -Name 'gpu'
        if ($SchemaVersion -ne 1 -or -not $Online -or $null -eq $NodeObject -or $null -eq $Gpu) {
            throw 'The telemetry response does not match schema version 1.'
        }
        $ExpectedNodeIP = [string](Get-ConfigProperty -InputObject $Node -Name 'displayIp' -DefaultValue $Node.host)
        if ([string]$NodeObject.ip -ne $ExpectedNodeIP) {
            throw 'The telemetry node identity did not match its configured address.'
        }
        return $Snapshot
    }
    catch {
        return Get-OfflineNode -Node $Node -ErrorCode (Get-SafeFetchError -ErrorRecord $_)
    }
}

function ConvertFrom-GPUmatesPrometheusText {
    param([AllowEmptyString()][string]$Text)

    $Metrics = [Collections.Generic.List[object]]::new()
    foreach ($Line in @($Text -split "`r?`n")) {
        if ($Metrics.Count -ge 256) {
            break
        }
        if ($Line -match '^(?<name>[a-zA-Z_:][a-zA-Z0-9_:]*)(?<labels>\{.*\})?\s+(?<value>[-+]?(?:[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?|Inf|NaN))(?:\s+[0-9]+)?$') {
            $Value = $null
            if ($Matches.value -notmatch '^(?:[-+]?Inf|NaN)$') {
                [double]$Parsed = 0
                if ([double]::TryParse(
                        $Matches.value,
                        [Globalization.NumberStyles]::Float,
                        [Globalization.CultureInfo]::InvariantCulture,
                        [ref]$Parsed)) {
                    $Value = $Parsed
                }
            }
            $Metrics.Add([ordered]@{
                    name   = $Matches.name
                    labels = if ($Matches.labels) { $Matches.labels } else { $null }
                    value  = $Value
                })
        }
    }
    return @($Metrics)
}

function Find-GPUmatesMetricValue {
    param(
        [Parameter(Mandatory)][object[]]$Metric,
        [Parameter(Mandatory)][string[]]$CandidateName
    )

    foreach ($Name in $CandidateName) {
        $Match = $Metric | Where-Object { $_.name -eq $Name -and $null -ne $_.value } | Select-Object -First 1
        if ($Match) {
            return [double]$Match.value
        }
    }
    return $null
}

function Get-LlamaStatus {
    param(
        [Parameter(Mandatory)][object]$LlamaConfig,
        [string]$ApiKey,
        [int]$TimeoutMilliseconds,
        [Parameter(Mandatory)][string]$AllowedCoordinatorIP
    )

    $Enabled = [bool](Get-ConfigProperty -InputObject $LlamaConfig -Name 'enabled' -DefaultValue $false)
    if (-not $Enabled) {
        return [ordered]@{ enabled = $false; online = $false }
    }

    $BaseUrl = ([string](Get-ConfigProperty -InputObject $LlamaConfig -Name 'baseUrl' -DefaultValue 'http://127.0.0.1:8080')).TrimEnd('/')
    $BaseUri = [uri]$BaseUrl
    $AllowedLlamaHosts = @('127.0.0.1', 'localhost', $AllowedCoordinatorIP)
    if ($BaseUri.Scheme -ne 'http' -or
        $BaseUri.Host -notin $AllowedLlamaHosts -or
        $BaseUri.Port -ne 8080 -or
        -not [string]::IsNullOrEmpty($BaseUri.UserInfo) -or
        $BaseUri.AbsolutePath -ne '/' -or
        -not [string]::IsNullOrEmpty($BaseUri.Query) -or
        -not [string]::IsNullOrEmpty($BaseUri.Fragment)) {
        return [ordered]@{ enabled = $true; online = $false; error = 'invalid_local_url' }
    }

    $Header = @{}
    if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
        $Header['Authorization'] = "Bearer $ApiKey"
    }

    $Result = [ordered]@{
        enabled          = $true
        online           = $false
        baseUrl          = $BaseUrl
        publicUrl        = $null
        activeModel      = $null
        models           = @()
        metricsAvailable = $false
        metrics          = @()
        promptTokensPerSecond     = $null
        generationTokensPerSecond = $null
    }

    $PublicUrl = [string](Get-ConfigProperty -InputObject $LlamaConfig -Name 'publicUrl' -DefaultValue '')
    if (-not [string]::IsNullOrWhiteSpace($PublicUrl)) {
        try {
            $PublicUri = [uri]$PublicUrl
            if ($PublicUri.Scheme -ne 'http' -or
                $PublicUri.Host -notin $AllowedLlamaHosts -or
                $PublicUri.Port -ne 8080 -or
                -not [string]::IsNullOrEmpty($PublicUri.UserInfo) -or
                $PublicUri.AbsolutePath -ne '/' -or
                -not [string]::IsNullOrEmpty($PublicUri.Query) -or
                -not [string]::IsNullOrEmpty($PublicUri.Fragment)) {
                throw 'publicUrl must be the exact loopback or coordinator HTTP address on port 8080.'
            }
            $Result.publicUrl = $PublicUrl.TrimEnd('/')
        }
        catch {
            return [ordered]@{ enabled = $true; online = $false; error = 'invalid_public_url' }
        }
    }

    try {
        $ModelsResponse = Invoke-GPUmatesHttpGet `
            -Uri ([uri]"$BaseUrl/models") `
            -Header $Header `
            -TimeoutMilliseconds $TimeoutMilliseconds
        $Models = @(Get-ConfigProperty -InputObject $ModelsResponse -Name 'data' -DefaultValue $ModelsResponse)
        $SafeModels = @(ConvertTo-SafeLlamaModels -Model $Models)
        $Result.models = $SafeModels
        $LoadedModel = $SafeModels | Where-Object { $_.status -eq 'loaded' } | Select-Object -First 1
        if ($LoadedModel) {
            $Result.activeModel = $LoadedModel.id
        }
        $Result.online = $true
    }
    catch {
        $Result.error = Get-SafeFetchError -ErrorRecord $_
        return $Result
    }

    if ($null -eq $Result.activeModel) {
        return $Result
    }

    try {
        $EncodedModel = [uri]::EscapeDataString([string]$Result.activeModel)
        $MetricsText = Invoke-GPUmatesHttpGet `
            -Uri ([uri]"$BaseUrl/metrics?model=$EncodedModel") `
            -Header $Header `
            -TimeoutMilliseconds $TimeoutMilliseconds `
            -ReturnText
        $Result.metrics = @(ConvertFrom-GPUmatesPrometheusText -Text $MetricsText)
        $Result.metricsAvailable = $true
        $PromptSpeed = Find-GPUmatesMetricValue -Metric $Result.metrics -CandidateName @(
            'llamacpp:prompt_tokens_seconds',
            'llamacpp_prompt_tokens_seconds'
        )
        $GenerationSpeed = Find-GPUmatesMetricValue -Metric $Result.metrics -CandidateName @(
            'llamacpp:predicted_tokens_seconds',
            'llamacpp_predicted_tokens_seconds'
        )
        if ($null -ne $PromptSpeed) {
            $Result.promptTokensPerSecond = [math]::Round($PromptSpeed, 1)
        }
        if ($null -ne $GenerationSpeed) {
            $Result.generationTokensPerSecond = [math]::Round($GenerationSpeed, 1)
        }
    }
    catch {
        # llama.cpp requires --metrics; model status remains useful when it is disabled.
    }

    return $Result
}

function Get-ClusterSnapshot {
    param(
        [Parameter(Mandatory)][object[]]$ConfiguredNode,
        [string]$AgentToken,
        [bool]$UseAgentAuthentication,
        [int]$TimeoutMilliseconds,
        [Parameter(Mandatory)][object]$LlamaConfig,
        [string]$LlamaApiKey,
        [Parameter(Mandatory)][string]$AllowedCoordinatorIP
    )

    $Snapshots = @($ConfiguredNode | ForEach-Object {
            Get-RemoteNodeSnapshot `
                -Node $_ `
                -Token $AgentToken `
                -UseAuthentication $UseAgentAuthentication `
                -TimeoutMilliseconds $TimeoutMilliseconds
        })

    [int]$GpuCount = 0
    [double]$GpuMemoryUsedMiB = 0
    [double]$GpuMemoryTotalMiB = 0
    [double]$WeightedUtilizationTotal = 0
    [double]$UtilizationTotal = 0
    [int]$UtilizationCount = 0
    [int]$NodesOnline = 0

    foreach ($Snapshot in $Snapshots) {
        if (-not [bool]$Snapshot.online) {
            continue
        }
        $NodesOnline++
        foreach ($Gpu in @($Snapshot.gpu)) {
            $GpuCount++
            $Used = Get-ConfigProperty -InputObject $Gpu -Name 'memoryUsedMiB'
            $Total = Get-ConfigProperty -InputObject $Gpu -Name 'memoryTotalMiB'
            $Utilization = Get-ConfigProperty -InputObject $Gpu -Name 'utilizationPct'
            if ($null -ne $Used) {
                $GpuMemoryUsedMiB += [double]$Used
            }
            if ($null -ne $Total) {
                $GpuMemoryTotalMiB += [double]$Total
            }
            if ($null -ne $Utilization) {
                $UtilizationTotal += [double]$Utilization
                $UtilizationCount++
                if ($null -ne $Total) {
                    $WeightedUtilizationTotal += [double]$Utilization * [double]$Total
                }
            }
        }
    }

    $WeightedUtilization = $null
    if ($GpuMemoryTotalMiB -gt 0) {
        $WeightedUtilization = [math]::Round($WeightedUtilizationTotal / $GpuMemoryTotalMiB, 1)
    }
    $AverageUtilization = $null
    if ($UtilizationCount -gt 0) {
        $AverageUtilization = [math]::Round($UtilizationTotal / $UtilizationCount, 1)
    }

    return [ordered]@{
        schemaVersion = 1
        timestamp     = [DateTimeOffset]::UtcNow.ToString('o')
        nodes         = @($Snapshots)
        totals        = [ordered]@{
            nodesOnline                    = $NodesOnline
            nodesTotal                     = $Snapshots.Count
            gpuCount                       = $GpuCount
            gpuMemoryUsedMiB                = [math]::Round($GpuMemoryUsedMiB, 1)
            gpuMemoryTotalMiB               = [math]::Round($GpuMemoryTotalMiB, 1)
            weightedGpuUtilizationPct       = $WeightedUtilization
            averageGpuUtilizationPct        = $AverageUtilization
        }
        llama         = Get-LlamaStatus `
            -LlamaConfig $LlamaConfig `
            -ApiKey $LlamaApiKey `
            -TimeoutMilliseconds $TimeoutMilliseconds `
            -AllowedCoordinatorIP $AllowedCoordinatorIP
    }
}

function Get-ContentType {
    param([Parameter(Mandatory)][string]$Path)

    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.html' { return 'text/html; charset=utf-8' }
        '.css'  { return 'text/css; charset=utf-8' }
        '.js'   { return 'text/javascript; charset=utf-8' }
        '.mjs'  { return 'text/javascript; charset=utf-8' }
        '.json' { return 'application/json; charset=utf-8' }
        '.svg'  { return 'image/svg+xml' }
        '.png'  { return 'image/png' }
        '.jpg'  { return 'image/jpeg' }
        '.jpeg' { return 'image/jpeg' }
        '.webp' { return 'image/webp' }
        '.ico'  { return 'image/x-icon' }
        '.woff' { return 'font/woff' }
        '.woff2' { return 'font/woff2' }
        default { return 'application/octet-stream' }
    }
}

function Resolve-StaticFile {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RequestPath
    )

    try {
        $Decoded = [uri]::UnescapeDataString($RequestPath)
    }
    catch {
        return $null
    }
    if ($Decoded.IndexOf([char]0) -ge 0 -or $Decoded.Contains('\') -or $Decoded.Contains(':')) {
        return $null
    }

    $Relative = $Decoded.TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($Relative)) {
        $Relative = 'index.html'
    }
    $Candidate = [IO.Path]::GetFullPath((Join-Path $Root ($Relative -replace '/', '\')))
    $RootPrefix = $Root.TrimEnd('\') + '\'
    if (-not $Candidate.StartsWith($RootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }
    if (Test-Path -LiteralPath $Candidate -PathType Container) {
        $Candidate = Join-Path $Candidate 'index.html'
    }
    if (Test-Path -LiteralPath $Candidate -PathType Leaf) {
        return $Candidate
    }

    # SPA fallback: browser-side routes receive index.html, while missing files do not.
    if (-not [IO.Path]::HasExtension($Relative)) {
        $Index = Join-Path $Root 'index.html'
        if (Test-Path -LiteralPath $Index -PathType Leaf) {
            return $Index
        }
    }
    return $null
}

Assert-GPUmatesListenAddress -ListenIP $ListenIP
if (-not $AllowUnauthenticatedDashboard -and
    ([string]::IsNullOrWhiteSpace($DashboardAccessToken) -or $DashboardAccessToken.Length -lt 24)) {
    throw 'Set GPUMATES_DASHBOARD_KEY to a random value of at least 24 characters, or explicitly pass -AllowUnauthenticatedDashboard for an isolated test.'
}
if ($AllowUnauthenticatedDashboard -and -not [string]::IsNullOrEmpty($DashboardAccessToken)) {
    throw 'Do not combine -AllowUnauthenticatedDashboard with DashboardAccessToken/GPUMATES_DASHBOARD_KEY.'
}
if (-not $AllowUnauthenticatedAgents -and
    ([string]::IsNullOrWhiteSpace($AgentAccessToken) -or $AgentAccessToken.Length -lt 24)) {
    throw 'Set GPUMATES_AGENT_KEY to the same random value used by the node agents.'
}
if ($AllowUnauthenticatedAgents -and -not [string]::IsNullOrEmpty($AgentAccessToken)) {
    throw 'Do not combine -AllowUnauthenticatedAgents with AgentAccessToken/GPUMATES_AGENT_KEY.'
}

$ResolvedNodeConfig = (Resolve-Path -LiteralPath $NodeConfig -ErrorAction Stop).Path
$Configuration = Get-Content -LiteralPath $ResolvedNodeConfig -Raw | ConvertFrom-Json -ErrorAction Stop
if ((Get-ConfigProperty -InputObject $Configuration -Name 'schemaVersion') -ne 1) {
    throw 'The node configuration must use schemaVersion 1.'
}
$DashboardConfig = Get-ConfigProperty -InputObject $Configuration -Name 'dashboard' -DefaultValue ([pscustomobject]@{})
$ConfiguredClientIP = @(Get-ConfigProperty -InputObject $DashboardConfig -Name 'allowedClientIps' -DefaultValue @())
$AllowedDashboardClientAddress = [Collections.Generic.List[string]]::new()
foreach ($ClientIPText in $ConfiguredClientIP) {
    $ParsedClientIP = $null
    if (-not [Net.IPAddress]::TryParse([string]$ClientIPText, [ref]$ParsedClientIP) -or
        -not (Test-PrivateOrLoopbackIPv4 -Address $ParsedClientIP) -or
        $ParsedClientIP.Equals([Net.IPAddress]::Any) -or
        $ParsedClientIP.Equals([Net.IPAddress]::Broadcast)) {
        throw "Dashboard allowedClientIps contains an invalid or public address: $ClientIPText"
    }
    if (-not $AllowedDashboardClientAddress.Contains($ParsedClientIP.IPAddressToString)) {
        $AllowedDashboardClientAddress.Add($ParsedClientIP.IPAddressToString)
    }
}
foreach ($LocalClientAddress in @($ListenIP.IPAddressToString, '127.0.0.1')) {
    if (-not $AllowedDashboardClientAddress.Contains($LocalClientAddress)) {
        $AllowedDashboardClientAddress.Add($LocalClientAddress)
    }
}
$ConfiguredNodes = @(Get-ConfigProperty -InputObject $Configuration -Name 'nodes' -DefaultValue @())
if ($ConfiguredNodes.Count -eq 0) {
    throw 'The node configuration contains no nodes.'
}
$SeenHostPort = @{}
[int]$LocalNodeCount = 0
$LocalCoordinatorDisplayIP = $null
foreach ($Node in $ConfiguredNodes) {
    $ParsedHost = $null
    if (-not [Net.IPAddress]::TryParse([string]$Node.host, [ref]$ParsedHost) -or
        $ParsedHost.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $ParsedHost.Equals([Net.IPAddress]::Any) -or
        $ParsedHost.Equals([Net.IPAddress]::Broadcast) -or
        -not (Test-PrivateOrLoopbackIPv4 -Address $ParsedHost)) {
        throw "Telemetry node '$($Node.name)' must use a loopback or RFC1918 IPv4 host."
    }
    [int]$NodePort = 0
    if (-not [int]::TryParse([string]$Node.port, [ref]$NodePort) -or $NodePort -lt 1024 -or $NodePort -gt 65535) {
        throw "Telemetry node '$($Node.name)' has an invalid port."
    }
    $Identity = "$($ParsedHost.IPAddressToString):$NodePort"
    if ($SeenHostPort.ContainsKey($Identity)) {
        throw "Duplicate telemetry node endpoint: $Identity"
    }
    $SeenHostPort[$Identity] = $true
    if ([bool](Get-ConfigProperty -InputObject $Node -Name 'local' -DefaultValue $false)) {
        $LocalNodeCount++
    }
    $DisplayIPText = [string](Get-ConfigProperty -InputObject $Node -Name 'displayIp' -DefaultValue $Node.host)
    $ParsedDisplayIP = $null
    if (-not [Net.IPAddress]::TryParse($DisplayIPText, [ref]$ParsedDisplayIP) -or
        $ParsedDisplayIP.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $ParsedDisplayIP.Equals([Net.IPAddress]::Any) -or
        $ParsedDisplayIP.Equals([Net.IPAddress]::Broadcast) -or
        -not (Test-PrivateOrLoopbackIPv4 -Address $ParsedDisplayIP)) {
        throw "Telemetry node '$($Node.name)' must use a loopback or RFC1918 IPv4 displayIp."
    }
    if ([bool](Get-ConfigProperty -InputObject $Node -Name 'local' -DefaultValue $false)) {
        $LocalCoordinatorDisplayIP = $ParsedDisplayIP.IPAddressToString
    }
}
if ($LocalNodeCount -ne 1 -or [string]::IsNullOrWhiteSpace($LocalCoordinatorDisplayIP)) {
    throw 'The node configuration must contain exactly one local telemetry node.'
}
$AssignedCoordinatorIP = @(
    [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.OperationalStatus -eq [Net.NetworkInformation.OperationalStatus]::Up } |
        ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
        Where-Object { $_.Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork } |
        ForEach-Object { $_.Address.IPAddressToString }
)
if ($LocalCoordinatorDisplayIP -notin $AssignedCoordinatorIP) {
    throw "The local coordinator displayIp $LocalCoordinatorDisplayIP is not assigned to this PC."
}

# Chat and metrics keep separate keys. Only the coordinator's exact chat origins
# can read this API from a browser; worker agents do not enable CORS.
$AllowedChatOrigins = @(
    "http://${LocalCoordinatorDisplayIP}:8080",
    'http://127.0.0.1:8080',
    'http://localhost:8080'
)

$LlamaConfig = Get-ConfigProperty -InputObject $Configuration -Name 'llama' -DefaultValue ([pscustomobject]@{ enabled = $false })
if ([string]::IsNullOrWhiteSpace($DashboardRoot)) {
    $Candidates = @(
        (Join-Path $ProjectRoot 'dashboard\static'),
        (Join-Path $ProjectRoot 'dashboard\out'),
        (Join-Path $ProjectRoot 'dashboard\dist\client')
    )
    $DashboardRoot = $Candidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'index.html') -PathType Leaf } | Select-Object -First 1
}
$ResolvedDashboardRoot = $null
if (-not [string]::IsNullOrWhiteSpace($DashboardRoot)) {
    $ResolvedDashboardRoot = (Resolve-Path -LiteralPath $DashboardRoot -ErrorAction Stop).Path
}

$Listener = [Net.Sockets.TcpListener]::new($ListenIP, $Port)
$CachedCluster = $null
$ClusterCachedAt = [DateTimeOffset]::MinValue
$SecurityHeader = @{
    'Content-Security-Policy' = "default-src 'self'; connect-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
    'Permissions-Policy'     = 'camera=(), microphone=(), geolocation=()'
    'X-Frame-Options'        = 'DENY'
}

try {
    $Listener.Start()
    Write-Host "GPUmates dashboard listening on http://$($ListenIP.IPAddressToString):$Port"
    Write-Host "Allowed dashboard client IP(s): $($AllowedDashboardClientAddress -join ', ')"
    Write-Host "Node configuration: $ResolvedNodeConfig"
    if ($ResolvedDashboardRoot) {
        Write-Host "Static dashboard: $ResolvedDashboardRoot"
    }
    else {
        Write-Warning 'No static dashboard index.html was found. The API will work, but / returns 503 until the frontend is built.'
    }
    Write-Host 'Cluster API: /api/v1/cluster. Press Ctrl+C to stop.'

    while ($true) {
        $Client = $null
        $Stream = $null
        try {
            $Client = $Listener.AcceptTcpClient()
            $Client.ReceiveTimeout = 3000
            $Client.SendTimeout = 5000
            $Client.NoDelay = $true
            $RemoteIP = ([Net.IPEndPoint]$Client.Client.RemoteEndPoint).Address.IPAddressToString
            $Stream = $Client.GetStream()

            if (-not $AllowedDashboardClientAddress.Contains($RemoteIP)) {
                $Body = ConvertTo-GPUmatesJsonBytes -InputObject ([ordered]@{ error = 'forbidden' })
                Write-GPUmatesHttpResponse -Stream $Stream -StatusCode 403 -ReasonPhrase 'Forbidden' -Body $Body -AdditionalHeader $SecurityHeader
                continue
            }

            try {
                $Request = Read-GPUmatesHttpRequest -Stream $Stream -AllowOptions
            }
            catch {
                $Body = ConvertTo-GPUmatesJsonBytes -InputObject ([ordered]@{ error = 'bad_request' })
                Write-GPUmatesHttpResponse -Stream $Stream -StatusCode 400 -ReasonPhrase 'Bad Request' -Body $Body -AdditionalHeader $SecurityHeader
                continue
            }

            if ($Request.method -eq 'OPTIONS' -and $Request.path -cne '/api/v1/cluster') {
                $Body = ConvertTo-GPUmatesJsonBytes -InputObject ([ordered]@{ error = 'method_not_allowed' })
                Write-GPUmatesHttpResponse -Stream $Stream -StatusCode 405 -ReasonPhrase 'Method Not Allowed' -Body $Body -AdditionalHeader ($SecurityHeader + @{ Allow = 'GET, HEAD' })
                continue
            }

            if ($Request.path -eq '/health') {
                $Body = ConvertTo-GPUmatesJsonBytes -InputObject ([ordered]@{
                        status        = 'ok'
                        schemaVersion = 1
                        timestamp     = [DateTimeOffset]::UtcNow.ToString('o')
                    })
                Write-GPUmatesHttpResponse `
                    -Stream $Stream `
                    -StatusCode 200 `
                    -ReasonPhrase 'OK' `
                    -Body $Body `
                    -AdditionalHeader $SecurityHeader `
                    -HeadOnly:($Request.method -eq 'HEAD')
                continue
            }

            if ($Request.path -ceq '/api/v1/cluster') {
                $ApiHeader = $SecurityHeader + @{ Vary = 'Origin' }
                $Origin = $null
                if ($Request.headers.ContainsKey('origin')) {
                    $Origin = [string]$Request.headers['origin']
                    $IsLoopbackOrigin = $Origin -cin @('http://127.0.0.1:8080', 'http://localhost:8080')
                    $IsCoordinatorClient = $RemoteIP -in @('127.0.0.1', $LocalCoordinatorDisplayIP)
                    if ($AllowedChatOrigins -cnotcontains $Origin -or ($IsLoopbackOrigin -and -not $IsCoordinatorClient)) {
                        $Body = ConvertTo-GPUmatesJsonBytes -InputObject ([ordered]@{ error = 'origin_not_allowed' })
                        Write-GPUmatesHttpResponse -Stream $Stream -StatusCode 403 -ReasonPhrase 'Forbidden' -Body $Body -AdditionalHeader $ApiHeader -HeadOnly:($Request.method -eq 'HEAD')
                        continue
                    }
                    $ApiHeader['Access-Control-Allow-Origin'] = $Origin
                }

                if ($Request.method -eq 'OPTIONS') {
                    if ([string]::IsNullOrEmpty($Origin) -or -not $Request.headers.ContainsKey('access-control-request-method')) {
                        $Body = ConvertTo-GPUmatesJsonBytes -InputObject ([ordered]@{ error = 'invalid_preflight' })
                        Write-GPUmatesHttpResponse -Stream $Stream -StatusCode 400 -ReasonPhrase 'Bad Request' -Body $Body -AdditionalHeader $ApiHeader
                        continue
                    }
                    if ([string]$Request.headers['access-control-request-method'] -cnotin @('GET', 'HEAD')) {
                        $Body = ConvertTo-GPUmatesJsonBytes -InputObject ([ordered]@{ error = 'method_not_allowed' })
                        Write-GPUmatesHttpResponse -Stream $Stream -StatusCode 405 -ReasonPhrase 'Method Not Allowed' -Body $Body -AdditionalHeader ($ApiHeader + @{ Allow = 'GET, HEAD, OPTIONS' })
                        continue
                    }
                    if ($Request.headers.ContainsKey('access-control-request-headers')) {
                        $RequestedHeaders = @(([string]$Request.headers['access-control-request-headers']).Split(',') | ForEach-Object { $_.Trim().ToLowerInvariant() })
                        if ($RequestedHeaders.Count -ne 1 -or $RequestedHeaders[0] -ne 'x-gpumates-key') {
                            $Body = ConvertTo-GPUmatesJsonBytes -InputObject ([ordered]@{ error = 'headers_not_allowed' })
                            Write-GPUmatesHttpResponse -Stream $Stream -StatusCode 403 -ReasonPhrase 'Forbidden' -Body $Body -AdditionalHeader $ApiHeader
                            continue
                        }
                    }
                    $ApiHeader['Access-Control-Allow-Methods'] = 'GET, HEAD'
                    $ApiHeader['Access-Control-Allow-Headers'] = 'X-GPUmates-Key'
                    $Body = ConvertTo-GPUmatesJsonBytes -InputObject ([ordered]@{ status = 'ok' })
                    Write-GPUmatesHttpResponse -Stream $Stream -StatusCode 200 -ReasonPhrase 'OK' -Body $Body -AdditionalHeader $ApiHeader
                    continue
                }

                $PresentedToken = $null
                if ($Request.headers.ContainsKey('x-gpumates-key')) {
                    $PresentedToken = [string]$Request.headers['x-gpumates-key']
                }
                if (-not $AllowUnauthenticatedDashboard -and
                    -not (Test-GPUmatesAccessToken -Expected $DashboardAccessToken -Presented $PresentedToken)) {
                    $Body = ConvertTo-GPUmatesJsonBytes -InputObject ([ordered]@{ error = 'unauthorized' })
                    Write-GPUmatesHttpResponse `
                        -Stream $Stream `
                        -StatusCode 401 `
                        -ReasonPhrase 'Unauthorized' `
                        -Body $Body `
                        -AdditionalHeader ($ApiHeader + @{ 'WWW-Authenticate' = 'GPUmatesKey' }) `
                        -HeadOnly:($Request.method -eq 'HEAD')
                    continue
                }

                try {
                    $Now = [DateTimeOffset]::UtcNow
                    if ($null -eq $CachedCluster -or ($Now - $ClusterCachedAt).TotalSeconds -ge $CacheSeconds) {
                        $CachedCluster = Get-ClusterSnapshot `
                            -ConfiguredNode $ConfiguredNodes `
                            -AgentToken $AgentAccessToken `
                            -UseAgentAuthentication (-not $AllowUnauthenticatedAgents) `
                            -TimeoutMilliseconds $NodeTimeoutMilliseconds `
                            -LlamaConfig $LlamaConfig `
                            -LlamaApiKey $LlamaApiKey `
                            -AllowedCoordinatorIP $LocalCoordinatorDisplayIP
                        $ClusterCachedAt = [DateTimeOffset]::UtcNow
                    }
                    $Body = ConvertTo-GPUmatesJsonBytes -InputObject $CachedCluster -Depth 20
                    Write-GPUmatesHttpResponse `
                        -Stream $Stream `
                        -StatusCode 200 `
                        -ReasonPhrase 'OK' `
                        -Body $Body `
                        -AdditionalHeader $ApiHeader `
                        -HeadOnly:($Request.method -eq 'HEAD')
                }
                catch {
                    Write-Warning "Cluster aggregation failed: $($_.Exception.Message)"
                    $Body = ConvertTo-GPUmatesJsonBytes -InputObject ([ordered]@{ error = 'aggregation_unavailable' })
                    Write-GPUmatesHttpResponse `
                        -Stream $Stream `
                        -StatusCode 503 `
                        -ReasonPhrase 'Service Unavailable' `
                        -Body $Body `
                        -AdditionalHeader $ApiHeader `
                        -HeadOnly:($Request.method -eq 'HEAD')
                }
                continue
            }

            if (-not $ResolvedDashboardRoot) {
                $Body = ConvertTo-GPUmatesJsonBytes -InputObject ([ordered]@{ error = 'dashboard_not_built' })
                Write-GPUmatesHttpResponse `
                    -Stream $Stream `
                    -StatusCode 503 `
                    -ReasonPhrase 'Service Unavailable' `
                    -Body $Body `
                    -AdditionalHeader $SecurityHeader `
                    -HeadOnly:($Request.method -eq 'HEAD')
                continue
            }

            $StaticFile = Resolve-StaticFile -Root $ResolvedDashboardRoot -RequestPath $Request.path
            if (-not $StaticFile) {
                $Body = ConvertTo-GPUmatesJsonBytes -InputObject ([ordered]@{ error = 'not_found' })
                Write-GPUmatesHttpResponse `
                    -Stream $Stream `
                    -StatusCode 404 `
                    -ReasonPhrase 'Not Found' `
                    -Body $Body `
                    -AdditionalHeader $SecurityHeader `
                    -HeadOnly:($Request.method -eq 'HEAD')
                continue
            }

            $Body = [IO.File]::ReadAllBytes($StaticFile)
            Write-GPUmatesHttpResponse `
                -Stream $Stream `
                -StatusCode 200 `
                -ReasonPhrase 'OK' `
                -Body $Body `
                -ContentType (Get-ContentType -Path $StaticFile) `
                -AdditionalHeader $SecurityHeader `
                -HeadOnly:($Request.method -eq 'HEAD')
        }
        catch {
            Write-Warning "Dashboard request failed: $($_.Exception.Message)"
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
}
