Set-StrictMode -Version Latest

$script:TelemetryVersion = '1.0.0'
$script:PreviousNativeSystemSample = $null

function Initialize-GPUmatesNativeMethods {
    if ('GPUmates.NativeMethods' -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace GPUmates {
    public static class NativeMethods {
        [StructLayout(LayoutKind.Sequential)]
        public struct FileTime {
            public uint Low;
            public uint High;
            public ulong Value { get { return ((ulong)High << 32) | Low; } }
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        public class MemoryStatusEx {
            public uint Length = (uint)Marshal.SizeOf(typeof(MemoryStatusEx));
            public uint MemoryLoad;
            public ulong TotalPhysical;
            public ulong AvailablePhysical;
            public ulong TotalPageFile;
            public ulong AvailablePageFile;
            public ulong TotalVirtual;
            public ulong AvailableVirtual;
            public ulong AvailableExtendedVirtual;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetSystemTimes(out FileTime idle, out FileTime kernel, out FileTime user);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern bool GlobalMemoryStatusEx([In, Out] MemoryStatusEx status);

        [DllImport("kernel32.dll")]
        public static extern ulong GetTickCount64();
    }
}
'@
}

function Get-GPUmatesNativeRawSystemSample {
    Initialize-GPUmatesNativeMethods

    $Idle = [GPUmates.NativeMethods+FileTime]::new()
    $Kernel = [GPUmates.NativeMethods+FileTime]::new()
    $User = [GPUmates.NativeMethods+FileTime]::new()
    if (-not [GPUmates.NativeMethods]::GetSystemTimes([ref]$Idle, [ref]$Kernel, [ref]$User)) {
        throw 'Windows GetSystemTimes failed.'
    }

    $Memory = [GPUmates.NativeMethods+MemoryStatusEx]::new()
    if (-not [GPUmates.NativeMethods]::GlobalMemoryStatusEx($Memory)) {
        throw 'Windows GlobalMemoryStatusEx failed.'
    }

    $Adapters = @{}
    foreach ($Adapter in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($Adapter.OperationalStatus -ne [Net.NetworkInformation.OperationalStatus]::Up -or
            $Adapter.NetworkInterfaceType -in @(
                [Net.NetworkInformation.NetworkInterfaceType]::Loopback,
                [Net.NetworkInformation.NetworkInterfaceType]::Tunnel
            )) {
            continue
        }
        try {
            $HasIPv4Address = @($Adapter.GetIPProperties().UnicastAddresses |
                Where-Object {
                    $_.Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and
                    -not $_.Address.Equals([Net.IPAddress]::Any)
                }).Count -gt 0
            if (-not $HasIPv4Address) {
                continue
            }
            $Statistics = $Adapter.GetIPv4Statistics()
            $Adapters[$Adapter.Id] = [ordered]@{
                name = $Adapter.Name
                rx   = [int64]$Statistics.BytesReceived
                tx   = [int64]$Statistics.BytesSent
            }
        }
        catch {
            # Some virtual adapters expose no IPv4 statistics.
        }
    }

    return [ordered]@{
        timestamp        = [DateTimeOffset]::UtcNow
        idleTime         = [uint64]$Idle.Value
        kernelTime       = [uint64]$Kernel.Value
        userTime         = [uint64]$User.Value
        memoryTotalBytes = [int64]$Memory.TotalPhysical
        memoryFreeBytes  = [int64]$Memory.AvailablePhysical
        uptimeSeconds    = [int64]([GPUmates.NativeMethods]::GetTickCount64() / 1000)
        adapters         = $Adapters
    }
}

function Get-GPUmatesNativeSystemTelemetry {
    $Current = Get-GPUmatesNativeRawSystemSample
    $Previous = $script:PreviousNativeSystemSample
    if ($null -eq $Previous) {
        Start-Sleep -Milliseconds 150
        $Previous = $Current
        $Current = Get-GPUmatesNativeRawSystemSample
    }
    $script:PreviousNativeSystemSample = $Current

    $ElapsedSeconds = ($Current.timestamp - $Previous.timestamp).TotalSeconds
    $CpuUtilization = $null
    $TotalDelta = ([double]$Current.kernelTime - [double]$Previous.kernelTime) +
        ([double]$Current.userTime - [double]$Previous.userTime)
    $IdleDelta = [double]$Current.idleTime - [double]$Previous.idleTime
    if ($TotalDelta -gt 0) {
        $CpuUtilization = [math]::Round(
            [math]::Max(0, [math]::Min(100, (($TotalDelta - $IdleDelta) / $TotalDelta) * 100)),
            1
        )
    }

    $NetworkAdapters = @()
    [int64]$NetworkRx = 0
    [int64]$NetworkTx = 0
    if ($ElapsedSeconds -gt 0) {
        foreach ($Id in $Current.adapters.Keys) {
            if (-not $Previous.adapters.ContainsKey($Id)) {
                continue
            }
            $RxDelta = [math]::Max(0, [int64]$Current.adapters[$Id].rx - [int64]$Previous.adapters[$Id].rx)
            $TxDelta = [math]::Max(0, [int64]$Current.adapters[$Id].tx - [int64]$Previous.adapters[$Id].tx)
            $RxRate = [int64][math]::Round($RxDelta / $ElapsedSeconds)
            $TxRate = [int64][math]::Round($TxDelta / $ElapsedSeconds)
            $NetworkRx += $RxRate
            $NetworkTx += $TxRate
            $NetworkAdapters += [ordered]@{
                name          = [string]$Current.adapters[$Id].name
                rxBytesPerSec = $RxRate
                txBytesPerSec = $TxRate
            }
        }
    }

    return [ordered]@{
        cpuUtilizationPct    = $CpuUtilization
        memoryUsedBytes      = [math]::Max([int64]0, $Current.memoryTotalBytes - $Current.memoryFreeBytes)
        memoryTotalBytes     = $Current.memoryTotalBytes
        networkRxBytesPerSec = $NetworkRx
        networkTxBytesPerSec = $NetworkTx
        networkAdapters      = @($NetworkAdapters)
        uptimeSeconds        = $Current.uptimeSeconds
    }
}

function ConvertTo-GPUmatesNullableDouble {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    $Text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($Text) -or
        $Text -match '^\[(N/A|Not Supported|Not Found|Unknown Error)\]$' -or
        $Text -eq 'N/A') {
        return $null
    }

    [double]$Number = 0
    if ([double]::TryParse(
            $Text,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$Number)) {
        return $Number
    }

    return $null
}

function ConvertTo-GPUmatesNullableInt64 {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [object]$Value
    )

    $Number = ConvertTo-GPUmatesNullableDouble -Value $Value
    if ($null -eq $Number) {
        return $null
    }

    return [int64][math]::Round($Number)
}

function ConvertFrom-GPUmatesNvidiaCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$CsvLine
    )

    $Headers = @(
        'index',
        'name',
        'uuid',
        'utilizationPct',
        'memoryUsedMiB',
        'memoryTotalMiB',
        'temperatureC',
        'powerDrawW',
        'powerLimitW',
        'fanPct',
        'graphicsClockMHz',
        'memoryClockMHz'
    )

    $UsefulLines = @($CsvLine | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($UsefulLines.Count -eq 0) {
        return @()
    }

    $Rows = @($UsefulLines | ConvertFrom-Csv -Header $Headers)
    $Result = foreach ($Row in $Rows) {
        [ordered]@{
            index            = ConvertTo-GPUmatesNullableInt64 -Value $Row.index
            name             = ([string]$Row.name).Trim()
            uuid             = ([string]$Row.uuid).Trim()
            utilizationPct   = ConvertTo-GPUmatesNullableDouble -Value $Row.utilizationPct
            memoryUsedMiB    = ConvertTo-GPUmatesNullableDouble -Value $Row.memoryUsedMiB
            memoryTotalMiB   = ConvertTo-GPUmatesNullableDouble -Value $Row.memoryTotalMiB
            temperatureC     = ConvertTo-GPUmatesNullableDouble -Value $Row.temperatureC
            powerDrawW       = ConvertTo-GPUmatesNullableDouble -Value $Row.powerDrawW
            powerLimitW      = ConvertTo-GPUmatesNullableDouble -Value $Row.powerLimitW
            fanPct           = ConvertTo-GPUmatesNullableDouble -Value $Row.fanPct
            graphicsClockMHz = ConvertTo-GPUmatesNullableDouble -Value $Row.graphicsClockMHz
            memoryClockMHz   = ConvertTo-GPUmatesNullableDouble -Value $Row.memoryClockMHz
        }
    }

    return @($Result)
}

