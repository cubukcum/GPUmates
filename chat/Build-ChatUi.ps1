[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ServerExe = Join-Path $ProjectRoot 'runtime\llama-server.exe'
$OutputRoot = Join-Path $PSScriptRoot 'static'
$BuildRoot = Join-Path $ProjectRoot ('results\chat-build-' + [Guid]::NewGuid().ToString('N'))
$Utf8 = [Text.UTF8Encoding]::new($false)

function Get-NativeAsset {
    param([string]$Name)
    $Request = [Net.HttpWebRequest]::Create("http://127.0.0.1:$BuildPort/$Name")
    $Request.AutomaticDecompression = [Net.DecompressionMethods]::GZip
    $Request.Proxy = $null
    $Request.Timeout = 10000
    $Response = $null
    $Buffer = [IO.MemoryStream]::new()
    try {
        $Response = $Request.GetResponse()
        $Response.GetResponseStream().CopyTo($Buffer)
        return ,$Buffer.ToArray()
    }
    finally {
        $Buffer.Dispose()
        if ($Response) { $Response.Dispose() }
    }
}

# Export the UI from the installed, pinned binary. No model is loaded and no
# external download, Node runtime, or upstream source build is required.
New-Item -ItemType Directory -Force -Path (Join-Path $BuildRoot 'models') | Out-Null
$VersionProcess = Start-Process -FilePath $ServerExe -ArgumentList '--version' -WindowStyle Hidden -Wait -PassThru `
    -RedirectStandardOutput (Join-Path $BuildRoot 'version.out') -RedirectStandardError (Join-Path $BuildRoot 'version.err')
$Version = [IO.File]::ReadAllText((Join-Path $BuildRoot 'version.out')) + [IO.File]::ReadAllText((Join-Path $BuildRoot 'version.err'))
if ($Version -notmatch 'build 10488, commit 9d77fa172') {
    throw 'The chat customization is pinned to llama.cpp b10488 (9d77fa172). Review it before upgrading.'
}
$WidgetJs = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'gpu-bar.js'))
$WidgetCss = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'gpu-bar.css'))
$Probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$Probe.Start()
$BuildPort = $Probe.LocalEndpoint.Port
$Probe.Stop()
$Server = $null
try {
    $Server = Start-Process -FilePath $ServerExe -WindowStyle Hidden -PassThru `
        -ArgumentList @('--models-dir', ('"' + (Join-Path $BuildRoot 'models') + '"'), '--no-models-autoload', '--host', '127.0.0.1', '--port', $BuildPort, '--ui') `
        -RedirectStandardOutput (Join-Path $BuildRoot 'stdout.log') `
        -RedirectStandardError (Join-Path $BuildRoot 'stderr.log')
    $Index = $null
    $Deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        if ($Server.HasExited) { throw "Native UI export server exited. See $BuildRoot\stderr.log" }
        try { $Index = $Utf8.GetString((Get-NativeAsset '')) } catch { Start-Sleep -Milliseconds 200 }
    } while ($null -eq $Index -and [DateTime]::UtcNow -lt $Deadline)
    if ($null -eq $Index) { throw 'Native chat UI did not start within 15 seconds.' }
    $ServiceWorker = $Utf8.GetString((Get-NativeAsset 'sw.js'))
    $AssetNames = @([regex]::Matches($ServiceWorker, 'url:"([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -ne './' })
    $Workbox = [regex]::Match($ServiceWorker, 'define\(\["\./(workbox-[^"]+)"\]')
    if ($AssetNames.Count -lt 3 -or -not $Workbox.Success -or $Index -notmatch '_app/immutable/bundle\.') {
        throw 'The embedded frontend layout changed. Review the export logic before building.'
    }
    $AssetNames += $Workbox.Groups[1].Value + '.js'
    $AssetNames += 'build.json'
    $StagingRoot = Join-Path $BuildRoot 'static'
    New-Item -ItemType Directory -Force -Path $StagingRoot | Out-Null
    foreach ($Name in ($AssetNames | Select-Object -Unique)) {
        if ($Name -notmatch '^[A-Za-z0-9_./-]+$' -or $Name.Contains('..') -or $Name.StartsWith('/')) {
            throw "Unexpected embedded asset path: $Name"
        }
        $Destination = Join-Path $StagingRoot $Name
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
        [IO.File]::WriteAllBytes($Destination, (Get-NativeAsset $Name))
    }

    # Leave native hashed assets untouched. All custom CSS/JS lives in index,
    # which is a public frontend route even when llama API authentication is on.
    $LayoutCss = @'
html { --gpumates-chat-height: calc(100dvh - 44px); }
body { padding-top: 44px !important; }
.chat-screen { min-height: calc(var(--gpumates-chat-height) - 1rem) !important; }
body > div[style="display: contents"] > .flex > aside { top: 52px !important; }
/* Native history/search and MCP controls use viewport-fixed positions. */
body > div[style="display: contents"] .fixed.top-0.z-10.left-0.right-0.p-2 { top: 44px !important; }
body > div[style="display: contents"] .fixed.top-4\.5.right-4.z-50.md\:hidden { top: calc(44px + 1.125rem) !important; }
body > div[style="display: contents"] .sticky.top-0.z-10.mt-4.mb-2 { top: 44px !important; }
@media (max-width: 767px) {
  body > div[style="display: contents"] > .flex > aside.is-expanded { height: calc(100dvh - 60px) !important; max-height: calc(100dvh - 60px) !important; }
}
@media (min-width: 768px) {
  body > div[style="display: contents"] > .flex > aside { height: calc(var(--gpumates-chat-height) - 1.125rem) !important; }
}
'@
    $HeadAddition = '<meta name="gpumates-dashboard-url" content="__GPUMATES_DASHBOARD_URL__">' + "`n<style>$LayoutCss</style>`n"
    $BodyAddition = '<template id="gpumates-gpu-bar-styles"><style>' + $WidgetCss + '</style></template>' + "`n<script>" + $WidgetJs + "</script>`n"
    $Index = $Index.Replace('</head>', $HeadAddition + '</head>').Replace('</body>', $BodyAddition + '</body>')
    [IO.File]::WriteAllText((Join-Path $StagingRoot 'index.html'), $Index, $Utf8)
    # Each prepared index includes its coordinator address. Its revision must
    # change when that address or this widget changes, so old PWA caches expire.
    $ServiceWorker = [regex]::Replace($ServiceWorker, '(url:"\./",revision:")[^"]+("})', '${1}__GPUMATES_INDEX_REVISION__${2}')
    $ServiceWorker = 'self.addEventListener("install",()=>self.skipWaiting());self.addEventListener("activate",event=>event.waitUntil(self.clients.claim()));' + $ServiceWorker
    [IO.File]::WriteAllText((Join-Path $StagingRoot 'sw.js'), $ServiceWorker, $Utf8)
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'THIRD-PARTY-NOTICES.txt') -Destination $StagingRoot
    $Files = @(Get-ChildItem -LiteralPath $StagingRoot -Recurse -File | ForEach-Object {
        [ordered]@{ path = $_.FullName.Substring($StagingRoot.Length + 1).Replace('\', '/'); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    $Manifest = [ordered]@{
        schemaVersion = 1
        llamaBuild = 10488
        llamaCommit = '9d77fa172'
        sources = @{
            'gpu-bar.js' = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'gpu-bar.js') -Algorithm SHA256).Hash.ToLowerInvariant()
            'gpu-bar.css' = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'gpu-bar.css') -Algorithm SHA256).Hash.ToLowerInvariant()
            'Build-ChatUi.ps1' = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        files = $Files
    }
    [IO.File]::WriteAllText((Join-Path $StagingRoot 'gpumates-build.json'), ($Manifest | ConvertTo-Json -Depth 5), $Utf8)
    New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
    Copy-Item -Path (Join-Path $StagingRoot '*') -Destination $OutputRoot -Recurse -Force
    Write-Host "Built GPUmates chat UI ($($Files.Count) files) in $OutputRoot"
}
finally {
    if ($Server -and -not $Server.HasExited) { $Server.Kill(); $Server.WaitForExit() }
    # Keep the isolated export logs under ignored results/ for diagnostics.
}
