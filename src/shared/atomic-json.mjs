import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";

const fileTransactions = new Map();

export async function withFileTransaction(filePath, operation) {
  const previous = fileTransactions.get(filePath) ?? Promise.resolve();
  const current = previous.catch(() => undefined).then(operation);
  fileTransactions.set(filePath, current);
  try {
    return await current;
  } finally {
    if (fileTransactions.get(filePath) === current) fileTransactions.delete(filePath);
  }
}

async function syncDirectory(directory) {
  let handle;
  try {
    handle = await fs.open(directory, "r");
    await handle.sync();
  } catch {
    // Directory fsync is not supported by every Windows/filesystem combination.
  } finally {
    await handle?.close().catch(() => undefined);
  }
}

export async function writeJsonAtomic(filePath, value, mode = 0o600) {
  const directory = path.dirname(filePath);
  await fs.mkdir(directory, { recursive: true });
  const temporaryPath = `${filePath}.${process.pid}.${crypto.randomUUID()}.tmp`;
  let committed = false;
  try {
    const handle = await fs.open(temporaryPath, "wx", mode);
    try {
      await handle.writeFile(`${JSON.stringify(value, null, 2)}\n`, "utf8");
      await handle.sync();
    } finally {
      await handle.close();
    }
    await fs.rename(temporaryPath, filePath);
    committed = true;
    await fs.chmod(filePath, mode).catch(() => undefined);
    await syncDirectory(directory);
  } finally {
    if (!committed) await fs.unlink(temporaryPath).catch(() => undefined);
  }
}
