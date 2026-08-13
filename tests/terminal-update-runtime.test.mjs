import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import test, { after } from "node:test";

import { installationIdentity } from "../src/shared/installation-identity.mjs";
import {
  prepareCheckoutRollback,
  preserveCheckoutRuntime,
  removeCheckoutSnapshot,
} from "../scripts/terminal-update-snapshot.mjs";

const repoRoot = path.resolve(import.meta.dirname, "..");
const updateHome = await fs.mkdtemp(
  path.join(os.tmpdir(), "roblox-mcp-terminal-status-")
);
const previousHome = process.env.HOME;
const previousUserProfile = process.env.USERPROFILE;
process.env.HOME = updateHome;
process.env.USERPROFILE = updateHome;
after(async () => {
  if (previousHome === undefined) delete process.env.HOME;
  else process.env.HOME = previousHome;
  if (previousUserProfile === undefined) delete process.env.USERPROFILE;
  else process.env.USERPROFILE = previousUserProfile;
  await fs.rm(updateHome, { recursive: true, force: true });
});
const { activateCheckoutRuntime } = await import(
  `../scripts/terminal-update-runtime.mjs?test=${Date.now()}`
);

async function freePort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  const port = typeof address === "object" && address ? address.port : 0;
  await new Promise((resolve) => server.close(resolve));
  return port;
}

async function waitForCore(url, predicate = () => true) {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`${url}/api/server-info`);
      if (response.ok) {
        const body = await response.json();
        if (predicate(body)) return body;
      }
    } catch {
      // Still transitioning.
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error("Core did not reach the expected terminal-update state.");
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
    return;
  }
  for (let attempt = 0; attempt < 40; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 50));
    try {
      process.kill(pid, 0);
    } catch {
      return;
    }
  }
}

function removeTestTree(root) {
  return fs.rm(root, {
    recursive: true,
    force: true,
    maxRetries: 10,
    retryDelay: 100,
  });
}

function coreSource(instanceId, installationId, failPort = 0) {
  return [
    'const http = require("node:http");',
    'const port = Number(process.env.ROBLOX_MCP_PORT);',
    `if (port === ${failPort}) process.exit(23);`,
    `const instanceId = ${JSON.stringify(instanceId)};`,
    `const installationId = ${JSON.stringify(installationId)};`,
    "const server = http.createServer((req, res) => {",
    '  if (req.url !== "/api/server-info") { res.writeHead(404); res.end(); return; }',
    '  res.writeHead(200, { "Content-Type": "application/json" });',
    '  res.end(JSON.stringify({ architecture: "background-core", pid: process.pid, instanceId, installationId }));',
    "});",
    'server.listen(port, "127.0.0.1");',
    'process.on("SIGTERM", () => server.close(() => process.exit(0)));',
  ].join("\n");
}

