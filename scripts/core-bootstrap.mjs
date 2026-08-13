#!/usr/bin/env node

import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const bundledRuntime = path.basename(scriptDirectory) === "dist";
const serverRoot = path.resolve(
  process.env.ROBLOX_MCP_SERVER_ROOT ||
    path.dirname(scriptDirectory)
);
process.env.ROBLOX_MCP_SERVER_ROOT = serverRoot;
const releasePointerModule = bundledRuntime
  ? path.join(scriptDirectory, "shared", "release-pointer.mjs")
  : path.join(serverRoot, "dist", "shared", "release-pointer.mjs");
const { readReleasePointerSync } = await import(
  pathToFileURL(releasePointerModule).href
);
const active = readReleasePointerSync(serverRoot);
const coreEntry = path.join(
  active?.releaseRoot || serverRoot,
  "dist",
  "core.js"
);

await import(pathToFileURL(coreEntry).href);
