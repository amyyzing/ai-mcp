import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import test, { after } from "node:test";
import { pathToFileURL } from "node:url";

const repoRoot = path.resolve(import.meta.dirname, "..");
const coreEntry = path.join(repoRoot, "dist", "core.js");
const adapterEntry = path.join(repoRoot, "dist", "index.js");
const trackedCorePids = new Set();
const allocatedTestPorts = new Set();

async function availablePort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  assert.ok(address && typeof address === "object");
  const { port } = address;
  await new Promise((resolve) => server.close(resolve));
  allocatedTestPorts.add(port);
  return port;
}

async function waitForCore(url, predicate = () => true) {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`${url}/api/server-info`);
      if (response.ok) {
        const data = await response.json();
        if (data.architecture === "background-core" && predicate(data)) return data;
      }
    } catch {
      // The core is still starting.
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error("Background core did not reach the expected state.");
}

async function stopChild(child, signal = "SIGTERM") {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  const closed = new Promise((resolve) => child.once("close", resolve));
  child.kill(signal);
  await Promise.race([
    closed,
    new Promise((resolve) => setTimeout(resolve, 2_000)),
  ]);
}

async function stopPid(pid, signal = "SIGTERM") {
  if (!Number.isInteger(pid) || pid <= 0) return;
  try {
    process.kill(pid, signal);
  } catch {
    trackedCorePids.delete(pid);
    return;
  }
  for (let attempt = 0; attempt < 40; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 50));
    try {
      process.kill(pid, 0);
    } catch {
      trackedCorePids.delete(pid);
      return;
    }
  }
}

