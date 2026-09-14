"use client";

import { FormEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";

type GpuMetrics = {
  index: number;
  name: string;
  uuid?: string;
  utilizationPct: number | null;
  memoryUsedMiB: number | null;
  memoryTotalMiB: number | null;
  temperatureC: number | null;
  powerDrawW: number | null;
  powerLimitW?: number | null;
  fanPct?: number | null;
  graphicsClockMHz?: number | null;
  memoryClockMHz?: number | null;
};

type SystemMetrics = {
  cpuUtilizationPct?: number | null;
  memoryUsedBytes?: number | null;
  memoryTotalBytes?: number | null;
  networkRxBytesPerSec?: number | null;
  networkTxBytesPerSec?: number | null;
  uptimeSeconds?: number | null;
};

type NodeMetrics = {
  online: boolean;
  timestamp?: string;
  node: { name: string; ip: string; role: string };
  gpu: GpuMetrics[];
  system?: SystemMetrics;
  error?: string;
};

type ClusterSnapshot = {
  schemaVersion: number;
  timestamp: string;
  nodes: NodeMetrics[];
  totals?: {
    gpuCount?: number;
    gpuMemoryUsedMiB?: number;
    gpuMemoryTotalMiB?: number;
    weightedGpuUtilizationPct?: number;
  };
  llama?: Record<string, unknown> | null;
};

type ConnectionState = "locked" | "connecting" | "live" | "stale" | "denied";

const STORAGE_KEY = "gpumates-dashboard-key";
const HISTORY_LIMIT = 450;

const finite = (value: unknown, fallback = 0) => {
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
};

const formatGiB = (mib: unknown) => `${(finite(mib) / 1024).toFixed(1)}`;

const formatBytes = (bytes: unknown) => {
  if (bytes == null) return "—";
  const value = finite(bytes);
  if (value >= 1024 ** 3) return `${(value / 1024 ** 3).toFixed(1)} GB`;
  if (value >= 1024 ** 2) return `${(value / 1024 ** 2).toFixed(1)} MB`;
  if (value >= 1024) return `${(value / 1024).toFixed(0)} KB`;
  return `${Math.round(value)} B`;
};

const firstString = (...values: unknown[]) => values.find((value): value is string => typeof value === "string" && value.length > 0);

function parseLlama(llama: ClusterSnapshot["llama"]) {
  if (!llama) return { online: false, model: "No model detected", state: "ROUTER OFFLINE", speed: null as number | null, publicUrl: null as string | null };
  const modelRecord = llama.models as Record<string, unknown> | undefined;
  const modelList = Array.isArray(llama.models) ? llama.models : Array.isArray(modelRecord?.data) ? modelRecord.data : [];
  const activeId = firstString(llama.activeModel, llama.model);
  const loadedModel = modelList.find((entry) => {
    const item = entry as Record<string, unknown>;
    return item.status === "loaded" || (activeId && item.id === activeId);
  }) as Record<string, unknown> | undefined;
  const model = activeId ?? firstString(loadedModel?.id, loadedModel?.name) ?? "No model loaded";
  const speedCandidate = llama.generationTokensPerSecond ?? llama.tokensPerSecond ?? llama.predictedTokensPerSecond;
  const speed = speedCandidate == null ? null : finite(speedCandidate, Number.NaN);
  const publicUrl = firstString(llama.publicUrl) ?? null;
  return { online: llama.online !== false, model, state: loadedModel || activeId ? "MODEL READY" : "ROUTER READY", speed: Number.isFinite(speed) ? speed : null, publicUrl };
}

function Sparkline({ values, color = "#9ee76f" }: { values: number[]; color?: string }) {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const context = canvas.getContext("2d");
    if (!context) return;

    const render = () => {
      const rect = canvas.getBoundingClientRect();
      const ratio = Math.min(window.devicePixelRatio || 1, 2);
      canvas.width = Math.max(1, Math.round(rect.width * ratio));
      canvas.height = Math.max(1, Math.round(rect.height * ratio));
      context.setTransform(ratio, 0, 0, ratio, 0, 0);
      context.clearRect(0, 0, rect.width, rect.height);

      context.strokeStyle = "rgba(221,238,220,.08)";
      context.lineWidth = 1;
      for (let index = 1; index < 4; index += 1) {
        const y = (rect.height / 4) * index;
        context.beginPath(); context.moveTo(0, y); context.lineTo(rect.width, y); context.stroke();
      }
      if (values.length < 2) return;

      const points = values.slice(-HISTORY_LIMIT);
      const step = rect.width / Math.max(points.length - 1, 1);
      const yFor = (value: number) => rect.height - Math.min(100, Math.max(0, value)) / 100 * (rect.height - 5) - 2;
      const gradient = context.createLinearGradient(0, 0, 0, rect.height);
      gradient.addColorStop(0, "rgba(158,231,111,.25)"); gradient.addColorStop(1, "rgba(158,231,111,0)");
      context.beginPath(); context.moveTo(0, rect.height); points.forEach((value, index) => context.lineTo(index * step, yFor(value))); context.lineTo(rect.width, rect.height); context.closePath(); context.fillStyle = gradient; context.fill();
      context.beginPath(); points.forEach((value, index) => index === 0 ? context.moveTo(0, yFor(value)) : context.lineTo(index * step, yFor(value)));
      context.strokeStyle = color; context.lineWidth = 1.6; context.lineJoin = "round"; context.stroke();
    };

    render();
    const observer = new ResizeObserver(render); observer.observe(canvas);
    return () => observer.disconnect();
  }, [values, color]);

  return <canvas className="sparkCanvas" ref={canvasRef} role="img" aria-label="Recent GPU utilization chart" />;
}

