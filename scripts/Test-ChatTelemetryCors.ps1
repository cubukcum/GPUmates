[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-TestPort {
    $Probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
        $Probe.Start()
        return ([Net.IPEndPoint]$Probe.LocalEndpoint).Port
    }
    finally { $Probe.Stop() }
}

function Invoke-TestHttp {
    param(
        [int]$Port,
        [string]$Method = 'GET',
        [string]$Path = '/api/v1/cluster',
        [hashtable]$Headers = @{},
        [string[]]$ExtraHeaders = @(),
        [string]$SourceIP = '127.0.0.1'
    )
    $Client = [Net.Sockets.TcpClient]::new([Net.IPEndPoint]::new([Net.IPAddress]::Parse($SourceIP), 0))
    $Client.ReceiveTimeout = 20000
    $Client.SendTimeout = 3000
    $Received = [IO.MemoryStream]::new()
    try {
        $Client.Connect([Net.IPAddress]::Loopback, $Port)
        $Stream = $Client.GetStream()
        $Lines = @("$Method $Path HTTP/1.1", "Host: 127.0.0.1:$Port", 'Connection: close')
        foreach ($Name in $Headers.Keys) { $Lines += "${Name}: $($Headers[$Name])" }
        $Lines += $ExtraHeaders
        $Bytes = [Text.Encoding]::ASCII.GetBytes(($Lines + @('', '')) -join "`r`n")
        $Stream.Write($Bytes, 0, $Bytes.Length)
        $Buffer = New-Object byte[] 4096
        while ($true) {
            try { $Count = $Stream.Read($Buffer, 0, $Buffer.Length) }
            catch {
                # An IP-denied client may be closed before its request is read.
                if ($Received.Length -gt 0) { break }
                throw
            }
            if ($Count -eq 0) { break }
            $Received.Write($Buffer, 0, $Count)
        }
        $Text = [Text.Encoding]::UTF8.GetString($Received.ToArray())
        $Parts = $Text -split "`r`n`r`n", 2
        $ResponseLines = $Parts[0] -split "`r`n"
        Assert-Test ($ResponseLines[0] -match '^HTTP/1\.1 (\d{3}) ') 'Expected an HTTP response.'
        $Status = [int]$Matches[1]
        $ResponseHeaders = @{}
        foreach ($Line in $ResponseLines | Select-Object -Skip 1) {
            $Colon = $Line.IndexOf(':')
            if ($Colon -gt 0) { $ResponseHeaders[$Line.Substring(0, $Colon).ToLowerInvariant()] = $Line.Substring($Colon + 1).Trim() }
        }
        return [pscustomobject]@{ status = $Status; headers = $ResponseHeaders; body = $(if ($Parts.Count -gt 1) { $Parts[1] } else { '' }) }
    }
    finally {
        $Received.Dispose()
        $Client.Dispose()
    }
}

function Wait-TestServer {
    param([int]$Port, [Management.Automation.Job]$Job, [hashtable]$Headers = @{})
    $Deadline = [DateTime]::UtcNow.AddSeconds(20)
    while ([DateTime]::UtcNow -lt $Deadline) {
        if ($Job.State -ne 'Running') {
            $Details = Receive-Job -Job $Job -ErrorAction Continue | Out-String
            throw "Test server stopped: $Details"
        }
        try {
            $Response = Invoke-TestHttp -Port $Port -Path '/health' -Headers $Headers
            if ($Response.status -eq 200) { return }
        }
        catch { }
        Start-Sleep -Milliseconds 100
    }
    throw 'Test server did not start within 20 seconds.'
}