after(async () => {
  for (const pid of [...trackedCorePids]) {
    await stopPid(pid, "SIGKILL");
  }
  // An adapter can race with shutdown and spawn one final detached fallback
  // core. Only inspect ephemeral ports reserved by this test process.
  await new Promise((resolve) => setTimeout(resolve, 300));
  for (const port of allocatedTestPorts) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/api/server-info`, {
        signal: AbortSignal.timeout(300),
      });
      if (!response.ok) continue;
      const info = await response.json();
      if (info?.architecture === "background-core" && Number.isInteger(info.pid)) {
        await stopPid(info.pid, "SIGKILL");
      }
    } catch {
      // Nothing from this test remains on the port.
    }
  }
});

function createMessageReader(stream) {
  const lines = readline.createInterface({ input: stream });
  const queue = [];
  const waiters = [];

  lines.on("line", (line) => {
    const message = JSON.parse(line);
    const waiter = waiters.shift();
    if (waiter) waiter.resolve(message);
    else queue.push(message);
  });
  lines.on("close", () => {
    for (const waiter of waiters.splice(0)) {
      waiter.reject(new Error("Adapter stdout closed."));
    }
  });

  return () => {
    const message = queue.shift();
    if (message) return Promise.resolve(message);
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        const index = waiters.findIndex((waiter) => waiter.resolve === complete);
        if (index >= 0) waiters.splice(index, 1);
        reject(new Error("Timed out waiting for an adapter response."));
      }, 10_000);
      const complete = (value) => {
        clearTimeout(timeout);
        resolve(value);
      };
      const fail = (error) => {
        clearTimeout(timeout);
        reject(error);
      };
      waiters.push({ resolve: complete, reject: fail });
    });
  };
}

function launchAdapter(environment, serverName, extraArgs = []) {
  const adapter = spawn(
    process.execPath,
    [adapterEntry, "--server-name", serverName, ...extraArgs],
    {
      cwd: repoRoot,
      env: environment,
      stdio: ["pipe", "pipe", "pipe"],
    }
  );
  adapter.stderr.on("data", (chunk) => {
    if (process.env.DEBUG_STDIO_ADAPTER_TEST) {
      process.stderr.write(chunk);
    }
  });
  return { adapter, nextMessage: createMessageReader(adapter.stdout) };
}

async function initializeAdapter(connection, id = 1) {
  connection.adapter.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0",
    id,
    method: "initialize",
    params: {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: { name: "adapter-test-client", version: "1.0.0" },
    },
  })}\n`);
  const initialization = await connection.nextMessage();
  connection.adapter.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0",
    method: "notifications/initialized",
    params: {},
  })}\n`);
  return initialization;
}

async function nextResponseFor(connection, ids) {
  const expected = new Set(ids);
  for (let attempt = 0; attempt < 10; attempt += 1) {
    const message = await connection.nextMessage();
    if (expected.has(message.id)) return message;
  }
  throw new Error(`Adapter did not return response ${ids.join(" or ")}.`);
}

function launchCore(environment) {
  const core = spawn(process.execPath, [coreEntry], {
    cwd: repoRoot,
    env: environment,
    stdio: ["ignore", "ignore", "pipe"],
  });
  core.stderr.on("data", (chunk) => {
    if (process.env.DEBUG_STDIO_ADAPTER_TEST) {
      process.stderr.write(chunk);
    }
  });
  if (core.pid) {
    trackedCorePids.add(core.pid);
    core.once("close", () => trackedCorePids.delete(core.pid));
  }
  return core;
}

async function launchCancellationProbeCore() {
  let slowStartedResolve;
  let cancellationResolve;
  const slowStarted = new Promise((resolve) => {
    slowStartedResolve = resolve;
  });
  const cancellationReceived = new Promise((resolve) => {
    cancellationResolve = resolve;
  });
  const server = http.createServer((request, response) => {
    if (request.url === "/api/server-info") {
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(JSON.stringify({ architecture: "background-core" }));
      return;
    }
    if (request.url !== "/mcp") {
      response.writeHead(404);
      response.end();
      return;
    }
    if (request.method === "GET") {
      response.writeHead(405);
      response.end();
      return;
    }
    if (request.method === "DELETE") {
      response.writeHead(200);
      response.end();
      return;
    }

    let body = "";
    request.setEncoding("utf8");
    request.on("data", (chunk) => {
      body += chunk;
    });
    request.on("end", () => {
      const message = JSON.parse(body);
      const headers = {
        "Content-Type": "application/json",
        "Mcp-Session-Id": "cancellation-probe",
      };
      if (message.method === "initialize") {
        response.writeHead(200, headers);
        response.end(JSON.stringify({
          jsonrpc: "2.0",
          id: message.id,
          result: {
            protocolVersion: "2025-06-18",
            capabilities: {},
            serverInfo: { name: "probe-core", version: "1.0.0" },
          },
        }));
        return;
      }
      if (message.method === "notifications/initialized") {
        response.writeHead(202, headers);
        response.end();
        return;
      }
      if (message.method === "probe/slow") {
        slowStartedResolve();
        setTimeout(() => {
          response.writeHead(200, headers);
          response.end(JSON.stringify({
            jsonrpc: "2.0",
            id: message.id,
            result: { completed: true },
          }));
        }, 800);
        return;
      }
      if (message.method === "notifications/cancelled") {
        cancellationResolve();
        response.writeHead(202, headers);
        response.end();
        return;
      }
      response.writeHead(400);
      response.end();
    });
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  assert.ok(address && typeof address === "object");
  return {
    server,
    url: `http://127.0.0.1:${address.port}`,
    slowStarted,
    cancellationReceived,
  };
}

async function launchUpdateLock(home) {
  const statusModule = pathToFileURL(
    path.join(repoRoot, "src", "shared", "update-status.mjs")
  ).href;
  const source = `
    const status = await import(${JSON.stringify(statusModule)});
    await status.acquireUpdateLock("adapter-cutover-test");
    console.log("locked");
    process.stdin.resume();
    process.stdin.once("end", async () => {
      await status.releaseUpdateLock("adapter-cutover-test");
      process.exit(0);
    });
  `;
  const holder = spawn(
    process.execPath,
    ["--input-type=module", "-e", source],
    {
      env: { ...process.env, HOME: home, USERPROFILE: home },
      stdio: ["pipe", "pipe", "pipe"],
    }
  );
  const output = readline.createInterface({ input: holder.stdout });
  await new Promise((resolve, reject) => {
    holder.once("error", reject);
    output.once("line", (line) => {
      if (line === "locked") resolve();
      else reject(new Error(`Unexpected lock-holder output: ${line}`));
    });
  });
  return holder;
}