function AccessGate({ state, message, onConnect }: { state: ConnectionState; message: string; onConnect: (key: string, remember: boolean) => void }) {
  const [key, setKey] = useState("");
  const [remember, setRemember] = useState(false);
  const submit = (event: FormEvent) => { event.preventDefault(); if (key.trim()) onConnect(key.trim(), remember); };
  return (
    <main className="accessShell">
      <div className="accessGlow" />
      <section className="accessCard" aria-labelledby="access-title">
        <span className="accessMark">G</span>
        <p className="eyebrow"><span>PRIVATE LAN</span> GPU CLUSTER</p>
        <h1 id="access-title">Enter the<br /><em>observatory.</em></h1>
        <p className="accessIntro">Use the dashboard key created during setup. Metrics are read-only and stay inside your network.</p>
        <form onSubmit={submit}>
          <label htmlFor="dashboard-key">Dashboard access key</label>
          <div className="keyRow"><input id="dashboard-key" type="password" value={key} onChange={(event) => setKey(event.target.value)} autoComplete="current-password" placeholder="Paste access key" autoFocus /><button disabled={!key.trim() || state === "connecting"}>{state === "connecting" ? "Checking…" : "Connect"}</button></div>
          <label className="remember"><input type="checkbox" checked={remember} onChange={(event) => setRemember(event.target.checked)} /><span>Remember on this browser</span></label>
        </form>
        {message && <p className={`accessMessage ${state === "denied" ? "error" : ""}`}>{message}</p>}
        <footer><span>GPUmates</span><span>LAN only · read-only</span></footer>
      </section>
    </main>
  );
}

