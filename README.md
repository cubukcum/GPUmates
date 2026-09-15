# GPUmates: two-PC llama.cpp RPC trial

This workspace contains a pinned, reproducible Windows 11 setup for running one
GGUF model across two RTX 5070 Ti GPUs on the same LAN.

For PC3 or additional workers, follow [ADD-ANOTHER-WORKER.md](ADD-ANOTHER-WORKER.md).

For the shared read-only GPU monitoring dashboard, follow
[DASHBOARD-LAN-SETUP.md](DASHBOARD-LAN-SETUP.md).
Copy-pasteable single-line commands are in
[DASHBOARD-ONE-LINE-COMMANDS.md](DASHBOARD-ONE-LINE-COMMANDS.md).

## Pinned runtime

- llama.cpp build: `b10488` (`9d77fa172`)
- CUDA runtime: 13.3
- Coordinator: this PC, `DESKTOP-272LQKU`
- Coordinator IPv4: `172.25.50.14/24` (currently assigned by DHCP)
- Coordinator Ethernet: Realtek PCIe GbE, negotiated at 1.0 Gbps
- Worker: PC2, `DESKTOP-1K2PL3G`
- Worker IPv4: `172.25.50.49/24` (reachable from the coordinator)
- RPC port: TCP `50052`
- Local UI/API default port: TCP `8080` (selectable in Setup)
- GPU dashboard default port: TCP `8090` (selectable in Setup)
- PC1-only Control Center default port: TCP `8091` (selectable in Setup)
- Worker telemetry port: TCP `9835`

The runtime in `runtime/` has already been validated against this PC's RTX 5070
Ti. The official release archives and their recorded hashes are in `downloads/`
and `checksums.sha256`.

## Unified installer and PC1 Control Center

The recommended operator path for every Windows GPU PC is one offline setup:

```text
dist\installer\GPUmates-Setup-0.3.4.exe
```

On PC1 choose **Main PC / Coordinator**. On PC2 and every additional GPU
contributor choose **GPU Worker**. Choose exactly one role per computer; PC1
does not also need the Worker role because the coordinator uses PC1's GPU
directly. A browser-only client installs nothing.

Keep the installer beside its `.sha256` file and verify it after transfer; this
preview is not Authenticode-signed. Run Setup with its requested Administrator
approval, then open **GPUmates Coordinator** from the Start menu or optional
desktop shortcut. It opens the PC1-only administration page at
<http://127.0.0.1:8091/>. On first run, generate and save the separate Agent,
Dashboard, and Llama API keys before starting the router or dashboard.
Open this page through the shortcut rather than a bookmark: the launcher
delivers its encrypted per-user, per-session browser token without exposing it
from an unauthenticated HTTP response.

Daily operation needs no PowerShell: start the visible worker windows on each
selected worker, open the Coordinator shortcut on PC1, check RPC and telemetry
separately, select the compute workers, choose **Start all**, and load one model
from **Model library**. That library can also add or remove PC1-local GGUF
presets through a native file picker while the router is stopped. LAN chat and
dashboard access are granted only to exact client IPs through **Sharing**, which
opens a UAC prompt for the narrow firewall change.

Setup asks for the chat/API, dashboard, and local Control Center ports. Keep
the defaults if they are free, or choose three different ports from 1024 to
65535. Setup checks availability before installing and reports the occupied
address and port so you can go back and choose another. The launcher, URLs,
and chat GPU statistics use the saved choices in `config/network.json`.

To let other PCs connect, open **Sharing**, enable LAN chat, enter each allowed
PC's private IPv4 address in the chat and/or dashboard client list, and apply.
Windows Firewall rules use your selected ports and exact client IPs. Use the
URLs shown in the Control Center. The administration page stays local to PC1.
After changing ports by rerunning Setup, apply Sharing again to update the
rules, and update worker dashboard shortcuts to match. Examples below use the
default ports.