function Resolve-GPUmatesNvidiaSmi {
    [CmdletBinding()]
    param(
        [string]$NvidiaSmiPath
    )

    if (-not [string]::IsNullOrWhiteSpace($NvidiaSmiPath)) {
        return (Resolve-Path -LiteralPath $NvidiaSmiPath -ErrorAction Stop).Path
    }

    $Candidates = @(
        (Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'),
        (Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe')
    )

    foreach ($Candidate in $Candidates) {
        if (Test-Path -LiteralPath $Candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $Candidate).Path
        }
    }

    $Command = Get-Command 'nvidia-smi.exe' -CommandType Application -ErrorAction SilentlyContinue
    if ($Command) {
        return $Command.Source
    }

    throw 'nvidia-smi.exe was not found. Install a current NVIDIA driver, or pass -NvidiaSmiPath.'
}

function Get-GPUmatesGpuTelemetry {
    [CmdletBinding()]
    param(
        [string]$NvidiaSmiPath
    )

    $ResolvedPath = Resolve-GPUmatesNvidiaSmi -NvidiaSmiPath $NvidiaSmiPath
    $Query = @(
        'index',
        'name',
        'uuid',
        'utilization.gpu',
        'memory.used',
        'memory.total',
        'temperature.gpu',
        'power.draw',
        'power.limit',
        'fan.speed',
        'clocks.current.graphics',
        'clocks.current.memory'
    ) -join ','

    $Output = @(& $ResolvedPath "--query-gpu=$Query" '--format=csv,noheader,nounits' 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "nvidia-smi failed with exit code $LASTEXITCODE."
    }

    return @(ConvertFrom-GPUmatesNvidiaCsv -CsvLine @($Output | ForEach-Object { [string]$_ }))
}

function Get-GPUmatesSystemTelemetry {
    [CmdletBinding()]
    param()

    $CpuUtilization = $null
    $MemoryUsedBytes = $null
    $MemoryTotalBytes = $null
    $UptimeSeconds = $null
    $NetworkRxBytesPerSec = $null
    $NetworkTxBytesPerSec = $null
    $NetworkAdapters = @()

    try {
        $Cpu = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
        $CpuUtilization = ConvertTo-GPUmatesNullableDouble -Value $Cpu.PercentProcessorTime
    }
    catch {
        # A missing or temporarily unavailable counter must not take down GPU telemetry.
    }

    try {
        $OperatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $MemoryTotalBytes = [int64]$OperatingSystem.TotalVisibleMemorySize * 1KB
        $MemoryFreeBytes = [int64]$OperatingSystem.FreePhysicalMemory * 1KB
        $MemoryUsedBytes = [math]::Max([int64]0, $MemoryTotalBytes - $MemoryFreeBytes)
        if ($OperatingSystem.LastBootUpTime) {
            $UptimeSeconds = [int64][math]::Max(0, ((Get-Date) - $OperatingSystem.LastBootUpTime).TotalSeconds)
        }
    }
    catch {
        # Return nulls; the dashboard can distinguish missing system counters from zero usage.
    }

    try {
        $AdapterRows = @(Get-CimInstance -ClassName Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction Stop |
            Where-Object { $_.Name -and $_.Name -notmatch '(?i)loopback' })
        $NetworkAdapters = @($AdapterRows | ForEach-Object {
                [ordered]@{
                    name          = [string]$_.Name
                    rxBytesPerSec = ConvertTo-GPUmatesNullableInt64 -Value $_.BytesReceivedPersec
                    txBytesPerSec = ConvertTo-GPUmatesNullableInt64 -Value $_.BytesSentPersec
                }
            })

        if ($NetworkAdapters.Count -gt 0) {
            $NetworkRxBytesPerSec = [int64](($NetworkAdapters | Measure-Object -Property rxBytesPerSec -Sum).Sum)
            $NetworkTxBytesPerSec = [int64](($NetworkAdapters | Measure-Object -Property txBytesPerSec -Sum).Sum)
        }
    }
    catch {
        # Network performance counters are optional.
    }

    if ($null -eq $CpuUtilization -or
        $null -eq $MemoryTotalBytes -or
        $null -eq $UptimeSeconds -or
        $null -eq $NetworkRxBytesPerSec) {
        try {
            $Native = Get-GPUmatesNativeSystemTelemetry
            if ($null -eq $CpuUtilization) {
                $CpuUtilization = $Native.cpuUtilizationPct
            }
            if ($null -eq $MemoryTotalBytes) {
                $MemoryUsedBytes = $Native.memoryUsedBytes
                $MemoryTotalBytes = $Native.memoryTotalBytes
            }
            if ($null -eq $UptimeSeconds) {
                $UptimeSeconds = $Native.uptimeSeconds
            }
            if ($null -eq $NetworkRxBytesPerSec) {
                $NetworkRxBytesPerSec = $Native.networkRxBytesPerSec
                $NetworkTxBytesPerSec = $Native.networkTxBytesPerSec
                $NetworkAdapters = @($Native.networkAdapters)
            }
        }
        catch {
            # Native counters are best-effort; GPU metrics remain independently available.
        }
    }

    return [ordered]@{
        cpuUtilizationPct  = $CpuUtilization
        memoryUsedBytes    = $MemoryUsedBytes
        memoryTotalBytes   = $MemoryTotalBytes
        networkRxBytesPerSec = $NetworkRxBytesPerSec
        networkTxBytesPerSec = $NetworkTxBytesPerSec
        networkAdapters    = @($NetworkAdapters)
        uptimeSeconds      = $UptimeSeconds
    }
}

function Get-GPUmatesTelemetrySnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$NodeName,

        [Parameter(Mandatory)]
        [System.Net.IPAddress]$NodeIP,

        [ValidateSet('coordinator', 'worker')]
        [string]$Role = 'worker',

        [ValidateRange(1, 300)]
        [int]$SampleIntervalSeconds = 2,

        [string]$NvidiaSmiPath
    )

    $Gpu = @(Get-GPUmatesGpuTelemetry -NvidiaSmiPath $NvidiaSmiPath)
    $System = Get-GPUmatesSystemTelemetry

    return [ordered]@{
        schemaVersion = 1
        node          = [ordered]@{
            name = $NodeName
            ip   = $NodeIP.IPAddressToString
            role = $Role
        }
        timestamp     = [DateTimeOffset]::UtcNow.ToString('o')
        online        = $true
        gpu           = $Gpu
        system        = $System
        agent         = [ordered]@{
            version               = $script:TelemetryVersion
            sampleIntervalSeconds = $SampleIntervalSeconds
        }
    }
}

