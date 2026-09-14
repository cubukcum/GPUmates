# PC2: GPU dashboard monitoring

This optional agent lets PC1 display PC2's GPU and system utilization. It is
read-only: it calls NVIDIA's installed `nvidia-smi` and Windows counters. It
cannot start or stop models, change GPU settings, browse files, or run commands.

Safety boundaries:

- it listens only on PC2's fixed LAN address at TCP `9835`;
- Windows Firewall accepts that port only from PC1 `172.25.50.14`;
- every metrics request also needs the shared agent key;
- nothing should be port-forwarded to the Internet.

One-time administrator command on PC2:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
& .\scripts\Configure-MetricsFirewall.ps1 `
  -CoordinatorIP 172.25.50.14 `
  -AgentIP 172.25.50.49
```

Normal start on PC2—paste the agent key supplied by PC1 when prompted:

```powershell
$Secret = Read-Host -AsSecureString 'Paste the GPUmates agent key'
$env:GPUMATES_AGENT_KEY = [Net.NetworkCredential]::new('', $Secret).Password
Remove-Variable Secret

& .\scripts\Start-TelemetryAgent.ps1 `
  -ListenIP 172.25.50.49 `
  -CoordinatorIP 172.25.50.14 `
  -Port 9835
```

Leave the window open. Press `Ctrl+C` to stop monitoring; the llama.cpp RPC
worker is unaffected. To remove the firewall rule later, run as Administrator:

```powershell
& .\scripts\Configure-MetricsFirewall.ps1 -Remove
```
