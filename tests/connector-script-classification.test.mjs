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
