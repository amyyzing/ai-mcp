import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs/promises";
import net from "node:net";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const runtimeDirectory = path.dirname(fileURLToPath(import.meta.url));
const releasePointerPath =
  path.basename(runtimeDirectory) === "updater" &&
    path.basename(path.dirname(runtimeDirectory)) === "dist"
    ? path.join(runtimeDirectory, "..", "shared", "release-pointer.mjs")
    : path.join(runtimeDirectory, "..", "dist", "shared", "release-pointer.mjs");
const releasePointerModule = pathToFileURL(releasePointerPath).href;
const {
  readReleasePointer,
  resolveActiveReleaseRoot,
  writeReleasePointer,
} = await import(releasePointerModule);
const {
  applyBackgroundService,
  getBackgroundServiceStatus,
} = await import(pathToFileURL(path.join(path.dirname(releasePointerPath), "background-service-install.mjs")).href);
const configuredBridgeAuthModule = pathToFileURL(
  path.basename(runtimeDirectory) === "updater" &&
    path.basename(path.dirname(runtimeDirectory)) === "dist"
    ? path.join(runtimeDirectory, "..", "shared", "configured-bridge-auth.mjs")
    : path.join(runtimeDirectory, "..", "src", "shared", "configured-bridge-auth.mjs")
).href;
const { configuredBridgeAuthHeaders } = await import(configuredBridgeAuthModule);

const CORE_STOP_TIMEOUT_MS = 10_000;
const CORE_START_TIMEOUT_MS = 60_000;
const POLL_INTERVAL_MS = 200;

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function crashAtTestPhase(phase) {
  if (process.env.ROBLOX_MCP_UPDATE_FAULT_PHASE === phase) {
    process.kill(process.pid, "SIGKILL");
  }
}

function processExists(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

function terminateProcess(pid) {
  if (!processExists(pid)) return;
  if (process.platform === "win32") {
    const result = spawnSync("taskkill", ["/PID", String(pid), "/T", "/F"], {
      encoding: "utf8",
      windowsHide: true,
    });
    if (result.status !== 0 && processExists(pid)) {
      throw new Error(result.stderr.trim() || `taskkill failed for PID ${pid}.`);
    }
    return;
  }
  process.kill(pid, "SIGTERM");
}

async function waitForProcessExit(pid, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (!processExists(pid)) return true;
    await delay(POLL_INTERVAL_MS);
  }
  return !processExists(pid);
}

function forceTerminateProcess(pid) {
  if (!processExists(pid)) return;
  if (process.platform === "win32") {
    const result = spawnSync("taskkill", ["/PID", String(pid), "/T", "/F"], {
      encoding: "utf8",
      windowsHide: true,
    });
    if (result.status !== 0 && processExists(pid)) {
      throw new Error(result.stderr.trim() || `taskkill failed for PID ${pid}.`);
    }
    return;
  }
  process.kill(pid, "SIGKILL");
}

async function stopProcess(pid, timeoutMs = CORE_STOP_TIMEOUT_MS) {
  if (!processExists(pid)) return;
  terminateProcess(pid);
  if (await waitForProcessExit(pid, timeoutMs)) return;
  forceTerminateProcess(pid);
  if (await waitForProcessExit(pid, Math.max(timeoutMs, 1_000))) return;
  throw new Error(`Background core PID ${pid} did not stop.`);
}

export async function fetchCoreInfo(coreUrl) {
  const response = await fetch(new URL("/api/server-info", coreUrl), {
    cache: "no-store",
    headers: configuredBridgeAuthHeaders(),
    signal: AbortSignal.timeout(800),
  });
  if (!response.ok) throw new Error(`Core health returned HTTP ${response.status}.`);
  return response.json();
}