function Test-GPUmatesAccessToken {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Expected,

        [AllowNull()]
        [string]$Presented
    )

    if ([string]::IsNullOrEmpty($Expected) -or [string]::IsNullOrEmpty($Presented)) {
        return $false
    }

    $Sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $ExpectedHash = $Sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($Expected))
        $PresentedHash = $Sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($Presented))
        [int]$Difference = 0
        for ($Index = 0; $Index -lt $ExpectedHash.Length; $Index++) {
            $Difference = $Difference -bor ($ExpectedHash[$Index] -bxor $PresentedHash[$Index])
        }
        return $Difference -eq 0
    }
    finally {
        $Sha256.Dispose()
    }
}

function Read-GPUmatesHttpRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Net.Sockets.NetworkStream]$Stream,

        [ValidateRange(1024, 65536)]
        [int]$MaximumHeaderBytes = 16384,

        # Only the dashboard opts in for its authenticated chat telemetry API.
        [switch]$AllowOptions
    )

    $Bytes = [Collections.Generic.List[byte]]::new()
    [int]$Matched = 0
    $Terminator = [byte[]](13, 10, 13, 10)

    while ($Bytes.Count -lt $MaximumHeaderBytes) {
        $Value = $Stream.ReadByte()
        if ($Value -lt 0) {
            break
        }

        $Byte = [byte]$Value
        $Bytes.Add($Byte)
        if ($Byte -eq $Terminator[$Matched]) {
            $Matched++
            if ($Matched -eq $Terminator.Length) {
                break
            }
        }
        else {
            $Matched = if ($Byte -eq $Terminator[0]) { 1 } else { 0 }
        }
    }

    if ($Matched -ne $Terminator.Length) {
        throw 'HTTP request headers were incomplete or too large.'
    }

    $HeaderText = [Text.Encoding]::ASCII.GetString($Bytes.ToArray())
    $Lines = @($HeaderText -split "\r\n")
    $RequestPattern = if ($AllowOptions) { '^(GET|HEAD|OPTIONS) ([^ ]+) HTTP/(1\.0|1\.1)$' } else { '^(GET|HEAD) ([^ ]+) HTTP/(1\.0|1\.1)$' }
    if ($Lines.Count -lt 1 -or $Lines[0] -cnotmatch $RequestPattern) {
        throw 'The HTTP request method or request line is not supported.'
    }

    $Method = $Matches[1]
    $Target = $Matches[2]
    if ($Target.Length -gt 2048 -or -not $Target.StartsWith('/')) {
        throw 'The HTTP request target is invalid.'
    }

    $Headers = @{}
    foreach ($Line in $Lines[1..($Lines.Count - 1)]) {
        if ([string]::IsNullOrEmpty($Line)) {
            continue
        }
        $ColonIndex = $Line.IndexOf(':')
        if ($ColonIndex -le 0) {
            throw 'A malformed HTTP header was received.'
        }
        $Name = $Line.Substring(0, $ColonIndex).Trim().ToLowerInvariant()
        $Value = $Line.Substring($ColonIndex + 1).Trim()
        if ($AllowOptions -and $Headers.ContainsKey($Name) -and
            $Name -in @('origin', 'access-control-request-method', 'access-control-request-headers')) {
            throw 'Duplicate CORS request headers are not supported.'
        }
        if (-not $Headers.ContainsKey($Name)) {
            $Headers[$Name] = $Value
        }
    }

    return [ordered]@{
        method  = $Method
        target  = $Target
        path    = ($Target -split '\?', 2)[0]
        headers = $Headers
    }
}

