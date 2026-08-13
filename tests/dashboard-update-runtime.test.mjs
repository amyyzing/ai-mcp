import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { pathToFileURL } from "node:url";

import {
  activateCandidateBuild,
  restartActiveCore,
  validateCandidateCore,
} from "../scripts/dashboard-update-runtime.mjs";

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

function coreSource(instanceId, failPort = 0, hangOnFail = false) {
  return [
    'const http = require("node:http");',
    'const port = Number(process.env.ROBLOX_MCP_PORT);',
    `const failPort = ${failPort};`,
    `const hangOnFail = ${hangOnFail};`,
    `if (port === failPort && hangOnFail) {`,
    `  process.on("SIGTERM", () => {});`,
    `  setInterval(() => {}, 1_000);`,
    `} else {`,
    `if (port === failPort) process.exit(23);`,
    `const instanceId = ${JSON.stringify(instanceId)};`,
    `const server = http.createServer((req, res) => {`,
    `  if (req.url === "/api/server-info") {`,
    `    res.writeHead(200, { "Content-Type": "application/json" });`,
    `    res.end(JSON.stringify({`,
    `      architecture: "background-core",`,
    `      pid: process.pid,`,
    `      instanceId,`,
    `      version: "test",`,
    `    }));`,
    `    return;`,
    `  }`,
    `  res.writeHead(404); res.end();`,
    `});`,
    `server.listen(port, "127.0.0.1");`,
    `process.on("SIGTERM", () => server.close(() => process.exit(0)));`,
    `}`,
  ].join("\n");
}

async function waitForHealth(port, expectedInstanceId) {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/api/server-info`);
      const info = await response.json();
      if (info.instanceId === expectedInstanceId) return info;
    } catch {
      // The process is still starting.
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`Core ${expectedInstanceId} did not start.`);
}

async function waitForProcessExit(pid, timeoutMs = 3_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      process.kill(pid, 0);
    } catch {
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
}

async function fixture(
  t,
  { candidateFailsFinal = false, candidateHangsFinal = false } = {}
) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "roblox-mcp-update-"));
  const liveDist = path.join(root, "dist");
  const liveNodeModules = path.join(root, "node_modules");
  const candidateDist = path.join(root, "candidate-dist");
  const candidateNodeModules = path.join(root, "candidate-node_modules");
  const port = await freePort();
  await fs.mkdir(liveDist, { recursive: true });
  await fs.mkdir(liveNodeModules, { recursive: true });
  await fs.mkdir(candidateDist, { recursive: true });
  await fs.mkdir(candidateNodeModules, { recursive: true });
  await fs.mkdir(path.join(liveDist, "updater"), { recursive: true });
  await fs.mkdir(path.join(candidateDist, "updater"), { recursive: true });
  await fs.writeFile(path.join(liveNodeModules, "release.txt"), "old-dependencies", "utf8");
  await fs.writeFile(
    path.join(candidateNodeModules, "release.txt"),
    "candidate-dependencies",
    "utf8"
  );
  await fs.writeFile(path.join(liveDist, "core.js"), coreSource("old-core"), "utf8");
  await fs.writeFile(path.join(liveDist, "index.js"), "old stable adapter bootstrap", "utf8");
  await fs.writeFile(
    path.join(liveDist, "updater", "dashboard-update-worker.mjs"),
    "old updater",
    "utf8"
  );
  await fs.writeFile(
    path.join(candidateDist, "core.js"),
    coreSource(
      "candidate-core",
      candidateFailsFinal || candidateHangsFinal ? port : 0,
      candidateHangsFinal
    ),
    "utf8"
  );
  await fs.writeFile(path.join(candidateDist, "adapter.js"), "candidate adapter", "utf8");
  await fs.writeFile(path.join(candidateDist, "index.js"), "candidate bootstrap", "utf8");
  await fs.writeFile(
    path.join(candidateDist, "updater", "dashboard-update-worker.mjs"),
    "candidate updater",
    "utf8"
  );

  const oldCore = spawn(process.execPath, [path.join(liveDist, "core.js")], {
    cwd: root,
    env: { ...process.env, ROBLOX_MCP_PORT: String(port) },
    stdio: "ignore",
  });
  const oldInfo = await waitForHealth(port, "old-core");
  const cleanupPids = new Set([oldCore.pid]);
  t.after(async () => {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/api/server-info`);
      cleanupPids.add((await response.json()).pid);
    } catch {
      // No core is listening.
    }
    for (const pid of cleanupPids) {
      if (!pid) continue;
      try {
        process.kill(pid, "SIGKILL");
      } catch {
        // The process may already have exited.
      }
    }
    await Promise.all([...cleanupPids].filter(Boolean).map((pid) => waitForProcessExit(pid)));
    await fs.rm(root, {
      recursive: true,
      force: true,
      maxRetries: 10,
      retryDelay: 100,
    });
  });

  return {
    root,
    liveDist,
    liveNodeModules,
    candidateDist,
    candidateNodeModules,
    port,
    oldCore,
    oldInfo,
    cleanupPids,
  };
}

