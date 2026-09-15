GPUmates Worker role
====================

Open Start Menu > GPUmates Worker > Start GPUmates Worker after every reboot.
Keep both visible windows open while sharing this GPU. The RPC window provides
compute on TCP 50052; the telemetry window reports read-only status on TCP
9835. Closing either window stops that function.

The first telemetry start asks for the AgentKey generated on PC1. Windows DPAPI
protects it for the signed-in user. The saved key is associated with PC1's IP;
changing the configured Coordinator IP asks for the new PC1's AgentKey. A key
saved by version 0.3.3 or earlier asks once again after upgrading to 0.3.4.

If compute is online but GPU readings are missing after changing groups:
1. Stop both worker windows with Ctrl+C.
2. In Start Menu > GPUmates Worker, choose Forget saved AgentKey using the same
   Windows account that runs the worker.
3. Start GPUmates Worker again and enter the new PC1's AgentKey in the telemetry
   window. This is separate from the dashboard and chat keys.
4. Have the new PC1 owner add or verify this worker's name and current IP under
   GPUmates Coordinator > GPU nodes > Add worker. Check RPC compute and Telemetry.

Use Forget saved AgentKey after PC1 changes its key or is replaced at the same
IP. If needed, rerun Worker Setup with the new PC1 IP and current worker IP to
update the two exact-IP firewall rules. Both worker windows must stay open.

The complete GGUF model remains on PC1.
When caching is enabled, the worker keeps its assigned tensor data
under %LOCALAPPDATA%\GPUmates\Worker\TensorCache\b10488\rpc so repeated model loads avoid another full
network transfer.
Disabling caching keeps existing files. Use GPUmates Worker Cache Settings >
Clear cache to delete them explicitly.

Tell the PC1 owner this worker's name and fixed IP. The owner adds it through
GPUmates Coordinator > GPU nodes > Add worker; no PowerShell registration is
needed. Browser-only users do not install GPUmates, while GPU-contributing PCs
use this Worker role.

Start Menu shortcuts:

* Start GPUmates Worker
* GPUmates Worker Status
* GPUmates Worker Cache Settings
* Open GPU Dashboard
* Forget saved AgentKey

Never port-forward TCP 50052, 9835, 8080, or 8090.
