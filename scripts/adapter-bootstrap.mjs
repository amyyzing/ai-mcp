#!/usr/bin/env node

import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { readReleasePointerSync } from "./shared/release-pointer.mjs";

const distRoot = path.dirname(fileURLToPath(import.meta.url));
const serverRoot = path.resolve(
  process.env.ROBLOX_MCP_SERVER_ROOT || path.dirname(distRoot)
);
process.env.ROBLOX_MCP_SERVER_ROOT = serverRoot;
let adapterEntry = path.join(distRoot, "adapter.js");

const activeRelease = readReleasePointerSync(serverRoot);
if (activeRelease) {
  adapterEntry = path.join(activeRelease.releaseRoot, "dist", "adapter.js");
}

await import(pathToFileURL(adapterEntry).href);
