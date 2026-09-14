# GPUmates PC1 Control Center

The unified installer is the normal, no-PowerShell way to operate the cluster.
On PC1, choose **Main PC / Coordinator**. PC1 is the computer that stores the
GGUF models and coordinates inference.

## Which computer gets which software

| Computer role | What to install | What it does |
| --- | --- | --- |
| PC1 coordinator | `GPUmates-Setup-0.3.0.exe` -> **Main PC / Coordinator** | Uses PC1's GPU, manages workers, models, chat sharing, and the node dashboard |
| PC2 and additional GPU workers | `GPUmates-Setup-0.3.0.exe` -> **GPU Worker** | Contributes a GPU over RPC and publishes read-only telemetry |
| Browser-only client | Nothing | Opens PC1's shared chat or node-dashboard URL after its exact IP is allowed |

A worker PC may also be a browser client. Its IP must still be included in the
appropriate client list. Do not add a browser-only PC to the GPU worker list.
Do not choose the Worker role on PC1: the coordinator already uses PC1's GPU
directly, including when no remote worker is selected.

## Install on PC1

Before setup, keep PC1 on a DHCP-reserved or static private IPv4 address and
close older GPUmates router, dashboard, or Control Center processes that may be
using TCP 8080, 8090, or 8091. PC1 needs Windows 11 x64, a current NVIDIA
driver that provides `nvidia-smi`, a usable NVIDIA GPU, and the Microsoft
Visual C++ v14 x64 runtime. The installer includes the pinned llama.cpp/CUDA
application runtime, but not the NVIDIA driver, Visual C++ redistributable, or
GGUF model files.

1. Keep the installer beside its `.sha256` file and verify that file after any
   transfer. This preview is not Authenticode-signed, so SmartScreen may show
   **Unknown publisher**.
2. Run `GPUmates-Setup-0.3.0.exe` on PC1, approve the setup UAC prompt, and
   choose **Main PC / Coordinator**. Setup writes the application under
   `C:\Program Files`.
3. Leave **Open GPUmates Coordinator now** selected, or later use **Start menu →
   GPUmates Coordinator → GPUmates Coordinator**. Setup can also create a
   desktop shortcut.
4. The launcher starts the local controller without a console window and opens
   <http://127.0.0.1:8091/>.

Always enter the administration page through the GPUmates Coordinator
shortcut. The launcher supplies a per-session token through the browser URL
fragment and immediately removes it from the visible address; the controller
never returns that token to an unauthenticated web request. A bookmark or a
manually typed `127.0.0.1:8091` URL cannot create an authenticated session.

The Control Center itself runs as the signed-in Windows user, not as
Administrator. It asks for elevation only when an exact-IP Windows Firewall
rule must change.

## First run: create the three keys

The services cannot be started until all three keys are saved.

1. In **First-run security**, select **Generate secure keys**.
2. Select **Copy all once** and put the values in a password manager before
   leaving the form. The generated clear values are shown only at this point.
3. Select **Save existing keys** to protect them on PC1.

| Key | Who receives it |
| --- | --- |
| Agent key | Every worker's telemetry window; use the same value for all workers |
| Dashboard key | People allowed to view the read-only node dashboard |
| Llama API key | People or applications allowed to use the LAN model UI/API |

The three keys have different privileges; do not reuse one value for another
purpose. PC1 stores them in `%LOCALAPPDATA%\GPUmates\Coordinator\secrets.dpapi.json`
using Windows DPAPI and a private directory ACL. They are not revealed again by
the Control Center. If keys are replaced, stop the affected services, update
every worker or client that used the old values, and start the services again.

## Add and prepare workers

Install the unified EXE with the **GPU Worker** role on each GPU worker first.
Configure it with PC1 as the
coordinator, start **GPUmates Worker**, and paste PC1's Agent key into its
telemetry window on first use. Keep both visible worker windows open:

- the RPC window contributes GPU compute on TCP 50052;
- the telemetry window supplies monitoring on TCP 9835.

On PC1, use **GPU nodes -> Add an installed GPU PC** to enter the worker's name
and fixed private IPv4 address. Registration changes PC1 only; it does not
install, reconfigure, or start the other PC. Adding a worker selects it for the
next router start and adds its IP to the draft sharing lists. Use **Apply
sharing & firewall** separately if that PC should also open chat or the node
dashboard.

## Daily operation without PowerShell

After every reboot or sign-in:

1. On every worker you want to use, open **Start GPUmates Worker** and leave its
   RPC and telemetry windows running.
2. On PC1, open **GPUmates Coordinator** from the Start menu or desktop.
3. In **GPU nodes**, check the two independent status columns. Select the
   workers to use and choose **Save selection**. An empty selection runs on
   PC1's GPU only.