test("concurrent stdio adapters start and share one background core", async (t) => {
  const port = await availablePort();
  const coreUrl = `http://127.0.0.1:${port}`;
  const environment = { ...process.env, ROBLOX_MCP_PORT: String(port) };
  const first = launchAdapter(environment, "first-adapter");
  const second = launchAdapter(environment, "second-adapter");
  let corePid;
  t.after(async () => {
    await Promise.all([
      stopChild(first.adapter),
      stopChild(second.adapter),
    ]);
    await stopPid(corePid);
  });

  const [firstInit, secondInit] = await Promise.all([
    initializeAdapter(first, 1),
    initializeAdapter(second, 2),
  ]);
  assert.equal(firstInit.result.serverInfo.name, "first-adapter");
  assert.equal(secondInit.result.serverInfo.name, "second-adapter");

  const info = await waitForCore(coreUrl, (data) => data.mcpSessionCount === 2);
  corePid = info.pid;
  trackedCorePids.add(corePid);
  assert.equal(info.mcpSessionCount, 2);

  const statusResponse = await fetch(`${coreUrl}/api/status`);
  assert.equal(statusResponse.status, 200);
  const status = await statusResponse.json();
  assert.equal(status.relayPeers, 2);
  assert.equal(status.relayClients, 2);
  assert.equal(status.mcpSessions, 2);
  assert.equal(status.legacyRelayClients, 0);
});

test("--baseurl connects the stdio adapter directly to a remote background core", async (t) => {
  const remotePort = await availablePort();
  const unusedLocalPort = await availablePort();
  const remoteUrl = `http://127.0.0.1:${remotePort}`;
  const core = launchCore({ ...process.env, ROBLOX_MCP_PORT: String(remotePort) });
  const adapterEnvironment = {
    ...process.env,
    ROBLOX_MCP_PORT: String(unusedLocalPort),
  };
  await waitForCore(remoteUrl);
  const connection = launchAdapter(
    adapterEnvironment,
    "remote-adapter",
    ["--baseurl", remoteUrl]
  );
  t.after(async () => {
    await stopChild(connection.adapter);
    await stopChild(core);
  });

  const initialization = await initializeAdapter(connection);
  assert.equal(initialization.result.serverInfo.name, "remote-adapter");
  const remoteInfo = await waitForCore(
    remoteUrl,
    (data) => data.mcpSessionCount === 1
  );
  assert.equal(remoteInfo.mcpSessionCount, 1);
  await assert.rejects(
    fetch(`http://127.0.0.1:${unusedLocalPort}/api/server-info`, {
      signal: AbortSignal.timeout(500),
    })
  );
});

test("an established --baseurl adapter stays on the remote host through core replacement", async (t) => {
  const remotePort = await availablePort();
  const unusedLocalPort = await availablePort();
  const remoteUrl = `http://127.0.0.1:${remotePort}`;
  let core = launchCore({ ...process.env, ROBLOX_MCP_PORT: String(remotePort) });
  const adapterEnvironment = {
    ...process.env,
    ROBLOX_MCP_PORT: String(unusedLocalPort),
    ROBLOX_MCP_UPDATE_CUTOVER_TIMEOUT_MS: "3000",
  };
  await waitForCore(remoteUrl);
  const connection = launchAdapter(
    adapterEnvironment,
    "persistent-remote-adapter",
    ["--baseurl", remoteUrl]
  );
  t.after(async () => {
    await stopChild(connection.adapter);
    await stopChild(core);
  });
  await initializeAdapter(connection);

  core.kill("SIGTERM");
  await new Promise((resolve) => core.once("close", resolve));
  core = launchCore({ ...process.env, ROBLOX_MCP_PORT: String(remotePort) });
  await waitForCore(remoteUrl);

  connection.adapter.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0",
    id: 2,
    method: "tools/list",
    params: {},
  })}\n`);
  let tools = await nextResponseFor(connection, [2]);
  if (tools.error) {
    assert.equal(tools.id, 2);
    assert.equal(tools.error.code, -32001);
    connection.adapter.stdin.write(`${JSON.stringify({
      jsonrpc: "2.0",
      id: 3,
      method: "tools/list",
      params: {},
    })}\n`);
    tools = await nextResponseFor(connection, [3]);
  }
  assert.ok(tools.id === 2 || tools.id === 3);
  assert.ok(tools.result.tools.some((tool) => tool.name === "execute"));
  await assert.rejects(
    fetch(`http://127.0.0.1:${unusedLocalPort}/api/server-info`, {
      signal: AbortSignal.timeout(500),
    })
  );
});