async function activeReleaseRoot(root) {
  const pointer = JSON.parse(
    await fs.readFile(path.join(root, ".roblox-mcp-current.json"), "utf8")
  );
  return pointer.releaseRoot;
}

async function crashActivation(setup, phase) {
  const runtimeUrl = pathToFileURL(
    path.join(import.meta.dirname, "..", "scripts", "dashboard-update-runtime.mjs")
  ).href;
  const options = JSON.stringify({
    serverRoot: setup.root,
    candidateDist: setup.candidateDist,
    candidateNodeModules: setup.candidateNodeModules,
    runId: `fault-${phase}`,
    corePid: setup.oldInfo.pid,
    coreInstanceId: setup.oldInfo.instanceId,
    corePort: setup.port,
    commit: "candidate",
  });
  const source = `
    const { activateCandidateBuild } = await import(${JSON.stringify(runtimeUrl)});
    await activateCandidateBuild({
      ...${options},
      activateCheckout: async () => {
        await (await import("node:fs/promises")).writeFile(
          ${JSON.stringify(path.join(setup.root, "checkout-advanced"))},
          "advanced"
        );
      },
      writeStatus: async () => undefined
    });
  `;
  const child = spawn(process.execPath, ["--input-type=module", "-e", source], {
    env: { ...process.env, ROBLOX_MCP_UPDATE_FAULT_PHASE: phase },
    stdio: "ignore",
  });
  const [code, signal] = await new Promise((resolve) => {
    child.once("close", (exitCode, exitSignal) => resolve([exitCode, exitSignal]));
  });
  if (process.platform === "win32") {
    assert.notEqual(code, 0);
    assert.equal(signal, null);
  } else {
    assert.equal(code, null);
    assert.equal(signal, "SIGKILL");
  }
}

test("dashboard updater validates, atomically activates, and health-checks a candidate", async (t) => {
  const setup = await fixture(t);
  const statuses = [];
  await validateCandidateCore(setup.candidateDist, setup.root);
  const result = await activateCandidateBuild({
    serverRoot: setup.root,
    candidateDist: setup.candidateDist,
    candidateNodeModules: setup.candidateNodeModules,
    runId: "successful",
    corePid: setup.oldInfo.pid,
    coreInstanceId: setup.oldInfo.instanceId,
    corePort: setup.port,
    writeStatus: async (status) => statuses.push(status),
  });
  setup.cleanupPids.add(result.corePid);

  assert.equal((await waitForHealth(setup.port, "candidate-core")).pid, result.corePid);
  const releaseRoot = await activeReleaseRoot(setup.root);
  assert.equal(releaseRoot, result.releaseRoot);
  assert.match(
    await fs.readFile(path.join(releaseRoot, "dist", "core.js"), "utf8"),
    /candidate-core/
  );
  assert.equal(
    await fs.readFile(path.join(releaseRoot, "node_modules", "release.txt"), "utf8"),
    "candidate-dependencies"
  );
  assert.match(await fs.readFile(path.join(setup.liveDist, "core.js"), "utf8"), /old-core/);
  assert.match(result.message, /adapters will reconnect automatically/);
  assert.deepEqual(statuses, [{
    state: "restarting",
    message: "Switching to the verified update…",
  }]);
});

test("dashboard restart launches the active verified release", async (t) => {
  const setup = await fixture(t);
  const activated = await activateCandidateBuild({
    serverRoot: setup.root,
    candidateDist: setup.candidateDist,
    candidateNodeModules: setup.candidateNodeModules,
    runId: "restart-active",
    corePid: setup.oldInfo.pid,
    coreInstanceId: setup.oldInfo.instanceId,
    corePort: setup.port,
    writeStatus: async () => undefined,
  });
  setup.cleanupPids.add(activated.corePid);
  const active = await waitForHealth(setup.port, "candidate-core");
  const restarted = await restartActiveCore({
    serverRoot: setup.root,
    corePid: active.pid,
    coreInstanceId: active.instanceId,
    corePort: setup.port,
  });
  setup.cleanupPids.add(restarted.corePid);
  assert.notEqual(restarted.corePid, active.pid);
  assert.equal(restarted.releaseRoot, await activeReleaseRoot(setup.root));
  assert.equal((await waitForHealth(setup.port, "candidate-core")).pid, restarted.corePid);
  assert.match(restarted.message, /active verified release/);
});

