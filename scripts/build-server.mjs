#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const defaultDist = path.join(root, "dist");
const outputDir = path.resolve(process.env.ROBLOX_MCP_DIST_DIR || defaultDist);

if (outputDir === root || !outputDir.startsWith(`${root}${path.sep}`)) {
  throw new Error(`Refusing to build outside the repository: ${outputDir}`);
}

fs.rmSync(outputDir, { recursive: true, force: true });
const tscEntry = path.join(root, "node_modules", "typescript", "bin", "tsc");
const compile = spawnSync(
  process.execPath,
  [tscEntry, "--outDir", outputDir],
  { cwd: root, env: process.env, stdio: "inherit" }
);
if (compile.status !== 0) process.exit(compile.status || 1);

for (const extension of [".js", ".d.ts"]) {
  const indexEntry = path.join(outputDir, `index${extension}`);
  if (fs.existsSync(indexEntry)) {
    fs.renameSync(indexEntry, path.join(outputDir, `adapter${extension}`));
  }
}
fs.copyFileSync(
  path.join(root, "scripts", "adapter-bootstrap.mjs"),
  path.join(outputDir, "index.js")
);
fs.copyFileSync(
  path.join(root, "scripts", "core-bootstrap.mjs"),
  path.join(outputDir, "core-bootstrap.js")
);

const copy = spawnSync(
  process.execPath,
  [path.join(root, "scripts", "copy-assets.mjs")],
  {
    cwd: root,
    env: { ...process.env, ROBLOX_MCP_DIST_DIR: outputDir },
    stdio: "inherit",
  }
);
if (copy.status !== 0) process.exit(copy.status || 1);

const updaterDir = path.join(outputDir, "updater");
fs.mkdirSync(updaterDir, { recursive: true });
for (const filename of [
  "dashboard-startup-worker.mjs",
  "dashboard-update-git.mjs",
  "dashboard-update-worker.mjs",
  "dashboard-update-runtime.mjs",
  "legacy-runtime-migration.mjs",
  "update-command.mjs",
  "update-runner.mjs",
  "update-source.mjs",
]) {
  fs.copyFileSync(
    path.join(root, "scripts", filename),
    path.join(updaterDir, filename)
  );
}
