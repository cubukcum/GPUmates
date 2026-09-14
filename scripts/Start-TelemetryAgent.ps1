[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [System.Net.IPAddress]$ListenIP,

    [Parameter(Mandatory)]
    [Alias('CoordinatorIP')]
    [System.Net.IPAddress[]]$AllowedClientIP,

    [ValidateRange(1024, 65535)]
    [int]$Port = 9835,

    [string]$NodeName = $env:COMPUTERNAME,

    [System.Net.IPAddress]$AdvertisedIP,

    [ValidateSet('coordinator', 'worker')]
    [string]$Role = 'worker',

    [ValidateRange(1, 300)]
    [int]$SampleIntervalSeconds = 2,

    [string]$AccessToken = $env:GPUMATES_AGENT_KEY,

    [switch]$AllowUnauthenticated,

    [string]$NvidiaSmiPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'GPUmates.Telemetry.psm1') -Force

Assert-GPUmatesListenAddress -ListenIP $ListenIP
if ($null -eq $AdvertisedIP) {
    $AdvertisedIP = $ListenIP
}
if ($AdvertisedIP.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
    $AdvertisedIP.Equals([Net.IPAddress]::Any) -or
    $AdvertisedIP.Equals([Net.IPAddress]::Broadcast)) {
    throw 'AdvertisedIP must be one explicit IPv4 address.'
}
if ([string]::IsNullOrWhiteSpace($NodeName)) {
    throw 'NodeName cannot be empty.'
}
if ($AllowedClientIP.Count -eq 0) {
    throw 'At least one AllowedClientIP is required.'
}
foreach ($Address in $AllowedClientIP) {
    if ($Address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $Address.Equals([Net.IPAddress]::Any) -or
        $Address.Equals([Net.IPAddress]::Broadcast)) {
        throw 'Every AllowedClientIP must be one explicit IPv4 address.'
    }
}

if (-not $AllowUnauthenticated -and
    ([string]::IsNullOrWhiteSpace($AccessToken) -or $AccessToken.Length -lt 24)) {
    throw 'Set GPUMATES_AGENT_KEY to a random value of at least 24 characters, or explicitly pass -AllowUnauthenticated for an isolated test.'
}
if ($AllowUnauthenticated -and -not [string]::IsNullOrEmpty($AccessToken)) {
    throw 'Do not combine -AllowUnauthenticated with AccessToken/GPUMATES_AGENT_KEY.'
}

# Resolve this once so a missing NVIDIA driver fails before the listening socket opens.
$ResolvedNvidiaSmi = Resolve-GPUmatesNvidiaSmi -NvidiaSmiPath $NvidiaSmiPath
$AllowedClientAddress = @($AllowedClientIP | ForEach-Object { $_.IPAddressToString } | Select-Object -Unique)
$Listener = [Net.Sockets.TcpListener]::new($ListenIP, $Port)
$CachedSnapshot = $null
$LastSampleAt = [DateTimeOffset]::MinValue