test("an idle adapter proactively recreates its session after core replacement", async (t) => {
  const port = await availablePort();
  const coreUrl = `http://127.0.0.1:${port}`;
  const environment = {
    ...process.env,
    ROBLOX_MCP_PORT: String(port),
    ROBLOX_MCP_CORE_URL: coreUrl,
    ROBLOX_MCP_CORE_MONITOR_INTERVAL_MS: "100",
  };
  let core = launchCore(environment);
  await waitForCore(coreUrl);
  const connection = launchAdapter(environment, "idle-reconnect-adapter");
  t.after(async () => {
    await stopChild(connection.adapter);
    await stopChild(core);
  });
  await initializeAdapter(connection);
  await waitForCore(coreUrl, (data) => data.mcpSessionCount === 1);

  core.kill("SIGTERM");
  await new Promise((resolve) => core.once("close", resolve));
  core = launchCore(environment);
  await waitForCore(coreUrl);

  const reconnected = await waitForCore(
    coreUrl,
    (data) => data.mcpSessionCount === 1
  );
  assert.equal(reconnected.mcpSessionCount, 1);
});

test("--baseurl falls back to one local background core when the remote is unavailable", async (t) => {
  const unavailableRemotePort = await availablePort();
  const localPort = await availablePort();
  const localUrl = `http://127.0.0.1:${localPort}`;
  const environment = { ...process.env, ROBLOX_MCP_PORT: String(localPort) };
  const connection = launchAdapter(
    environment,
    "fallback-adapter",
    ["--baseurl", `http://127.0.0.1:${unavailableRemotePort}`]
  );
  let corePid;
  t.after(async () => {
    await stopChild(connection.adapter);
    await stopPid(corePid);
  });

  const initialization = await initializeAdapter(connection);
  assert.equal(initialization.result.serverInfo.name, "fallback-adapter");
  const info = await waitForCore(localUrl);
  corePid = info.pid;
  trackedCorePids.add(corePid);
  assert.equal(info.architecture, "background-core");
});

test("adapter waits for an active update lock instead of racing to start the core", async (t) => {
  const port = await availablePort();
  const coreUrl = `http://127.0.0.1:${port}`;
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "roblox-mcp-cutover-"));
  const environment = {
    ...process.env,
    HOME: home,
    USERPROFILE: home,
    ROBLOX_MCP_PORT: String(port),
    ROBLOX_MCP_UPDATE_CUTOVER_TIMEOUT_MS: "5000",
  };
  const lockHolder = await launchUpdateLock(home);
  const connection = launchAdapter(environment, "cutover-adapter");
  let core;
  t.after(async () => {
    await stopChild(connection.adapter);
    if (!lockHolder.stdin.writableEnded) lockHolder.stdin.end();
    await Promise.all([stopChild(lockHolder), stopChild(core)]);
    await fs.rm(home, {
      recursive: true,
      force: true,
      maxRetries: 10,
      retryDelay: 100,
    });
  });

  const initializationPromise = initializeAdapter(connection);
  await new Promise((resolve) => setTimeout(resolve, 300));
  await assert.rejects(
    fetch(`${coreUrl}/api/server-info`, { signal: AbortSignal.timeout(300) })
  );

  core = launchCore(environment);
  await waitForCore(coreUrl);
  lockHolder.stdin.end();
  await new Promise((resolve) => lockHolder.once("close", resolve));

  const initialization = await initializationPromise;
  assert.equal(initialization.result.serverInfo.name, "cutover-adapter");
});