test("status reporting cannot interrupt a successful release activation", async (t) => {
  const setup = await fixture(t);
  await validateCandidateCore(setup.candidateDist, setup.root);
  const result = await activateCandidateBuild({
    serverRoot: setup.root,
    candidateDist: setup.candidateDist,
    candidateNodeModules: setup.candidateNodeModules,
    runId: "status-write-failure",
    corePid: setup.oldInfo.pid,
    coreInstanceId: setup.oldInfo.instanceId,
    corePort: setup.port,
    writeStatus: async () => {
      throw new Error("status disk is unavailable");
    },
  });
  setup.cleanupPids.add(result.corePid);

  assert.equal((await waitForHealth(setup.port, "candidate-core")).pid, result.corePid);
  const releaseRoot = await activeReleaseRoot(setup.root);
  assert.match(
    await fs.readFile(path.join(releaseRoot, "dist", "core.js"), "utf8"),
    /candidate-core/
  );
  assert.equal(
    await fs.readFile(path.join(releaseRoot, "node_modules", "release.txt"), "utf8"),
    "candidate-dependencies"
  );
});

test("dashboard updater refuses to signal a reused or mismatched core PID", async (t) => {
  const setup = await fixture(t);
  await validateCandidateCore(setup.candidateDist, setup.root);

  await assert.rejects(
    activateCandidateBuild({
      serverRoot: setup.root,
      candidateDist: setup.candidateDist,
      candidateNodeModules: setup.candidateNodeModules,
      runId: "identity-mismatch",
      corePid: setup.oldInfo.pid,
      coreInstanceId: "not-the-running-core",
      corePort: setup.port,
      writeStatus: async () => undefined,
    }),
    /refusing to signal its PID/
  );
  assert.equal((await waitForHealth(setup.port, "old-core")).pid, setup.oldInfo.pid);
  assert.match(await fs.readFile(path.join(setup.liveDist, "core.js"), "utf8"), /old-core/);
  assert.equal(
    await fs.readFile(path.join(setup.liveNodeModules, "release.txt"), "utf8"),
    "old-dependencies"
  );
});

test("a late checkout conflict removes the inactive candidate release", async (t) => {
  const setup = await fixture(t);
  await validateCandidateCore(setup.candidateDist, setup.root);
  await assert.rejects(
    activateCandidateBuild({
      serverRoot: setup.root,
      candidateDist: setup.candidateDist,
      candidateNodeModules: setup.candidateNodeModules,
      runId: "checkout-conflict",
      corePid: setup.oldInfo.pid,
      coreInstanceId: setup.oldInfo.instanceId,
      corePort: setup.port,
      activateCheckout: async () => {
        throw new Error("checkout changed");
      },
      writeStatus: async () => undefined,
    }),
    /checkout changed/
  );

  assert.equal((await waitForHealth(setup.port, "old-core")).pid, setup.oldInfo.pid);
  assert.deepEqual(
    await fs.readdir(path.join(setup.root, ".roblox-mcp-releases")),
    []
  );
  await assert.rejects(
    fs.access(path.join(setup.root, ".roblox-mcp-current.json"))
  );
});

test("dashboard updater restores the previous build when final startup fails", async (t) => {
  const setup = await fixture(t, { candidateFailsFinal: true });
  await validateCandidateCore(setup.candidateDist, setup.root);

  await assert.rejects(
    activateCandidateBuild({
      serverRoot: setup.root,
      candidateDist: setup.candidateDist,
      candidateNodeModules: setup.candidateNodeModules,
      runId: "rollback",
      corePid: setup.oldInfo.pid,
      coreInstanceId: setup.oldInfo.instanceId,
      corePort: setup.port,
      writeStatus: async () => undefined,
    }),
    /previous build was restored/
  );

  const rollbackInfo = await waitForHealth(setup.port, "old-core");
  setup.cleanupPids.add(rollbackInfo.pid);
  assert.notEqual(rollbackInfo.pid, setup.oldInfo.pid);
  assert.match(await fs.readFile(path.join(setup.liveDist, "core.js"), "utf8"), /old-core/);
  assert.equal(
    await fs.readFile(path.join(setup.liveNodeModules, "release.txt"), "utf8"),
    "old-dependencies"
  );
  assert.deepEqual(
    await fs.readdir(path.join(setup.root, ".roblox-mcp-releases")),
    []
  );
});