test("terminal update deactivates a versioned core and the checkout adapter starts the rebuild", async (t) => {
  const serverRoot = await fs.mkdtemp(path.join(os.tmpdir(), "roblox-mcp-terminal-update-"));
  const releaseRoot = path.join(serverRoot, ".roblox-mcp-releases", "old-release");
  const linkType = process.platform === "win32" ? "junction" : "dir";
  await fs.mkdir(releaseRoot, { recursive: true });
  await fs.symlink(path.join(repoRoot, "dist"), path.join(serverRoot, "dist"), linkType);
  await fs.symlink(
    path.join(repoRoot, "node_modules"),
    path.join(serverRoot, "node_modules"),
    linkType
  );
  await fs.symlink(path.join(repoRoot, "dist"), path.join(releaseRoot, "dist"), linkType);
  await fs.symlink(
    path.join(repoRoot, "node_modules"),
    path.join(releaseRoot, "node_modules"),
    linkType
  );
  await fs.writeFile(
    path.join(serverRoot, ".roblox-mcp-current.json"),
    `${JSON.stringify({ releaseRoot, runId: "old-release" })}\n`,
    "utf8"
  );

  const port = await freePort();
  const environment = {
    ...process.env,
    ROBLOX_MCP_PORT: String(port),
    ROBLOX_MCP_SERVER_ROOT: serverRoot,
  };
  const oldCore = spawn(
    process.execPath,
    [path.join("dist", "core-bootstrap.js")],
    { cwd: serverRoot, env: environment, stdio: "ignore" }
  );
  const baseUrl = `http://127.0.0.1:${port}`;
  const oldInfo = await waitForCore(baseUrl);
  let adapter;
  t.after(async () => {
    await stopChild(oldCore, "SIGKILL");
    await stopChild(adapter);
    try {
      const info = await (await fetch(`${baseUrl}/api/server-info`)).json();
      await stopPid(info.pid);
    } catch {
      // Already stopped.
    }
    await removeTestTree(serverRoot);
  });

  const oldCoreClosed = new Promise((resolve) => oldCore.once("close", resolve));
  const activation = await activateCheckoutRuntime(serverRoot, { port });
  assert.ok(activation.coreProcesses.some((item) => item.pid === oldInfo.pid));
  await oldCoreClosed;
  await assert.rejects(fs.access(path.join(serverRoot, ".roblox-mcp-current.json")));
  const activatedInfo = await waitForCore(
    baseUrl,
    (info) => info.pid === activation.corePid
  );
  assert.notEqual(activatedInfo.pid, oldInfo.pid);

  adapter = spawn(process.execPath, [path.join(repoRoot, "dist", "index.js")], {
    cwd: serverRoot,
    env: environment,
    stdio: ["pipe", "pipe", "ignore"],
  });
  const lines = readline.createInterface({ input: adapter.stdout });
  adapter.stdin.write(`${JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: { name: "terminal-update-test", version: "1" },
    },
  })}\n`);
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("Adapter did not initialize.")), 5_000);
    lines.once("line", () => {
      clearTimeout(timeout);
      resolve();
    });
  });
  const rebuiltInfo = await waitForCore(baseUrl, (info) => info.pid !== oldInfo.pid);
  assert.equal(rebuiltInfo.pid, activation.corePid);
});

test("terminal update refuses to replace a different checkout on the same port", async (t) => {
  const ownerRoot = await fs.mkdtemp(path.join(os.tmpdir(), "roblox-mcp-owner-"));
  const updaterRoot = await fs.mkdtemp(path.join(os.tmpdir(), "roblox-mcp-updater-"));
  const linkType = process.platform === "win32" ? "junction" : "dir";
  await fs.symlink(path.join(repoRoot, "dist"), path.join(ownerRoot, "dist"), linkType);
  await fs.symlink(path.join(repoRoot, "node_modules"), path.join(ownerRoot, "node_modules"), linkType);
  await fs.symlink(path.join(repoRoot, "dist"), path.join(updaterRoot, "dist"), linkType);
  await fs.symlink(path.join(repoRoot, "node_modules"), path.join(updaterRoot, "node_modules"), linkType);
  const port = await freePort();
  const owner = spawn(process.execPath, [path.join("dist", "core.js")], {
    cwd: ownerRoot,
    env: {
      ...process.env,
      ROBLOX_MCP_PORT: String(port),
      ROBLOX_MCP_SERVER_ROOT: ownerRoot,
    },
    stdio: "ignore",
  });
  const url = `http://127.0.0.1:${port}`;
  const ownerInfo = await waitForCore(url);
  t.after(async () => {
    const closed = owner.exitCode === null
      ? new Promise((resolve) => owner.once("close", resolve))
      : Promise.resolve();
    owner.kill("SIGKILL");
    await closed;
    await fs.rm(ownerRoot, { recursive: true, force: true });
    await fs.rm(updaterRoot, { recursive: true, force: true });
  });

  await assert.rejects(
    activateCheckoutRuntime(updaterRoot, { port }),
    /different Roblox MCP installation/
  );
  assert.equal((await waitForCore(url)).pid, ownerInfo.pid);
});

