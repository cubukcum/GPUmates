import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const source = await readFile(new URL("../gpu-bar.js", import.meta.url), "utf8");
const snapshot = () => ({
  schemaVersion: 1,
  timestamp: new Date().toISOString(),
  nodes: [{
    online: true,
    node: { name: "PC1", ip: "192.168.1.10", role: "coordinator" },
    gpu: [0, 1].map((index) => ({ index, name: "Test GPU", utilizationPct: 35, memoryUsedMiB: 1024, memoryTotalMiB: 8192, temperatureC: null, powerDrawW: null })),
  }],
});

function harness(fetch) {
  let Widget;
  const timers = new Set();
  const storage = new Map();
  const document = { hidden: false, readyState: "loading", addEventListener() {} };
  vm.runInNewContext(source, {
    customElements: { get() {}, define(name, widget) { Widget = widget; } },
    HTMLElement: class { isConnected = true; attachShadow() {} },
    AbortController, document, fetch,
    sessionStorage: { removeItem: (key) => storage.delete(key) },
    setTimeout: (callback, ms) => { const timer = { callback, ms }; timers.add(timer); return timer; },
    clearTimeout: (timer) => timers.delete(timer),
  });
  const widget = new Widget();
  widget.endpoint = "http://192.168.1.10:8090";
  widget.storageKey = `gpumates-chat-dashboard-key:${widget.endpoint}`;
  widget.key = "dashboard-test-key";
  storage.set(widget.storageKey, widget.key);
  widget.render = () => {};
  return { widget, timers, storage, document };
}

test("polls all GPU readings with only the dashboard header and schedules the next request", async () => {
  const data = snapshot();
  let request;
  const { widget, timers } = harness(async (url, options) => {
    request = { url, options };
    return { ok: true, status: 200, json: async () => data };
  });
  await widget.poll();
  assert.equal(widget.state, "live");
  assert.equal(widget.snapshot.nodes[0].gpu.length, 2);
  assert.equal(widget.snapshot.nodes[0].gpu[0].temperatureC, null);
  assert.equal(request.url, "http://192.168.1.10:8090/api/v1/cluster");
  assert.equal(request.options.headers["X-GPUmates-Key"], "dashboard-test-key");
  assert.deepEqual(Object.keys(request.options.headers), ["X-GPUmates-Key"]);
  assert.equal(request.options.credentials, "omit");
  assert.equal(request.options.redirect, "error");
  assert.equal(request.options.cache, "no-store");
  assert.equal(timers.size, 1);
  assert.equal([...timers][0].ms, 2000);
});

test("rejects malformed payloads and keeps the last good snapshot marked stale", async () => {
  for (const corrupt of [
    (data) => { data.nodes = {}; },
    (data) => { data.timestamp = "not a timestamp"; },
    (data) => { data.nodes[0].gpu[0].utilizationPct = "35"; },
    (data) => { data.nodes[0].gpu[0].memoryUsedMiB = -1; },
    (data) => { data.nodes[0].gpu[0].index = 0.5; },
    (data) => { data.nodes[0].online = "yes"; },
  ]) {
    const data = snapshot();
    corrupt(data);
    const { widget } = harness(async () => ({ ok: true, status: 200, json: async () => data }));
    const previous = snapshot();
    widget.snapshot = previous;
    await widget.poll();
    assert.equal(widget.snapshot, previous);
    assert.equal(widget.state, "stale");
    assert.match(widget.message, /invalid GPU data/);
  }
});

test("offline nodes and missing metrics remain unavailable instead of becoming zero", async () => {
  const data = snapshot();
  data.nodes[0].gpu[0].utilizationPct = null;
  data.nodes.push({ online: false, node: { name: "PC2", ip: "192.168.1.11" }, gpu: [] });
  const { widget } = harness(async () => ({ ok: true, status: 200, json: async () => data }));
  await widget.poll();
  assert.equal(widget.state, "live");
  assert.equal(widget.snapshot.nodes[0].gpu[0].utilizationPct, null);
  assert.equal(widget.snapshot.nodes[1].online, false);
  assert.equal(widget.snapshot.nodes[1].gpu.length, 0);
});

test("authentication failure forgets the key, clears readings, and stops retrying", async () => {
  const { widget, timers, storage } = harness(async () => ({ ok: false, status: 403 }));
  widget.snapshot = snapshot();
  await widget.poll();
  assert.equal(widget.key, "");
  assert.equal(widget.snapshot, null);
  assert.equal(widget.state, "locked");
  assert.equal(storage.size, 0);
  assert.equal(timers.size, 0);
});

test("disconnect prevents an in-flight response from restoring readings or retrying", async () => {
  let resolve;
  const { widget, timers, storage } = harness(() => new Promise((done) => { resolve = done; }));
  const pending = widget.poll();
  const controller = widget.controller;
  widget.forgetKey();
  assert.equal(controller.signal.aborted, true);
  resolve({ ok: true, status: 200, json: async () => snapshot() });
  await pending;
  assert.equal(widget.snapshot, null);
  assert.equal(widget.key, "");
  assert.equal(widget.state, "locked");
  assert.equal(storage.size, 0);
  assert.equal(timers.size, 0);
});

test("does not overlap requests and does not poll a hidden page", async () => {
  let resolve;
  let requests = 0;
  const { widget, document } = harness(() => { requests += 1; return new Promise((done) => { resolve = done; }); });
  const pending = widget.poll();
  await widget.poll();
  assert.equal(requests, 1);
  resolve({ ok: true, status: 200, json: async () => snapshot() });
  await pending;
  document.hidden = true;
  await widget.poll();
  assert.equal(requests, 1);
});
