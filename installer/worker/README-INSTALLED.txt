GPUmates Worker
===============

Start Menu shortcuts
--------------------

* Start GPUmates Worker: opens the visible llama.cpp RPC and telemetry windows.
* GPUmates Worker Status: reports the GPU and whether both ports are listening.
* GPUmates Worker Cache Settings: enables, disables, inspects, or clears the
  persistent tensor cache. Restart the RPC worker after changing the setting.
* Open GPU Dashboard: opens the coordinator's monitoring page.
* Forget saved AgentKey: removes this user's DPAPI-encrypted telemetry key.

The telemetry window asks for the coordinator's AgentKey the first time it is
started. Windows DPAPI then protects it for the current Windows user; it is not
stored in the worker JSON, registry, installer log, or shortcut arguments.
The saved key is associated with the configured Coordinator IP. A different
Coordinator IP or an older saved key without that association prompts again.

If compute is online but GPU readings are missing after changing groups, stop
both worker windows with Ctrl+C, choose Forget saved AgentKey in the Start Menu
using the same Windows account, then start GPUmates Worker again. Enter the new
Coordinator's AgentKey in the telemetry window; this is separate from dashboard
and chat keys. Also have the new Coordinator owner register this worker's name
and current IP. Use Forget saved AgentKey if the Coordinator changes its key or
is replaced at the same IP. Rerun Setup with the new Coordinator IP and current
worker IP if the two inbound firewall rules still allow the old Coordinator.

Keep both worker windows open while contributing this GPU. Ctrl+C stops the
corresponding process. The complete model file remains on the coordinator, and
the cache choice made during Setup controls whether assigned model tensors
remain under %LOCALAPPDATA%\GPUmates\Worker\TensorCache\b10488\rpc for faster later loads. Unloading a
model frees VRAM but intentionally keeps an enabled disk cache.
Disabling caching also keeps existing files; use Cache Settings > Clear cache
to delete them explicitly.

Adding this node on PC1
-----------------------

Tell the coordinator owner the node name and worker IP entered during setup.
On PC1, the owner runs Register-WorkerOnCoordinator.ps1 with that name and IP;
it updates telemetry configuration and prints the complete router command.

Default ports:

* llama.cpp RPC: TCP 50052
* read-only telemetry: TCP 9835
* coordinator GPU dashboard: TCP 8090

Never port-forward these ports.

If Setup reports a missing Microsoft Visual C++ v14 x64 runtime, obtain the
current supported installer from https://aka.ms/vc14/vc_redist.x64.exe and
then run GPUmates Setup again.