4. Choose **Start all**, or start the model router and node dashboard
   individually.
5. In **Model library**, choose **Load on cluster** for the required model.
6. Use the **Chat** and **Node dashboard** links at the top of the Control
   Center.

If desired, **Coordinator settings** can auto-start the router and/or dashboard
after the Control Center itself opens. This does not launch GPUmates at Windows
sign-in; after a reboot you still open the PC1 shortcut once.

When finished, unload the model if you only want to free model memory. Use
**Stop all** to stop the router and dashboard. Then use **Shut down Control
Center** if the local administration listener should also stop. Closing only
the browser tab does not stop any of these processes; reopening the shortcut
connects to the existing local controller.

No GPUmates component is installed as a Windows service or launched at Windows
sign-in. After a PC reboot, models are unloaded, PC1 must be opened from its
shortcut, and each worker must be started by its owner.

### GPU status inside chat

The chat page includes a compact GPU status bar above the existing llama.cpp
chat interface. Start the **Node dashboard** as well as the model router to
make telemetry available, then unlock the bar with your **Dashboard key**.
This key is separate from the Llama API key used for shared chat. A browser
client must also be in the exact-IP **Node dashboard client IPs** list; chat
access alone does not grant monitoring access.

The bar reads the same telemetry as the node dashboard. Its dashboard link
opens the full monitoring view. If monitoring is stopped or access is missing,
chat remains available and the bar reports that monitoring is unavailable.
After an update, an existing chat tab may need a second manual reload once its
service worker has updated. Finish or save any prompt draft before reloading;
GPUmates does not force a reload of an active chat.

The installer includes the chat assets. Each router start prepares a writable
copy under `%LOCALAPPDATA%\GPUmates\Coordinator\ChatUi`, with PC1's dashboard
address for both local and LAN chat. It does not rewrite the files in
`C:\Program Files`. Source-checkout users can build these assets with
`chat\Build-ChatUi.ps1`; older checkouts without the bundle continue to use
the native llama.cpp chat and log a warning. For a manually launched router,
`Start-ModelRouter.ps1 -DashboardBaseUrl http://<PC1-IP>:8090` overrides the
dashboard address normally read from `config\telemetry-nodes.json`.

## RPC and telemetry status are separate

- **RPC compute — TCP 50052:** this is the path used for model tensors and GPU
  work. Every selected worker must show RPC online before the router can start.
- **Telemetry — TCP 9835:** this is the read-only monitoring path used by the
  node dashboard. Telemetry online does not prove that RPC compute is ready,
  and RPC may work while telemetry is unavailable.
- **Use selection:** this controls the next router start. Changing it does not
  reshape a router that is already running; stop and start the router to change
  the active compute pool.

If a selected worker's RPC service is offline, deselect it or start its RPC
window. A telemetry-only failure does not prevent inference, but that worker's
dashboard data will be unavailable.

## Load, unload, and add models

Start the model router before loading a model. The router starts without a
model, and only one configured model can occupy the cluster at a time. For a
predictable switch, select **Unload model**, wait for it to become available,
then select **Load on cluster** on the other model. Unloading a model keeps the
router and chat service running; stopping the router ends both.

The installer does not include GGUF model files. To add one without PowerShell
or manual file editing:

1. Put the `.gguf` file on a permanent local drive on PC1. Do not leave it on a
   removable drive or a network path that may disappear.
2. Stop the **Model router**. The model list is locked while the router is
   running.
3. In **Model library**, choose **Add GGUF model** and select the file in the
   native Windows picker.
4. Confirm or edit the friendly model name, then choose **Confirm add**.
5. Start the router and choose **Load on cluster** on the new model card.

Use **Remove** while the router is stopped to remove a card from the library.
This never deletes the GGUF itself. Worker PCs do not need a copy of the GGUF;
PC1 distributes the required tensor work over RPC.

On a trusted worker, leave **Keep model tensor cache on this PC** enabled during
Worker setup. The first load still transfers that worker's tensor share, while
later loads can reuse its SSD cache after **Unload model** frees VRAM. This is a
worker-owned setting: change or clear it from **GPUmates Worker Cache Settings**
on that PC, then restart its RPC worker. The PC1 Control Center does not remotely
rewrite worker storage settings.

Model presets and their absolute PC1 paths are stored in:

```text
%LOCALAPPDATA%\GPUmates\Coordinator\Config\gpumates-models.ini
```

The UI writes this file atomically and keeps a backup before changing the
library. Manual INI editing is only a troubleshooting option. A model marked
**MISSING** cannot be loaded.

## Share chat and the node dashboard on the LAN

Use a trusted private LAN and reserve the addresses of PC1 and every approved
client. On PC1:

