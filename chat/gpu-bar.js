// Inlined after a <template id="gpumates-gpu-bar-styles"> containing the widget CSS.
(() => {
  "use strict";
  if (customElements.get("gpumates-gpu-bar")) return;
  const POLL_MS = 2000;
  const STALE_MS = 15000;
  const metricNames = ["utilizationPct", "memoryUsedMiB", "memoryTotalMiB", "temperatureC", "powerDrawW"];
  const validNumber = (value) => value == null || (typeof value === "number" && Number.isFinite(value) && value >= 0);
  const validTimestamp = (value) => typeof value === "string" && Number.isFinite(Date.parse(value));
  const display = (value, suffix, divisor = 1, digits = 0) => value == null ? "—" : `${(value / divisor).toFixed(digits)}${suffix}`;
  const memory = (gpu) => `${display(gpu.memoryUsedMiB, "", 1024, 1)} / ${display(gpu.memoryTotalMiB, "", 1024, 1)} GiB`;

  function validateSnapshot(value) {
    if (!value || value.schemaVersion !== 1 || !validTimestamp(value.timestamp) || !Array.isArray(value.nodes)) return false;
    return value.nodes.every((entry) => entry && typeof entry.online === "boolean"
      && entry.node && typeof entry.node.name === "string" && typeof entry.node.ip === "string"
      && (entry.timestamp == null || validTimestamp(entry.timestamp)) && Array.isArray(entry.gpu)
      && entry.gpu.every((gpu) => gpu && Number.isInteger(gpu.index) && gpu.index >= 0 && typeof gpu.name === "string"
        && metricNames.every((name) => validNumber(gpu[name]))
        && (gpu.utilizationPct == null || gpu.utilizationPct <= 100)));
  }

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  class GpuBar extends HTMLElement {
    constructor() {
      super();
      this.attachShadow({ mode: "open" });
      this.key = "";
      this.snapshot = null;
      this.state = "locked";
      this.message = "";
      this.epoch = 0;
      this.onVisibility = () => {
        this.stopRequest();
        if (!document.hidden && this.key) void this.poll();
        this.render();
      };
    }

    connectedCallback() {
      if (this.ready) return;
      this.ready = true;
      const styles = document.getElementById("gpumates-gpu-bar-styles");
      if (styles) this.shadowRoot.append(styles.content.cloneNode(true));
      this.shadowRoot.append(this.build());
      try {
        const configured = document.querySelector('meta[name="gpumates-dashboard-url"]');
        const url = new URL(configured ? configured.content : `${location.protocol}//${location.hostname}:8090`);
        if (!/^https?:$/.test(url.protocol) || url.username || url.password || url.search || url.hash || url.pathname !== "/") throw new Error("Invalid dashboard URL");
        this.endpoint = url.origin;
        this.storageKey = `gpumates-chat-dashboard-key:${this.endpoint}`;
        try { this.key = sessionStorage.getItem(this.storageKey) || ""; } catch { /* Storage may be disabled. */ }
        this.state = this.key ? "connecting" : "locked";
        this.dashboard.href = this.endpoint;
        this.address.textContent = new URL(this.endpoint).host;
      } catch {
        this.message = "The dashboard address is invalid. Rebuild the chat UI with the coordinator address.";
        this.input.disabled = true;
        this.submit.disabled = true;
      }
      const setTheme = () => {
        const root = document.documentElement;
        const dark = root.classList.contains("dark") || root.dataset.theme === "dark"
          || (!root.classList.contains("light") && root.dataset.theme !== "light" && getComputedStyle(root).colorScheme === "dark");
        this.toggleAttribute("dark", dark);
      };
      this.themeObserver = new MutationObserver(setTheme);
      this.themeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ["class", "data-theme", "style"] });
      setTheme();
      document.addEventListener("visibilitychange", this.onVisibility);
      this.render();
      if (this.key && !document.hidden) void this.poll();
    }

    disconnectedCallback() {
      this.stopRequest();
      this.themeObserver?.disconnect();
      document.removeEventListener("visibilitychange", this.onVisibility);
    }

    build() {
      const wrapper = element("section", "widget");
      wrapper.setAttribute("aria-label", "GPU activity");
      const bar = element("div", "bar");
      const brand = element("span", "brand", "GPUs");
      this.indicator = element("span", "indicator");
      this.indicator.setAttribute("aria-hidden", "true");
      brand.prepend(this.indicator);
      this.chips = element("div", "chips");
      this.chips.setAttribute("aria-label", "GPU utilization and memory");
      this.status = element("span", "status");
      this.status.setAttribute("role", "status");
      this.toggle = element("button", "toggle", "Connect GPUs");
      this.toggle.type = "button";
      this.toggle.setAttribute("aria-expanded", "false");
      this.toggle.setAttribute("aria-controls", "gpu-panel");
      this.toggle.addEventListener("click", () => this.expand(this.panel.hidden));
      bar.append(brand, this.chips, this.status, this.toggle);
      this.panel = element("div", "panel");
      this.panel.id = "gpu-panel";
      this.panel.hidden = true;
      const heading = element("div", "panel-heading");
      heading.append(element("strong", "", "GPU activity"));
      const close = element("button", "close", "✕");
      close.type = "button";
      close.setAttribute("aria-label", "Close GPU details");
      close.addEventListener("click", () => this.expand(false));
      heading.append(close);
      this.form = element("form", "connect-form");
      const label = element("label", "", "Dashboard access key");
      label.htmlFor = "dashboard-key";
      this.input = element("input", "key-input");
      this.input.id = "dashboard-key";
      this.input.type = "password";
      this.input.autocomplete = "off";
      this.input.placeholder = "Paste dashboard key";
      this.input.required = true;
      this.input.setAttribute("aria-describedby", "key-help");
      this.submit = element("button", "primary", "Connect");
      this.submit.type = "submit";
      const keyRow = element("div", "key-row");
      keyRow.append(this.input, this.submit);
      const help = element("p", "muted", "Use the dashboard key from GPUmates setup. Kept only for this tab’s session.");
      help.id = "key-help";
      this.form.append(label, keyRow, help);
      this.form.addEventListener("submit", (event) => {
        event.preventDefault();
        const key = this.input.value.trim();
        if (!key || !this.endpoint) return;
        this.stopRequest();
        this.key = key;
        this.input.value = "";
        this.state = "connecting";
        this.message = "";
        try { sessionStorage.setItem(this.storageKey, key); } catch { /* In-memory use still works. */ }
        this.render();
        this.toggle.focus();
        if (!document.hidden) void this.poll();
      });
      this.notice = element("p", "notice");
      this.notice.setAttribute("role", "status");
      this.cards = element("div", "cards");
      this.footer = element("div", "panel-footer");
      this.updated = element("span", "muted");
      this.disconnect = element("button", "text-button", "Disconnect");
      this.disconnect.type = "button";
      this.disconnect.addEventListener("click", () => {
        this.forgetKey();
        this.message = "";
        this.render();
        this.input.focus();
      });
      this.footer.append(this.updated, this.disconnect);
      const source = element("div", "source muted");
      this.dashboard = element("a", "", "Open dashboard ↗");
      this.dashboard.target = "_blank";
      this.dashboard.rel = "noopener noreferrer";
      this.address = element("span");
      source.append(this.dashboard, this.address);
      this.panel.append(heading, this.form, this.notice, this.cards, this.footer, source);
      wrapper.append(bar, this.panel);
      wrapper.addEventListener("keydown", (event) => {
        if (event.key === "Escape" && !this.panel.hidden) { event.preventDefault(); this.expand(false); }
      });
      return wrapper;
    }

    expand(open) {
      this.panel.hidden = !open;
      this.toggle.setAttribute("aria-expanded", String(open));
      this.render();
      if (!open) this.toggle.focus();
      else if (!this.key) this.input.focus();
    }

    stopRequest() {
      this.epoch += 1;
      clearTimeout(this.timer);
      this.controller?.abort();
      this.controller = null;
    }

    forgetKey() {
      this.stopRequest();
      try { sessionStorage.removeItem(this.storageKey); } catch { /* Storage may be disabled. */ }
      this.key = "";
      this.snapshot = null;
      this.state = "locked";
    }

    async poll() {
      if (!this.key || document.hidden || this.controller || !this.isConnected) return;
      const epoch = this.epoch;
      const controller = new AbortController();
      this.controller = controller;
      const timeout = setTimeout(() => controller.abort(), 5000);
      try {
        const response = await fetch(`${this.endpoint}/api/v1/cluster`, {
          headers: { "X-GPUmates-Key": this.key }, signal: controller.signal,
          credentials: "omit", mode: "cors", cache: "no-store", redirect: "error",
        });
        if (epoch !== this.epoch) return;
        if (response.status === 401 || response.status === 403) {
          this.forgetKey();
          this.message = "That dashboard key was not accepted. Check the setup key and reconnect.";
          this.render();
          return;
        }
        if (!response.ok) throw new Error("Dashboard unavailable");
        const snapshot = await response.json();
        if (epoch !== this.epoch) return;
        if (!validateSnapshot(snapshot)) throw new Error("Invalid GPU data");
        this.snapshot = snapshot;
        this.state = "live";
        this.message = "";
      } catch (error) {
        if (epoch !== this.epoch) return;
        this.state = "stale";
        this.message = error.message === "Invalid GPU data"
          ? "The dashboard returned invalid GPU data. Retrying…"
          : "Dashboard unavailable. Check that GPUmates is running and this chat address is allowed. Retrying…";
      } finally {
        clearTimeout(timeout);
        if (epoch === this.epoch) {
          this.controller = null;
          this.render();
          if (this.key && !document.hidden && this.isConnected) this.timer = setTimeout(() => void this.poll(), POLL_MS);
        }
      }
    }

    render() {
      const now = Date.now();
      const stale = this.state === "stale" || (this.snapshot && now - Date.parse(this.snapshot.timestamp) > STALE_MS);
      const state = document.hidden && this.key ? "paused" : stale ? "stale" : this.state;
      this.indicator.dataset.state = state;
      this.status.textContent = ({ live: "Live", stale: "Stale", connecting: "Connecting…", paused: "Paused", locked: "" })[state];
      this.toggle.textContent = !this.panel.hidden ? "Close" : this.key ? "Details" : "Connect GPUs";
      this.form.hidden = Boolean(this.key);
      this.footer.hidden = !this.key;
      this.notice.textContent = this.message || (stale ? "Readings are older than 15 seconds. Waiting for fresh data…" : this.key ? "Overall GPU activity, including other applications." : "");
      this.notice.hidden = !this.notice.textContent;
      this.chips.replaceChildren();
      this.cards.replaceChildren();
      if (!this.snapshot) {
        this.chips.append(element("span", "hint", this.key ? "Waiting for GPU readings…" : "Your cluster, while you chat"));
      }
      for (const node of this.snapshot?.nodes || []) {
        const nodeStale = stale || (node.timestamp && now - Date.parse(node.timestamp) > STALE_MS);
        const nodeState = !node.online ? "Offline" : nodeStale ? "Stale" : "";
        if (!node.gpu.length) {
          this.chips.append(element("span", "chip unavailable", `${node.node.name} · ${nodeState || "No GPUs"}`));
          this.cards.append(element("div", "gpu-card muted", `${node.node.name} · ${nodeState || "No GPU readings"}`));
        }
        for (const gpu of node.gpu) {
          const title = `${node.node.name} · GPU ${gpu.index}`;
          const chip = element("span", `chip${nodeState ? " unavailable" : ""}`);
          chip.title = `${title} · ${gpu.name}${nodeState ? ` · ${nodeState}` : ""}`;
          const usage = !node.online ? "—" : display(gpu.utilizationPct, "%");
          chip.append(element("span", "chip-name", title), element("strong", "utilization", usage));
          chip.append(element("span", "vram", node.online ? memory(gpu) : "VRAM —"));
          if (nodeState) chip.append(element("span", "badge", nodeState));
          this.chips.append(chip);
          const card = element("article", "gpu-card");
          card.append(element("strong", "", `${title}${nodeState ? ` · ${nodeState}` : ""}`), element("span", "gpu-name muted", gpu.name));
          const metrics = element("dl", "metrics");
          for (const [label, value] of [["Utilization", usage], ["VRAM", memory(gpu)], ["Temperature", display(gpu.temperatureC, " °C")], ["Power", display(gpu.powerDrawW, " W")]]) {
            metrics.append(element("dt", "muted", label), element("dd", "", node.online ? value : "—"));
          }
          card.append(metrics);
          if (node.timestamp) card.append(element("span", "muted sampled", `Sampled ${new Date(node.timestamp).toLocaleTimeString()}`));
          this.cards.append(card);
        }
      }
      if (this.snapshot && !this.snapshot.nodes.length) this.chips.append(element("span", "hint", "No nodes reported"));
      this.updated.textContent = this.snapshot ? `Updated ${new Date(this.snapshot.timestamp).toLocaleTimeString()}` : "Waiting for first update";
    }
  }

  customElements.define("gpumates-gpu-bar", GpuBar);
  const mount = () => { if (!document.querySelector("gpumates-gpu-bar")) document.body.append(document.createElement("gpumates-gpu-bar")); };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", mount, { once: true });
  else mount();
})();