GPUmates does not install these components as Windows services or launch them
at Windows sign-in. After a reboot, worker owners start their worker windows
and the PC1 owner opens the Coordinator shortcut again. The Control Center can
optionally start its router and dashboard as soon as it is opened. See
[UNIFIED-INSTALLER.md](UNIFIED-INSTALLER.md) covers role selection, migration,
silent setup, and security. See
[COORDINATOR-CONTROL-CENTER.md](COORDINATOR-CONTROL-CENTER.md) for first-run
keys, model controls, LAN URLs, data paths, and shutdown behavior.

The PowerShell sections below remain the reproducible manual and troubleshooting
reference.

## First trial

### 1. Copy the runtime to PC2

The simplest method is to copy `scripts/`, `downloads/`, and
`checksums.sha256` to a new `GPUmates` directory on PC2, then run the pinned
installer:

```text
scripts/
downloads/
checksums.sha256
```

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\Install-LlamaCpp.ps1
```

The installer deliberately copies only `llama-server.exe`, `llama-bench.exe`,
`ggml-rpc-server.exe`, and the DLLs they require. The official release contains
additional utilities that this cluster does not need.

The process-scoped execution-policy change disappears when that PowerShell
window closes.

### 2. Verify PC2's wired IPv4 address

On PC2:

```powershell
.\scripts\Get-NetworkInfo.ps1
```

Confirm that the wired Ethernet address is `172.25.50.49`. Both PCs are in
`172.25.50.0/24`, and PC1 can already ping PC2. Reserve both addresses in DHCP
before relying on this long term.

### 3. Create PC2's narrow firewall rule

Open PowerShell **as Administrator** on PC2:

```powershell
.\scripts\Configure-WorkerFirewall.ps1 `
  -CoordinatorIP 172.25.50.14 `
  -WorkerIP 172.25.50.49
```

This rule allows only PC1 to reach `ggml-rpc-server.exe` on PC2 at TCP 50052.
It works without changing the network from Public to Private and does not open
the port to the whole subnet.

Remove the rule later with:

```powershell
.\scripts\Configure-WorkerFirewall.ps1 -Remove
```

### 4. Start PC2's worker

In a normal, non-administrator PowerShell window on PC2:

```powershell
.\scripts\Start-Worker.ps1 -WorkerIP 172.25.50.49 -EnableCache
```

`-EnableCache` keeps the remote model tensors assigned to this worker under
`%LOCALAPPDATA%\GPUmates\Worker\TensorCache\b10488\rpc`. The first load still crosses the LAN, but later
loads of the same tensors can come from the worker's SSD instead. Omit the
switch when the worker owner does not agree to persistent model data or disk
use.

Leave that window running. It should report `CUDA0: NVIDIA GeForce RTX 5070 Ti`.

### 5. Test and start from PC1

First compare the existing 12B model locally versus local+remote RPC:

```powershell
.\scripts\Test-Cluster.ps1 -WorkerIP 172.25.50.49
```

Then start the chat server:

```powershell
.\scripts\Start-Coordinator.ps1 -WorkerIP 172.25.50.49
```

Open <http://127.0.0.1:8080> on PC1. The initial launcher binds only to
loopback, so no coordinator firewall rule is needed.

## Browser model chooser

`Start-ModelRouter.ps1` starts llama.cpp's built-in Web UI in router mode. It
lists the GGUF paths in `config/gpumates-models.ini`, loads at most one model at
a time, and sends oversized models across the local and RPC GPUs.

With PC2's worker running:

```powershell
.\scripts\Start-ModelRouter.ps1 -WorkerIP 172.25.50.49
```

Open <http://127.0.0.1:8080>, choose a model, load it, and start a chat. The
current preset contains `muse-glimmer-30b-q4-k-xl` and
`gemma4-12b-q4-k-m`. Unified-installer users normally add another PC1-local
GGUF with **Control Center -> Model library -> Add GGUF model**; the manual INI
remains available for troubleshooting.

## Shared GPU dashboard

The local dashboard under `dashboard/` shows GPU utilization, VRAM,
temperature, power, fan and clocks alongside system CPU, RAM, network, active
llama.cpp model, throughput, and worker health. PC1 collects its own readings
directly; each worker runs the read-only telemetry agent. Browsers connect only
to PC1, and the cluster API requires a dashboard key.

Setup commands, exact firewall scopes, and PC2 instructions are in
[DASHBOARD-LAN-SETUP.md](DASHBOARD-LAN-SETUP.md).

## Worker role in the unified installer

For PC2 and future Windows 11 worker PCs, run the same unified EXE and choose
**GPU Worker**. It installs the CUDA/RPC runtime, telemetry, exact-IP firewall
setup, validation, and Start Menu shortcuts. Worker setup offers a clearly
labelled persistent tensor-cache option and enables it by default for fast
reloads on trusted PCs. The setting and cache can be managed later from
**GPUmates Worker Cache Settings** on that worker. See
[WORKER-INSTALLER.md](WORKER-INSTALLER.md).

Version 0.3.4 asks for a new AgentKey when a worker's configured Coordinator IP
changes. A key saved by an older version also needs to be entered once after
upgrading. If a worker is online for compute but its GPU is missing from the
dashboard after changing groups, stop both worker windows, use **Start menu ->
GPUmates Worker -> Forget saved AgentKey**, then start the worker and enter the
new Coordinator's **AgentKey**. See the
[worker recovery steps](WORKER-INSTALLER.md#change-coordinator-or-replace-a-saved-agentkey).

## Let PC2 use the chat API later

Coordinator-installer users should normally configure the complete exact-IP
client lists in the Control Center's **Sharing** panel. The commands below are
the manual equivalent.

After the private test works, create an inbound API rule on PC1 from an
elevated PowerShell window:

```powershell
.\scripts\Configure-CoordinatorFirewall.ps1 `
  -CoordinatorIP 172.25.50.14 `
  -ClientIP 172.25.50.49
