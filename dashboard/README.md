# GPUmates dashboard frontend

This is the read-only browser UI for the Windows llama.cpp cluster. The normal
LAN deployment is the standalone build under `static/`, served by
`scripts/Start-GPUmatesDashboard.ps1`; it is not an Internet-hosted site.

## Source layout

- `ui/Dashboard.tsx`: shared live dashboard and access-key screen
- `app/`: Sites-compatible development preview
- `local/`: standalone LAN entry point
- `static/`: compiled files consumed by the PowerShell dashboard host

## Development

Node.js 22.13 or later and pnpm 11 are required only when changing the UI.
Neither is required to run the already-built LAN dashboard.

```powershell
pnpm install
pnpm run dev
pnpm run build:local
pnpm test
```

The browser requests only same-origin `/api/v1/cluster` and sends the access
key in `X-GPUmates-Key`. It never contacts a worker telemetry port directly.
Operational setup is documented in `..\DASHBOARD-LAN-SETUP.md`.
