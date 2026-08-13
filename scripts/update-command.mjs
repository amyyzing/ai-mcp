#!/usr/bin/env node

import { randomUUID } from "node:crypto";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { fetchCoreInfo } from "./dashboard-update-runtime.mjs";
import {
  legacyServerRequiresShutdown,
  waitForLegacyServerShutdown,
} from "./legacy-runtime-migration.mjs";
import { runStagedUpdate } from "./update-runner.mjs";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const bundledRuntime =
  path.basename(scriptDirectory) === "updater" &&
  path.basename(path.dirname(scriptDirectory)) === "dist";
const serverRoot = path.resolve(
  process.env.ROBLOX_MCP_SERVER_ROOT ||
    (bundledRuntime
      ? path.resolve(scriptDirectory, "..", "..")
      : path.resolve(scriptDirectory, ".."))
);
process.env.ROBLOX_MCP_SERVER_ROOT = serverRoot;

const sharedDirectory = bundledRuntime
  ? path.join(scriptDirectory, "..", "shared")
  : path.join(serverRoot, "src", "shared");
const [updateStatus, installationIdentityModule, processDiscovery] = await Promise.all([
  import(pathToFileURL(path.join(sharedDirectory, "update-status.mjs")).href),
  import(pathToFileURL(path.join(sharedDirectory, "installation-identity.mjs")).href),
  import(pathToFileURL(path.join(sharedDirectory, "process-discovery.mjs")).href),
]);
const {
  acquireUpdateLock,
  releaseUpdateLock,
  writeUpdateStatus,
} = updateStatus;
const { installationIdentity } = installationIdentityModule;
const {
  findInstallationRuntimeProcesses,
  isCoreProcess,
  listMcpRuntimeProcesses,
} = processDiscovery;

const corePort = Number(process.env.ROBLOX_MCP_PORT) || 16384;
const runId = randomUUID();
const startedAt = Date.now();

async function report(message, extra = {}) {
  const state = extra.state || "running";
  await writeUpdateStatus({
    state,
    message,
    source: extra.source,
    runId,
    workerPid: process.pid,
    startedAt,
    finishedAt: extra.finishedAt,
    error: extra.error,
  });
  if (state !== "restarting") console.log(message);
}

async function activeCore() {
  let info;
  try {
    info = await fetchCoreInfo(`http://127.0.0.1:${corePort}`);
  } catch {
    return null;
  }
  if (info?.architecture !== "background-core") return null;
  if (
    !Number.isInteger(info.pid) ||
    typeof info.instanceId !== "string" ||
    info.installationId !== installationIdentity(serverRoot)
  ) {
    throw new Error(
      "The MCP port belongs to a different installation; refusing to replace it."
    );
  }
  const verified = listMcpRuntimeProcesses()
    .filter(isCoreProcess)
    .some((processInfo) => processInfo.pid === info.pid);
  if (!verified) {
    throw new Error(
      "The running core could not be verified from its process command; refusing to signal it."
    );
  }
  return info;
}

async function stopLegacyRuntime() {
  if (!await legacyServerRequiresShutdown(corePort)) return;
  const legacyProcesses = findInstallationRuntimeProcesses(serverRoot).filter(
    (item) => item.command.replace(/\\/g, "/").includes("dist/index.js")
  );
  if (!legacyProcesses.length) {
    throw new Error(
      "A legacy MCP server is using the port. Close its harness and run the update again."
    );
  }
  console.log("Stopping the legacy MCP runtime before the architecture upgrade…");
  for (const processInfo of legacyProcesses) {
    try {
      process.kill(processInfo.pid, "SIGTERM");
    } catch (error) {
      if (error?.code !== "ESRCH") throw error;
    }
  }
  await waitForLegacyServerShutdown(corePort);
}

async function main() {
  await acquireUpdateLock(runId, {
    commandToken: path.basename(process.argv[1] || "update.mjs"),
  });
  try {
    console.log(`Updating Roblox MCP in ${serverRoot}`);
    await stopLegacyRuntime();
    const core = await activeCore();
    const result = await runStagedUpdate({
      serverRoot,
      runId,
      corePid: core?.pid || null,
      coreInstanceId: core?.instanceId || null,
      corePort,
      status: report,
    });
    await report(result.message, {
      state: "complete",
      source: result.source,
      finishedAt: Date.now(),
    });
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    await report(`Automatic update failed: ${detail}`, {
      state: "failed",
      finishedAt: Date.now(),
      error: detail,
    }).catch(() => undefined);
    throw error;
  } finally {
    await releaseUpdateLock(runId).catch(() => undefined);
  }
}

await main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