function Write-GPUmatesHttpResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Net.Sockets.NetworkStream]$Stream,

        [Parameter(Mandatory)]
        [int]$StatusCode,

        [Parameter(Mandatory)]
        [string]$ReasonPhrase,

        [Parameter(Mandatory)]
        [byte[]]$Body,

        [string]$ContentType = 'application/json; charset=utf-8',

        [hashtable]$AdditionalHeader = @{},

        [switch]$HeadOnly
    )

    $HeaderLines = @(
        "HTTP/1.1 $StatusCode $ReasonPhrase",
        "Date: $([DateTime]::UtcNow.ToString('R'))",
        'Server: GPUmates-Telemetry',
        "Content-Type: $ContentType",
        "Content-Length: $($Body.Length)",
        'X-Content-Type-Options: nosniff',
        'Referrer-Policy: no-referrer',
        'Cache-Control: no-store',
        'Connection: close'
    )
    foreach ($Name in $AdditionalHeader.Keys) {
        $HeaderLines += "${Name}: $($AdditionalHeader[$Name])"
    }
    $HeaderLines += '', ''

    $HeaderBytes = [Text.Encoding]::ASCII.GetBytes($HeaderLines -join "`r`n")
    $Stream.Write($HeaderBytes, 0, $HeaderBytes.Length)
    if (-not $HeadOnly -and $Body.Length -gt 0) {
        $Stream.Write($Body, 0, $Body.Length)
    }
    $Stream.Flush()
}

