[CmdletBinding()]
param(
    [Parameter(Mandatory)][System.Net.IPAddress]$CoordinatorIP,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9 ._-]{1,64}$')][string]$NodeName,
    [Parameter(Mandatory)][string]$InstallRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Coordinator installation must run with Administrator privileges.'
}
if ($CoordinatorIP.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
    throw 'CoordinatorIP must be one IPv4 address.'
}
$CoordinatorAddress = $CoordinatorIP.IPAddressToString
$LocalIPv4 = @(
    [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object OperationalStatus -eq ([Net.NetworkInformation.OperationalStatus]::Up) |
        ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
        Where-Object { $_.Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork } |
        ForEach-Object { $_.Address.IPAddressToString }
)
if ($CoordinatorAddress -notin $LocalIPv4) {
    throw "Coordinator IP $CoordinatorAddress is not assigned to this PC."
}

$ResolvedInstallRoot = (Resolve-Path -LiteralPath $InstallRoot -ErrorAction Stop).Path
$ConfigRoot = Join-Path $ResolvedInstallRoot 'config'
$NodeConfigPath = Join-Path $ConfigRoot 'telemetry-nodes.json'
$ModelPresetPath = Join-Path $ConfigRoot 'gpumates-models.ini'
New-Item -ItemType Directory -Path $ConfigRoot -Force | Out-Null
$Utf8NoBom = [Text.UTF8Encoding]::new($false)

$NodeConfiguration = [pscustomobject][ordered]@{
    schemaVersion = 1
    dashboard     = [pscustomobject][ordered]@{
        allowedClientIps = @($CoordinatorAddress)
    }
    nodes         = @(
        [pscustomobject][ordered]@{
            name      = $NodeName.Trim()
            host      = '127.0.0.1'
            displayIp = $CoordinatorAddress
            local     = $true
            port      = 9835
            role      = 'coordinator'
        }
    )
    llama         = [pscustomobject][ordered]@{
        enabled = $true
        baseUrl = 'http://127.0.0.1:8080'
    }
}
$NodeJson = $NodeConfiguration | ConvertTo-Json -Depth 12
[IO.File]::WriteAllText(
    $NodeConfigPath,
    $NodeJson + [Environment]::NewLine,
    $Utf8NoBom
)

if (Test-Path -LiteralPath $ModelPresetPath -PathType Leaf) {
    $Lines = @(Get-Content -LiteralPath $ModelPresetPath)
    $Preamble = [Collections.Generic.List[string]]::new()
    $Sections = [Collections.Generic.List[object]]::new()
    $Current = $null
    foreach ($Line in $Lines) {
        if ($Line -match '^\s*\[([^]]+)\]\s*$') {
            if ($null -ne $Current) { $Sections.Add($Current) }
            $Current = [Collections.Generic.List[string]]::new()
            $Current.Add($Line)
        }
        elseif ($null -eq $Current) {
            $Preamble.Add($Line)
        }
        else {
            $Current.Add($Line)
        }
    }
    if ($null -ne $Current) { $Sections.Add($Current) }

    $KeptSections = [Collections.Generic.List[object]]::new()
    foreach ($Section in $Sections) {
        $ModelPath = $null
        foreach ($Line in $Section) {
            if ($Line -match '^\s*model\s*=\s*(.+?)\s*$') {
                $ModelPath = $Matches[1].Trim().Trim('"').Trim("'")
                break
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($ModelPath) -and (Test-Path -LiteralPath $ModelPath -PathType Leaf)) {
            $KeptSections.Add($Section)
        }
    }

    $OutputLines = [Collections.Generic.List[string]]::new()
    foreach ($Line in $Preamble) { $OutputLines.Add($Line) }
    if (-not ($OutputLines | Where-Object { $_ -match '^\s*version\s*=' })) {
        $OutputLines.Insert(0, 'version = 1')
    }
    foreach ($Section in $KeptSections) {
        if ($OutputLines.Count -gt 0 -and $OutputLines[$OutputLines.Count - 1] -ne '') { $OutputLines.Add('') }
        foreach ($Line in $Section) { $OutputLines.Add($Line) }
    }
    if ($KeptSections.Count -eq 0) {
        $OutputLines.Add('')
        $OutputLines.Add('# Add [friendly-name] sections with absolute GGUF paths from the Control Center guide.')
    }
    [IO.File]::WriteAllText(
        $ModelPresetPath,
        (($OutputLines -join [Environment]::NewLine) + [Environment]::NewLine),
        $Utf8NoBom
    )
}

Write-Host "GPUmates Coordinator seed configuration prepared for $($NodeName.Trim()) at $CoordinatorAddress."
