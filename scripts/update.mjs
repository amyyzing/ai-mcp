#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const serverRoot = path.resolve(
  process.env.ROBLOX_MCP_SERVER_ROOT ||
    path.join(path.dirname(fileURLToPath(import.meta.url)), "..")
);
process.env.ROBLOX_MCP_SERVER_ROOT = serverRoot;

let releaseRoot = serverRoot;
try {
  const pointer = JSON.parse(
    fs.readFileSync(path.join(serverRoot, ".roblox-mcp-current.json"), "utf8")
  );
  const candidate = path.resolve(pointer?.releaseRoot || "");
  const releasesRoot = path.join(serverRoot, ".roblox-mcp-releases");
  if (candidate.startsWith(`${releasesRoot}${path.sep}`)) releaseRoot = candidate;
} catch {
  // The root build is active until the first versioned update succeeds.
}

const bundledCommand = path.join(
  releaseRoot,
  "dist",
  "updater",
  "update-command.mjs"
);
const sourceCommand = path.join(serverRoot, "scripts", "update-command.mjs");
const commandEntry = fs.existsSync(bundledCommand) ? bundledCommand : sourceCommand;
await import(pathToFileURL(commandEntry).href);
