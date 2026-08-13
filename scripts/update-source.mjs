import { createHash } from "node:crypto";
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import fsPromises from "node:fs/promises";
import path from "node:path";

// There is intentionally no network update source baked into the executable.
// A deleted, transferred, or compromised repository must not silently become a
// code-execution channel on every installed MCP server. Git checkouts continue
// to use their configured upstream; archive installs require an explicit URL.
export const DEFAULT_UPDATE_ARCHIVE_URL = "";

const MAX_ARCHIVE_BYTES = 512 * 1024 * 1024;
const MAX_ARCHIVE_ENTRIES = 50_000;
const MAX_EXTRACTED_ARCHIVE_BYTES = 1024 * 1024 * 1024;
const ARCHIVE_INSPECTION_TIMEOUT_MS = 120_000;

function git(root, args) {
  const result = spawnSync("git", args, {
    cwd: root,
    encoding: "utf8",
    windowsHide: true,
  });
  return result.status === 0 ? result.stdout.trim() : null;
}

export function hasOwnGitCheckout(root) {
  const topLevel = git(root, ["rev-parse", "--show-toplevel"]);
  if (!topLevel) return false;
  try {
    return fs.realpathSync.native(topLevel) === fs.realpathSync.native(root);
  } catch {
    return false;
  }
}

export function trackingReference(root) {
  if (!hasOwnGitCheckout(root)) return null;
  return git(root, [
    "rev-parse",
    "--abbrev-ref",
    "--symbolic-full-name",
    "@{u}",
  ]);
}

function updateArchiveUrl(value) {
  if (typeof value !== "string" || !value.trim()) {
    throw new Error(
      "No trusted update archive is configured. Set ROBLOX_MCP_UPDATE_ARCHIVE_URL to an HTTPS archive you control."
    );
  }
  const url = new URL(value.trim());
  const loopback = new Set(["127.0.0.1", "::1", "localhost"]);
  if (url.protocol !== "https:" && !(url.protocol === "http:" && loopback.has(url.hostname))) {
    throw new Error("The update archive must use HTTPS (or loopback HTTP for local testing).");
  }
  return url;
}

async function downloadArchive(url, destination, fetchImpl) {
  const response = await fetchImpl(url, {
    redirect: "follow",
    headers: {
      Accept: "application/gzip, application/octet-stream",
      "User-Agent": "roblox-mcp-updater",
    },
    signal: AbortSignal.timeout(120_000),
  });
  // `fetch` may follow redirects across schemes. Re-validate the final URL so
  // an HTTPS update source cannot silently downgrade to cleartext HTTP.
  updateArchiveUrl(response.url || url.toString());
  if (!response.ok) {
    throw new Error(`Could not download the latest Roblox MCP archive (HTTP ${response.status}).`);
  }
  const advertisedSize = Number(response.headers.get("content-length") || 0);
  if (advertisedSize > MAX_ARCHIVE_BYTES) {
    throw new Error("The update archive is larger than the allowed 512 MB limit.");
  }
  if (!response.body) throw new Error("The update archive response was empty.");

  const digest = createHash("sha256");
  const handle = await fsPromises.open(destination, "wx", 0o600);
  let received = 0;
  const reader = response.body.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      received += value.byteLength;
      if (received > MAX_ARCHIVE_BYTES) {
        throw new Error("The update archive exceeded the allowed 512 MB limit.");
      }
      digest.update(value);
      let offset = 0;
      while (offset < value.byteLength) {
        const { bytesWritten } = await handle.write(
          value,
          offset,
          value.byteLength - offset
        );
        if (!bytesWritten) throw new Error("The update archive could not be saved completely.");
        offset += bytesWritten;
      }
    }
    await handle.sync();
  } finally {
    await reader.cancel().catch(() => undefined);
    await handle.close();
  }
  if (!received) throw new Error("The update archive response was empty.");
  return digest.digest("hex");
}

