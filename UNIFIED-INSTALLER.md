# GPUmates unified Windows installer

`GPUmates-Setup-0.3.4.exe` is the recommended offline installer for every
Windows 11 GPU computer in the cluster. Setup asks for exactly one role:

| Role | Install it on | Purpose |
| --- | --- | --- |
| Main PC / Coordinator | PC1 only | Stores GGUF models, uses PC1's GPU, controls workers, inference, sharing, and the dashboard |
| GPU Worker | PC2 and every additional NVIDIA GPU PC | Contributes its GPU over RPC and sends read-only telemetry to PC1 |

Do not choose both roles on one computer. PC1 already uses its GPU directly.
A browser-only client installs nothing.

## Before installation

- Use Windows 11 x64, a current NVIDIA driver with working `nvidia-smi`, and
  the Microsoft Visual C++ v14 x64 runtime.
- Give PC1 and all workers unique DHCP-reserved or static private IPv4
  addresses on a trusted LAN.
- Close existing GPUmates, llama-server, RPC-worker, and telemetry windows.
- Keep the EXE beside its `.sha256` file and verify it after copying. Version
  0.3.4 is not Authenticode-signed, so SmartScreen may show **Unknown
  publisher**.
- If either older standalone GPUmates Coordinator or Worker package is
  installed, uninstall it first. Unified Setup deliberately blocks mixed
  legacy/unified installations because their uninstallers and firewall rules
  overlap.

## Install PC1

1. Run `GPUmates-Setup-0.3.4.exe`, approve UAC, and choose **Main PC /
   Coordinator**.
2. Confirm PC1's name and its reserved private IPv4 address.
3. Choose the chat/API, dashboard, and Control Center TCP ports. The defaults
   are 8080, 8090, and 8091. Use three different numbers from 1024 to 65535.
   Setup checks that the ports are free; if one is occupied, go back to
   **Main PC TCP ports** and choose another number or close the app using it.
4. Leave **Open GPUmates Coordinator now** selected.
5. In the local Control Center, generate and save the Agent, Dashboard, and
   Llama API keys. Keep a separate secure copy.
6. Add each worker by name and IP, select the workers to use, start the router
   and dashboard, then load one model from **Model library**. To register a new
   PC1-local GGUF, stop the router and use **Add GGUF model** in that library.

The Control Center is opened from **Start menu -> GPUmates Coordinator** at
`http://127.0.0.1:CONTROL-PORT/` (8091 by default). Always use the shortcut because the launcher supplies
the per-session administration token. Setup does not include GGUF files.

## Install PC2 and later workers

1. Copy the same `GPUmates-Setup-0.3.4.exe` and checksum sidecar to the worker.
2. Run Setup, approve UAC, and choose **GPU Worker**.
3. Enter a unique worker name, PC1's private IPv4, and this worker's detected
   private IPv4. Set **Main PC dashboard port** to the dashboard port chosen
   on PC1 (8090 by default); the worker's dashboard shortcut uses it.
4. Leave **Keep model tensor cache on this PC** selected for faster reloads on
   a trusted worker. Clear it to disable future caching. To erase tensor files
   already stored by an earlier installation, use **GPUmates Worker Cache
   Settings > Clear cache** after Setup.
5. Leave **Start GPUmates Worker now** selected.
6. On the first telemetry start, paste the same AgentKey saved by PC1. It is
   protected for that Windows account with DPAPI and associated with PC1's IP.
   Changing that IP prompts for the new Coordinator's AgentKey. A key saved by
   version 0.3.3 or earlier also prompts once after upgrading.

The worker creates inbound TCP 50052 and 9835 rules restricted to PC1's exact
IP. Its two visible PowerShell windows must stay open. After a reboot, use
**Start menu -> GPUmates Worker -> Start GPUmates Worker**.

The first model load still transfers this worker's tensor share over the LAN.
With caching enabled, unloading frees VRAM while the tensor files remain under
`%LOCALAPPDATA%\GPUmates\Worker\TensorCache\b10488\rpc`, so later loads can read them from the worker's
SSD. Use **GPUmates Worker Cache Settings** on the worker to enable, disable,
inspect, or clear the cache. A worker restart is required after changing the
enabled setting.

## Let other PCs use inference and the dashboard

Browser clients do not install GPUmates. In PC1's Control Center, add every
client's exact private IP under **Sharing** and apply the firewall change:

- Chat and model UI: `http://PC1-IP:ROUTER-PORT` with the Llama API key (8080 by default).
- Read-only node dashboard: `http://PC1-IP:DASHBOARD-PORT` with the DashboardKey (8090 by default).
- PC1 administration: `http://127.0.0.1:CONTROL-PORT` on PC1 only (8091 by default).

Use the URLs shown in the Control Center. Applying **Sharing** creates Windows
Firewall rules for the selected chat and dashboard ports, restricted to the
exact private client IPs you allow. The Control Center stays local to PC1.
Enable LAN chat sharing and start the relevant service for its LAN URL to work.

RPC online and telemetry online are separate signals. A worker must have RPC
TCP 50052 online to contribute to inference. Telemetry TCP 9835 controls its
dashboard card.

## Upgrade, change role, and uninstall