test("terminal update dry-run can preview a running legacy monolith", async (t) => {
  const serverRoot = await fs.mkdtemp(
    path.join(os.tmpdir(), "roblox-mcp-legacy-dry-run-")
  );
  const legacy = http.createServer((request, response) => {
    if (request.url !== "/api/server-info") {
      response.writeHead(404).end();
      return;
    }
    response.writeHead(200, { "Content-Type": "application/json" });
    response.end(JSON.stringify({ version: "0.9.0" }));
  });
  await new Promise((resolve) => legacy.listen(0, "127.0.0.1", resolve));
  t.after(async () => {
    await new Promise((resolve) => legacy.close(resolve));
    await fs.rm(serverRoot, { recursive: true, force: true });
  });

  await assert.doesNotReject(
    activateCheckoutRuntime(serverRoot, {
      dryRun: true,
      port: legacy.address().port,
    })
  );
});

test("terminal update restores the previous release when final startup fails", async (t) => {
  const serverRoot = await fs.mkdtemp(
    path.join(os.tmpdir(), "roblox-mcp-terminal-rollback-")
  );
  const releaseRoot = path.join(serverRoot, ".roblox-mcp-releases", "previous");
  const port = await freePort();
  const identity = installationIdentity(serverRoot);
  await fs.mkdir(path.join(serverRoot, "dist"), { recursive: true });
  await fs.mkdir(path.join(releaseRoot, "dist"), { recursive: true });
  await fs.mkdir(path.join(releaseRoot, "node_modules"), { recursive: true });
  await fs.writeFile(
    path.join(serverRoot, "dist", "core.js"),
    coreSource("candidate", identity, port),
    "utf8"
  );
  await fs.writeFile(
    path.join(releaseRoot, "dist", "core.js"),
    coreSource("previous", identity),
    "utf8"
  );
  await fs.writeFile(
    path.join(releaseRoot, "dist", "adapter.js"),
    "export {};",
    "utf8"
  );
  await fs.writeFile(
    path.join(serverRoot, ".roblox-mcp-current.json"),
    `${JSON.stringify({ releaseRoot, runId: "previous" })}\n`,
    "utf8"
  );
  const previous = spawn(process.execPath, [path.join("dist", "core.js")], {
    cwd: releaseRoot,
    env: {
      ...process.env,
      ROBLOX_MCP_PORT: String(port),
      ROBLOX_MCP_SERVER_ROOT: serverRoot,
    },
    stdio: "ignore",
  });
  const url = `http://127.0.0.1:${port}`;
  const previousInfo = await waitForCore(url, (info) => info.instanceId === "previous");
  t.after(async () => {
    await stopChild(previous, "SIGKILL");
    try {
      await stopPid((await (await fetch(`${url}/api/server-info`)).json()).pid, "SIGKILL");
    } catch {
      // Already stopped.
    }
    await removeTestTree(serverRoot);
  });

  await assert.rejects(
    activateCheckoutRuntime(serverRoot, { port }),
    /previous build was restored/
  );
  const restored = await waitForCore(url, (info) => info.instanceId === "previous");
  assert.notEqual(restored.pid, previousInfo.pid);
  const pointer = JSON.parse(
    await fs.readFile(path.join(serverRoot, ".roblox-mcp-current.json"), "utf8")
  );
  assert.equal(pointer.releaseRoot, releaseRoot);
});

test("terminal update snapshots and restores a checkout runtime with no pointer", async (t) => {
  const serverRoot = await fs.mkdtemp(
    path.join(os.tmpdir(), "roblox-mcp-terminal-root-rollback-")
  );
  const port = await freePort();
  const identity = installationIdentity(serverRoot);
  await fs.mkdir(path.join(serverRoot, "dist"), { recursive: true });
  await fs.mkdir(path.join(serverRoot, "node_modules"), { recursive: true });
  await fs.writeFile(
    path.join(serverRoot, "dist", "core.js"),
    coreSource("checkout-previous", identity),
    "utf8"
  );
  await fs.writeFile(
    path.join(serverRoot, "dist", "adapter.js"),
    "export {};",
    "utf8"
  );
  const previous = spawn(process.execPath, [path.join("dist", "core.js")], {
    cwd: serverRoot,
    env: {
      ...process.env,
      ROBLOX_MCP_PORT: String(port),
      ROBLOX_MCP_SERVER_ROOT: serverRoot,
    },
    stdio: "ignore",
  });
  const url = `http://127.0.0.1:${port}`;
  const previousInfo = await waitForCore(
    url,
    (info) => info.instanceId === "checkout-previous"
  );
  t.after(async () => {
    await stopChild(previous, "SIGKILL");
    try {
      await stopPid((await (await fetch(`${url}/api/server-info`)).json()).pid, "SIGKILL");
    } catch {
      // Already stopped.
    }
    await removeTestTree(serverRoot);
  });

  const snapshot = await preserveCheckoutRuntime(serverRoot, {
    runId: "root-rollback-test",
  });
  assert.equal(snapshot.created, true);
  await fs.writeFile(
    path.join(serverRoot, "dist", "core.js"),
    coreSource("checkout-candidate", identity, port),
    "utf8"
  );
  await fs.mkdir(path.join(serverRoot, "node_modules"), { recursive: true });

  await assert.rejects(
    activateCheckoutRuntime(serverRoot, { port }),
    /previous build was restored/
  );
  const restored = await waitForCore(
    url,
    (info) => info.instanceId === "checkout-previous"
  );
  assert.notEqual(restored.pid, previousInfo.pid);
  const pointer = JSON.parse(
    await fs.readFile(path.join(serverRoot, ".roblox-mcp-current.json"), "utf8")
  );
  assert.equal(pointer.releaseRoot, snapshot.releaseRoot);
});