try {
    $Listener.Start()
    Write-Host "GPUmates telemetry agent $NodeName listening on http://$($ListenIP.IPAddressToString):$Port"
    Write-Host "Allowed client IP(s): $($AllowedClientAddress -join ', ')"
    if ($AllowUnauthenticated) {
        Write-Warning 'Authentication is disabled. Keep the firewall restricted to the coordinator.'
    }
    else {
        Write-Host 'Requests require X-GPUmates-Agent-Key. The key is not logged.'
    }
    Write-Host 'Read-only endpoints: /health and /api/v1/metrics. Press Ctrl+C to stop.'

    while ($true) {
        $Client = $null
        $Stream = $null
        try {
            $Client = $Listener.AcceptTcpClient()
            $Client.ReceiveTimeout = 3000
            $Client.SendTimeout = 3000
            $Client.NoDelay = $true
            $RemoteIP = ([Net.IPEndPoint]$Client.Client.RemoteEndPoint).Address.IPAddressToString
            $Stream = $Client.GetStream()

            if ($RemoteIP -notin $AllowedClientAddress) {
                $Body = ConvertTo-GPUmatesJsonBytes -InputObject ([ordered]@{ error = 'forbidden' })
                Write-GPUmatesHttpResponse -Stream $Stream -StatusCode 403 -ReasonPhrase 'Forbidden' -Body $Body
                continue
            }

            try {
                $Request = Read-GPUmatesHttpRequest -Stream $Stream
            }
            catch {
                $Body = ConvertTo-GPUmatesJsonBytes -InputObject ([ordered]@{ error = 'bad_request' })
                Write-GPUmatesHttpResponse -Stream $Stream -StatusCode 400 -ReasonPhrase 'Bad Request' -Body $Body
                continue
            }

            $PresentedToken = $null
            if ($Request.headers.ContainsKey('x-gpumates-agent-key')) {
                $PresentedToken = [string]$Request.headers['x-gpumates-agent-key']
            }
            if (-not $AllowUnauthenticated -and
                -not (Test-GPUmatesAccessToken -Expected $AccessToken -Presented $PresentedToken)) {
                $Body = ConvertTo-GPUmatesJsonBytes -InputObject ([ordered]@{ error = 'unauthorized' })
                Write-GPUmatesHttpResponse `
                    -Stream $Stream `
                    -StatusCode 401 `
                    -ReasonPhrase 'Unauthorized' `
                    -Body $Body `
                    -AdditionalHeader @{ 'WWW-Authenticate' = 'GPUmatesKey' } `
                    -HeadOnly:($Request.method -eq 'HEAD')
                continue
            }

            switch ($Request.path) {
                '/health' {
                    $Body = ConvertTo-GPUmatesJsonBytes -InputObject ([ordered]@{
                            status        = 'ok'
                            schemaVersion = 1
                            node          = $NodeName
                            timestamp     = [DateTimeOffset]::UtcNow.ToString('o')
                        })
                    Write-GPUmatesHttpResponse `
                        -Stream $Stream `
                        -StatusCode 200 `
                        -ReasonPhrase 'OK' `
                        -Body $Body `
                        -HeadOnly:($Request.method -eq 'HEAD')
                }
                '/api/v1/metrics' {
                    try {
                        $Now = [DateTimeOffset]::UtcNow
                        if ($null -eq $CachedSnapshot -or
                            ($Now - $LastSampleAt).TotalSeconds -ge $SampleIntervalSeconds) {
                            $CachedSnapshot = Get-GPUmatesTelemetrySnapshot `
                                -NodeName $NodeName `
                                -NodeIP $AdvertisedIP `
                                -Role $Role `
                                -SampleIntervalSeconds $SampleIntervalSeconds `
                                -NvidiaSmiPath $ResolvedNvidiaSmi
                            $LastSampleAt = $Now
                        }
                        $Body = ConvertTo-GPUmatesJsonBytes -InputObject $CachedSnapshot
                        Write-GPUmatesHttpResponse `
                            -Stream $Stream `
                            -StatusCode 200 `
                            -ReasonPhrase 'OK' `
                            -Body $Body `
                            -HeadOnly:($Request.method -eq 'HEAD')
                    }
                    catch {
                        Write-Warning "Telemetry collection failed: $($_.Exception.Message)"
                        $Body = ConvertTo-GPUmatesJsonBytes -InputObject ([ordered]@{
                                error     = 'telemetry_unavailable'
                                timestamp = [DateTimeOffset]::UtcNow.ToString('o')
                            })
                        Write-GPUmatesHttpResponse `
                            -Stream $Stream `
                            -StatusCode 503 `
                            -ReasonPhrase 'Service Unavailable' `
                            -Body $Body `
                            -HeadOnly:($Request.method -eq 'HEAD')
                    }
                }
                default {
                    $Body = ConvertTo-GPUmatesJsonBytes -InputObject ([ordered]@{ error = 'not_found' })
                    Write-GPUmatesHttpResponse `
                        -Stream $Stream `
                        -StatusCode 404 `
                        -ReasonPhrase 'Not Found' `
                        -Body $Body `
                        -HeadOnly:($Request.method -eq 'HEAD')
                }
            }
        }
        catch {
            # A client disconnect or malformed packet must not stop the long-running agent.
            Write-Warning "Telemetry request failed: $($_.Exception.Message)"
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
