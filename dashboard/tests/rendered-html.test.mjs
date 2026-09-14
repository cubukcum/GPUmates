import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import test from "node:test";

async function render() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);
  return worker.fetch(
    new Request("http://172.25.50.14:8090/", { headers: { accept: "text/html" } }),
    { ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) } },
    { waitUntil() {}, passThroughOnException() {} },
  );
}

test("server-renders the private GPUmates access gate", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);
  const html = await response.text();
  assert.match(html, /<title>GPUmates.*Cluster Observatory<\/title>/i);
  assert.match(html, /Dashboard access key/i);
  assert.match(html, /PRIVATE LAN/i);
  assert.match(html, /read-only/i);
  assert.doesNotMatch(html, /codex-preview|Your site is taking shape|react-loading-skeleton/i);
});

test("ships a standalone LAN build and authenticated cluster polling", async () => {
  const [component, packageJson, localHtml, builtHtml] = await Promise.all([
    readFile(new URL("../ui/Dashboard.tsx", import.meta.url), "utf8"),
    readFile(new URL("../package.json", import.meta.url), "utf8"),
    readFile(new URL("../local/index.html", import.meta.url), "utf8"),
    readFile(new URL("../static/index.html", import.meta.url), "utf8"),
  ]);
  assert.match(component, /fetch\("\/api\/v1\/cluster"/);
  assert.match(component, /"X-GPUmates-Key"/);
  assert.match(component, /sessionStorage/);
  assert.match(component, /localStorage/);
  assert.match(component, /HISTORY_LIMIT = 450/);
  assert.match(packageJson, /"build:local"/);
  assert.doesNotMatch(packageJson, /react-loading-skeleton/);
  assert.match(localHtml, /GPUmates.*Cluster Observatory/);
  assert.match(builtHtml, /assets\/index-[A-Za-z0-9_-]+\.js/);
  await assert.rejects(access(new URL("../app/_sites-preview", import.meta.url)));
});