```

Then start the coordinator with a strong API key:

```powershell
.\scripts\Start-Coordinator.ps1 `
  -WorkerIP 172.25.50.49 `
  -ListenHost 172.25.50.14 `
  -ApiKey 'replace-with-a-long-random-secret'
```

PC2 can then use `http://172.25.50.14:8080`.

## Current test model and baseline

The scripts default to the text model blob behind the existing Ollama model
`gemma4:12b`. It is a 6.86 GiB, 11.91B-parameter Q4_K_M GGUF. No model copy is
created.

PC1 local CUDA baseline, build 10488:

- prompt processing, 128 tokens: 2117.38 tokens/s
- generation, 32 tokens: 81.60 tokens/s

The RPC backend and full coordinator launcher were also smoke-tested on PC1
through a temporary loopback worker. `llama-server` loaded the model with
`CUDA,RPC`, `/health` returned `{"status":"ok"}`, and the OpenAI-compatible
chat-completions endpoint completed an inference request. The temporary worker
and coordinator were stopped afterward.

This model fits on one GPU, so it validates RPC but does not demonstrate the
main benefit of pooled capacity. After the connection is stable, use a roughly
27B-35B Q4 GGUF that cannot fit entirely on one 16 GB card.

## Safety and stability notes

- Never port-forward TCP 50052. llama.cpp RPC is experimental and unauthenticated.
- Keep both PCs on exactly build 10488 for this trial.
- Stop or unload active Ollama models before starting the coordinator.
- Use wired Ethernet. The current 1 GbE connection is adequate for validation;
  2.5 GbE is the most useful next upgrade if prompt processing is network-bound.
- `Start-Coordinator.ps1` uses `--cache-ram 0` because current llama.cpp RPC can
  crash when server prompt-cache state is saved through an RPC backend.
- In the installed Control Center use **Stop all**; `Ctrl+C` applies to the
  manual worker or coordinator commands in this reference.
