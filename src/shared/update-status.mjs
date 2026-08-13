import { spawnSync } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {
  withFileTransaction,
  writeJsonAtomic,
} from "./atomic-json.mjs";

export const UPDATE_STATUS_PATH = path.join(
  os.homedir(),
  ".roblox-mcp",
  "update-status.json"
);
export const UPDATE_LOCK_PATH = path.join(
  os.homedir(),
  ".roblox-mcp",
  "update.lock"
);

export async function readUpdateStatus() {
  try {
    const raw = await fs.readFile(UPDATE_STATUS_PATH, "utf8");
    const status = JSON.parse(raw);
    return status && typeof status === "object"
      ? status
      : { state: "idle", message: "No update has been run yet." };
  } catch {
    return { state: "idle", message: "No update has been run yet." };
  }
}

export async function writeUpdateStatus(status, options = {}) {
  return withFileTransaction(UPDATE_STATUS_PATH, async () => {
    if (options.expectedRunId) {
      const current = await readUpdateStatus();
      if (current.runId !== options.expectedRunId) return false;
    }
    await writeJsonAtomic(UPDATE_STATUS_PATH, {
      ...status,
      updatedAt: Date.now(),
    });
    return true;
  });
}

export async function readUpdateLock() {
  try {
    const lock = JSON.parse(await fs.readFile(UPDATE_LOCK_PATH, "utf8"));
    return lock && typeof lock === "object" ? lock : null;
  } catch {
    return null;
  }
}

export function processIsRunning(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

export function updateWorkerIsRunning(lock) {
  if (
    !lock ||
    !Number.isInteger(lock.workerPid) ||
    typeof lock.runId !== "string" ||
    !processIsRunning(lock.workerPid)
  ) {
    return false;
  }
  const pid = String(lock.workerPid);
  const result =
    process.platform === "win32"
      ? spawnSync(
          "powershell.exe",
          [
            "-NoProfile",
            "-Command",
            `(Get-CimInstance Win32_Process -Filter "ProcessId = ${pid}").CommandLine`,
          ],
          { encoding: "utf8", windowsHide: true }
        )
      : spawnSync("ps", ["-p", pid, "-o", "command="], {
          encoding: "utf8",
          windowsHide: true,
        });
  const token =
    typeof lock.commandToken === "string" && lock.commandToken
      ? lock.commandToken
      : lock.runId;
  return result.status === 0 && result.stdout.includes(token);
}

export async function acquireUpdateLock(runId, options = {}) {
  await fs.mkdir(path.dirname(UPDATE_LOCK_PATH), { recursive: true });
  const lock = {
    runId,
    workerPid: process.pid,
    createdAt: Date.now(),
    commandToken: options.commandToken || runId,
  };
  try {
    await fs.writeFile(UPDATE_LOCK_PATH, `${JSON.stringify(lock)}\n`, {
      encoding: "utf8",
      mode: 0o600,
      flag: "wx",
    });
    return lock;
  } catch (error) {
    if (error?.code !== "EEXIST") throw error;
    const existing = await readUpdateLock();
    if (updateWorkerIsRunning(existing)) {
      throw new Error(`Update ${existing.runId || "worker"} is already running.`);
    }
    await fs.unlink(UPDATE_LOCK_PATH).catch(() => undefined);
    return acquireUpdateLock(runId, options);
  }
}

export async function releaseUpdateLock(runId) {
  const current = await readUpdateLock();
  if (!current || current.runId !== runId) return false;
  await fs.unlink(UPDATE_LOCK_PATH).catch(() => undefined);
  return true;
}