export default function Dashboard() {
  const [snapshot, setSnapshot] = useState<ClusterSnapshot | null>(null);
  const [accessKey, setAccessKey] = useState("");
  const [connection, setConnection] = useState<ConnectionState>("locked");
  const [message, setMessage] = useState("");
  const [history, setHistory] = useState<Record<string, number[]>>({});
  const [lastUpdated, setLastUpdated] = useState<Date | null>(null);
  const requestInFlight = useRef(false);

  useEffect(() => {
    const saved = localStorage.getItem(STORAGE_KEY) || sessionStorage.getItem(STORAGE_KEY) || "";
    if (saved) { setAccessKey(saved); setConnection("connecting"); }
  }, []);

  const fetchSnapshot = useCallback(async (key: string) => {
    if (!key || requestInFlight.current) return;
    requestInFlight.current = true;
    try {
      const response = await fetch("/api/v1/cluster", { headers: { "X-GPUmates-Key": key }, cache: "no-store" });
      if (response.status === 401 || response.status === 403) {
        localStorage.removeItem(STORAGE_KEY); sessionStorage.removeItem(STORAGE_KEY);
        setAccessKey(""); setSnapshot(null); setConnection("denied");
        setMessage("That key was not accepted. Check the setup key and try again.");
        return;
      }
      if (!response.ok) throw new Error(`Dashboard returned ${response.status}`);
      const next = await response.json() as ClusterSnapshot;
      if (!Array.isArray(next.nodes)) throw new Error("Unexpected metrics response");
      setSnapshot(next); setLastUpdated(new Date()); setConnection("live"); setMessage("");
      setHistory((current) => {
        const updated = { ...current };
        next.nodes.forEach((node) => {
          const id = node.node?.ip || node.node?.name;
          const load = finite(node.gpu?.[0]?.utilizationPct);
          updated[id] = [...(updated[id] ?? []), node.online ? load : 0].slice(-HISTORY_LIMIT);
        });
        return updated;
      });
    } catch (error) {
      setConnection((current) => current === "live" ? "stale" : "connecting");
      setMessage(error instanceof Error ? error.message : "Unable to reach the coordinator");
    } finally {
      requestInFlight.current = false;
    }
  }, []);

  useEffect(() => {
    if (!accessKey) return;
    void fetchSnapshot(accessKey);
    const timer = window.setInterval(() => void fetchSnapshot(accessKey), 2000);
    return () => window.clearInterval(timer);
  }, [accessKey, fetchSnapshot]);

  const connect = (key: string, remember: boolean) => {
    localStorage.removeItem(STORAGE_KEY); sessionStorage.removeItem(STORAGE_KEY);
    (remember ? localStorage : sessionStorage).setItem(STORAGE_KEY, key);
    setMessage(""); setConnection("connecting"); setAccessKey(key);
  };

  const lock = () => { localStorage.removeItem(STORAGE_KEY); sessionStorage.removeItem(STORAGE_KEY); setAccessKey(""); setSnapshot(null); setConnection("locked"); };

  const nodes = snapshot?.nodes ?? [];
  const onlineNodes = nodes.filter((node) => node.online).length;
  const allGpus = nodes.flatMap((node) => node.online ? node.gpu ?? [] : []);
  const memoryUsed = snapshot?.totals?.gpuMemoryUsedMiB ?? allGpus.reduce((sum, gpu) => sum + finite(gpu.memoryUsedMiB), 0);
  const memoryTotal = snapshot?.totals?.gpuMemoryTotalMiB ?? allGpus.reduce((sum, gpu) => sum + finite(gpu.memoryTotalMiB), 0);
  const utilization = snapshot?.totals?.weightedGpuUtilizationPct ?? (allGpus.length ? allGpus.reduce((sum, gpu) => sum + finite(gpu.utilizationPct), 0) / allGpus.length : 0);
  const llama = useMemo(() => parseLlama(snapshot?.llama), [snapshot?.llama]);

  if (!accessKey || (!snapshot && connection !== "live")) return <AccessGate state={connection} message={message} onConnect={connect} />;

  return (
    <main className="shell">
      <header className="topbar">
        <a className="brand" href="#top" aria-label="GPUmates dashboard home"><span className="brandMark" aria-hidden="true">G</span><span>GPUmates</span><span className="brandSection">Cluster observatory</span></a>
        <div className="topActions">
          <span className={`statusPill ${connection === "stale" ? "warning" : ""}`}><i /> {onlineNodes} / {nodes.length} nodes online</span>
          <button className="keyButton" onClick={lock} title="Forget access key">Lock</button>
          {llama.publicUrl
            ? <a className="chatButton" href={llama.publicUrl} target="_blank" rel="noreferrer">Open chat <span>↗</span></a>
            : <span className="chatButton chatUnavailable" title="The model UI is currently bound to PC1 only">Chat: PC1 only</span>}
        </div>
      </header>

      <section className="hero" id="top">
        <div><p className="eyebrow"><span>{connection === "live" ? "LIVE" : "STALE"}</span> DISTRIBUTED INFERENCE</p><h1>The whole cluster,<br /><em>at a glance.</em></h1><p className="lede">Every GPU, model and machine in one calm, shared view—without leaving your local network.</p></div>
        <div className="heroStats" aria-label="Cluster summary">
          <article><span>GPU compute</span><strong>{Math.round(utilization)}<small>%</small></strong><p>Across {allGpus.length} GPU{allGpus.length === 1 ? "" : "s"}</p></article>
          <article><span>VRAM allocated</span><strong>{formatGiB(memoryUsed)}<small> / {formatGiB(memoryTotal)} GB</small></strong><p>{formatGiB(Math.max(0, memoryTotal - memoryUsed))} GB currently free</p></article>
          <article><span>Generation</span><strong>{llama.speed == null ? "—" : llama.speed.toFixed(1)}<small> tok/s</small></strong><p>{llama.model}</p></article>
        </div>
      </section>

      <section className={`modelStrip ${llama.online ? "" : "offlineStrip"}`} aria-label="Active model">
        <div className="modelPulse"><span /></div><div className="modelIdentity"><p>LLAMA.CPP ROUTER</p><strong>{llama.model}</strong></div>
        <div className="modelMeta"><span>{allGpus.length}-GPU cluster</span><span>{formatGiB(memoryTotal)} GB VRAM</span><span>read-only metrics</span></div><p className="modelState">{llama.state}</p>
      </section>

      <section className="nodesSection">
        <div className="sectionHeading"><div><p className="eyebrow">NODES</p><h2>GPU fleet</h2></div><p>{lastUpdated ? `Updated ${lastUpdated.toLocaleTimeString()}` : "Waiting for sample"} <span>•</span> every 2 seconds</p></div>
        <div className="nodeGrid">
          {nodes.map((node, index) => {
            const gpu = node.gpu?.[0];
            const hasLoad = gpu?.utilizationPct != null;
            const load = finite(gpu?.utilizationPct);
            const used = finite(gpu?.memoryUsedMiB);
            const total = finite(gpu?.memoryTotalMiB);
            const systemUsed = finite(node.system?.memoryUsedBytes);
            const systemTotal = finite(node.system?.memoryTotalBytes);
            return (
              <article className={`nodeCard ${node.online ? "" : "nodeOffline"}`} key={node.node.ip || node.node.name}>
                <header><div><p>{node.node.role || `WORKER ${String(index).padStart(2, "0")}`}</p><h3>{node.node.name}</h3><span>{node.node.ip}</span></div><span className="online"><i /> {node.online ? "ONLINE" : "OFFLINE"}</span></header>
                {node.online && gpu ? <>
                  <div className="gpuTitle"><span>GPU {gpu.index ?? 0}</span><strong>{gpu.name}</strong></div>
                  <div className="utilRow"><div className="dial" style={{ "--value": `${Math.min(100, load) * 3.6}deg` } as React.CSSProperties}><div><strong>{hasLoad ? Math.round(load) : "—"}</strong><span>{hasLoad ? "%" : ""}</span><small>GPU LOAD</small></div></div><div className="sparkPanel"><p>UTILIZATION · 15 MIN</p><Sparkline values={history[node.node.ip] ?? [load, load]} /></div></div>
                  <div className="vramBlock"><p><span>VRAM</span><strong>{formatGiB(used)} <small>/ {formatGiB(total)} GB</small></strong></p><div><i style={{ width: `${total ? Math.min(100, used / total * 100) : 0}%` }} /></div></div>
                  <div className="metricRow"><div><span>Temperature</span><strong>{gpu.temperatureC == null ? "—" : Math.round(finite(gpu.temperatureC))}<small>{gpu.temperatureC == null ? "" : "°C"}</small></strong></div><div><span>Power draw</span><strong>{gpu.powerDrawW == null ? "—" : Math.round(finite(gpu.powerDrawW))}<small>{gpu.powerDrawW == null ? "" : " W"}</small></strong></div><div><span>Fan</span><strong>{gpu.fanPct == null ? "—" : Math.round(finite(gpu.fanPct))}<small>{gpu.fanPct == null ? "" : "%"}</small></strong></div></div>
                  <div className="systemRow"><span>CPU <strong>{node.system?.cpuUtilizationPct == null ? "—" : `${Math.round(finite(node.system.cpuUtilizationPct))}%`}</strong></span><span>RAM <strong>{systemTotal ? `${(systemUsed / systemTotal * 100).toFixed(0)}%` : "—"}</strong></span><span>NET ↓ <strong>{formatBytes(node.system?.networkRxBytesPerSec)}{node.system?.networkRxBytesPerSec == null ? "" : "/s"}</strong></span><span>↑ <strong>{formatBytes(node.system?.networkTxBytesPerSec)}{node.system?.networkTxBytesPerSec == null ? "" : "/s"}</strong></span></div>
                </> : <div className="offlineBody"><strong>Node unavailable</strong><p>{node.error || "The telemetry agent did not answer this sample."}</p><span>Last checked {new Date(snapshot?.timestamp ?? Date.now()).toLocaleTimeString()}</span></div>}
              </article>
            );
          })}
        </div>
      </section>
      <footer><span>GPUmates / LAN only</span><span>{connection === "stale" ? "Showing last good sample" : "Read-only telemetry"}</span></footer>
    </main>
  );
}
