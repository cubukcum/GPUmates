GPUmates Worker role
====================

Open Start Menu > GPUmates Worker > Start GPUmates Worker after every reboot.
Keep both visible windows open while sharing this GPU. The RPC window provides
compute on TCP 50052; the telemetry window reports read-only status on TCP
9835. Closing either window stops that function.

The first telemetry start asks for the AgentKey generated on PC1. Windows DPAPI
protects it for the signed-in user. The complete GGUF model remains on PC1.
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