function ConvertTo-GPUmatesJsonBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$InputObject,

        [ValidateRange(2, 30)]
        [int]$Depth = 12
    )

    $Json = $InputObject | ConvertTo-Json -Depth $Depth -Compress
    return [Text.Encoding]::UTF8.GetBytes($Json)
}

function Assert-GPUmatesListenAddress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Net.IPAddress]$ListenIP
    )

    if ($ListenIP.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        throw 'ListenIP must be an IPv4 address.'
    }
    if ($ListenIP.Equals([Net.IPAddress]::Any) -or $ListenIP.Equals([Net.IPAddress]::Broadcast)) {
        throw 'ListenIP must be one explicit address, not a wildcard or broadcast address.'
    }

    if ($ListenIP.Equals([Net.IPAddress]::Loopback)) {
        return
    }

    $LocalIPv4 = @([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.OperationalStatus -eq [Net.NetworkInformation.OperationalStatus]::Up } |
        ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
        Where-Object { $_.Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork } |
        ForEach-Object { $_.Address.IPAddressToString })
    if ($ListenIP.IPAddressToString -notin $LocalIPv4) {
        throw "$($ListenIP.IPAddressToString) is not assigned to an active local network interface."
    }
}

Export-ModuleMember -Function @(
    'Assert-GPUmatesListenAddress',
    'ConvertFrom-GPUmatesNvidiaCsv',
    'ConvertTo-GPUmatesJsonBytes',
    'Get-GPUmatesGpuTelemetry',
    'Get-GPUmatesSystemTelemetry',
    'Get-GPUmatesTelemetrySnapshot',
    'Read-GPUmatesHttpRequest',
    'Resolve-GPUmatesNvidiaSmi',
    'Test-GPUmatesAccessToken',
    'Write-GPUmatesHttpResponse'
)