async function waitForCore(
  coreUrl,
  { child, expectedPid, timeoutMs = CORE_START_TIMEOUT_MS } = {}
) {
  const deadline = Date.now() + timeoutMs;
  let lastError = "health endpoint unavailable";
  while (Date.now() < deadline) {
    if (child?.spawnError) {
      throw child.spawnError;
    }
    if (child && child.exitCode !== null) {
      throw new Error(`Background core exited with code ${child.exitCode}.`);
    }
    try {
      const info = await fetchCoreInfo(coreUrl);
      if (
        info?.architecture === "background-core" &&
        (!expectedPid || info.pid === expectedPid)
      ) {
        return info;
      }
      lastError = "health endpoint reported the wrong process";
    } catch (error) {
      lastError = error instanceof Error ? error.message : String(error);
    }
    await delay(POLL_INTERVAL_MS);
  }
  throw new Error(`Background core did not become ready at ${coreUrl}: ${lastError}`);
}

async function freePort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  const port = typeof address === "object" && address ? address.port : 0;
  await new Promise((resolve) => server.close(resolve));
  if (!port) throw new Error("Could not reserve a candidate health-check port.");
  return port;
}

function spawnCore(
  coreEntry,
  { cwd, port, detached, executable = process.execPath, serverRoot = cwd }
) {
  const child = spawn(executable, [coreEntry], {
    cwd,
    detached,
    env: {
      ...process.env,
      ROBLOX_MCP_PORT: String(port),
      ROBLOX_MCP_SERVER_ROOT: serverRoot,
    },
    stdio: "ignore",
    windowsHide: true,
  });
  child.spawnError = null;
  child.once("error", (error) => {
    child.spawnError = error;
  });
  if (detached) child.unref();
  return child;
}

async function stopChild(child, timeoutMs = CORE_STOP_TIMEOUT_MS) {
  if (!child?.pid || !processExists(child.pid)) return;
  await stopProcess(child.pid, timeoutMs);
}

export async function validateCandidateCore(candidateDist, serverRoot) {
  const coreEntry = path.join(candidateDist, "core.js");
  await fs.access(coreEntry);
  const port = await freePort();
  const child = spawnCore(coreEntry, {
    cwd: serverRoot,
    serverRoot,
    port,
    detached: false,
  });
  try {
    const info = await waitForCore(`http://127.0.0.1:${port}`, {
      child,
      expectedPid: child.pid,
    });
    return { port, version: info.version };
  } finally {
    await stopChild(child);
  }
}

async function verifyCoreIdentity(coreUrl, expectedPid, expectedInstanceId) {
  const deadline = Date.now() + CORE_STOP_TIMEOUT_MS;
  let lastError = "health endpoint unavailable";
  while (Date.now() < deadline) {
    try {
      const info = await fetchCoreInfo(coreUrl);
      if (info?.architecture !== "background-core" || info.pid !== expectedPid || info.instanceId !== expectedInstanceId) {
        throw new Error("The running background core changed during the update; refusing to signal its PID.");
      }
      return;
    } catch (error) {
      if (error instanceof Error && error.message.includes("refusing to signal")) throw error;
      lastError = error instanceof Error ? error.message : String(error);
      await delay(POLL_INTERVAL_MS);
    }
  }
  throw new Error(`Could not verify the running background core: ${lastError}`);
}

export async function startReleaseCore({
  releaseRoot,
  serverRoot,
  corePort,
  coreStartTimeoutMs,
}) {
  const rollback = spawnCore(path.join(releaseRoot, "dist", "core.js"), {
    cwd: releaseRoot,
    serverRoot,
    port: corePort,
    detached: true,
  });
  try {
    await waitForCore(`http://127.0.0.1:${corePort}`, {
      child: rollback,
      expectedPid: rollback.pid,
      timeoutMs: coreStartTimeoutMs,
    });
    return rollback;
  } catch (error) {
    await stopChild(rollback).catch(() => undefined);
    throw error;
  }
}

