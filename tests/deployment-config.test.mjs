import assert from "node:assert/strict";
import fs from "node:fs/promises";
import test from "node:test";

import { GET as getHealth, setPrimaryReady } from "../dist/http/routes/health.js";

const deploymentKeys = [
  "ROBLOX_MCP_PORT",
  "ROBLOX_MCP_HOST",
  "RAILWAY_ENVIRONMENT_ID",
  "RAILWAY_PROJECT_ID",
  "RAILWAY_PUBLIC_DOMAIN",
  "PORT",
  "HOST",
];
let importSerial = 0;

async function configuration(overrides = {}) {
  const previous = new Map(deploymentKeys.map((key) => [key, process.env[key]]));
  try {
    for (const key of deploymentKeys) delete process.env[key];
    Object.assign(process.env, overrides);
    const config = await import(`../dist/config.js?deployment-test=${++importSerial}`);
    return { port: config.WS_PORT, host: config.BRIDGE_HOST };
  } finally {
    for (const [key, value] of previous) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

test("local bridge defaults ignore unrelated PORT and HOST variables", async () => {
  assert.deepEqual(await configuration(), { port: 16384, host: "127.0.0.1" });
  assert.deepEqual(await configuration({ PORT: "3000", HOST: "0.0.0.0" }), {
    port: 16384,
    host: "127.0.0.1",
  });
  assert.deepEqual(await configuration({
    RAILWAY_PUBLIC_DOMAIN: "example.up.railway.app",
    RAILWAY_ENVIRONMENT_ID: " ",
    RAILWAY_PROJECT_ID: "",
    PORT: "3000",
  }), { port: 16384, host: "127.0.0.1" }, "a domain alone must not widen the bind address");
});

test("Railway deployment markers enable PORT and public binding fallbacks", async () => {
  for (const marker of ["RAILWAY_ENVIRONMENT_ID", "RAILWAY_PROJECT_ID"]) {
    assert.deepEqual(await configuration({ [marker]: "test-deployment", PORT: "3000" }), {
      port: 3000,
      host: "0.0.0.0",
    });
  }
  assert.deepEqual(await configuration({ RAILWAY_ENVIRONMENT_ID: "test-deployment" }), {
    port: 16384,
    host: "0.0.0.0",
  });
});

test("explicit bridge host and port take precedence on Railway and locally", async () => {
  const explicit = { ROBLOX_MCP_PORT: " 16834 ", ROBLOX_MCP_HOST: " 127.0.0.2 " };
  assert.deepEqual(await configuration(explicit), { port: 16834, host: "127.0.0.2" });
  assert.deepEqual(await configuration({ ...explicit, RAILWAY_PROJECT_ID: "test", PORT: "3000" }), {
    port: 16834,
    host: "127.0.0.2",
  });
  assert.deepEqual(await configuration({
    RAILWAY_PROJECT_ID: "test",
    PORT: "3000",
    ROBLOX_MCP_PORT: "not-a-port",
    ROBLOX_MCP_HOST: " ",
  }), { port: 3000, host: "0.0.0.0" });
});

test("invalid platform ports never become an invalid listen port", async () => {
  for (const port of ["0", "65536", "1.5", "NaN", "-1", " "]) {
    assert.deepEqual(await configuration({ RAILWAY_ENVIRONMENT_ID: "test", PORT: port }), {
      port: 16384,
      host: "0.0.0.0",
    });
  }
});

function response() {
  return {
    statusCode: null,
    headers: null,
    body: null,
    writeHead(statusCode, headers) { this.statusCode = statusCode; this.headers = headers; },
    end(body) { this.body = body; },
  };
}

test("health readiness is explicit and discloses only minimal status", () => {
  try {
    setPrimaryReady(false);
    const starting = response();
    getHealth({}, starting);
    assert.equal(starting.statusCode, 503);
    assert.deepEqual(JSON.parse(starting.body), { status: "starting" });
    assert.equal(starting.headers["Cache-Control"], "no-store");

    setPrimaryReady(true);
    const ready = response();
    getHealth({}, ready);
    assert.equal(ready.statusCode, 200);
    assert.deepEqual(JSON.parse(ready.body), { status: "ready" });
    assert.match(ready.headers["Content-Type"], /^application\/json/);

    setPrimaryReady(false);
    const stopped = response();
    getHealth({}, stopped);
    assert.equal(stopped.statusCode, 503);
  } finally {
    setPrimaryReady(false);
  }
});

test("primary marks readiness after route and WebSocket setup without logging pairing credentials", async () => {
  const primary = await fs.readFile(new URL("../src/bridge/handlers/server/primary.ts", import.meta.url), "utf8");
  const routesReady = primary.indexOf("await loadRoutes()");
  const listening = primary.indexOf("httpServer.listen(");
  const wsReady = primary.indexOf('wss.on("connection"');
  const ready = primary.indexOf("setPrimaryReady(true)");
  assert.ok(routesReady >= 0 && routesReady < listening);
  assert.ok(wsReady > listening && wsReady < ready);
  assert.match(primary, /httpServer\.on\("close", \(\) => setPrimaryReady\(false\)\)/);
  assert.doesNotMatch(primary, /getBridgeAuthToken|pairing token for this run:/);
  assert.match(primary, /Configure ROBLOX_MCP_AUTH_TOKEN and a separate ROBLOX_MCP_CONNECTOR_TOKEN/);
});
