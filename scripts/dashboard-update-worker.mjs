#!/usr/bin/env node

import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { restartActiveCore } from "./dashboard-update-runtime.mjs";
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
const statusModuleUrl = pathToFileURL(
  bundledRuntime
    ? path.join(scriptDirectory, "..", "shared", "update-status.mjs")
    : path.join(serverRoot, "dist", "shared", "update-status.mjs")
).href;
const {
  acquireUpdateLock,
  releaseUpdateLock,
  writeUpdateStatus,
} = await import(statusModuleUrl);

const runId = argValue("--run-id");
const corePid = Number.parseInt(argValue("--core-pid") || "", 10);
const coreInstanceId = argValue("--core-instance-id");
const restartOnly = process.argv.includes("--restart-only");
const corePort =
  Number.parseInt(process.env.ROBLOX_MCP_PORT || "", 10) || 16384;
const operationStartedAt = Date.now();
const RUN_ID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function argValue(flag) {
  const index = process.argv.indexOf(flag);
  const value = index >= 0 ? process.argv[index + 1] : "";
  return value && !value.startsWith("--") ? value : null;
}

async function status(state, message, extra = {}) {
  await writeUpdateStatus(
    {
      state,
      message,
      runId,
      source: extra.source,
      startedAt: extra.startedAt || operationStartedAt,
      finishedAt: extra.finishedAt,
      error: extra.error,
      operation: restartOnly ? "restart" : "update",
      workerPid: process.pid,
    },
    { expectedRunId: runId }
  );
}

async function main() {
  if (!runId || !RUN_ID_PATTERN.test(runId)) {
    throw new Error("Invalid --run-id; expected a UUID.");
  }
  if (!Number.isInteger(corePid) || corePid <= 0) throw new Error("Invalid --core-pid.");
  if (!coreInstanceId) throw new Error("Missing --core-instance-id.");

  await acquireUpdateLock(runId);
  const startedAt = operationStartedAt;
  const result = restartOnly
    ? await restartActiveCore({ serverRoot, corePid, coreInstanceId, corePort })
    : await runStagedUpdate({
        serverRoot,
        runId,
        corePid,
        coreInstanceId,
        corePort,
        status: (message, extra = {}) => status(
          extra.state || "running",
          message,
          { ...extra, startedAt }
        ),
      });
  await status("complete", result.message, {
    source: restartOnly ? "active-release" : result.source,
    startedAt,
    finishedAt: Date.now(),
  }).catch(() => undefined);
}

main()
  .catch(async (error) => {
    const detail = error instanceof Error ? error.message : String(error);
    const message = detail.length > 1_500 ? `${detail.slice(0, 1_500)}…` : detail;
    if (runId) {
      await status("failed", `${restartOnly ? "Server restart" : "Automatic update"} failed: ${message}`, {
        finishedAt: Date.now(),
        error: message,
      }).catch(() => undefined);
    } else {
      console.error(`Automatic update failed: ${message}`);
    }
    process.exitCode = 1;
  })
  .finally(async () => {
    if (runId) await releaseUpdateLock(runId).catch(() => undefined);
  });
