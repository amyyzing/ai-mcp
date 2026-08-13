import fs from "node:fs";
import path from "node:path";
import { writeJsonAtomic } from "./atomic-json.mjs";

export const RELEASE_POINTER_FILENAME = ".roblox-mcp-current.json";
export const RELEASES_DIRECTORY_NAME = ".roblox-mcp-releases";

function safeReleaseRoot(serverRoot, value) {
  if (typeof value !== "string" || !value) return null;
  const releasesRoot = path.resolve(serverRoot, RELEASES_DIRECTORY_NAME);
  const releaseRoot = path.resolve(value);
  return releaseRoot.startsWith(`${releasesRoot}${path.sep}`) ? releaseRoot : null;
}

export function releaseIsCompleteSync(releaseRoot) {
  return [
    path.join(releaseRoot, "dist", "adapter.js"),
    path.join(releaseRoot, "dist", "core.js"),
    path.join(releaseRoot, "node_modules"),
  ].every((entry) => fs.existsSync(entry));
}

export async function releaseIsComplete(releaseRoot) {
  const results = await Promise.all(
    [
      path.join(releaseRoot, "dist", "adapter.js"),
      path.join(releaseRoot, "dist", "core.js"),
      path.join(releaseRoot, "node_modules"),
    ].map((entry) =>
      fs.promises.access(entry).then(() => true, () => false)
    )
  );
  return results.every(Boolean);
}

export function readReleasePointerSync(serverRoot) {
  try {
    const pointer = JSON.parse(
      fs.readFileSync(path.join(serverRoot, RELEASE_POINTER_FILENAME), "utf8")
    );
    const releaseRoot = safeReleaseRoot(serverRoot, pointer?.releaseRoot);
    return releaseRoot && releaseIsCompleteSync(releaseRoot)
      ? { ...pointer, releaseRoot }
      : null;
  } catch {
    return null;
  }
}

export async function readReleasePointer(serverRoot) {
  try {
    const pointer = JSON.parse(
      await fs.promises.readFile(
        path.join(serverRoot, RELEASE_POINTER_FILENAME),
        "utf8"
      )
    );
    const releaseRoot = safeReleaseRoot(serverRoot, pointer?.releaseRoot);
    return releaseRoot && await releaseIsComplete(releaseRoot)
      ? { ...pointer, releaseRoot }
      : null;
  } catch {
    return null;
  }
}

export async function writeReleasePointer(serverRoot, pointer) {
  const pointerPath = path.join(serverRoot, RELEASE_POINTER_FILENAME);
  if (pointer === null) {
    await fs.promises.rm(pointerPath, { force: true });
    return;
  }
  const releaseRoot = safeReleaseRoot(serverRoot, pointer.releaseRoot);
  if (!releaseRoot) throw new Error("Refusing to activate a release outside the release store.");
  if (!await releaseIsComplete(releaseRoot)) {
    throw new Error("Refusing to activate an incomplete release.");
  }
  await writeJsonAtomic(pointerPath, { ...pointer, releaseRoot });
}

export async function resolveActiveReleaseRoot(serverRoot) {
  return (await readReleasePointer(serverRoot))?.releaseRoot || serverRoot;
}
