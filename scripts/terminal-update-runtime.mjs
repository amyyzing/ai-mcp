import { randomUUID } from "node:crypto";
import path from "node:path";

import {
  acquireUpdateLock,
  releaseUpdateLock,
} from "../src/shared/update-status.mjs";
import {
  readReleasePointer,
  writeReleasePointer,
} from "../src/shared/release-pointer.mjs";
import { installationIdentity } from "../src/shared/installation-identity.mjs";
import {
  findInstallationRuntimeProcesses,
  isCoreProcess,
  listMcpRuntimeProcesses,
} from "../src/shared/process-discovery.mjs";
import {
  fetchCoreInfo,
  restartCoreWithRollback,
  startReleaseCore,
  validateCandidateCore,
} from "./dashboard-update-runtime.mjs";

export function findBackgroundCoreProcesses(serverRoot) {
  return findInstallationRuntimeProcesses(serverRoot).filter(isCoreProcess);
}

async function discoverActiveCore(serverRoot, port) {
  const coreUrl = `http://127.0.0.1:${port}`;
  let info;
  try {
    info = await fetchCoreInfo(coreUrl);
  } catch {
    return null;
  }
  if (
    info?.architecture !== "background-core" ||
    !Number.isInteger(info.pid) ||
    typeof info.instanceId !== "string" ||
    info.installationId !== installationIdentity(serverRoot)
  ) {
    throw new Error(
      "The selected port is owned by a different Roblox MCP installation; refusing to replace it."
    );
  }
  const processInfo = listMcpRuntimeProcesses()
    .filter(isCoreProcess)
    .find((item) => item.pid === info.pid);
  if (!processInfo) {
    throw new Error(
      "The running core could not be verified from its process command; refusing to signal it."
    );
  }
  return { ...processInfo, instanceId: info.instanceId };
}

export async function activateCheckoutRuntime(
  serverRoot,
  {
    dryRun = false,
    port = Number(process.env.ROBLOX_MCP_PORT) || 16384,
    lockRunId = null,
  } = {}
) {
  const pointerPath = path.join(serverRoot, ".roblox-mcp-current.json");
  if (dryRun) {
    const active = await discoverActiveCore(serverRoot, port).catch(() => null);
    return {
      pointerPath,
      coreProcesses: active
        ? [active]
        : findBackgroundCoreProcesses(serverRoot),
      corePid: null,
    };
  }

  const runId = lockRunId || randomUUID();
  const ownsLock = !lockRunId;
  const commandToken = path.basename(process.argv[1] || "");
  if (ownsLock) await acquireUpdateLock(runId, { commandToken });
  try {
    const previousPointer = await readReleasePointer(serverRoot);
    const previousReleaseRoot = previousPointer?.releaseRoot || serverRoot;
    const active = await discoverActiveCore(serverRoot, port);
    const coreProcesses = active ? [active] : [];

    await validateCandidateCore(path.join(serverRoot, "dist"), serverRoot);

    if (!active) {
      await writeReleasePointer(serverRoot, null);
      try {
        const child = await startReleaseCore({
          releaseRoot: serverRoot,
          serverRoot,
          corePort: port,
        });
        return { pointerPath, coreProcesses, corePid: child.pid };
      } catch (error) {
        await writeReleasePointer(serverRoot, previousPointer);
        throw error;
      }
    }

    const child = await restartCoreWithRollback({
      serverRoot,
      corePid: active.pid,
      coreInstanceId: active.instanceId,
      corePort: port,
      nextReleaseRoot: serverRoot,
      previousReleaseRoot,
      activateNext: async () => {
        await writeReleasePointer(serverRoot, null);
      },
      activatePrevious: async () => {
        await writeReleasePointer(serverRoot, previousPointer);
      },
    });
    return { pointerPath, coreProcesses, corePid: child.pid };
  } finally {
    if (ownsLock) await releaseUpdateLock(runId).catch(() => undefined);
  }
}
