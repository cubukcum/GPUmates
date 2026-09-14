# Add another Windows GPU worker

This runbook adds PC3, PC4, or another Windows 11 NVIDIA PC to the existing
GPUmates llama.cpp RPC cluster.

## Recommended no-PowerShell path

Use the same `GPUmates-Setup-0.3.0.exe` on every new GPU PC:

1. Reserve a unique private IPv4 address for the new PC in the router/DHCP
   settings. Keep PC1 at `172.25.50.14`; for example, PC2 may use
   `172.25.50.49` and PC3 may use `172.25.50.60`.
2. Copy the installer and its `.sha256` sidecar to the new PC, verify the hash,
   run Setup, and choose **GPU Worker**.
3. Enter a unique worker name, PC1's address, and the new PC's reserved address.
   Leave **Start GPUmates Worker now** selected.
4. Paste only PC1's **Agent key** into the first telemetry prompt. Keep both
   visible worker windows open; RPC uses TCP 50052 and telemetry uses TCP 9835.
5. On PC1, open **GPUmates Coordinator -> GPU nodes**, enter the same name and
   IP under **Add an installed GPU PC**, and choose **Add worker**.
6. Wait for both **RPC compute** and **Telemetry** to report **ONLINE**. Keep the
   worker selected and save the selection if prompted.
7. Under **Sharing**, keep the complete exact-IP lists for chat and dashboard
   viewers, choose **Apply sharing & firewall**, and approve UAC. Adding a
   worker drafts its IP into both lists, but does not change PC1's firewall
   until this button is used.
8. Start or restart the router so it uses the selected worker. Other approved
   PCs open `http://172.25.50.14:8080` with the Llama API key and
   `http://172.25.50.14:8090` with the Dashboard key. Browser-only PCs install
   nothing and belong only in the Sharing lists.

After a worker reboot, its owner uses **Start menu -> GPUmates Worker -> Start
GPUmates Worker** again. The command-line sections below are retained as the
manual/troubleshooting path for a source checkout; unified-installer users do
not need them for normal operation.

## Current topology

| Role | Address | Purpose |
| --- | --- | --- |
| PC1 coordinator | `172.25.50.14` | Holds the GGUF, runs `llama-server`, and controls inference |
| PC2 worker | `172.25.50.49` | Exposes its RTX 5070 Ti as RPC `CUDA0` |
| New worker | Discover it below | Adds another GPU through TCP `50052` |

All machines may stay on Windows 11. Use wired Ethernet on the same trusted
LAN, reserve each address in the router's DHCP settings, and keep every machine
on the same pinned llama.cpp build (`b10488`).

The new PC does not need its own GGUF model file. PC1 sends the tensor portions
needed for remote computation while the worker is connected. The commands
below enable the optional persistent tensor cache so that share normally
crosses the LAN only on its first load.

## 1. Prepare the new PC

Copy the reusable GPUmates worker bundle or these items to the new PC:

```text
scripts/
downloads/
checksums.sha256
```

Extract them into one `GPUmates` folder. Open a normal PowerShell window in
that folder and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Install-LlamaCpp.ps1
.\scripts\Get-NetworkInfo.ps1
nvidia-smi
```

Record the active wired IPv4 address. It should normally begin with
`172.25.50.`. Confirm that `nvidia-smi` sees the intended NVIDIA GPU.

## 2. Verify the new address from PC1

On PC1, open PowerShell in the main `GPUmates` folder:

```powershell
$NewWorkerIP = Read-Host 'Enter the new worker IPv4 address'
ping $NewWorkerIP
```

Do not continue if the address belongs to a guest network, an untrusted LAN, or
another device. A failed TCP test at this point is normal because the worker is
not running yet:

```powershell
Test-NetConnection -ComputerName $NewWorkerIP -Port 50052
```

## 3. Allow only PC1 through the new worker's firewall

On the new worker, open PowerShell **as Administrator** in its `GPUmates`
folder. Run the complete commands below; `-WorkerIP` is a parameter and cannot
be entered by itself.

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
$NewWorkerIP = Read-Host 'Enter this PC IPv4 address'
.\scripts\Configure-WorkerFirewall.ps1 -CoordinatorIP 172.25.50.14 -WorkerIP $NewWorkerIP
```

This creates an inbound Windows Firewall rule restricted to:

- PC1 source address `172.25.50.14`
- the new worker's exact local address
- TCP port `50052`
- the exact `ggml-rpc-server.exe` program

It does not disable Windows Firewall or create an Internet-facing rule.

## 4. Start the new worker