async function measureArchiveContents(archivePath, maxExtractedBytes) {
  await new Promise((resolve, reject) => {
    const child = spawn("tar", ["-xOzf", archivePath], {
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    });
    let extractedBytes = 0;
    let stderr = "";
    let limitExceeded = false;
    let timedOut = false;
    const timeout = setTimeout(() => {
      timedOut = true;
      child.kill();
    }, ARCHIVE_INSPECTION_TIMEOUT_MS);

    child.stdout.on("data", (chunk) => {
      extractedBytes += chunk.length;
      if (extractedBytes > maxExtractedBytes && !limitExceeded) {
        limitExceeded = true;
        child.kill();
      }
    });
    child.stderr.on("data", (chunk) => {
      stderr = `${stderr}${chunk}`.slice(-8_000);
    });
    child.once("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
    child.once("close", (code) => {
      clearTimeout(timeout);
      if (limitExceeded) {
        reject(new Error("The update archive expands beyond the allowed 1 GB limit."));
      } else if (timedOut) {
        reject(new Error("Timed out while measuring the expanded update archive."));
      } else if (code !== 0) {
        reject(new Error(stderr.trim() || "The update archive could not be expanded safely."));
      } else {
        resolve();
      }
    });
  });
}

export async function inspectArchive(
  archivePath,
  {
    maxEntries = MAX_ARCHIVE_ENTRIES,
    maxExtractedBytes = MAX_EXTRACTED_ARCHIVE_BYTES,
  } = {}
) {
  const inspectOptions = {
    encoding: "utf8",
    windowsHide: true,
    timeout: 30_000,
    maxBuffer: 16 * 1024 * 1024,
  };
  const listing = spawnSync("tar", ["-tzf", archivePath], {
    ...inspectOptions,
  });
  if (listing.status !== 0) {
    throw new Error(
      listing.error?.message || listing.stderr?.trim() || "The downloaded update archive is invalid."
    );
  }
  const entries = listing.stdout.split(/\r?\n/).filter(Boolean);
  if (!entries.length) throw new Error("The downloaded update archive is empty.");
  if (entries.length > maxEntries) {
    throw new Error(`The update archive contains more than ${maxEntries} entries.`);
  }

  let rootName = null;
  for (const entry of entries) {
    const normalized = entry.replace(/\\/g, "/");
    if (normalized.startsWith("/") || normalized.split("/").includes("..")) {
      throw new Error("The downloaded update archive contains an unsafe path.");
    }
    const first = normalized.split("/")[0];
    if (!first || first === ".") {
      throw new Error("The downloaded update archive has an invalid root folder.");
    }
    rootName ||= first;
    if (first !== rootName) {
      throw new Error("The downloaded update archive must contain one repository root.");
    }
  }

  const verbose = spawnSync("tar", ["-tvzf", archivePath], {
    ...inspectOptions,
  });
  if (verbose.status !== 0) {
    throw new Error(
      verbose.error?.message || verbose.stderr?.trim() || "The downloaded update archive could not be inspected."
    );
  }
  if (
    verbose.stdout
      .split(/\r?\n/)
      .some((line) => line && !/^[-d]/.test(line.trimStart()))
  ) {
    throw new Error("The downloaded update archive contains unsupported links or special files.");
  }

  await measureArchiveContents(archivePath, maxExtractedBytes);
}

function extractArchive(archivePath, stagingRoot) {
  const extraction = spawnSync(
    "tar",
    [
      "-xzf",
      archivePath,
      "--strip-components=1",
      "--no-same-owner",
      "-C",
      stagingRoot,
    ],
    { encoding: "utf8", windowsHide: true }
  );
  if (extraction.status !== 0) {
    throw new Error(extraction.stderr.trim() || "The update archive could not be extracted.");
  }
}

export async function prepareArchiveSource({
  serverRoot,
  stagingRoot,
  archiveUrl = process.env.ROBLOX_MCP_UPDATE_ARCHIVE_URL || DEFAULT_UPDATE_ARCHIVE_URL,
  fetchImpl = fetch,
  expectedSha256 = process.env.ROBLOX_MCP_UPDATE_ARCHIVE_SHA256 || "",
}) {
  const resolvedStagingRoot = path.resolve(stagingRoot);
  if (
    path.dirname(resolvedStagingRoot) !== path.resolve(serverRoot) ||
    !path.basename(resolvedStagingRoot).startsWith(".roblox-mcp-update-")
  ) {
    throw new Error("Refusing to extract an update outside the installation directory.");
  }
  const archivePath = `${resolvedStagingRoot}.tar.gz`;
  await fsPromises.rm(resolvedStagingRoot, { recursive: true, force: true });
  await fsPromises.rm(archivePath, { force: true });
  await fsPromises.mkdir(resolvedStagingRoot, { recursive: true });
  try {
    const digest = await downloadArchive(
      updateArchiveUrl(archiveUrl),
      archivePath,
      fetchImpl
    );
    const normalizedExpected = String(expectedSha256).trim().toLowerCase();
    if (normalizedExpected) {
      if (!/^[a-f0-9]{64}$/.test(normalizedExpected)) {
        throw new Error("ROBLOX_MCP_UPDATE_ARCHIVE_SHA256 must be a 64-character SHA-256 digest.");
      }
      if (digest !== normalizedExpected) {
        throw new Error(
          `Update archive SHA-256 mismatch (expected ${normalizedExpected}, received ${digest}).`
        );
      }
    }
    await inspectArchive(archivePath);
    extractArchive(archivePath, resolvedStagingRoot);
    await Promise.all([
      fsPromises.access(path.join(resolvedStagingRoot, "package.json")),
      fsPromises.access(path.join(resolvedStagingRoot, "scripts", "build-server.mjs")),
    ]);
    return {
      kind: "archive",
      revision: `archive-${digest.slice(0, 12)}`,
      stagingRoot: resolvedStagingRoot,
      archivePath,
    };
  } catch (error) {
    await fsPromises.rm(resolvedStagingRoot, { recursive: true, force: true }).catch(() => undefined);
    throw error;
  } finally {
    await fsPromises.rm(archivePath, { force: true }).catch(() => undefined);
  }
}

export async function cleanupPreparedSource(source, runCommand) {
  if (!source?.stagingRoot) return;
  if (source.kind === "git") {
    await runCommand(
      "git",
      ["worktree", "remove", "--force", source.stagingRoot],
      { cwd: source.serverRoot }
    ).catch(() => undefined);
  }
  await fsPromises.rm(source.stagingRoot, { recursive: true, force: true }).catch(() => undefined);
  if (source.archivePath) {
    await fsPromises.rm(source.archivePath, { force: true }).catch(() => undefined);
  }
}
