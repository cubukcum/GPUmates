# GPUmates dashboard: one-line PowerShell commands

Run every command from the GPUmates folder that contains `scripts`. Each code
block below is exactly one PowerShell line; do not type the list number.

## 1. PC1 — create the two keys in a normal PowerShell window

Keep this window open. Send only the displayed `AgentKey` to the PC2 owner. Use
the displayed `DashboardKey` when a browser asks for dashboard access.

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force; $Keys = & .\scripts\New-GPUmatesSecrets.ps1; $env:GPUMATES_AGENT_KEY = $Keys.AgentKey; $env:GPUMATES_DASHBOARD_KEY = $Keys.DashboardKey; $Keys | Format-List
```

## 2. PC2 — create the narrow firewall rule as Administrator

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force; & .\scripts\Configure-MetricsFirewall.ps1 -CoordinatorIP 172.25.50.14 -AgentIP 172.25.50.49
```

## 3. PC2 — start monitoring in a normal PowerShell window

Paste the `AgentKey` from PC1 into the hidden prompt. Leave the window open.

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force; $Secret = Read-Host -AsSecureString 'Paste the GPUmates AgentKey'; $env:GPUMATES_AGENT_KEY = [Net.NetworkCredential]::new('', $Secret).Password; Remove-Variable Secret; & .\scripts\Start-TelemetryAgent.ps1 -ListenIP 172.25.50.49 -CoordinatorIP 172.25.50.14 -Port 9835
```

## 4. PC1 — allow PC2 to view the dashboard, as Administrator

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force; & .\scripts\Configure-DashboardFirewall.ps1 -CoordinatorIP 172.25.50.14 -ClientIP 172.25.50.49
```

## 5. PC1 — start the dashboard in the same normal window as step 1

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force; & .\scripts\Start-GPUmatesDashboard.ps1 -ListenIP 172.25.50.14 -Port 8090 -NodeConfig .\config\telemetry-nodes.json
```

Open `http://172.25.50.14:8090` on either PC and enter the `DashboardKey`.
Press `Ctrl+C` in the PC1 dashboard or PC2 telemetry window to stop it.