test("adapter reports an ambiguous interrupted request without replaying it", async (t) => {
  const port = await availablePort();
  const coreUrl = `http://127.0.0.1:${port}`;
  const environment = {
    ...process.env,
    ROBLOX_MCP_PORT: String(port),
    ROBLOX_MCP_CORE_URL: coreUrl,
  };
  let core = launchCore(environment);
  await waitForCore(coreUrl);
  const connection = launchAdapter(environment, "restart-adapter");
  t.after(async () => {
    await stopChild(connection.adapter);
    await stopChild(core);
  });
  await initializeAdapter(connection);

  core.kill("SIGTERM");
  await new Promise((resolve) => core.once("close", resolve));
  core = launchCore(environment);
  await waitForCore(coreUrl);

  connection.adapter.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0",
    id: 2,
    method: "tools/list",
    params: {},
  })}\n`);
  const interrupted = await connection.nextMessage();
  assert.equal(interrupted.id, 2);
  assert.equal(interrupted.error.code, -32001);
  assert.match(interrupted.error.message, /did not retry it automatically/);

  connection.adapter.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0",
    id: 3,
    method: "tools/list",
    params: {},
  })}\n`);
  const tools = await connection.nextMessage();
  assert.equal(tools.id, 3);
  assert.ok(tools.result.tools.some((tool) => tool.name === "list-clients"));
  assert.ok(tools.result.tools.some((tool) => tool.name === "execute"));
});

test("a healthy adapter transparently replaces an expired idle session", async (t) => {
  const port = await availablePort();
  const coreUrl = `http://127.0.0.1:${port}`;
  const environment = {
    ...process.env,
    ROBLOX_MCP_PORT: String(port),
    ROBLOX_MCP_CORE_URL: coreUrl,
    ROBLOX_MCP_SESSION_TTL_MS: "150",
  };
  const core = launchCore(environment);
  await waitForCore(coreUrl);
  const connection = launchAdapter(environment, "idle-adapter");
  t.after(async () => {
    await stopChild(connection.adapter);
    await stopChild(core);
  });
  await initializeAdapter(connection);
  await waitForCore(coreUrl, (data) => data.mcpSessionCount === 0);

  connection.adapter.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0",
    id: 2,
    method: "tools/list",
    params: {},
  })}\n`);
  const tools = await connection.nextMessage();
  assert.equal(tools.id, 2);
  assert.ok(tools.result.tools.some((tool) => tool.name === "execute"));
});

test("cancellation notifications are not queued behind long-running requests", async (t) => {
  const probe = await launchCancellationProbeCore();
  const environment = {
    ...process.env,
    ROBLOX_MCP_CORE_URL: probe.url,
  };
  const connection = launchAdapter(environment, "cancellation-adapter");
  t.after(async () => {
    await stopChild(connection.adapter);
    await new Promise((resolve) => probe.server.close(resolve));
  });
  await initializeAdapter(connection);

  connection.adapter.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0",
    id: 2,
    method: "probe/slow",
    params: {},
  })}\n`);
  await probe.slowStarted;
  connection.adapter.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0",
    method: "notifications/cancelled",
    params: { requestId: 2, reason: "test" },
  })}\n`);
  await Promise.race([
    probe.cancellationReceived,
    new Promise((_, reject) => {
      setTimeout(() => reject(new Error("Cancellation was blocked by the slow request.")), 250);
    }),
  ]);

  const slowResult = await connection.nextMessage();
  assert.equal(slowResult.id, 2);
  assert.equal(slowResult.result.completed, true);
});

test("core expires an MCP session after an adapter is killed abruptly", async (t) => {
  const port = await availablePort();
  const coreUrl = `http://127.0.0.1:${port}`;
  const environment = {
    ...process.env,
    ROBLOX_MCP_PORT: String(port),
    ROBLOX_MCP_CORE_URL: coreUrl,
    ROBLOX_MCP_SESSION_TTL_MS: "150",
  };
  const core = launchCore(environment);
  await waitForCore(coreUrl);
  const connection = launchAdapter(environment, "expiring-adapter");
  t.after(async () => {
    await stopChild(connection.adapter);
    await stopChild(core);
  });
  await initializeAdapter(connection);
  await waitForCore(coreUrl, (data) => data.mcpSessionCount === 1);

  connection.adapter.kill("SIGKILL");
  const expired = await waitForCore(coreUrl, (data) => data.mcpSessionCount === 0);
  assert.equal(expired.mcpSessionCount, 0);
});
