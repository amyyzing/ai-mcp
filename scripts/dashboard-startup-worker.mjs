#!/usr/bin/env node

import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const bundledRuntime =
  path.basename(scriptDirectory) === "updater" &&
  path.basename(path.dirname(scriptDirectory)) === "dist";
const serverRoot = path.resolve(
  argValue("--server-root") ||
  process.env.ROBLOX_MCP_SERVER_ROOT ||
  (bundledRuntime
    ? path.resolve(scriptDirectory, "..", "..")
    : path.resolve(scriptDirectory, ".."))
);
const sharedDirectory = bundledRuntime
  ? path.join(scriptDirectory, "..", "shared")
  : path.join(serverRoot, "dist", "shared");
const mode = argValue("--mode");
const enabled = mode === "background";
const dryRun = process.env.ROBLOX_MCP_DASHBOARD_SETUP_DRY_RUN === "1";

if (mode !== "background" && mode !== "on-demand") {
  throw new Error("Startup mode must be background or on-demand.");
}

const { applyBackgroundService } = await import(
  pathToFileURL(
    path.join(sharedDirectory, "background-service-install.mjs")
  ).href
);
const { writeStartupStatus } = await import(
  pathToFileURL(path.join(sharedDirectory, "startup-status.mjs")).href
);

try {
  await new Promise((resolve) => setTimeout(resolve, 750));
  const service = await applyBackgroundService({
    serverRoot,
    mode,
    dryRun,
  });
  if (!enabled && !dryRun) startOnDemandCore();
  await writeStartupStatus({
    state: "complete",
    message: enabled
      ? `Roblox MCP will start with your computer using ${service.manager}.`
      : "Roblox MCP will only start when an AI harness connects.",
    enabled,
    startedAt: Number(argValue("--started-at")) || Date.now(),
    finishedAt: Date.now(),
    workerPid: process.pid,
  });
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  await writeStartupStatus({
    state: "failed",
    message: "The startup preference could not be changed.",
    enabled: !enabled,
    startedAt: Number(argValue("--started-at")) || Date.now(),
    finishedAt: Date.now(),
    workerPid: process.pid,
    error: message,
  }).catch(() => undefined);
  process.exitCode = 1;
}

function startOnDemandCore() {
  const child = spawn(
    process.execPath,
    [path.join(serverRoot, "dist", "core-bootstrap.js")],
    {
      cwd: serverRoot,
      detached: true,
      env: { ...process.env, ROBLOX_MCP_SERVER_ROOT: serverRoot },
      stdio: "ignore",
      windowsHide: true,
    }
  );
  child.unref();
}

function argValue(flag) {
  const index = process.argv.indexOf(flag);
  const value = index >= 0 ? process.argv[index + 1] : "";
  return value && !value.startsWith("--") ? value : null;
}
