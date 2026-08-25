import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const readSource = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("connector shows a reload-safe toast only after bridge registration", async () => {
  const [init, runtime, toastHost] = await Promise.all([
    readSource("../connector-src/init.luau"),
    readSource("../connector-src/bridge/runtime.luau"),
    readSource("../connector-src/ui/toast-host.luau"),
  ]);

  assert.match(init, /require\("\.\/ui\/toast-host"\)/);
  assert.match(runtime, /local clientId = WaitForBridgeClientId\(Bridge\)[\s\S]*ToastHost:ShowConnected/);
  assert.match(runtime, /Bridge\.WebSocket and "ws" or "http"/);
  assert.match(toastHost, /local HOST_NAME = "RobloxMCPToastHost"/);
  assert.match(toastHost, /oldHost:Destroy\(\)/);
  assert.match(toastHost, /if self\.Toast then[\s\S]*self\.Toast:Destroy\(\)/);
  assert.match(toastHost, /"MCP connected"/);
});
