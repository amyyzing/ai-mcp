import { randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";

import {
  readReleasePointer,
  releaseIsComplete,
  writeReleasePointer,
} from "../src/shared/release-pointer.mjs";

const SNAPSHOT_PREFIX = "terminal-checkout-";

function crashAtTestPhase(phase) {
  if (process.env.ROBLOX_MCP_TERMINAL_SNAPSHOT_FAULT_PHASE === phase) {
    process.kill(process.pid, "SIGKILL");
  }
}

async function removeOrphanedSnapshots(serverRoot) {
  const releasesRoot = path.join(serverRoot, ".roblox-mcp-releases");
  const active = await readReleasePointer(serverRoot);
  for (const entry of await fs.readdir(releasesRoot).catch(() => [])) {
    if (!entry.startsWith(SNAPSHOT_PREFIX)) continue;
    const releaseRoot = path.join(releasesRoot, entry);
    if (active?.releaseRoot === releaseRoot) continue;
    await fs.rm(releaseRoot, { recursive: true, force: true });
  }
}

async function syncTree(entryPath) {
  const stat = await fs.lstat(entryPath);
  if (stat.isSymbolicLink()) return;
  if (stat.isDirectory()) {
    for (const entry of await fs.readdir(entryPath)) {
      await syncTree(path.join(entryPath, entry));
    }
    await syncDirectory(entryPath);
    return;
  }
  if (
    process.env.ROBLOX_MCP_TERMINAL_SNAPSHOT_SYNC_FAILURE ===
    path.basename(entryPath)
  ) {
    const error = new Error(`Injected snapshot fsync failure for ${entryPath}`);
    error.code = "EIO";
    throw error;
  }
  // Windows requires a writable handle for FlushFileBuffers/fsync even when
  // the file contents are not being changed.
  const handle = await fs.open(entryPath, process.platform === "win32" ? "r+" : "r");
  try {
    await handle.sync();
  } finally {
    await handle.close();
  }
}

async function syncDirectory(directory) {
  let handle;
  try {
    handle = await fs.open(directory, "r");
    await handle.sync();
  } catch (error) {
    const unsupported = new Set([
      "EACCES",
      "EBADF",
      "EISDIR",
      "EINVAL",
      "ENOTSUP",
      "EPERM",
    ]);
    if (!unsupported.has(error?.code)) throw error;
  } finally {
    await handle?.close().catch(() => undefined);
  }
}

export async function prepareCheckoutRollback(
  serverRoot,
  { legacyMigration = false, ...options } = {}
) {
  if (legacyMigration) {
    return {
      created: false,
      managed: false,
      releaseRoot: null,
      skippedIncomplete: true,
    };
  }
  const active = await readReleasePointer(serverRoot);
  if (!active && !await releaseIsComplete(serverRoot)) {
    return {
      created: false,
      managed: false,
      releaseRoot: null,
      skippedIncomplete: true,
    };
  }
  return preserveCheckoutRuntime(serverRoot, options);
}

export async function preserveCheckoutRuntime(
  serverRoot,
  { dryRun = false, runId = randomUUID() } = {}
) {
  const active = await readReleasePointer(serverRoot);
  if (active) {
    return {
      created: false,
      managed: path.basename(active.releaseRoot).startsWith(SNAPSHOT_PREFIX),
      releaseRoot: active.releaseRoot,
    };
  }
  if (!await releaseIsComplete(serverRoot)) {
    throw new Error(
      "The current checkout runtime is incomplete, so it cannot be preserved for rollback."
    );
  }

  await removeOrphanedSnapshots(serverRoot);
  const releaseRoot = path.join(
    serverRoot,
    ".roblox-mcp-releases",
    `${SNAPSHOT_PREFIX}${runId}`
  );
  if (dryRun) return { created: true, managed: true, releaseRoot };

  await fs.mkdir(releaseRoot, { recursive: true });
  try {
    await fs.cp(
      path.join(serverRoot, "dist"),
      path.join(releaseRoot, "dist"),
      { recursive: true }
    );
    await fs.cp(
      path.join(serverRoot, "node_modules"),
      path.join(releaseRoot, "node_modules"),
      { recursive: true }
    );
    await syncTree(releaseRoot);
    await syncDirectory(path.dirname(releaseRoot));
    await syncDirectory(serverRoot);
    crashAtTestPhase("after-snapshot-dependencies");
    await writeReleasePointer(serverRoot, {
      releaseRoot,
      runId: `${SNAPSHOT_PREFIX}${runId}`,
    });
    return { created: true, managed: true, releaseRoot };
  } catch (error) {
    await fs.rm(releaseRoot, { recursive: true, force: true }).catch(() => undefined);
    throw error;
  }
}

export async function removeCheckoutSnapshot(serverRoot, snapshot) {
  if (!snapshot?.managed || typeof snapshot.releaseRoot !== "string") return;
  const releasesRoot = path.join(serverRoot, ".roblox-mcp-releases");
  const releaseRoot = path.resolve(snapshot.releaseRoot);
  if (
    path.dirname(releaseRoot) !== path.resolve(releasesRoot) ||
    !path.basename(releaseRoot).startsWith(SNAPSHOT_PREFIX)
  ) {
    throw new Error("Refusing to remove an invalid terminal-update snapshot.");
  }
  const active = await readReleasePointer(serverRoot);
  if (active?.releaseRoot === releaseRoot) return;
  await fs.rm(releaseRoot, { recursive: true, force: true });
}