test("dashboard updater rolls back when the final core process cannot spawn", async (t) => {
  const setup = await fixture(t);
  await validateCandidateCore(setup.candidateDist, setup.root);

  await assert.rejects(
    activateCandidateBuild({
      serverRoot: setup.root,
      candidateDist: setup.candidateDist,
      candidateNodeModules: setup.candidateNodeModules,
      runId: "spawn-error",
      corePid: setup.oldInfo.pid,
      coreInstanceId: setup.oldInfo.instanceId,
      corePort: setup.port,
      coreExecutable: path.join(setup.root, "missing-node"),
      writeStatus: async () => undefined,
    }),
    /previous build was restored/
  );

  const rollbackInfo = await waitForHealth(setup.port, "old-core");
  setup.cleanupPids.add(rollbackInfo.pid);
  assert.match(await fs.readFile(path.join(setup.liveDist, "core.js"), "utf8"), /old-core/);
  assert.equal(
    await fs.readFile(path.join(setup.liveNodeModules, "release.txt"), "utf8"),
    "old-dependencies"
  );
});

test("dashboard updater force-stops a hung candidate before rollback", async (t) => {
  const setup = await fixture(t, { candidateHangsFinal: true });
  await validateCandidateCore(setup.candidateDist, setup.root);

  await assert.rejects(
    activateCandidateBuild({
      serverRoot: setup.root,
      candidateDist: setup.candidateDist,
      candidateNodeModules: setup.candidateNodeModules,
      runId: "hung-candidate",
      corePid: setup.oldInfo.pid,
      coreInstanceId: setup.oldInfo.instanceId,
      corePort: setup.port,
      coreStartTimeoutMs: 300,
      coreStopTimeoutMs: 200,
      writeStatus: async () => undefined,
    }),
    /previous build was restored/
  );

  const rollbackInfo = await waitForHealth(setup.port, "old-core");
  setup.cleanupPids.add(rollbackInfo.pid);
  assert.match(await fs.readFile(path.join(setup.liveDist, "core.js"), "utf8"), /old-core/);
  assert.equal(
    await fs.readFile(path.join(setup.liveNodeModules, "release.txt"), "utf8"),
    "old-dependencies"
  );
});

for (const phase of [
  "after-release-dist",
  "after-release-dependencies",
  "after-checkout",
  "after-release-pointer",
]) {
  test(`release activation remains bootable after crash at ${phase}`, async (t) => {
    const setup = await fixture(t);
    await validateCandidateCore(setup.candidateDist, setup.root);
    await crashActivation(setup, phase);

    assert.equal((await waitForHealth(setup.port, "old-core")).pid, setup.oldInfo.pid);
    assert.match(await fs.readFile(path.join(setup.liveDist, "core.js"), "utf8"), /old-core/);
    assert.equal(
      await fs.readFile(path.join(setup.liveDist, "index.js"), "utf8"),
      "old stable adapter bootstrap"
    );
    assert.equal(
      await fs.readFile(
        path.join(setup.liveDist, "updater", "dashboard-update-worker.mjs"),
        "utf8"
      ),
      "old updater"
    );
    assert.equal(
      await fs.readFile(path.join(setup.liveNodeModules, "release.txt"), "utf8"),
      "old-dependencies"
    );
    const pointerPath = path.join(setup.root, ".roblox-mcp-current.json");
    if (phase === "after-release-pointer") {
      const releaseRoot = await activeReleaseRoot(setup.root);
      assert.match(
        await fs.readFile(path.join(releaseRoot, "dist", "core.js"), "utf8"),
        /candidate-core/
      );
      assert.equal(
        await fs.readFile(path.join(releaseRoot, "node_modules", "release.txt"), "utf8"),
        "candidate-dependencies"
      );
      assert.equal(
        await fs.readFile(path.join(releaseRoot, "dist", "adapter.js"), "utf8"),
        "candidate adapter"
      );
      assert.equal(
        await fs.readFile(
          path.join(releaseRoot, "dist", "updater", "dashboard-update-worker.mjs"),
          "utf8"
        ),
        "candidate updater"
      );
    } else {
      await assert.rejects(fs.access(pointerPath));
    }
    if (phase === "after-checkout" || phase === "after-release-pointer") {
      assert.equal(
        await fs.readFile(path.join(setup.root, "checkout-advanced"), "utf8"),
        "advanced"
      );
    }
  });
}
