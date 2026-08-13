import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

export function canonicalServerRoot(serverRoot) {
  const resolved = path.resolve(serverRoot);
  let canonical;
  try {
    canonical = fs.realpathSync.native(resolved);
  } catch {
    canonical = resolved;
  }
  const normalized = canonical.replace(/\\/g, "/");
  return process.platform === "win32" ? normalized.toLowerCase() : normalized;
}

export function installationIdentity(serverRoot) {
  return crypto
    .createHash("sha256")
    .update(canonicalServerRoot(serverRoot))
    .digest("hex");
}
