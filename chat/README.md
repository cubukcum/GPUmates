# GPU bar in llama.cpp chat

The chat uses the unmodified frontend assets embedded in llama.cpp **b10488,
commit 9d77fa172**. GPUmates adds one compact, expandable bar to its index page.
The model engine, chat history, model picker, and streaming UI remain upstream.

`gpu-bar.js` and `gpu-bar.css` are the maintained widget sources. The bar reuses
the dashboard's authenticated `/api/v1/cluster` endpoint; it never connects to
workers or receives the Agent or Llama API key. Each tab stores its Dashboard
key in session storage, and Disconnect removes it. It displays whole-device
utilization, which can include applications other than llama.cpp.

## Build

From the repository root, run:

```powershell
.\chat\Build-ChatUi.ps1
```

The build briefly starts the pinned binary on a free loopback port with an
empty model directory, exports its static assets, and stops that process.
No models are loaded and no network download is needed. The checked-in
`static/` bundle is what coordinator installers ship. Its manifest records
upstream version and source/asset hashes. Rebuild after editing either widget
source. Review the export/layout integration before upgrading llama.cpp.
Both installer build scripts run `chat\Test-ChatUiBuild.ps1`, which verifies
the recorded source and asset hashes and rejects stale or incomplete bundles.

The router prepares a separate writable UI directory at launch, inserting the
coordinator's dashboard address and updating the service-worker index revision.
Installed templates under Program Files are never edited by the ordinary user.
Native asset paths stay unchanged so the llama server's public-asset allowlist
continues to work when its API key is enabled. Custom scripts and styles are
inline in the public index rather than added as new authenticated asset routes.
Existing chat tabs may need a second manual reload after the service worker
updates. Save any draft or finish the current response first; the widget never
forces a page reload.

## Accepted design and decisions

- Compact 44px bar with utilization and VRAM per GPU; expandable temperature,
  power, freshness, and connection controls.
- Reuse existing two-second telemetry caching. Missing readings and offline
  workers do not become zero activity. Monitoring failures leave chat usable.
- Keep the separate dashboard key and exact viewer-IP access rules. The API
  permits narrowly scoped CORS from the coordinator's chat origins only.
- Use a small standalone widget rather than maintaining a fork of the whole
  Svelte application. Pin the source version and verify the native layout when
  upgrading. Administration stays local and worker storage settings are untouched.
- Assume the existing small trusted Windows LAN, low polling overhead, and
  owner-maintained coordinator installation. No telemetry persistence is added.

Upstream llama.cpp and its web UI are MIT licensed. The existing installer
third-party notices apply; see `THIRD-PARTY-NOTICES.txt` in this directory.

## Verification

```powershell
node --test chat/tests/gpu-bar.test.mjs
powershell -NoProfile -File scripts/Test-PrepareGPUmatesChatUi.ps1
powershell -NoProfile -File scripts/Test-ChatTelemetryCors.ps1
powershell -NoProfile -File chat/Test-ChatUiBuild.ps1
```

The integration was also checked in the pinned chat UI with API authentication
enabled, real local telemetry, and a simulated two-GPU worker. Browser checks
covered dashboard-key connection, all three GPU readings, expanded details,
worker-offline status, disconnect, and mobile navigation/search at 390px width.
No model was loaded for these UI checks.
