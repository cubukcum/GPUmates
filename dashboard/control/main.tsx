import React, { FormEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import "./styles.css";

type ServiceState = {
  running?: boolean;
  state?: string;
  mode?: "local" | "lan" | string;
  activeModel?: string | null;
  url?: string | null;
  error?: string | null;
};

type WorkerState = {
  name: string;
  ip: string;
  rpcOnline: boolean;
  telemetryOnline: boolean;
  selected: boolean;
};

type ModelState = {
  id: string;
  path: string;
  exists: boolean;
  sizeBytes?: number | null;
  status?: string | null;
};

type SharingState = {
  enabled?: boolean;
  lanAccess?: boolean;
  chatClientIps?: string[];
  dashboardClientIps?: string[];
  restartRequired?: boolean;
  message?: string;
};

type SetupState = {
  agentKey?: boolean;
  dashboardKey?: boolean;
  llamaApiKey?: boolean;
  agentKeySaved?: boolean;
  dashboardKeySaved?: boolean;
  llamaApiKeySaved?: boolean;
  complete?: boolean;
};

type SettingsState = {
  contextSize?: number;
  tensorSplit?: string | null;
  rpcPort?: number;
  routerPort?: number;
  dashboardPort?: number;
  autoStartRouter?: boolean;
  autoStartDashboard?: boolean;
  [key: string]: unknown;
};

type ControlStatus = {
  coordinator?: { name?: string; ip?: string };
  services?: { router?: ServiceState; dashboard?: ServiceState };
  setup?: SetupState;
  workers?: WorkerState[];
  models?: ModelState[];
  sharing?: SharingState;
  settings?: SettingsState;
  urls?: { chat?: string | null; dashboard?: string | null; control?: string | null };
  lastError?: string | null;
};

type Notice = { kind: "success" | "error" | "info"; text: string };
type SecretDraft = { agentKey: string; dashboardKey: string; llamaApiKey: string };
type ModelDraft = { model: string; path: string; sizeBytes: number | null };
type SettingsDraft = {
  contextSize: string;
  tensorSplit: string;
  rpcPort: string;
  routerPort: string;
  dashboardPort: string;
  autoStartRouter: boolean;
  autoStartDashboard: boolean;
};
type SettingsTextField = "contextSize" | "tensorSplit";

function takeLauncherToken() {
  const parameters = new URLSearchParams(window.location.hash.replace(/^#/, ""));
  const token = parameters.get("token") ?? "";
  if (window.location.hash) {
    window.history.replaceState(null, "", `${window.location.pathname}${window.location.search}`);
  }
  return token;
}

const CONTROL_TOKEN = takeLauncherToken();
const CONTROL_HEADER = {
  "Content-Type": "application/json",
  "X-GPUmates-Control": "1",
  "X-GPUmates-Control-Token": CONTROL_TOKEN,
};
const EMPTY_SECRETS: SecretDraft = { agentKey: "", dashboardKey: "", llamaApiKey: "" };

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

function errorMessage(value: unknown, fallback: string) {
  const record = asRecord(value);
  const candidate = record?.message ?? record?.error;
  if (typeof candidate === "string" && candidate.trim()) return candidate;
  const nested = asRecord(candidate);
  return typeof nested?.message === "string" && nested.message.trim() ? nested.message : fallback;
}

async function readResponse(response: Response): Promise<Record<string, unknown>> {
  const text = await response.text();
  if (!text) return {};
  try {
    return asRecord(JSON.parse(text)) ?? {};
  } catch {
    return { message: text };
  }
}

async function postJson(endpoint: string, body: Record<string, unknown> = {}) {
  const response = await fetch(endpoint, {
    method: "POST",
    headers: CONTROL_HEADER,
    body: JSON.stringify(body),
  });
  const data = await readResponse(response);
  if (!response.ok) throw new Error(errorMessage(data, `Request failed with HTTP ${response.status}`));
  return data;
}

function serviceRunning(service?: ServiceState) {
  if (typeof service?.running === "boolean") return service.running;
  return ["running", "online", "ready", "loading"].includes(String(service?.state ?? "").toLowerCase());
}

function modelLoaded(model: ModelState, activeModel?: string | null) {
  return String(model.status ?? "").toLowerCase() === "loaded" || model.id === activeModel;
}

function formatBytes(value?: number | null) {
  if (value == null || !Number.isFinite(value)) return "Size unavailable";
  if (value >= 1024 ** 3) return `${(value / 1024 ** 3).toFixed(1)} GB`;
  if (value >= 1024 ** 2) return `${(value / 1024 ** 2).toFixed(0)} MB`;
  return `${Math.round(value / 1024)} KB`;
}

function normalizedIps(text: string) {
  return [...new Set(text.split(/[\s,;]+/).map((item) => item.trim()).filter(Boolean))];
}

function newBrowserSecret() {
  if (!globalThis.crypto?.getRandomValues) return null;
  const bytes = new Uint8Array(32);
  globalThis.crypto.getRandomValues(bytes);
  return btoa(String.fromCharCode(...bytes));
}

function secretConfigured(setup: SetupState | undefined, name: "agentKey" | "dashboardKey" | "llamaApiKey") {
  const savedName = `${name}Saved` as keyof SetupState;
  return setup?.[savedName] === true || setup?.[name] === true;
}

function statusLabel(online: boolean) {
  return online ? "ONLINE" : "OFFLINE";
}

function StatusPill({ online, children }: { online: boolean; children: React.ReactNode }) {
  return <span className={`statePill ${online ? "isOnline" : "isOffline"}`}><i aria-hidden="true" />{children}</span>;
}

function Switch({ checked, onChange, label }: { checked: boolean; onChange: (checked: boolean) => void; label: string }) {
  return (
    <label className="switchLabel">
      <button className={`switch ${checked ? "switchOn" : ""}`} type="button" role="switch" aria-checked={checked} onClick={() => onChange(!checked)}><span /></button>
      <span>{label}</span>
    </label>
  );
}

function ExternalLink({ href, children, className = "secondaryButton" }: { href?: string | null; children: React.ReactNode; className?: string }) {
  if (!href || !/^https?:\/\//i.test(href)) return <span className={`${className} disabledLink`}>{children}</span>;
  return <a className={className} href={href} target="_blank" rel="noreferrer">{children}<span aria-hidden="true">↗</span></a>;
}

function ControlCenter() {
  const [snapshot, setSnapshot] = useState<ControlStatus | null>(null);
  const [pageError, setPageError] = useState("");
  const [notice, setNotice] = useState<Notice | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [lastUpdated, setLastUpdated] = useState<Date | null>(null);
  const [selectedIps, setSelectedIps] = useState<string[]>([]);
  const [selectionChanged, setSelectionChanged] = useState(false);
  const [workerDraft, setWorkerDraft] = useState({ name: "", ip: "" });
  const [sharingEnabled, setSharingEnabled] = useState(false);
  const [chatIps, setChatIps] = useState("");
  const [dashboardIps, setDashboardIps] = useState("");
  const [sharingResult, setSharingResult] = useState("");
  const [sharingChanged, setSharingChanged] = useState(false);
  const [secretDraft, setSecretDraft] = useState<SecretDraft>(EMPTY_SECRETS);
  const [showSecrets, setShowSecrets] = useState(false);
  const [revealSecrets, setRevealSecrets] = useState(false);
  const [settingsDraft, setSettingsDraft] = useState<SettingsDraft>({ contextSize: "8192", tensorSplit: "", rpcPort: "50052", routerPort: "8080", dashboardPort: "8090", autoStartRouter: false, autoStartDashboard: false });
  const [settingsChanged, setSettingsChanged] = useState(false);
  const [modelDraft, setModelDraft] = useState<ModelDraft | null>(null);
  const [controllerStopped, setControllerStopped] = useState(false);

  const requestInFlight = useRef(false);
  const actionInFlight = useRef(false);
  const selectionDirty = useRef(false);
  const sharingDirty = useRef(false);
  const settingsDirty = useRef(false);

  const acceptStatus = useCallback((next: ControlStatus) => {
    setSnapshot(next);
    setLastUpdated(new Date());
    setPageError("");

    if (!selectionDirty.current) {
      setSelectedIps((next.workers ?? []).filter((worker) => worker.selected).map((worker) => worker.ip));
    }
    if (!sharingDirty.current) {
      setSharingEnabled(next.sharing?.enabled ?? next.sharing?.lanAccess ?? false);
      setChatIps((next.sharing?.chatClientIps ?? []).join("\n"));
      setDashboardIps((next.sharing?.dashboardClientIps ?? []).join("\n"));
    }
    if (!settingsDirty.current) {
      setSettingsDraft({
        contextSize: String(next.settings?.contextSize ?? 8192),
        tensorSplit: String(next.settings?.tensorSplit ?? ""),
        rpcPort: String(next.settings?.rpcPort ?? 50052),
        routerPort: String(next.settings?.routerPort ?? 8080),
        dashboardPort: String(next.settings?.dashboardPort ?? 8090),
        autoStartRouter: next.settings?.autoStartRouter ?? false,
        autoStartDashboard: next.settings?.autoStartDashboard ?? false,
      });
    }
  }, []);

  const refreshStatus = useCallback(async (quiet = false) => {
    if (requestInFlight.current || controllerStopped) return;
    if (!CONTROL_TOKEN) {
      setPageError("Open GPUmates Coordinator from the PC1 Start menu or desktop shortcut to create a secure local session.");
      return;
    }
    requestInFlight.current = true;
    try {
      const response = await fetch("/api/v1/status", {
        cache: "no-store",
        headers: { "X-GPUmates-Control-Token": CONTROL_TOKEN },
      });
      const data = await readResponse(response);
      if (!response.ok) throw new Error(errorMessage(data, `Status failed with HTTP ${response.status}`));
      const nestedStatus = asRecord(data.status);
      acceptStatus((nestedStatus ?? data) as ControlStatus);
    } catch (error) {
      const message = error instanceof Error ? error.message : "The local control service did not answer.";
      setPageError(message);
      if (!quiet) setNotice(null);
    } finally {
      requestInFlight.current = false;
    }
  }, [acceptStatus, controllerStopped]);

  useEffect(() => {
    const initial = window.setTimeout(() => void refreshStatus(), 0);
    const timer = window.setInterval(() => void refreshStatus(true), 4000);
    return () => { window.clearTimeout(initial); window.clearInterval(timer); };
  }, [refreshStatus]);

  useEffect(() => {
    if (!notice) return;
    const timer = window.setTimeout(() => setNotice(null), notice.kind === "error" ? 8000 : 5000);
    return () => window.clearTimeout(timer);
  }, [notice]);

  const runAction = useCallback(async <T,>(key: string, operation: () => Promise<T>, successText: string): Promise<T | undefined> => {
    if (actionInFlight.current) return undefined;
    actionInFlight.current = true;
    setBusy(key);
    setNotice(null);
    try {
      const result = await operation();
      const message = errorMessage(result, successText);
      setNotice({ kind: "success", text: message || successText });
      await refreshStatus(true);
      return result;
    } catch (error) {
      setNotice({ kind: "error", text: error instanceof Error ? error.message : "The action failed." });
      return undefined;
    } finally {
      actionInFlight.current = false;
      setBusy(null);
    }
  }, [refreshStatus]);

  const workers = snapshot?.workers ?? [];
  const models = snapshot?.models ?? [];
  const router = snapshot?.services?.router;
  const dashboard = snapshot?.services?.dashboard;
  const routerOnline = serviceRunning(router);
  const dashboardOnline = serviceRunning(dashboard);
  const selectedWorkers = workers.filter((worker) => selectedIps.includes(worker.ip));
  const rpcReady = selectedWorkers.filter((worker) => worker.rpcOnline).length;
  const telemetryReady = workers.filter((worker) => worker.telemetryOnline).length;
  const activeModel = router?.activeModel ?? models.find((model) => String(model.status).toLowerCase() === "loaded")?.id ?? null;
  const chatUrl = snapshot?.urls?.chat ?? router?.url ?? null;
  const dashboardUrl = snapshot?.urls?.dashboard ?? null;
  const setup = snapshot?.setup;
  const secretsReady = setup?.complete === true || (["agentKey", "dashboardKey", "llamaApiKey"] as const).every((key) => secretConfigured(setup, key));
  const configuredSecretCount = (["agentKey", "dashboardKey", "llamaApiKey"] as const).filter((key) => secretConfigured(setup, key)).length;
  const allServicesRunning = routerOnline && dashboardOnline;
  const anyServiceRunning = routerOnline || dashboardOnline;

  const routerPayload = useMemo(() => ({ workerIps: selectedIps }), [selectedIps]);

  const startRouter = () => runAction("router-start", () => postJson("/api/v1/router/start", routerPayload), "Model router started.");
  const stopRouter = () => runAction("router-stop", () => postJson("/api/v1/router/stop"), "Model router stopped.");
  const startDashboard = () => runAction("dashboard-start", () => postJson("/api/v1/dashboard/start"), "Node dashboard started.");
  const stopDashboard = () => runAction("dashboard-stop", () => postJson("/api/v1/dashboard/stop"), "Node dashboard stopped.");

  const startAll = () => runAction("start-all", async () => {
    if (!routerOnline) await postJson("/api/v1/router/start", routerPayload);
    if (!dashboardOnline) return postJson("/api/v1/dashboard/start");
    return { message: "All requested services are running." };
  }, "Router and dashboard started.");

  const stopAll = () => runAction("stop-all", async () => {
    if (routerOnline) await postJson("/api/v1/router/stop");
    if (dashboardOnline) return postJson("/api/v1/dashboard/stop");
    return { message: "All requested services are stopped." };
  }, "Router and dashboard stopped.");

  const toggleWorker = (ip: string) => {
    selectionDirty.current = true;
    setSelectionChanged(true);
    setSelectedIps((current) => current.includes(ip) ? current.filter((item) => item !== ip) : [...current, ip]);
  };

  const saveSelection = async () => {
    const result = await runAction("selection-save", () => postJson("/api/v1/settings/save", { selectedWorkerIps: selectedIps }), "Worker selection saved.");
    if (result) {
      selectionDirty.current = false;
      setSelectionChanged(false);
    }
  };

  const addWorker = async (event: FormEvent) => {
    event.preventDefault();
    const name = workerDraft.name.trim();
    const ip = workerDraft.ip.trim();
    if (!name || !ip) {
      setNotice({ kind: "error", text: "Enter both a node name and its fixed LAN IPv4 address." });
      return;
    }
    const result = await runAction("worker-add", () => postJson("/api/v1/workers/add", { name, ip }), `${name} added.`);
    if (result) {
      if (selectionDirty.current) {
        setSelectedIps((current) => current.includes(ip) ? current : [...current, ip]);
      }
      setWorkerDraft({ name: "", ip: "" });
    }
  };

  const removeWorker = async (worker: WorkerState) => {
    if (!window.confirm(`Remove ${worker.name} (${worker.ip}) from PC1? This does not uninstall the worker PC.`)) return;
    const result = await runAction(`worker-remove-${worker.ip}`, () => postJson("/api/v1/workers/remove", { ip: worker.ip }), `${worker.name} removed.`);
    if (result) setSelectedIps((current) => current.filter((ip) => ip !== worker.ip));
  };

  const loadModel = (model: ModelState) => runAction(`model-load-${model.id}`, () => postJson("/api/v1/models/load", { model: model.id }), `${model.id} is loading.`);
  const unloadModel = (model: ModelState) => runAction(`model-unload-${model.id}`, () => postJson("/api/v1/models/unload", { model: model.id }), `${model.id} unloaded.`);

  const pickModel = async () => {
    if (actionInFlight.current) return;
    if (routerOnline) {
      setNotice({ kind: "info", text: "Stop the model router before changing the model library." });
      return;
    }
    actionInFlight.current = true;
    setBusy("model-pick");
    setNotice(null);
    try {
      const result = await postJson("/api/v1/models/pick");
      if (result.cancelled === true) return;
      const path = typeof result.path === "string" ? result.path.trim() : "";
      const suggestedName = typeof result.suggestedName === "string" ? result.suggestedName.trim() : "";
      if (!path) throw new Error("The selected GGUF path was not returned. Choose the file again.");
      setModelDraft({
        model: suggestedName,
        path,
        sizeBytes: typeof result.sizeBytes === "number" && Number.isFinite(result.sizeBytes) ? result.sizeBytes : null,
      });
    } catch (error) {
      setNotice({ kind: "error", text: error instanceof Error ? error.message : "The GGUF picker failed." });
    } finally {
      actionInFlight.current = false;
      setBusy(null);
    }
  };

  const addModel = async (event: FormEvent) => {
    event.preventDefault();
    if (!modelDraft) return;
    const model = modelDraft.model.trim();
    if (!/^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,62}[A-Za-z0-9])?$/.test(model)) {
      setNotice({ kind: "error", text: "Use 1–64 letters, numbers, dots, underscores, or hyphens; begin and end with a letter or number." });
      return;
    }
    const result = await runAction("model-add", () => postJson("/api/v1/models/add", { model, path: modelDraft.path }), `${model} added to the model library.`);
    if (result) {
      setModelDraft(null);
      setNotice({ kind: "success", text: `${model} added. Start the model router, then choose Load on cluster.` });
    }
  };

  const removeModel = async (model: ModelState) => {
    if (modelLoaded(model, activeModel) || String(model.status ?? "").toLowerCase() === "loading") return;
    if (!window.confirm(`Remove ${model.id} from the model list?\n\nThe GGUF file will stay on disk.`)) return;
    await runAction(`model-remove-${model.id}`, () => postJson("/api/v1/models/remove", { model: model.id }), `${model.id} removed from the model library.`);
  };

  const generateSecrets = async () => {
    const browserSecrets = {
      agentKey: newBrowserSecret(),
      dashboardKey: newBrowserSecret(),
      llamaApiKey: newBrowserSecret(),
    };
    const result = await runAction("secrets-generate", async () => {
      try {
        return await postJson("/api/v1/secrets/generate");
      } catch (error) {
        if (Object.values(browserSecrets).every(Boolean)) return { message: "Keys generated locally with Web Crypto." };
        throw error;
      }
    }, "New keys generated. Save them when ready.");
    const record = asRecord(result);
    const source = asRecord(record?.secrets) ?? record;
    if (!source && !Object.values(browserSecrets).every(Boolean)) return;
    setSecretDraft({
      agentKey: browserSecrets.agentKey ?? (typeof source?.agentKey === "string" ? source.agentKey : ""),
      dashboardKey: browserSecrets.dashboardKey ?? (typeof source?.dashboardKey === "string" ? source.dashboardKey : ""),
      llamaApiKey: browserSecrets.llamaApiKey ?? (typeof source?.llamaApiKey === "string" ? source.llamaApiKey : ""),
    });
    setRevealSecrets(true);
    setShowSecrets(true);
  };

  const copySecrets = async () => {
    if (Object.values(secretDraft).some((value) => !value)) return;
    try {
      await navigator.clipboard.writeText(`GPUmates AgentKey: ${secretDraft.agentKey}\nGPUmates DashboardKey: ${secretDraft.dashboardKey}\nGPUmates LlamaApiKey: ${secretDraft.llamaApiKey}`);
      setNotice({ kind: "info", text: "All three keys copied. Put them in your password manager now." });
    } catch {
      setNotice({ kind: "error", text: "The browser could not access the clipboard. Reveal and copy each value manually." });
    }
  };

  const saveSecrets = async (event: FormEvent) => {
    event.preventDefault();
    if (Object.values(secretDraft).some((value) => value.trim().length < 24)) {
      setNotice({ kind: "error", text: "Each key must contain at least 24 characters." });
      return;
    }
    const result = await runAction("secrets-save", () => postJson("/api/v1/secrets/save", secretDraft), "Keys saved for PC1.");
    if (result) {
      setSecretDraft(EMPTY_SECRETS);
      setRevealSecrets(false);
      setShowSecrets(false);
    }
  };

  const applySharing = async () => {
    const payload = {
      enabled: sharingEnabled,
      chatClientIps: normalizedIps(chatIps),
      dashboardClientIps: normalizedIps(dashboardIps),
    };
    const result = await runAction("sharing-apply", () => postJson("/api/v1/sharing/apply", payload), "LAN sharing rules applied.");
    if (!result) return;
    sharingDirty.current = false;
    setSharingChanged(false);
    const restartRequired = result.restartRequired === true;
    const message = typeof result.message === "string" ? result.message : "Sharing configuration saved.";
    setSharingResult(restartRequired ? `${message} Restart the affected service to apply it.` : message);
  };

  const changeSharing = (update: () => void) => {
    sharingDirty.current = true;
    setSharingChanged(true);
    setSharingResult("");
    update();
  };

  const saveSettings = async (event: FormEvent) => {
    event.preventDefault();
    const payload: Record<string, unknown> = {
      contextSize: Number(settingsDraft.contextSize),
      rpcPort: Number(settingsDraft.rpcPort),
      routerPort: Number(settingsDraft.routerPort),
      dashboardPort: Number(settingsDraft.dashboardPort),
      selectedWorkerIps: selectedIps,
      tensorSplit: settingsDraft.tensorSplit.trim(),
      autoStartRouter: settingsDraft.autoStartRouter,
      autoStartDashboard: settingsDraft.autoStartDashboard,
    };
    if ([payload.contextSize, payload.rpcPort, payload.routerPort, payload.dashboardPort].some((value) => !Number.isInteger(value) || Number(value) <= 0)) {
      setNotice({ kind: "error", text: "Context size and ports must be positive whole numbers." });
      return;
    }
    const result = await runAction("settings-save", () => postJson("/api/v1/settings/save", payload), "Coordinator defaults saved.");
    if (result) {
      settingsDirty.current = false;
      selectionDirty.current = false;
      setSettingsChanged(false);
      setSelectionChanged(false);
    }
  };

  const stopController = async () => {
    if (!window.confirm("Shut down the local GPUmates Control Center? Running inference and dashboard services are managed separately.")) return;
    const result = await runAction("controller-shutdown", () => postJson("/api/v1/shutdown"), "Control Center stopped.");
    if (result) {
      setControllerStopped(true);
      setSnapshot(null);
      setPageError("The local Control Center is stopped. Start it again from PC1 to reconnect.");
    }
  };

  const settingsChange = (field: SettingsTextField, value: string) => {
    settingsDirty.current = true;
    setSettingsChanged(true);
    setSettingsDraft((current) => ({ ...current, [field]: value }));
  };

  const settingsToggle = (field: "autoStartRouter" | "autoStartDashboard", value: boolean) => {
    settingsDirty.current = true;
    setSettingsChanged(true);
    setSettingsDraft((current) => ({ ...current, [field]: value }));
  };

  if (!snapshot && pageError) {
    return (
      <main className="offlineShell">
        <div className="ambientGlow" />
        <section className="offlineCard">
          <span className="brandMark">G</span>
          <p className="eyebrow"><span>PC1 LOCAL</span> CONTROL CENTER</p>
          <h1>Coordinator<br /><em>unavailable.</em></h1>
          <p>{pageError}</p>
          {!controllerStopped && <button className="primaryButton" type="button" onClick={() => void refreshStatus()}>Try again</button>}
          <small>This admin surface only accepts connections from this PC.</small>
        </section>
      </main>
    );
  }

  if (!snapshot) {
    return <main className="loadingShell"><span className="loader" /><p>Connecting to the local coordinator…</p></main>;
  }

  return (
    <main className="controlShell" id="top">
      <header className="topbar">
        <a className="brand" href="#top" aria-label="GPUmates Control Center home"><span className="brandMark">G</span><span>GPUmates</span><span className="brandSection">PC1 Control Center</span></a>
        <div className="topbarActions">
          <span className="adminBadge"><i /> LOCAL-ONLY ADMIN</span>
          <ExternalLink href={chatUrl} className="utilityLink">Chat</ExternalLink>
          <ExternalLink href={dashboardUrl} className="utilityLink">Node dashboard</ExternalLink>
        </div>
      </header>

      {notice && <div className={`notice notice-${notice.kind}`} role="status"><span>{notice.kind === "success" ? "✓" : notice.kind === "error" ? "!" : "i"}</span><p>{notice.text}</p><button type="button" aria-label="Dismiss message" onClick={() => setNotice(null)}>×</button></div>}
      {(snapshot.lastError || pageError) && <div className="errorBanner"><strong>Coordinator notice</strong><span>{snapshot.lastError || pageError}</span></div>}

      <section className="controlHero">
        <div className="heroCopy">
          <p className="eyebrow"><span>CONTROL PLANE</span> {snapshot.coordinator?.ip ?? "LOOPBACK"}</p>
          <h1>Run the cluster<br /><em>from PC1.</em></h1>
          <p className="lede">Choose the model, bring GPU nodes into the pool, and share only the services you intend to share.</p>
        </div>
        <div className="heroPanel">
          <div className="heroIdentity"><span>COORDINATOR</span><strong>{snapshot.coordinator?.name ?? "PC1"}</strong><small>{snapshot.coordinator?.ip ?? "Local machine"}</small></div>
          <div className="heroCounts">
            <div><strong>{rpcReady}<small> / {selectedWorkers.length}</small></strong><span>Selected RPC ready</span></div>
            <div><strong>{telemetryReady}<small> / {workers.length}</small></strong><span>Telemetry online</span></div>
          </div>
          <div className="allActions">
            <button className="primaryButton" type="button" disabled={busy !== null || allServicesRunning || !secretsReady} onClick={() => void startAll()}>{busy === "start-all" ? "Starting…" : "Start all"}</button>
            <button className="dangerButton" type="button" disabled={busy !== null || !anyServiceRunning} onClick={() => void stopAll()}>{busy === "stop-all" ? "Stopping…" : "Stop all"}</button>
          </div>
          {!secretsReady && <p className="heroHint">Finish first-run keys before starting shared services.</p>}
        </div>
      </section>

      <section className="section" aria-labelledby="services-title">
        <div className="sectionHeading"><div><p className="eyebrow">RUNTIME</p><h2 id="services-title">Services</h2></div><p>{lastUpdated ? `Status sampled ${lastUpdated.toLocaleTimeString()}` : "Waiting for status"}</p></div>
        <div className="serviceGrid">
          <article className={`serviceCard ${routerOnline ? "serviceRunning" : ""}`}>
            <header><div><span className="cardIndex">01</span><div><p>LLAMA.CPP</p><h3>Model router</h3></div></div><StatusPill online={routerOnline}>{routerOnline ? "RUNNING" : "STOPPED"}</StatusPill></header>
            <div className="serviceBody">
              <div className="serviceMetric"><span>Access mode</span><strong>{(router?.mode ?? (sharingEnabled ? "lan" : "local")).toUpperCase()}</strong></div>
              <div className="serviceMetric"><span>Active model</span><strong title={activeModel ?? undefined}>{activeModel ?? "None loaded"}</strong></div>
              <div className="urlLine"><span>URL</span><code>{chatUrl ?? "Available after start"}</code><ExternalLink href={chatUrl} className="tinyLink">Open</ExternalLink></div>
              {router?.error && <p className="inlineError">{router.error}</p>}
            </div>
            <footer><button className="cardButton" type="button" disabled={busy !== null || routerOnline || !secretsReady} onClick={() => void startRouter()}>{busy === "router-start" ? "Starting…" : "Start router"}</button><button className="cardButton mutedButton" type="button" disabled={busy !== null || !routerOnline} onClick={() => void stopRouter()}>{busy === "router-stop" ? "Stopping…" : "Stop"}</button></footer>
          </article>

          <article className={`serviceCard ${dashboardOnline ? "serviceRunning" : ""}`}>
            <header><div><span className="cardIndex">02</span><div><p>OBSERVABILITY</p><h3>Node dashboard</h3></div></div><StatusPill online={dashboardOnline}>{dashboardOnline ? "RUNNING" : "STOPPED"}</StatusPill></header>
            <div className="serviceBody">
              <div className="serviceMetric"><span>Visible nodes</span><strong>{workers.length + 1}</strong></div>
              <div className="serviceMetric"><span>Telemetry ready</span><strong>{telemetryReady} workers</strong></div>
              <div className="urlLine"><span>URL</span><code>{dashboardUrl ?? "Available after start"}</code><ExternalLink href={dashboardUrl} className="tinyLink">Open</ExternalLink></div>
              {dashboard?.error && <p className="inlineError">{dashboard.error}</p>}
            </div>
            <footer><button className="cardButton" type="button" disabled={busy !== null || dashboardOnline || !secretsReady} onClick={() => void startDashboard()}>{busy === "dashboard-start" ? "Starting…" : "Start dashboard"}</button><button className="cardButton mutedButton" type="button" disabled={busy !== null || !dashboardOnline} onClick={() => void stopDashboard()}>{busy === "dashboard-stop" ? "Stopping…" : "Stop"}</button></footer>
          </article>
        </div>
      </section>

      <section className={`section secretSection ${secretsReady ? "secretsReady" : "secretsNeeded"}`} aria-labelledby="secrets-title">
        <div className="secretSummary">
          <div className="securityMark" aria-hidden="true">{secretsReady ? "✓" : "!"}</div>
          <div><p className="eyebrow">FIRST-RUN SECURITY</p><h2 id="secrets-title">{secretsReady ? "Keys configured" : "Create the three access keys"}</h2><p>{secretsReady ? "PC1 has the worker, dashboard, and model API keys it needs." : "Generate fresh keys or paste keys you already keep in a password manager."}</p></div>
          <div className="secretState"><strong>{configuredSecretCount} / 3</strong><span>keys saved</span></div>
          <button className="secondaryButton" type="button" onClick={() => setShowSecrets((current) => !current)}>{showSecrets || !secretsReady ? "Hide key form" : "Replace keys"}</button>
        </div>
        {(showSecrets || !secretsReady) && <form className="secretForm" onSubmit={saveSecrets}>
          <div className="formIntro"><p>Generated values are shown once. Save a copy securely before leaving this screen.</p><div><button className="secondaryButton" type="button" disabled={busy !== null} onClick={() => void generateSecrets()}>{busy === "secrets-generate" ? "Generating…" : "Generate secure keys"}</button><button className="secondaryButton" type="button" disabled={Object.values(secretDraft).some((value) => !value)} onClick={() => void copySecrets()}>Copy all once</button><label className="revealToggle"><input type="checkbox" checked={revealSecrets} onChange={(event) => setRevealSecrets(event.target.checked)} /> Show values</label></div></div>
          <div className="fieldGrid threeFields">
            <label><span>Agent key</span><small>Shared with every telemetry worker</small><input type={revealSecrets ? "text" : "password"} autoComplete="off" value={secretDraft.agentKey} onChange={(event) => setSecretDraft((current) => ({ ...current, agentKey: event.target.value }))} placeholder="At least 24 characters" /></label>
            <label><span>Dashboard key</span><small>Given only to node-dashboard viewers</small><input type={revealSecrets ? "text" : "password"} autoComplete="off" value={secretDraft.dashboardKey} onChange={(event) => setSecretDraft((current) => ({ ...current, dashboardKey: event.target.value }))} placeholder="At least 24 characters" /></label>
            <label><span>Llama API key</span><small>Given only to approved model users</small><input type={revealSecrets ? "text" : "password"} autoComplete="off" value={secretDraft.llamaApiKey} onChange={(event) => setSecretDraft((current) => ({ ...current, llamaApiKey: event.target.value }))} placeholder="At least 24 characters" /></label>
          </div>
          <div className="formActions"><span>{anyServiceRunning ? "Stop the router and dashboard before replacing keys." : "Keys are handled by the local PC1 controller."}</span><button className="primaryButton" type="submit" disabled={busy !== null || anyServiceRunning}>{busy === "secrets-save" ? "Saving…" : "Save existing keys"}</button></div>
        </form>}
      </section>

      <section className="section" aria-labelledby="models-title">
        <div className="sectionHeading modelHeading"><div><p className="eyebrow">MODEL LIBRARY</p><h2 id="models-title">Choose what to run</h2></div><div className="modelHeadingActions"><p>One model can occupy the cluster at a time.</p><button className="secondaryButton" type="button" disabled={busy !== null || routerOnline} title={routerOnline ? "Stop the model router first" : "Choose a GGUF file on PC1"} onClick={() => void pickModel()}>{busy === "model-pick" ? "Choosing…" : "Add GGUF model"}</button></div></div>
        <div className={`modelRouterNote ${routerOnline ? "routerStopNeeded" : "routerStopped"}`}><span aria-hidden="true">{routerOnline ? "!" : "✓"}</span><p><strong>{routerOnline ? "Stop the model router to change the library." : "The model router is stopped; library changes are enabled."}</strong> The router reads the model list at startup, so start it again after adding or removing a model.</p></div>
        {modelDraft && <form className="modelAddForm" onSubmit={addModel}>
          <div className="modelPickedFile"><p className="eyebrow">SELECTED GGUF</p><strong title={modelDraft.path}>{modelDraft.path.split(/[\\/]/).pop() ?? modelDraft.path}</strong><code title={modelDraft.path}>{modelDraft.path}</code><small>{formatBytes(modelDraft.sizeBytes)}</small></div>
          <label><span>Model name</span><small>1–64 letters, numbers, dots, underscores, or hyphens. This is the name shown in GPUmates.</small><input type="text" maxLength={64} pattern="[A-Za-z0-9](?:[A-Za-z0-9._-]{0,62}[A-Za-z0-9])?" value={modelDraft.model} onChange={(event) => setModelDraft((current) => current ? { ...current, model: event.target.value } : current)} placeholder="my-model-q4" /></label>
          <div className="modelAddActions"><button className="secondaryButton" type="button" disabled={busy !== null} onClick={() => setModelDraft(null)}>Cancel</button><button className="primaryButton" type="submit" disabled={busy !== null || routerOnline || !modelDraft.model.trim()}>{busy === "model-add" ? "Adding…" : "Confirm add"}</button></div>
        </form>}
        <div className="modelGrid">
          {models.length === 0 && <div className="emptyState"><strong>No models added yet</strong><p>Stop the router, then choose <b>Add GGUF model</b> to select a file stored on PC1.</p></div>}
          {models.map((model, index) => {
            const loaded = modelLoaded(model, activeModel);
            const loading = String(model.status ?? "").toLowerCase() === "loading";
            return <article className={`modelCard ${loaded ? "activeModel" : ""} ${!model.exists ? "missingModel" : ""}`} key={model.id}>
              <header><span>{String(index + 1).padStart(2, "0")}</span><StatusPill online={loaded}>{loading ? "LOADING" : loaded ? "LOADED" : model.exists ? "AVAILABLE" : "MISSING"}</StatusPill></header>
              <div className="modelName"><p>GGUF PRESET</p><h3>{model.id}</h3></div>
              <div className="modelMeta"><span>{formatBytes(model.sizeBytes)}</span><code title={model.path}>{model.path || "Path unavailable"}</code></div>
              <footer>{loaded ? <button className="cardButton mutedButton" type="button" disabled={busy !== null} onClick={() => void unloadModel(model)}>{busy === `model-unload-${model.id}` ? "Unloading…" : "Unload model"}</button> : <><button className="cardButton" type="button" disabled={busy !== null || !routerOnline || !model.exists} onClick={() => void loadModel(model)}>{busy === `model-load-${model.id}` ? "Loading…" : "Load on cluster"}</button><button className="modelRemoveButton" type="button" disabled={busy !== null || routerOnline || loading} title={routerOnline ? "Stop the model router first" : `Remove ${model.id} from the list`} onClick={() => void removeModel(model)}>{busy === `model-remove-${model.id}` ? "Removing…" : "Remove"}</button></>}</footer>
            </article>;
          })}
        </div>
      </section>

      <section className="section" aria-labelledby="workers-title">
        <div className="sectionHeading workerHeading"><div><p className="eyebrow">COMPUTE POOL</p><h2 id="workers-title">GPU nodes</h2></div><div className="headingActions">{selectionChanged && <span className="pendingTag">Unsaved selection</span>}<button className="secondaryButton" type="button" disabled={busy !== null || !selectionChanged} onClick={() => void saveSelection()}>{busy === "selection-save" ? "Saving…" : "Save selection"}</button></div></div>
        <div className="workerTable" role="table" aria-label="Configured GPU workers">
          <div className="workerRow workerHeader" role="row"><span role="columnheader">Use</span><span role="columnheader">Node</span><span role="columnheader">RPC compute</span><span role="columnheader">Telemetry</span><span role="columnheader">Management</span></div>
          {workers.map((worker) => <div className="workerRow" role="row" key={worker.ip}>
            <span role="cell"><button className={`selectToggle ${selectedIps.includes(worker.ip) ? "selected" : ""}`} type="button" aria-label={`${selectedIps.includes(worker.ip) ? "Exclude" : "Include"} ${worker.name} on next router start`} aria-pressed={selectedIps.includes(worker.ip)} onClick={() => toggleWorker(worker.ip)}><i /></button></span>
            <span className="workerIdentity" role="cell"><strong>{worker.name}</strong><code>{worker.ip}</code></span>
            <span role="cell"><StatusPill online={worker.rpcOnline}>{statusLabel(worker.rpcOnline)}</StatusPill><small>TCP 50052</small></span>
            <span role="cell"><StatusPill online={worker.telemetryOnline}>{statusLabel(worker.telemetryOnline)}</StatusPill><small>TCP 9835</small></span>
            <span role="cell"><button className="textButton dangerText" type="button" disabled={busy !== null} onClick={() => void removeWorker(worker)}>{busy === `worker-remove-${worker.ip}` ? "Removing…" : "Remove"}</button></span>
          </div>)}
          {workers.length === 0 && <div className="tableEmpty">No worker PCs registered yet.</div>}
        </div>
        <p className="tableNote">Selection controls the next router start. RPC and telemetry are separate: an online dashboard card does not prove that RPC compute is ready.</p>
        <form className="addWorkerForm" onSubmit={addWorker}>
          <div><p className="eyebrow">REGISTER WORKER</p><strong>Add an installed GPU PC</strong><small>The worker EXE must already be configured with PC1 as coordinator.</small></div>
          <label><span>Node name</span><input value={workerDraft.name} onChange={(event) => setWorkerDraft((current) => ({ ...current, name: event.target.value }))} placeholder="PC3" maxLength={64} /></label>
          <label><span>Fixed LAN IPv4</span><input value={workerDraft.ip} onChange={(event) => setWorkerDraft((current) => ({ ...current, ip: event.target.value }))} placeholder="172.25.50.60" inputMode="decimal" /></label>
          <button className="primaryButton" type="submit" disabled={busy !== null}>{busy === "worker-add" ? "Adding…" : "Add worker"}</button>
        </form>
      </section>

      <section className="section splitSection" aria-label="Sharing and coordinator settings">
        <article className="panel" aria-labelledby="sharing-title">
          <header><div><p className="eyebrow">LAN ACCESS</p><h2 id="sharing-title">Sharing</h2></div><StatusPill online={sharingEnabled}>{sharingEnabled ? "LAN CHAT ON" : "CHAT: PC1 ONLY"}</StatusPill></header>
          <Switch checked={sharingEnabled} onChange={(checked) => changeSharing(() => setSharingEnabled(checked))} label="Share the chat / model UI on LAN" />
          <p className="panelIntro">The toggle controls chat access. The node-dashboard viewer list is applied independently. Only exact client addresses below are admitted.</p>
          <label className="textAreaField"><span>Chat / model UI client IPs</span><small>Port 8080 · one IP per line or comma-separated</small><textarea rows={4} value={chatIps} onChange={(event) => changeSharing(() => setChatIps(event.target.value))} placeholder={"172.25.50.49\n172.25.50.60"} /></label>
          <label className="textAreaField"><span>Node dashboard client IPs</span><small>Port 8090 · complete viewer list</small><textarea rows={4} value={dashboardIps} onChange={(event) => changeSharing(() => setDashboardIps(event.target.value))} placeholder={"172.25.50.49\n172.25.50.60"} /></label>
          <div className="uacNote"><span>UAC</span><p>Apply may open a Windows elevation prompt because PC1 must recreate narrow firewall rules. Submit the complete client lists every time.</p></div>
          {sharingResult && <p className="resultNote">{sharingResult}</p>}
          <button className="primaryButton fullButton" type="button" disabled={busy !== null || !sharingChanged} onClick={() => void applySharing()}>{busy === "sharing-apply" ? "Applying…" : "Apply sharing & firewall"}</button>
        </article>

        <article className="panel" aria-labelledby="settings-title">
          <header><div><p className="eyebrow">DEFAULTS</p><h2 id="settings-title">Coordinator settings</h2></div><span className="settingsTag">NEXT START</span></header>
          <p className="panelIntro">These values are applied when PC1 next starts the affected service. Existing processes are not silently replaced.</p>
          <form className="settingsForm" onSubmit={saveSettings}>
            <label><span>Context size</span><small>512–1,048,576 tokens</small><input type="number" min="512" max="1048576" step="512" value={settingsDraft.contextSize} onChange={(event) => settingsChange("contextSize", event.target.value)} /></label>
            <label><span>Tensor split</span><small>Optional proportions</small><input value={settingsDraft.tensorSplit} onChange={(event) => settingsChange("tensorSplit", event.target.value)} placeholder="Automatic" /></label>
            <label><span>RPC port</span><small>Fixed worker compute port</small><input className="fixedInput" type="number" value={settingsDraft.rpcPort} readOnly aria-readonly="true" /></label>
            <label><span>Router port</span><small>Fixed chat / API port</small><input className="fixedInput" type="number" value={settingsDraft.routerPort} readOnly aria-readonly="true" /></label>
            <label><span>Dashboard port</span><small>Fixed node UI port</small><input className="fixedInput" type="number" value={settingsDraft.dashboardPort} readOnly aria-readonly="true" /></label>
            <div className="settingsSummary"><span>Selected workers</span><strong>{selectedIps.length}</strong><small>{selectedIps.length ? selectedIps.join(", ") : "PC1 GPU only"}</small></div>
            <div className="autoStartOptions"><span>After Control Center starts</span><Switch checked={settingsDraft.autoStartRouter} onChange={(checked) => settingsToggle("autoStartRouter", checked)} label="Auto-start model router" /><Switch checked={settingsDraft.autoStartDashboard} onChange={(checked) => settingsToggle("autoStartDashboard", checked)} label="Auto-start node dashboard" /></div>
            <button className="primaryButton fullButton" type="submit" disabled={busy !== null || (!settingsChanged && !selectionChanged)}>{busy === "settings-save" ? "Saving…" : "Save defaults"}</button>
          </form>
        </article>
      </section>

      <section className="shutdownRow">
        <div><p className="eyebrow">LOCAL CONTROLLER</p><strong>Close the administration surface</strong><span>This does not implicitly uninstall workers. Service state is managed above.</span></div>
        <button className="dangerButton" type="button" disabled={busy !== null} onClick={() => void stopController()}>{busy === "controller-shutdown" ? "Shutting down…" : "Shut down Control Center"}</button>
      </section>

      <footer className="siteFooter"><span>GPUmates / PC1 local control</span><span>Never expose this admin port to the LAN or Internet</span></footer>
    </main>
  );
}

createRoot(document.getElementById("root")!).render(<React.StrictMode><ControlCenter /></React.StrictMode>);
