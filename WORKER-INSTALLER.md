# GPUmates unified installer: Worker role

The preview installer packages the llama.cpp CUDA/RPC runtime, monitoring agent,
restricted Windows Firewall setup, configuration validation, and Start Menu
shortcuts into one offline EXE.

## Requirements

- Windows 11 x64
- a current NVIDIA driver and a visible NVIDIA GPU
- Microsoft Visual C++ v14 x64 runtime (Setup checks this prerequisite)
- a trusted private LAN
- a fixed/DHCP-reserved RFC1918 address for the worker and coordinator
- the coordinator's GPUmates AgentKey for first telemetry start

Close old RPC-worker and telemetry PowerShell windows before installing or
upgrading. They otherwise occupy TCP `50052` and `9835`.

## Install a worker

1. Copy `dist\installer\GPUmates-Setup-0.3.1.exe` to the worker PC.
2. Verify the adjacent SHA-256 file after transfer.
3. Double-click the EXE normally; Setup requests Administrator permission.
4. Choose **GPU Worker**, then enter a worker name, the coordinator/PC1 IPv4,
   and this worker's detected
   private IPv4.
5. Leave **Keep model tensor cache on this PC** selected for faster repeat
   loads on a trusted worker.
6. Leave **Start GPUmates Worker now** selected.

Setup installs under `C:\Program Files\GPUmates\Worker`, keeps non-secret
configuration under `C:\ProgramData\GPUmates\Worker`, and recreates two
inbound rules restricted to the exact coordinator IP and local ports.

On first monitoring start, paste the shared AgentKey. It is protected for that
Windows user with Windows DPAPI; it is not stored in configuration, installer
logs, shortcut arguments, or the registry. Use the **Forget saved AgentKey**
shortcut to remove it.

The PC owner explicitly starts two visible windows from **Start GPUmates
Worker** and can stop either with `Ctrl+C`. No hidden service or automatic
startup is installed. Setup shows a **Keep model tensor cache on this PC**
option, enabled by default for faster repeat loads. It stores only the tensor
data assigned to this worker rather than copying the complete GGUF, and keeps
that raw model data after unload or restart. Clear or disable it later with
**GPUmates Worker Cache
Settings** in the Start Menu; restart the RPC worker after changing the setting.

The cache is stored under
`%LOCALAPPDATA%\GPUmates\Worker\TensorCache\b10488\rpc`. It may use
several gigabytes and has no automatic size quota in the bundled llama.cpp
runtime. Disabling caching prevents new cache use but deliberately keeps files
that already exist; use **GPUmates Worker Cache Settings -> Clear cache** to
remove them. Disable it during Setup if this PC is not trusted to retain raw
model tensor data.

## Register it on PC1

The worker installer does not remotely modify PC1. Tell the coordinator owner
the worker name and IP. In PC1's **GPUmates Coordinator** Control Center:

1. Under **GPU nodes**, enter the name and fixed IP in **Add an installed GPU
   PC**, then choose **Add worker**.
2. Wait for both **RPC compute** and **Telemetry** to show **ONLINE**. Keep the
   worker selected for the next router start and save the selection if prompted.
3. Under **Sharing**, keep the complete chat and dashboard viewer lists, choose
   **Apply sharing & firewall**, and approve UAC if this PC should use either
   browser UI. Adding a worker drafts its IP into both lists, but does not apply
   PC1 firewall access by itself.
4. Start or restart the model router so the selected worker joins inference.

Browser-only clients install nothing and go only into the Sharing lists. The
equivalent registration command remains available for source-checkout
troubleshooting:

```powershell
& '.\scripts\Register-WorkerOnCoordinator.ps1' -WorkerIP 172.25.50.60 -NodeName 'PC3'
```

The script validates the address, backs up and updates
`config\telemetry-nodes.json`, preserves the complete dashboard client list,
and prints the exact multi-worker router and Administrator firewall commands.
Restart the dashboard after manual registration.

For example, two workers use one line on PC1:

```powershell
& '.\scripts\Start-ModelRouter.ps1' -WorkerIP 172.25.50.49,172.25.50.60 -ListenHost 172.25.50.14 -ApiKey $env:GPUMATES_LLAMA_API_KEY
```

Every listed RPC worker must be running before the router starts.

## Security and signing

The RPC protocol remains experimental, unencrypted, and unauthenticated. Never
port-forward its ports. The exact-IP firewall rule is the security boundary;
telemetry additionally requires the AgentKey.

Version `0.3.0` is not Authenticode-signed, so Windows SmartScreen may display
**Unknown publisher**. Verify the SHA-256 checksum. A trusted code-signing
certificate is needed before distributing this as a polished public installer.

Uninstall stops this installed worker, removes its two firewall rules, config,
logs, and the DPAPI AgentKey belonging to the Windows account running the
uninstaller. If several Windows accounts used monitoring, each should run the
**Forget saved AgentKey** shortcut before uninstalling.

## Rebuild

With Inno Setup 6 installed:

```powershell
& '.\installer\unified\Build-UnifiedInstaller.ps1'
```

The reproducible source is `installer\unified\GPUmatesUnified.iss`.