test("legacy monolith layouts skip new-runtime snapshot requirements", async (t) => {
  const serverRoot = await fs.mkdtemp(
    path.join(os.tmpdir(), "roblox-mcp-legacy-snapshot-")
  );
  t.after(() => fs.rm(serverRoot, { recursive: true, force: true }));
  await fs.mkdir(path.join(serverRoot, "dist"), { recursive: true });
  await fs.mkdir(path.join(serverRoot, "node_modules"), { recursive: true });
  await fs.writeFile(path.join(serverRoot, "dist", "index.js"), "legacy", "utf8");

  const snapshot = await prepareCheckoutRollback(serverRoot);
  assert.deepEqual(snapshot, {
    created: false,
    managed: false,
    releaseRoot: null,
    skippedIncomplete: true,
  });
  await assert.rejects(
    fs.access(path.join(serverRoot, ".roblox-mcp-current.json"))
  );
});

test("a successful retry prunes its pre-existing terminal snapshot", async (t) => {
  const serverRoot = await fs.mkdtemp(
    path.join(os.tmpdir(), "roblox-mcp-retry-snapshot-")
  );
  t.after(() => fs.rm(serverRoot, { recursive: true, force: true }));
  await fs.mkdir(path.join(serverRoot, "dist"), { recursive: true });
  await fs.mkdir(path.join(serverRoot, "node_modules"), { recursive: true });
  await fs.writeFile(path.join(serverRoot, "dist", "core.js"), "", "utf8");
  await fs.writeFile(path.join(serverRoot, "dist", "adapter.js"), "", "utf8");
  await preserveCheckoutRuntime(serverRoot, { runId: "failed-first-run" });

  const retrySnapshot = await preserveCheckoutRuntime(serverRoot, {
    runId: "retry",
  });
  assert.equal(retrySnapshot.created, false);
  assert.equal(retrySnapshot.managed, true);
  await fs.rm(path.join(serverRoot, ".roblox-mcp-current.json"));
  await removeCheckoutSnapshot(serverRoot, retrySnapshot);
  await assert.rejects(fs.access(retrySnapshot.releaseRoot));
});

