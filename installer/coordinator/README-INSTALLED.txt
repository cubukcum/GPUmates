GPUmates Coordinator
====================

Open "GPUmates Coordinator" from the Start menu or desktop. It starts a
local-only control service and opens http://127.0.0.1:8091 in your browser.
Use the shortcut each time: it unlocks the page with an encrypted, per-user,
per-session token that is never returned by an unauthenticated web request.

The Control Center lets PC1:

* start and stop the model router and node dashboard;
* choose, load, and unload configured GGUF models;
* see RPC compute and telemetry status separately for every worker;
* register or remove worker PCs;
* choose which workers participate in the next model-router start;
* apply exact-IP LAN sharing rules through a Windows Administrator prompt;
* generate and save the AgentKey, DashboardKey, and llama API key.

PC1 needs Windows 11 x64, a current NVIDIA driver, a usable NVIDIA GPU, and
the Microsoft Visual C++ v14 x64 runtime. GGUF model files are not bundled.

The administration page is bound only to 127.0.0.1:8091. It is never exposed
to other PCs. Other users receive only the model UI on TCP 8080 and/or the
read-only node dashboard on TCP 8090 when PC1 explicitly allows their fixed IP.

The first-run key screen generates three different keys. Save them in a
password manager before leaving the screen. Give the AgentKey only to worker
telemetry users, the DashboardKey to dashboard viewers, and the llama API key
to approved model users.

The launcher and managed services are not Windows services. After signing in
or rebooting PC1, open GPUmates Coordinator from the Start menu or desktop.
You do not need to run any PowerShell commands.

Never port-forward TCP 50052, 9835, 8080, 8090, or 8091.