Version 0.3.4 fixes a worker retaining the previous group's AgentKey after
changing its Coordinator IP. Keys are now associated with the configured
Coordinator IP; a different IP or an older saved key with no IP association
requires entry again on the next telemetry start. Upgrades on the same
Coordinator reuse keys saved by version 0.3.4 or later.
Version 0.3.4 also fixes the **Forget saved AgentKey** shortcut failing to
convert its `Confirm` argument in Windows PowerShell.

To recover an existing worker immediately, stop both worker windows with
`Ctrl+C`, open **Start menu -> GPUmates Worker -> Forget saved AgentKey**, then
choose **Start GPUmates Worker** and enter the new Coordinator's **AgentKey**.
This is separate from the DashboardKey and Llama API key. If the Coordinator
is replaced at the same IP or its AgentKey is rotated, use the same **Forget
saved AgentKey** steps. Register the worker's name and current IP on the new
Coordinator under **GPU nodes -> Add worker**; worker installation does not
register it remotely. See [worker troubleshooting](WORKER-INSTALLER.md#change-coordinator-or-replace-a-saved-agentkey).

On version 0.3.3, if **Forget saved AgentKey** reports a `Confirm` argument
error, run this in the PowerShell window left open by that shortcut, then
restart the worker. Adjust the path if you chose a different installation folder:

```powershell
& 'C:\Program Files\GPUmates\Worker\scripts\Clear-WorkerAgentKey.ps1'
```

Version 0.3.3 adds selectable Coordinator ports with conflict checks during Setup.
The launcher, service URLs, and LAN sharing firewall rules use the saved ports;
workers can also select PC1's dashboard port for their shortcut. After changing
ports on PC1, apply **Sharing** again to replace the previous firewall rules.

Version 0.3.2 fixes the Control Center status error when no models are registered,
including on a fresh coordinator installation or after removing the last model.
If an earlier unified installation shows `PresetModels` / `empty array`, close GPUmates
(or restart Windows), run 0.3.2 with the same Coordinator role and install folder,
then open **GPUmates Coordinator** from the Start menu. No uninstall is needed;
the existing coordinator state and keys are retained.

Run a newer unified Setup and keep the same role to upgrade. Setup remembers
the role, node name, network addresses, selected Coordinator ports, the Worker's
dashboard port, and any cache choice saved by version
0.3.1 or later. A legacy upgrade with no saved cache choice starts unchecked
so persistent storage is not enabled silently. Changing a computer between
Coordinator and Worker requires uninstalling GPUmates first; Setup refuses an
in-place role switch.

Coordinator writable state and DPAPI secrets live under
`%LOCALAPPDATA%\GPUmates\Coordinator` and are retained by uninstall. Worker
configuration and logs under `%ProgramData%\GPUmates\Worker` are removed by
uninstall. Tensor files under
`%LOCALAPPDATA%\GPUmates\Worker\TensorCache\b10488\rpc` are retained so
an uninstall cannot silently destroy model data; use **GPUmates Worker Cache
Settings** to clear them first. Use **Forget saved AgentKey** before uninstall
if other Windows accounts also ran worker telemetry.

GPUmates processes are foreground applications, not Windows services. Firewall
rules persist, but the Coordinator and Worker applications must be opened again
after Windows restarts.

## Silent installation

Coordinator, with explicit values recommended:

```powershell
.\GPUmates-Setup-0.3.4.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /ROLE=coordinator /COORDINATORIP=172.25.50.14 /NODENAME=PC1 /ROUTERPORT=18080 /DASHBOARDPORT=18090 /CONTROLPORT=18091
```

Worker requires all four role/network parameters:

```powershell
.\GPUmates-Setup-0.3.4.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /ROLE=worker /COORDINATORIP=172.25.50.14 /WORKERIP=172.25.50.49 /NODENAME=PC2 /DASHBOARDPORT=18090 /CACHE=1
```

Use `/CACHE=0` to opt out of persistent worker tensor caching.
Port parameters are optional: Setup reuses saved choices on an upgrade and
uses 8080/8090/8091 for a fresh Coordinator install. Invalid, duplicate, or
occupied Coordinator ports block silent installation too. The standalone
Coordinator installer accepts the same `/COORDINATORIP`, `/NODENAME`, and three
port parameters. Coordinator port choices are written to the installation's
`config\network.json` for its launcher, runtime services, and sharing rules.
For silent Worker installation or upgrade, `/CACHE=1` or `/CACHE=0` is
required so persistent model-data storage is always an explicit choice.

## Security

Never port-forward TCP 50052, 9835, or any of your selected Coordinator ports
(8080, 8090, and 8091 by default). RPC and the web
endpoints use no transport encryption in this build; keep them on a trusted
private LAN or place a proper VPN/TLS layer in front. Exact-IP Windows Firewall
rules are the RPC security boundary.

## Rebuild

With Inno Setup 6 installed and the Control Center frontend already built:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\scripts\Test-ControlCenterModelStatus.ps1'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\scripts\Test-CoordinatorPortPreflight.ps1'
& '.\installer\unified\Build-UnifiedInstaller.ps1'
```

For a portable Inno Setup compiler, pass its path explicitly:

```powershell
& '.\installer\unified\Build-UnifiedInstaller.ps1' -CompilerPath '.\downloads\tools\inno-setup\ISCC.exe'
```

The reproducible setup source is `installer\unified\GPUmatesUnified.iss`.
