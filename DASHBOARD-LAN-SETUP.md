# GPUmates LAN dashboard setup

This adds read-only GPU monitoring without changing llama.cpp's chat UI. PC1
collects the measurements and serves the dashboard; PC2 only runs a small
telemetry agent. No model is copied to PC2 by this feature.

If multiline PowerShell gives you trouble, use the copy-pasteable commands in
[DASHBOARD-ONE-LINE-COMMANDS.md](DASHBOARD-ONE-LINE-COMMANDS.md).

## Network surface

| Service | PC | Port | Allowed source |
| --- | --- | ---: | --- |
| Dashboard | PC1 `172.25.50.14` | TCP 8090 | Explicitly listed friend PCs |
| Telemetry agent | Worker GPU PCs | TCP 9835 | PC1 `172.25.50.14` only |
| llama.cpp RPC | Worker PCs | TCP 50052 | PC1 `172.25.50.14` only |

The telemetry agent reads `nvidia-smi` and Windows performance counters. It
does not change GPU settings, run models, accept shell commands, or provide
access to files. Both the firewall and an access token protect its read-only
HTTP endpoint.

Do not port-forward 8090, 9835, or 50052. The dashboard uses plain HTTP on the
trusted LAN, so keep the IP allowlist and access-token checks enabled.

## Secrets without PowerShell history

Use two different random secrets of at least 32 characters:

- the **agent key** is shared by PC1 and every telemetry agent;
- the **dashboard key** is shared only with people allowed to view the UI.

Generate both cryptographically random values on PC1, then place them in the
current PowerShell process:

```powershell
$Keys = & .\scripts\New-GPUmatesSecrets.ps1
$env:GPUMATES_AGENT_KEY = $Keys.AgentKey
$env:GPUMATES_DASHBOARD_KEY = $Keys.DashboardKey
```

Give only `$Keys.AgentKey` to the PC2 owner for their telemetry-agent window.
Give `$Keys.DashboardKey` only to people allowed to view the dashboard. Keep the
PC1 window open; its process environment disappears when it closes.

On PC2, paste the received agent key into a process environment variable
without putting it in PowerShell history:

```powershell
$Secret = Read-Host -AsSecureString 'Paste the agent key'
$env:GPUMATES_AGENT_KEY = [Net.NetworkCredential]::new('', $Secret).Password
Remove-Variable Secret
```

If PC1 is restarted and you restore the dashboard key from a password manager,
use the same hidden prompt pattern:

```powershell
$Secret = Read-Host -AsSecureString 'Paste the dashboard key'
$env:GPUMATES_DASHBOARD_KEY = [Net.NetworkCredential]::new('', $Secret).Password
Remove-Variable Secret
```

These values disappear when that PowerShell window closes. Do not reuse an
email, Windows, router, or llama.cpp API password.

## PC2: allow and start telemetry

The short friend-facing explanation and commands are also available in
[PC2-DASHBOARD-MONITORING.md](PC2-DASHBOARD-MONITORING.md).

A ready-to-copy PC2 package is at
`dist/GPUmates-telemetry-pc2-172.25.50.49.zip`; it contains only the monitoring
scripts and the short README.

Copy the updated `scripts` directory to PC2. Open PowerShell **as
Administrator** in the GPUmates directory and create the coordinator-only
firewall rule:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
& .\scripts\Configure-MetricsFirewall.ps1 `
  -CoordinatorIP 172.25.50.14 `
  -AgentIP 172.25.50.49
```

Close the administrator window. In a normal PowerShell window, set the agent
key as shown above, then start the read-only agent:

```powershell
& .\scripts\Start-TelemetryAgent.ps1 `
  -ListenIP 172.25.50.49 `
  -CoordinatorIP 172.25.50.14 `
  -Port 9835
```

Leave that window running. PC2's user can press `Ctrl+C` at any time to stop
monitoring; this does not stop the llama.cpp RPC worker.

## PC1: allow dashboard viewers

Open PowerShell **as Administrator** in the GPUmates directory. The example
below permits only PC2 to open the dashboard:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
& .\scripts\Configure-DashboardFirewall.ps1 `
  -CoordinatorIP 172.25.50.14 `
  -ClientIP 172.25.50.49
```

To permit several fixed LAN addresses, pass a comma-separated array:

```powershell
& .\scripts\Configure-DashboardFirewall.ps1 `
  -CoordinatorIP 172.25.50.14 `
  -ClientIP 172.25.50.49,172.25.50.60
```

The dashboard also enforces its own client-IP list because Windows firewall
rules are additive. Keep the complete viewer list under
`dashboard.allowedClientIps` in `config/telemetry-nodes.json`; add the same new
address there whenever you recreate the firewall rule. PC1's own
`172.25.50.14` entry should remain in the list.

PC1 is measured directly by the dashboard, so it does not need a separate
telemetry-agent window. In a normal PC1 PowerShell window, set both process
environment keys and start the dashboard:

```powershell
& .\scripts\Start-GPUmatesDashboard.ps1 `
  -ListenIP 172.25.50.14 `
  -Port 8090 `
  -NodeConfig .\config\telemetry-nodes.json
```

PC1 and an allowed friend PC both open `http://172.25.50.14:8090` and enter the
dashboard key when prompted.

GPU monitoring works independently of model metrics. To show llama.cpp prompt
and generation throughput too, restart the model router later with the updated
`Start-ModelRouter.ps1`; it now enables metrics for each loaded child model.

The dashboard deliberately shows `Chat: PC1 only` while llama.cpp is bound to
loopback. If you later expose the chat UI safely on `172.25.50.14:8080` with an
API key and the existing coordinator firewall, add this optional field inside
the `llama` object in `config/telemetry-nodes.json`:

```json
"publicUrl": "http://172.25.50.14:8080"
```

## Verify the restrictions

While the services are running, run this on PC1 from a PowerShell process that
has `GPUMATES_DASHBOARD_KEY` set:

```powershell
& .\scripts\Test-DashboardSecurity.ps1 `
  -Role Coordinator `
  -ListenIP 172.25.50.14 `
  -ClientIP 172.25.50.49
```

Run this on PC2 from a process that has `GPUMATES_AGENT_KEY` set:

```powershell
& .\scripts\Test-DashboardSecurity.ps1 `
  -Role Agent `
  -ListenIP 172.25.50.49 `
  -CoordinatorIP 172.25.50.14
```

The checks verify the exact firewall scope and anonymous-request rejection.
From a worker, the authorized probe is intentionally skipped because the
agent also refuses every source IP except PC1; PC1's dashboard performs the
real authenticated probe. Use `-SkipHttp` to inspect only local address and
firewall configuration while a service is stopped.

## Stop sharing or remove rules

Press `Ctrl+C` in the agent/dashboard windows. From an administrator window,
remove only the rules created for these two services:

```powershell
& .\scripts\Configure-MetricsFirewall.ps1 -Remove
& .\scripts\Configure-DashboardFirewall.ps1 -Remove
```

If an IP changes, recreate the corresponding rule with the new fixed/DHCP-
reserved address. Never widen `RemoteAddress` to `Any` or `LocalSubnet`.