On the new worker, return to a normal PowerShell window in its `GPUmates`
folder:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
$NewWorkerIP = Read-Host 'Enter this PC IPv4 address'
.\scripts\Start-Worker.ps1 -WorkerIP $NewWorkerIP -EnableCache
```

Leave the window open. It should identify the GPU as `CUDA0`. Press `Ctrl+C`
whenever the owner wants to stop sharing the GPU.

`-EnableCache` requires the owner's agreement because raw tensor files remain
on the worker and use several gigabytes of disk. The cache location is normally
`%LOCALAPPDATA%\GPUmates\Worker\TensorCache\b10488\rpc`. Omit the switch for a
borrowed or untrusted PC.

## 5. Test every worker from PC1

On PC1:

```powershell
$NewWorkerIP = Read-Host 'Enter the new worker IPv4 address'
Test-NetConnection -ComputerName $NewWorkerIP -Port 50052
```

Continue only when `TcpTestSucceeded` is `True`. Build the worker list and run
the comparison benchmark:

```powershell
$Workers = @('172.25.50.49', $NewWorkerIP)
.\scripts\Test-Cluster.ps1 -WorkerIPs $Workers
```

For a fourth worker, extend the same array:

```powershell
$Workers = @('172.25.50.49', $NewWorkerIP, 'FOURTH_WORKER_IP')
```

Replace `FOURTH_WORKER_IP` before running it.

## 6. Start one model across all GPUs

Keep every worker window running, stop or unload any active Ollama model on
PC1, and then run:

```powershell
.\scripts\Start-Coordinator.ps1 -WorkerIPs $Workers
```

This uses PC1's local GPU plus every RPC worker in `$Workers`. The model file,
server controls, and chat history remain coordinated by PC1. llama.cpp assigns
model tensors and KV cache across the available local and remote devices.

Adding GPUs mainly increases model capacity. Speed does not scale linearly,
especially over 1 GbE. A three-card setup has roughly 48 GB of physical VRAM,
but usable model capacity is lower because contexts, buffers, Windows desktop
use, and other overhead also consume memory.

## Optional: let the new PC chat with the model

The RPC worker is not a chat server. To let both PC2 and the new PC use PC1's
UI/API, first recreate PC1's narrow API firewall rule from an elevated
PowerShell window:

```powershell
$NewWorkerIP = Read-Host 'Enter the new worker IPv4 address'
$Clients = @('172.25.50.49', $NewWorkerIP)
.\scripts\Configure-CoordinatorFirewall.ps1 -CoordinatorIP 172.25.50.14 -ClientIPs $Clients
```

The command must contain the complete allowed-client list because it replaces
the previous named API rule.

Then start the coordinator from a normal PC1 PowerShell window with a strong
API key:

```powershell
$Workers = @('172.25.50.49', $NewWorkerIP)
$ApiKey = Read-Host 'Enter a long random API key'
.\scripts\Start-Coordinator.ps1 -WorkerIPs $Workers -ListenHost 172.25.50.14 -ApiKey $ApiKey
```

Approved clients can then connect to `http://172.25.50.14:8080`. Do not expose
that port to the Internet. The initial configuration has one inference slot,
so simultaneous requests wait in a queue.

## Optional: add the GPU to the shared dashboard

On the new worker, run the firewall command from an administrator window, then
start the agent from a normal window with the agent key supplied by PC1:

```powershell
.\scripts\Configure-MetricsFirewall.ps1 `
  -CoordinatorIP 172.25.50.14 `
  -AgentIP $NewWorkerIP

.\scripts\Start-TelemetryAgent.ps1 `
  -ListenIP $NewWorkerIP `
  -CoordinatorIP 172.25.50.14
```

On PC1, add another object to the `nodes` array in
`config/telemetry-nodes.json`, using the new fixed address, port `9835`, and
role `worker`. Restart the dashboard; the UI creates another node card
automatically. If the new PC owner should also view the dashboard, include its
address in both `dashboard.allowedClientIps` and the complete
`Configure-DashboardFirewall.ps1 -ClientIPs` list. See
[DASHBOARD-LAN-SETUP.md](DASHBOARD-LAN-SETUP.md) for the security details.

## Stop or remove a worker

1. Press `Ctrl+C` in the worker window.
2. On that worker, remove the firewall rule from elevated PowerShell:

   ```powershell
   .\scripts\Configure-WorkerFirewall.ps1 -Remove
   ```

3. If caching was enabled, remove
   `%LOCALAPPDATA%\GPUmates\Worker\TensorCache\b10488\rpc` only if the
   owner no longer wants its cached tensors.
4. Delete the worker's `GPUmates` folder if llama.cpp is no longer needed.
5. Remove its address from PC1's `$Workers` and `$Clients` arrays.

## Safety checklist

- Trust PC1, every worker owner, and the local network.
- Never port-forward or expose TCP `50052`; llama.cpp RPC is experimental,
  unauthenticated, and unencrypted.
- Keep the firewall rule limited to PC1 rather than the entire subnet.
- Model tensors and inference data travel over the LAN; do not use sensitive
  prompts on a network whose other users you do not trust.
- Expect GPU load, power use, heat, fan noise, and reduced gaming performance
  while a worker is active.
- A worker has no remote-desktop or general file-sharing capability, and stops
  sharing its GPU as soon as `ggml-rpc-server` exits.

Official reference: [llama.cpp RPC documentation](https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md).

## Quick troubleshooting

- **`-WorkerIP` is not recognized:** paste the full script command on one line.
- **`TcpTestSucceeded : False`:** confirm the worker window is still running,
  its IP has not changed, and the firewall command was run as Administrator.
- **Wrong or missing GPU:** run `nvidia-smi`, update the NVIDIA driver, and make
  sure the worker reports `CUDA0`.
- **Protocol or loading error:** verify that all PCs use exactly build `b10488`.
- **Slow first model startup:** the first cache-enabled load must still send
  tensors over Ethernet. Later loads should be much faster; confirm the worker
  window says caching is enabled and that
  `%LOCALAPPDATA%\GPUmates\Worker\TensorCache\b10488\rpc` is
  growing during the first load.
