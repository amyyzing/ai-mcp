import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const lifecyclePath = new URL("../connector-src/mapping/lifecycle.luau", import.meta.url);
const scriptHandlerPath = new URL(
  "../connector-src/bridge/handlers/scripts.luau",
  import.meta.url
);

test("script mapping distinguishes LocalScript from Script by exact class", async () => {
  const [lifecycle, scriptHandler] = await Promise.all([
    readFile(lifecyclePath, "utf8"),
    readFile(scriptHandlerPath, "utf8"),
  ]);

  assert.match(lifecycle, /script\.ClassName == "Script"/);
  assert.doesNotMatch(lifecycle, /script:IsA\("Script"\)/);
  assert.match(scriptHandler, /scriptInstance\.ClassName == "Script"/);
  assert.doesNotMatch(scriptHandler, /scriptInstance:IsA\("Script"\)/);
});

test("connector automatically probes WebSocket variants and cools down failures", async () => {
  const [init, client] = await Promise.all([
    readFile(new URL("../connector-src/init.luau", import.meta.url), "utf8"),
    readFile(new URL("../connector-src/bridge/client.luau", import.meta.url), "utf8"),
  ]);

  assert.match(init, /ResolveWebSocketConnect/);
  assert.match(init, /websocket\.connect/);
  assert.match(init, /syn\.websocket\.connect/);
  assert.match(init, /WebSocketConnect = WebSocketConnect/);
  assert.match(client, /return WebSocketConnect\(websocketUrl\)/);
  assert.match(client, /connectionFinished/);
  assert.match(client, /websocketRetryDelay = 30/);
  assert.match(client, /return HTTPBridge\.new\(\)/);
});

test("connector normalizes common desktop and mobile HTTP executor APIs", async () => {
  const [init, executorHttp, client, capabilities] = await Promise.all([
    readFile(new URL("../connector-src/init.luau", import.meta.url), "utf8"),
    readFile(new URL("../connector-src/runtime/executor-http.luau", import.meta.url), "utf8"),
    readFile(new URL("../connector-src/bridge/client.luau", import.meta.url), "utf8"),
    readFile(new URL("../connector-src/runtime/capabilities.luau", import.meta.url), "utf8"),
  ]);

  for (const provider of [
    "environment.request",
    "environment.http_request",
    "environment.httprequest",
    'name = "http.request"',
    'name = "syn.request"',
    'name = "fluxus.request"',
    'name = "krnl.request"',
  ]) {
    assert.match(executorHttp, new RegExp(provider.replaceAll(".", "\\.")));
  }
  assert.match(executorHttp, /response\.StatusCode or response\.Status/);
  assert.match(executorHttp, /response\.Body or response\.body/);
  assert.match(init, /Request = ExecutorRequest/);
  assert.match(client, /This executor exposes neither a working WebSocket nor a supported HTTP request API/);
  assert.match(client, /Body = HttpGet\(BridgeHTTPURL\)/);
  assert.match(capabilities, /self\.HttpRequestProvider/);
});