1. In **Sharing**, enable **Share the chat / model UI on LAN** when chat/model
   UI access should leave PC1.
2. Enter the **complete** list of exact private IPv4 addresses allowed to use
   chat on TCP 8080. Use one address per line or comma-separated values.
3. Enter the complete exact-IP list allowed to view the node dashboard on TCP
   8090. A client does not need to be a GPU worker.
4. Choose **Apply sharing & firewall** and approve the Windows Administrator
   prompt. Canceling UAC leaves the new sharing request unapplied.

Applying sharing replaces the named firewall rules with the submitted lists;
it does not append to an older firewall list. Submit every approved client each
time. If the router or dashboard is running, the Control Center briefly stops
and restarts the affected service so its binding and configuration match the
new rules; a loaded model must then be loaded again.

To return everything to PC1-only access, turn LAN sharing off, clear both
client lists, and apply the firewall change. The dashboard list is independent
of the chat switch, so clearing it is required to remove dashboard sharing.

### Addresses and credentials

| Purpose | Address | Credential |
| --- | --- | --- |
| PC1 administration | <http://127.0.0.1:8091/> | Local per-launch control token; never shared |
| PC1 administration health | <http://127.0.0.1:8091/health> | None; loopback only |
| Chat/model UI on PC1 | <http://127.0.0.1:8080/> | Local mode |
| Shared chat/model UI | `http://<PC1-LAN-IP>:8080/` | Llama API key |
| Shared node dashboard | `http://<PC1-LAN-IP>:8090/` | Dashboard key |
| Worker RPC compute | `<worker-IP>:50052` | No application authentication; PC1-only firewall |
| Worker telemetry | `<worker-IP>:9835` | Agent key plus PC1-only firewall |

In the current two-PC setup, PC1's reserved address is `172.25.50.14`, so the
LAN URLs are <http://172.25.50.14:8080/> and
<http://172.25.50.14:8090/>. The node dashboard displays a key-entry screen.
For OpenAI-compatible API calls, send the Llama API key as a Bearer token.

On an approved client PC, open the chat URL and provide the Llama API key when
the model UI requests it. Open the node-dashboard URL separately and paste the
Dashboard key on its access screen. A browser-only client needs no GPUmates EXE
and cannot open or control the PC1 administration page.

The administration URL on TCP 8091 is deliberately bound only to PC1 loopback.
Do not try to share it. Other computers use only the explicitly enabled chat
and read-only dashboard URLs.

## Installed files and writable data

| Path | Contents |
| --- | --- |
| `C:\Program Files\GPUmates\Coordinator` | Installed launcher, scripts, runtime, and web assets |
| `%LOCALAPPDATA%\GPUmates\Coordinator\Config\control.json` | Selected workers, sharing state, and coordinator defaults |
| `%LOCALAPPDATA%\GPUmates\Coordinator\Config\telemetry-nodes.json` | PC1 and registered worker nodes |
| `%LOCALAPPDATA%\GPUmates\Coordinator\Config\gpumates-models.ini` | PC1 model presets and absolute GGUF paths |
| `%LOCALAPPDATA%\GPUmates\Coordinator\secrets.dpapi.json` | DPAPI-protected keys |
| `%LOCALAPPDATA%\GPUmates\Coordinator\control-session.dpapi` | Encrypted, per-launch browser token; removed on shutdown |
| `%LOCALAPPDATA%\GPUmates\Coordinator\Logs` | Hidden router and dashboard stdout/stderr logs |

Edit the writable copies under `%LOCALAPPDATA%`, not the seed files under
`C:\Program Files`. Uninstall stops recognized GPUmates listeners and removes
its named firewall rules. The current installer leaves the signed-in user's
writable data under `%LOCALAPPDATA%` in place; back it up or remove it
deliberately if it is no longer needed. Keep the clear keys in a password
manager independently of that encrypted data.

## Security rules

- Never port-forward TCP 50052, 9835, 8080, 8090, or 8091.
- Keep Windows Firewall enabled and restrict every LAN rule to exact client
  addresses. Do not use an entire subnet or `0.0.0.0/0`.
- RPC, shared chat, dashboard traffic, prompts, responses, model tensors, and
  telemetry are not end-to-end encrypted. Use only a trusted private LAN.
- RPC itself is experimental and unauthenticated. Its worker firewall must
  admit PC1 only.
- Keep the Agent, Dashboard, and Llama API keys separate and give each only to
  the people or machines that need that role.
- Keep TCP 8091 loopback-only. It is the administration surface, not a client
  portal.
- Keep PC1 and worker addresses DHCP-reserved. An address change can invalidate
  exact-IP rules and the saved coordinator configuration.