test("a crash before snapshot pointer commit leaves the checkout bootable", async (t) => {
  const serverRoot = await fs.mkdtemp(
    path.join(os.tmpdir(), "roblox-mcp-snapshot-crash-")
  );
  t.after(() => fs.rm(serverRoot, { recursive: true, force: true }));
  await fs.mkdir(path.join(serverRoot, "dist"), { recursive: true });
  await fs.mkdir(path.join(serverRoot, "node_modules"), { recursive: true });
  await fs.writeFile(path.join(serverRoot, "dist", "core.js"), "old core", "utf8");
  await fs.writeFile(path.join(serverRoot, "dist", "adapter.js"), "old adapter", "utf8");
  await fs.writeFile(
    path.join(serverRoot, "node_modules", "known-good"),
    "preserved",
    "utf8"
  );
  const snapshotModule = new URL(
    "../scripts/terminal-update-snapshot.mjs",
    import.meta.url
  ).href;
  const source = `
    const { preserveCheckoutRuntime } = await import(${JSON.stringify(snapshotModule)});
    await preserveCheckoutRuntime(${JSON.stringify(serverRoot)}, { runId: "crashed" });
  `;
  const child = spawn(process.execPath, ["--input-type=module", "-e", source], {
    env: {
      ...process.env,
      ROBLOX_MCP_TERMINAL_SNAPSHOT_FAULT_PHASE:
        "after-snapshot-dependencies",
    },
    stdio: "ignore",
  });
  const [code, signal] = await new Promise((resolve) => {
    child.once("close", (exitCode, exitSignal) =>
      resolve([exitCode, exitSignal])
    );
  });
  if (process.platform === "win32") {
    assert.notEqual(code, 0);
    assert.equal(signal, null);
  } else {
    assert.equal(code, null);
    assert.equal(signal, "SIGKILL");
  }
  assert.equal(
    await fs.readFile(
      path.join(serverRoot, "node_modules", "known-good"),
      "utf8"
    ),
    "preserved"
  );
  await assert.rejects(
    fs.access(path.join(serverRoot, ".roblox-mcp-current.json"))
  );

  const retry = await prepareCheckoutRollback(serverRoot, { runId: "retry" });
  assert.equal(retry.created, true);
  assert.deepEqual(
    (await fs.readdir(path.join(serverRoot, ".roblox-mcp-releases")))
      .filter((entry) => entry.startsWith("terminal-checkout-")),
    ["terminal-checkout-retry"]
  );
});

test("a regular-file fsync failure prevents snapshot pointer activation", async (t) => {
  const serverRoot = await fs.mkdtemp(
    path.join(os.tmpdir(), "roblox-mcp-snapshot-sync-failure-")
  );
  t.after(() => fs.rm(serverRoot, { recursive: true, force: true }));
  await fs.mkdir(path.join(serverRoot, "dist"), { recursive: true });
  await fs.mkdir(path.join(serverRoot, "node_modules"), { recursive: true });
  await fs.writeFile(path.join(serverRoot, "dist", "core.js"), "old core", "utf8");
  await fs.writeFile(path.join(serverRoot, "dist", "adapter.js"), "old adapter", "utf8");
  await fs.writeFile(
    path.join(serverRoot, "node_modules", "known-good"),
    "preserved",
    "utf8"
  );
  const snapshotModule = new URL(
    "../scripts/terminal-update-snapshot.mjs",
    import.meta.url
  ).href;
  const source = `
    const { preserveCheckoutRuntime } = await import(${JSON.stringify(snapshotModule)});
    await preserveCheckoutRuntime(${JSON.stringify(serverRoot)}, { runId: "sync-failure" });
  `;
  const child = spawn(process.execPath, ["--input-type=module", "-e", source], {
    env: {
      ...process.env,
      ROBLOX_MCP_TERMINAL_SNAPSHOT_SYNC_FAILURE: "known-good",
    },
    stdio: "ignore",
  });
  const code = await new Promise((resolve) => child.once("close", resolve));
  assert.notEqual(code, 0);
  assert.equal(
    await fs.readFile(
      path.join(serverRoot, "node_modules", "known-good"),
      "utf8"
    ),
    "preserved"
  );
  await assert.rejects(
    fs.access(path.join(serverRoot, ".roblox-mcp-current.json"))
  );
});

test("snapshot durability syncs the release parent before pointer commit", async () => {
  const snapshotSource = await fs.readFile(
    path.resolve(
      import.meta.dirname,
      "..",
      "scripts",
      "terminal-update-snapshot.mjs"
    ),
    "utf8"
  );
  const treeSync = snapshotSource.indexOf("await syncTree(releaseRoot)");
  const parentSync = snapshotSource.indexOf(
    "await syncDirectory(path.dirname(releaseRoot))"
  );
  const pointerCommit = snapshotSource.indexOf(
    "await writeReleasePointer(serverRoot"
  );
  assert.ok(treeSync >= 0 && treeSync < parentSync);
  assert.ok(parentSync < pointerCommit);
});
