[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DashboardBaseUrl,
    [ValidateRange(1024, 65535)][int]$DashboardPort = 8090,
    [string]$TemplateRoot,
    [string]$OutputRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $PSBoundParameters.ContainsKey('DashboardPort')) {
    Import-Module (Join-Path $PSScriptRoot 'GPUmates.Network.psm1') -Force
    $NetworkConfiguration = Get-GPUmatesNetworkConfiguration -ProjectRoot (Split-Path -Parent $PSScriptRoot)
    $DashboardPort = $NetworkConfiguration.dashboardPort
}

# Accept only the selected dashboard listener, never arbitrary external content.
$UrlText = $DashboardBaseUrl.Trim()
if ($UrlText -notmatch ('^http://(localhost|(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}):' + $DashboardPort + '/?$')) {
    throw "DashboardBaseUrl must use localhost or an exact private/loopback IPv4 address on configured HTTP port $DashboardPort."
}
$DashboardUri = [uri]$UrlText
if ($DashboardUri.Host -ne 'localhost') {
    $Address = $null
    if (-not [Net.IPAddress]::TryParse($DashboardUri.Host, [ref]$Address) -or
        $Address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        throw 'DashboardBaseUrl must contain a valid IPv4 address.'
    }
    $Octets = $Address.GetAddressBytes()
    $PrivateOrLoopback = $Octets[0] -eq 10 -or $Octets[0] -eq 127 -or
        ($Octets[0] -eq 172 -and $Octets[1] -ge 16 -and $Octets[1] -le 31) -or
        ($Octets[0] -eq 192 -and $Octets[1] -eq 168)
    if (-not $PrivateOrLoopback) { throw 'DashboardBaseUrl must use a private or loopback IPv4 address.' }
}
$NormalizedDashboardUrl = $DashboardUri.GetLeftPart([UriPartial]::Authority)

if ([string]::IsNullOrWhiteSpace($TemplateRoot)) {
    $TemplateRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'chat\static'
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $env:LOCALAPPDATA 'GPUmates\Coordinator\ChatUi'
}
$SourceRoot = (Resolve-Path -LiteralPath $TemplateRoot -ErrorAction Stop).Path.TrimEnd('\', '/')
$DestinationRoot = [IO.Path]::GetFullPath($OutputRoot).TrimEnd('\', '/')
$SourcePrefix = $SourceRoot + [IO.Path]::DirectorySeparatorChar
$DestinationPrefix = $DestinationRoot + [IO.Path]::DirectorySeparatorChar
if ($DestinationRoot -eq [IO.Path]::GetPathRoot($DestinationRoot).TrimEnd('\', '/') -or
    $DestinationRoot.Equals($SourceRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $DestinationPrefix.StartsWith($SourcePrefix, [StringComparison]::OrdinalIgnoreCase) -or
    $SourcePrefix.StartsWith($DestinationPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Chat UI output must be a separate dedicated directory, outside the template directory.'
}

function Assert-OrdinaryPath {
    param([Parameter(Mandatory)][string]$Path)
    $CurrentPath = $Path
    while (-not [string]::IsNullOrWhiteSpace($CurrentPath)) {
        if (Test-Path -LiteralPath $CurrentPath) {
            $Item = Get-Item -LiteralPath $CurrentPath -Force
            if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Chat UI paths cannot use a symbolic link or junction: $CurrentPath"
            }
        }
        $CurrentPath = Split-Path -Parent $CurrentPath
    }
}

Assert-OrdinaryPath -Path $SourceRoot
Assert-OrdinaryPath -Path $DestinationRoot
$IndexSource = Join-Path $SourceRoot 'index.html'
$IndexTemplate = [IO.File]::ReadAllText($IndexSource)
if (-not $IndexTemplate.Contains('__GPUMATES_DASHBOARD_URL__')) {
    throw 'The bundled chat index is missing its dashboard placeholder. Rebuild the chat UI.'
}
$SourceItems = @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -Force)
foreach ($Item in $SourceItems) {
    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Chat UI templates cannot contain symbolic links or junctions: $($Item.FullName)"
    }
}
New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
foreach ($Item in $SourceItems) {
    if ($Item.PSIsContainer) { continue }
    $RelativePath = $Item.FullName.Substring($SourcePrefix.Length)
    if ($RelativePath -in @('index.html', 'sw.js')) { continue }
    $TargetPath = [IO.Path]::GetFullPath((Join-Path $DestinationRoot $RelativePath))
    if (-not $TargetPath.StartsWith($DestinationPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'A chat asset resolved outside its output directory.'
    }
    Assert-OrdinaryPath -Path $TargetPath
    $Existing = if (Test-Path -LiteralPath $TargetPath -PathType Leaf) { Get-Item -LiteralPath $TargetPath } else { $null }
    if ($null -eq $Existing -or $Existing.Length -ne $Item.Length -or $Existing.LastWriteTimeUtc -ne $Item.LastWriteTimeUtc) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $TargetPath) -Force | Out-Null
        Copy-Item -LiteralPath $Item.FullName -Destination $TargetPath -Force
        [IO.File]::SetLastWriteTimeUtc($TargetPath, $Item.LastWriteTimeUtc)
    }
}

$IndexPath = Join-Path $DestinationRoot 'index.html'
Assert-OrdinaryPath -Path $IndexPath
$GeneratedIndex = $IndexTemplate.Replace('__GPUMATES_DASHBOARD_URL__', [Net.WebUtility]::HtmlEncode($NormalizedDashboardUrl))
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($IndexPath, $GeneratedIndex, $Utf8NoBom)

# The configured index needs its own cache revision when PC1's address changes.
$ServiceWorkerSource = Join-Path $SourceRoot 'sw.js'
if (Test-Path -LiteralPath $ServiceWorkerSource -PathType Leaf) {
    $ServiceWorkerTemplate = [IO.File]::ReadAllText($ServiceWorkerSource)
    if (-not $ServiceWorkerTemplate.Contains('__GPUMATES_INDEX_REVISION__')) {
        throw 'The bundled chat service worker is missing its index revision placeholder. Rebuild the chat UI.'
    }
    $IndexHash = (Get-FileHash -LiteralPath $IndexPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $ServiceWorkerPath = Join-Path $DestinationRoot 'sw.js'
    Assert-OrdinaryPath -Path $ServiceWorkerPath
    [IO.File]::WriteAllText($ServiceWorkerPath, $ServiceWorkerTemplate.Replace('__GPUMATES_INDEX_REVISION__', $IndexHash), $Utf8NoBom)
}

Write-Output $DestinationRoot