export async function restartActiveCore({ serverRoot, corePid, coreInstanceId, corePort, coreExecutable }) {
  const releaseRoot = await resolveActiveReleaseRoot(serverRoot);
  const service = getBackgroundServiceStatus();
  const serviceConfig = typeof service.configPath === "string"
    ? await fs.readFile(service.configPath, "utf8").catch(() => "")
    : "";
  const comparableConfig = process.platform === "win32" ? serviceConfig.toLowerCase() : serviceConfig;
  const comparableRoot = process.platform === "win32" ? serverRoot.toLowerCase() : serverRoot;
  const serviceOwnsCore = service.enabled && (
    comparableConfig.includes(comparableRoot) || service.manager === "Windows Task Scheduler (legacy)"
  );
  if (serviceOwnsCore) {
    const coreUrl = `http://127.0.0.1:${corePort}`;
    await verifyCoreIdentity(coreUrl, corePid, coreInstanceId);
    await applyBackgroundService({
      serverRoot,
      mode: "background",
      nodePath: coreExecutable || process.execPath,
    });
    const info = await waitForCore(coreUrl, { timeoutMs: CORE_START_TIMEOUT_MS });
    if (info.pid === corePid || info.instanceId === coreInstanceId) {
      throw new Error("The background service did not replace the running core.");
    }
    return {
      corePid: info.pid,
      releaseRoot,
      message: `Server restarted through ${service.manager} using the active verified release. Connected adapters will reconnect automatically.`,
    };
  }
  const child = await restartCoreWithRollback({
    serverRoot,
    corePid,
    coreInstanceId,
    corePort,
    nextReleaseRoot: releaseRoot,
    previousReleaseRoot: releaseRoot,
    coreExecutable,
  });
  return {
    corePid: child.pid,
    releaseRoot,
    message: "Server restarted using the active verified release. Connected adapters will reconnect automatically.",
  };
}

export async function restartCoreWithRollback({
  serverRoot,
  corePid,
  coreInstanceId,
  corePort,
  nextReleaseRoot,
  previousReleaseRoot,
  activateNext = async () => undefined,
  activatePrevious = async () => undefined,
  coreExecutable,
  coreStartTimeoutMs = CORE_START_TIMEOUT_MS,
  coreStopTimeoutMs = CORE_STOP_TIMEOUT_MS,
}) {
  const coreUrl = `http://127.0.0.1:${corePort}`;
  await verifyCoreIdentity(coreUrl, corePid, coreInstanceId);
  await activateNext();

  try {
    await verifyCoreIdentity(coreUrl, corePid, coreInstanceId);
    await stopProcess(corePid, coreStopTimeoutMs);
  } catch (error) {
    await activatePrevious();
    throw error;
  }

  const nextCore = spawnCore(path.join(nextReleaseRoot, "dist", "core.js"), {
    cwd: nextReleaseRoot,
    serverRoot,
    port: corePort,
    detached: true,
    executable: coreExecutable,
  });
  try {
    await waitForCore(coreUrl, {
      child: nextCore,
      expectedPid: nextCore.pid,
      timeoutMs: coreStartTimeoutMs,
    });
    return nextCore;
  } catch (startupError) {
    let stopError;
    try {
      await stopChild(nextCore, coreStopTimeoutMs);
    } catch (error) {
      stopError = error;
    }
    await activatePrevious();
    await startReleaseCore({
      releaseRoot: previousReleaseRoot,
      serverRoot,
      corePort,
      coreStartTimeoutMs: Math.max(
        CORE_START_TIMEOUT_MS,
        coreStartTimeoutMs
      ),
    });
    throw new Error(
      `The updated core failed its final health check and the previous build was restored: ${
        startupError instanceof Error ? startupError.message : startupError
      }${stopError ? `; candidate cleanup also failed: ${stopError}` : ""}`
    );
  }
}

async function removeInactiveRelease(serverRoot, releaseRoot) {
  const active = await readReleasePointer(serverRoot);
  if (active?.releaseRoot === releaseRoot) return;
  await fs.rm(releaseRoot, { recursive: true, force: true }).catch(() => undefined);
}