function Assert-Cors {
    param($Response, [int]$Status, [string]$Origin)
    Assert-Test ($Response.status -eq $Status) "Expected HTTP $Status, received $($Response.status)."
    Assert-Test ($Response.headers.ContainsKey('access-control-allow-origin')) 'Expected an exact CORS origin.'
    Assert-Test ($Response.headers['access-control-allow-origin'] -ceq $Origin) 'CORS origin must match exactly.'
    Assert-Test (-not $Response.headers.ContainsKey('access-control-allow-credentials')) 'Cookie credentials must not be enabled.'
    Assert-Test ($Response.headers['vary'] -eq 'Origin') 'Origin-sensitive responses must vary by Origin.'
    Assert-Test ($Response.headers['content-security-policy'] -match "frame-ancestors 'none'") 'Dashboard framing protection must remain enabled.'
    Assert-Test ($Response.headers['x-frame-options'] -eq 'DENY') 'Dashboard X-Frame-Options must remain DENY.'
}

$TestRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('gpumates-chat-cors-' + [Guid]::NewGuid().ToString('N'))))
$ExpectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
Assert-Test ($TestRoot.StartsWith($ExpectedParent, [StringComparison]::OrdinalIgnoreCase)) 'Tests must stay inside the temporary directory.'
New-Item -ItemType Directory -Path $TestRoot | Out-Null
$DashboardJob = $null
$AgentJob = $null
$ErrorDashboardJob = $null
try {
    $DashboardKey = [Guid]::NewGuid().ToString('N')
    $AgentKey = [Guid]::NewGuid().ToString('N')
    $DashboardPort = Get-TestPort
    $AgentPort = Get-TestPort
    $CoordinatorIP = @([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.OperationalStatus -eq [Net.NetworkInformation.OperationalStatus]::Up } |
        ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
        Where-Object { $_.Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and $_.Address.IPAddressToString -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' } |
        ForEach-Object { $_.Address.IPAddressToString } | Select-Object -First 1)
    $CoordinatorAddress = if ($CoordinatorIP.Count -gt 0) { $CoordinatorIP[0] } else { '127.0.0.1' }
    $CoordinatorOrigin = "http://${CoordinatorAddress}:8080"
    $NodeConfigPath = Join-Path $TestRoot 'nodes.json'
    $StaticRoot = Join-Path $TestRoot 'static'
    New-Item -ItemType Directory -Path $StaticRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $StaticRoot 'index.html'), '<!doctype html><title>CORS test</title>')
    @{
        schemaVersion = 1
        dashboard = @{ allowedClientIps = @('127.0.0.1', '127.0.0.2') }
        nodes = @(@{ name = 'Test coordinator'; host = '127.0.0.1'; displayIp = $CoordinatorAddress; port = 9835; local = $true; role = 'coordinator' })
        llama = @{ enabled = $false }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $NodeConfigPath -Encoding UTF8

    $DashboardJob = Start-Job -ScriptBlock {
        param($Script, $Config, $Static, $TestPort, $Key, $WorkerKey)
        [pscustomobject]@{ processId = $PID; purpose = 'GPUmates CORS test server' }
        & $Script -ListenIP '127.0.0.1' -Port $TestPort -NodeConfig $Config -DashboardRoot $Static -DashboardAccessToken $Key -AgentAccessToken $WorkerKey -LlamaApiKey ''
    } -ArgumentList (Join-Path $PSScriptRoot 'Start-GPUmatesDashboard.ps1'), $NodeConfigPath, $StaticRoot, $DashboardPort, $DashboardKey, $AgentKey
    Wait-TestServer -Port $DashboardPort -Job $DashboardJob

    foreach ($Origin in @($CoordinatorOrigin, 'http://127.0.0.1:8080', 'http://localhost:8080') | Select-Object -Unique) {
        $Preflight = @{ Origin = $Origin; 'Access-Control-Request-Method' = 'GET'; 'Access-Control-Request-Headers' = 'x-gpumates-key' }
        $Response = Invoke-TestHttp -Port $DashboardPort -Method OPTIONS -Headers $Preflight
        Assert-Cors $Response 200 $Origin
        Assert-Test ($Response.headers['access-control-allow-methods'] -eq 'GET, HEAD') 'Only read methods may be allowed.'
        Assert-Test ($Response.headers['access-control-allow-headers'] -eq 'X-GPUmates-Key') 'Only the dashboard key header may be allowed.'
        Assert-Test ($Response.body -notmatch 'nodes|gpu') 'Preflight must not expose metrics.'
        Assert-Cors (Invoke-TestHttp -Port $DashboardPort -Headers @{ Origin = $Origin }) 401 $Origin
        Assert-Cors (Invoke-TestHttp -Port $DashboardPort -Headers @{ Origin = $Origin; 'X-GPUmates-Key' = 'wrong-key' }) 401 $Origin
        Assert-Cors (Invoke-TestHttp -Port $DashboardPort -Headers @{ Origin = $Origin; 'X-GPUmates-Key' = $AgentKey }) 401 $Origin
        $Response = Invoke-TestHttp -Port $DashboardPort -Headers @{ Origin = $Origin; 'X-GPUmates-Key' = $DashboardKey }
        Assert-Cors $Response 200 $Origin
        Assert-Test (($Response.body | ConvertFrom-Json).schemaVersion -eq 1) 'Authenticated access must return the cluster schema.'
    }
    Write-Host '[PASS] Exact chat origins, preflight, missing/wrong/separate keys, and authenticated cluster access.'

    $TrustedOrigin = 'http://127.0.0.1:8080'
    foreach ($Origin in @('null', '', 'https://127.0.0.1:8080', 'http://127.0.0.1:8081', 'http://127.0.0.1:8080/', 'http://127.0.0.1:8080.evil.test', 'http://user@127.0.0.1:8080', 'http://127.0.0.2:8080', 'http://evil.test', 'http://127.0.0.1:8080 http://evil.test')) {
        foreach ($Method in @('OPTIONS', 'GET')) {
            $Response = Invoke-TestHttp -Port $DashboardPort -Method $Method -Headers @{ Origin = $Origin; 'Access-Control-Request-Method' = 'GET'; 'X-GPUmates-Key' = $DashboardKey }
            Assert-Test ($Response.status -eq 403) 'Untrusted or malformed origins must be denied even with a valid key.'
            Assert-Test (-not $Response.headers.ContainsKey('access-control-allow-origin')) 'Denied origins must not receive CORS permission.'
        }
    }
    foreach ($Method in @('POST', 'DELETE', 'get', 'GET, POST', '')) {
        Assert-Cors (Invoke-TestHttp -Port $DashboardPort -Method OPTIONS -Headers @{ Origin = $TrustedOrigin; 'Access-Control-Request-Method' = $Method }) 405 $TrustedOrigin
    }
    foreach ($Header in @('Authorization', 'X-GPUmates-Agent-Key', 'x-gpumates-key, authorization', 'x-gpumates-key,', '', 'x-gpumates-key, x-gpumates-key')) {
        Assert-Cors (Invoke-TestHttp -Port $DashboardPort -Method OPTIONS -Headers @{ Origin = $TrustedOrigin; 'Access-Control-Request-Method' = 'GET'; 'Access-Control-Request-Headers' = $Header }) 403 $TrustedOrigin
    }
    Assert-Cors (Invoke-TestHttp -Port $DashboardPort -Method OPTIONS -Headers @{ Origin = $TrustedOrigin }) 400 $TrustedOrigin
    $Response = Invoke-TestHttp -Port $DashboardPort -Method OPTIONS -Headers @{ 'Access-Control-Request-Method' = 'GET' }
    Assert-Test ($Response.status -eq 400 -and -not $Response.headers.ContainsKey('access-control-allow-origin')) 'Preflight without Origin must fail.'
    $Response = Invoke-TestHttp -Port $DashboardPort -Method OPTIONS -Headers @{ Origin = $TrustedOrigin; 'Access-Control-Request-Method' = 'GET' } -ExtraHeaders @('Origin: http://evil.test')
    Assert-Test ($Response.status -eq 400 -and -not $Response.headers.ContainsKey('access-control-allow-origin')) 'Duplicate Origin headers must fail.'
    Write-Host '[PASS] Malformed/disallowed origins, methods, headers, and duplicate origins are rejected.'

    foreach ($Path in @('/', '/health', '/api/v1/metrics', '/API/v1/cluster')) {
        $Response = Invoke-TestHttp -Port $DashboardPort -Method OPTIONS -Path $Path -Headers @{ Origin = $TrustedOrigin; 'Access-Control-Request-Method' = 'GET' }
        Assert-Test ($Response.status -eq 405 -and -not $Response.headers.ContainsKey('access-control-allow-origin')) 'Preflight permission must be limited to the exact cluster API.'
    }
    $Response = Invoke-TestHttp -Port $DashboardPort -Path '/' -Headers @{ Origin = $TrustedOrigin }
    Assert-Test ($Response.status -eq 200 -and -not $Response.headers.ContainsKey('access-control-allow-origin')) 'Static files must remain outside CORS.'
    $Response = Invoke-TestHttp -Port $DashboardPort -Headers @{ 'X-GPUmates-Key' = $DashboardKey }
    Assert-Test ($Response.status -eq 200 -and -not $Response.headers.ContainsKey('access-control-allow-origin')) 'Existing same-origin access must remain available.'
    $Response = Invoke-TestHttp -Port $DashboardPort -Method HEAD -Headers @{ Origin = $TrustedOrigin; 'X-GPUmates-Key' = $DashboardKey }
    Assert-Cors $Response 200 $TrustedOrigin
    Assert-Test ([string]::IsNullOrEmpty($Response.body)) 'HEAD must not return metrics in its body.'
    $Response = Invoke-TestHttp -Port $DashboardPort -SourceIP '127.0.0.3' -Headers @{ Origin = $TrustedOrigin; 'X-GPUmates-Key' = $DashboardKey }
    Assert-Test ($Response.status -eq 403 -and -not $Response.headers.ContainsKey('access-control-allow-origin')) 'A valid key and trusted origin must not bypass the client IP allowlist.'
    $Response = Invoke-TestHttp -Port $DashboardPort -SourceIP '127.0.0.2' -Headers @{ Origin = $TrustedOrigin; 'X-GPUmates-Key' = $DashboardKey }
    Assert-Test ($Response.status -eq 403 -and -not $Response.headers.ContainsKey('access-control-allow-origin')) 'Loopback chat origins must belong to the coordinator itself.'
    if ($CoordinatorAddress -ne '127.0.0.1') {
        Assert-Cors (Invoke-TestHttp -Port $DashboardPort -SourceIP '127.0.0.2' -Headers @{ Origin = $CoordinatorOrigin; 'X-GPUmates-Key' = $DashboardKey }) 200 $CoordinatorOrigin
    }
    Write-Host '[PASS] Route isolation, static/same-origin access, HEAD, framing protection, and exact client IP restrictions.'

    # Exercise the real aggregation-error response without disrupting any live config.
    $ErrorConfig = Get-Content -LiteralPath $NodeConfigPath -Raw | ConvertFrom-Json
    $ErrorConfig.llama = [pscustomobject]@{ enabled = $true; baseUrl = 'http://[invalid' }
    $ErrorConfigPath = Join-Path $TestRoot 'unavailable-nodes.json'
    $ErrorConfig | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ErrorConfigPath -Encoding UTF8
    $ErrorPort = Get-TestPort
    $ErrorDashboardJob = Start-Job -ScriptBlock {
        param($Script, $Config, $Static, $TestPort, $Key, $WorkerKey)
        [pscustomobject]@{ processId = $PID; purpose = 'GPUmates CORS test server' }
        & $Script -ListenIP '127.0.0.1' -Port $TestPort -NodeConfig $Config -DashboardRoot $Static -DashboardAccessToken $Key -AgentAccessToken $WorkerKey -LlamaApiKey ''
    } -ArgumentList (Join-Path $PSScriptRoot 'Start-GPUmatesDashboard.ps1'), $ErrorConfigPath, $StaticRoot, $ErrorPort, $DashboardKey, $AgentKey
    Wait-TestServer -Port $ErrorPort -Job $ErrorDashboardJob
    Assert-Cors (Invoke-TestHttp -Port $ErrorPort -Headers @{ Origin = $TrustedOrigin; 'X-GPUmates-Key' = $DashboardKey }) 503 $TrustedOrigin
    Write-Host '[PASS] Trusted chat receives readable aggregation failures without relaxing authentication.'

    # The real worker server must retain GET/HEAD-only parsing and its own key.
    # A harmless placeholder satisfies its executable-path check; /health never runs it.
    $DummySmi = Join-Path $TestRoot 'unused-nvidia-smi.ps1'
    [IO.File]::WriteAllText($DummySmi, "throw 'The CORS test must not execute GPU collection.'")
    $AgentJob = Start-Job -ScriptBlock {
        param($Script, $TestPort, $Key, $Smi)
        [pscustomobject]@{ processId = $PID; purpose = 'GPUmates CORS test server' }
        & $Script -ListenIP '127.0.0.1' -AllowedClientIP '127.0.0.1' -Port $TestPort -NodeName 'CORS test worker' -AccessToken $Key -NvidiaSmiPath $Smi
    } -ArgumentList (Join-Path $PSScriptRoot 'Start-TelemetryAgent.ps1'), $AgentPort, $AgentKey, $DummySmi
    Wait-TestServer -Port $AgentPort -Job $AgentJob -Headers @{ 'X-GPUmates-Agent-Key' = $AgentKey }
    $Response = Invoke-TestHttp -Port $AgentPort -Method OPTIONS -Path '/api/v1/metrics' -Headers @{ Origin = $TrustedOrigin; 'Access-Control-Request-Method' = 'GET'; 'X-GPUmates-Agent-Key' = $AgentKey }
    Assert-Test ($Response.status -eq 400 -and -not $Response.headers.ContainsKey('access-control-allow-origin')) 'Worker agents must not opt into OPTIONS or CORS.'
    $Response = Invoke-TestHttp -Port $AgentPort -Path '/health' -Headers @{ 'X-GPUmates-Key' = $DashboardKey }
    Assert-Test ($Response.status -eq 401) 'Dashboard credentials must not authorize worker access.'
    $Response = Invoke-TestHttp -Port $AgentPort -Path '/health' -Headers @{ Origin = $TrustedOrigin; 'X-GPUmates-Agent-Key' = $AgentKey }
    Assert-Test ($Response.status -eq 200 -and -not $Response.headers.ContainsKey('access-control-allow-origin')) 'Authenticated worker requests must remain outside CORS.'
    Write-Host '[PASS] Worker OPTIONS rejection, credential separation, and unchanged CORS isolation.'
}
finally {
    foreach ($Job in @($DashboardJob, $AgentJob, $ErrorDashboardJob)) {
        if ($null -ne $Job) {
            # Stop-Job alone waits on the servers' blocking AcceptTcpClient call.
            # Terminate only the test child process that identified itself above.
            if ($Job.State -eq 'Running' -and $Job.ChildJobs[0].Output.Count -gt 0) {
                $Identity = $Job.ChildJobs[0].Output[0]
                if ($Identity.purpose -eq 'GPUmates CORS test server' -and $Identity.processId -ne $PID) {
                    Stop-Process -Id ([int]$Identity.processId) -Force -ErrorAction SilentlyContinue
                }
            }
            Stop-Job -Job $Job -ErrorAction SilentlyContinue
            Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
        }
    }
    $ResolvedTestRoot = [IO.Path]::GetFullPath($TestRoot)
    if (-not $ResolvedTestRoot.StartsWith($ExpectedParent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to delete a directory outside the test temporary parent.' }
    Remove-Item -LiteralPath $ResolvedTestRoot -Recurse -Force
}

Write-Host 'All chat telemetry CORS security checks passed.'