async function pruneOldReleases(serverRoot, keepRoots) {
  const releasesRoot = path.join(serverRoot, ".roblox-mcp-releases");
  for (const entry of await fs.readdir(releasesRoot).catch(() => [])) {
    const releaseRoot = path.join(releasesRoot, entry);
    if (!keepRoots.has(releaseRoot)) {
      await fs.rm(releaseRoot, { recursive: true, force: true }).catch(() => undefined);
    }
  }
}

export async function activateCandidateBuild({
  serverRoot,
  candidateDist,
  candidateNodeModules,
  runId,
  corePid,
  coreInstanceId,
  corePort,
  coreExecutable,
  coreStartTimeoutMs = CORE_START_TIMEOUT_MS,
  coreStopTimeoutMs = CORE_STOP_TIMEOUT_MS,
  commit,
  activateCheckout = async () => undefined,
  writeStatus,
}) {
  const hasRunningCore = Number.isInteger(corePid) && corePid > 0;
  if (hasRunningCore !== Boolean(coreInstanceId)) {
    throw new Error("A running core update requires both its PID and instance ID.");
  }
  if (hasRunningCore) {
    await verifyCoreIdentity(
      `http://127.0.0.1:${corePort}`,
      corePid,
      coreInstanceId
    );
  }

  const previousPointer = await readReleasePointer(serverRoot);
  const previousReleaseRoot = previousPointer?.releaseRoot || serverRoot;
  const releaseRoot = path.join(
    serverRoot,
    ".roblox-mcp-releases",
    `${commit || "release"}-${runId}`
  );
  await fs.mkdir(releaseRoot, { recursive: true });
  try {
    await fs.rename(candidateDist, path.join(releaseRoot, "dist"));
    crashAtTestPhase("after-release-dist");
    await fs.rename(candidateNodeModules, path.join(releaseRoot, "node_modules"));
    crashAtTestPhase("after-release-dependencies");
  } catch (error) {
    await fs.rm(releaseRoot, { recursive: true, force: true }).catch(() => undefined);
    throw error;
  }

  const candidatePointer = { releaseRoot, runId, commit };
  try {
    await activateCheckout();
    crashAtTestPhase("after-checkout");
  } catch (error) {
    await removeInactiveRelease(serverRoot, releaseRoot);
    throw error;
  }
  await Promise.resolve(writeStatus({
    state: "restarting",
    message: "Switching to the verified update…",
  })).catch(() => undefined);

  let updatedCore;
  try {
    if (hasRunningCore) {
      updatedCore = await restartCoreWithRollback({
        serverRoot,
        corePid,
        coreInstanceId,
        corePort,
        nextReleaseRoot: releaseRoot,
        previousReleaseRoot,
        activateNext: async () => {
          await writeReleasePointer(serverRoot, candidatePointer);
          crashAtTestPhase("after-release-pointer");
        },
        activatePrevious: async () => {
          await writeReleasePointer(serverRoot, previousPointer);
        },
        coreExecutable,
        coreStartTimeoutMs,
        coreStopTimeoutMs,
      });
    } else {
      await writeReleasePointer(serverRoot, candidatePointer);
      crashAtTestPhase("after-release-pointer");
      try {
        updatedCore = await startReleaseCore({
          releaseRoot,
          serverRoot,
          corePort,
          coreStartTimeoutMs,
        });
      } catch (startupError) {
        await writeReleasePointer(serverRoot, previousPointer);
        throw new Error(
          `The updated core failed its final health check; the previous release remains selected: ${
            startupError instanceof Error ? startupError.message : startupError
          }`
        );
      }
    }
  } catch (error) {
    await removeInactiveRelease(serverRoot, releaseRoot);
    throw error;
  }

  await pruneOldReleases(
    serverRoot,
    new Set([
      releaseRoot,
      ...(previousPointer?.releaseRoot ? [previousPointer.releaseRoot] : []),
    ])
  );
  return {
    corePid: updatedCore.pid,
    releaseRoot,
    message:
      "Update complete. The background server restarted; connected adapters will reconnect automatically.",
  };
}
