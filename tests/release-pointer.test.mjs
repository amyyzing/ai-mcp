import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  readReleasePointerSync,
  resolveActiveReleaseRoot,
  writeReleasePointer,
} from "../src/shared/release-pointer.mjs";

test("incomplete release pointers fall back to the stable checkout", async (t) => {
  const serverRoot = await fs.mkdtemp(
    path.join(os.tmpdir(), "roblox-mcp-incomplete-release-")
  );
  const releaseRoot = path.join(serverRoot, ".roblox-mcp-releases", "partial");
  t.after(() => fs.rm(serverRoot, { recursive: true, force: true }));
  await fs.mkdir(path.join(releaseRoot, "dist"), { recursive: true });
  await fs.writeFile(path.join(releaseRoot, "dist", "adapter.js"), "", "utf8");
  await fs.writeFile(
    path.join(serverRoot, ".roblox-mcp-current.json"),
    `${JSON.stringify({ releaseRoot, runId: "partial" })}\n`,
    "utf8"
  );

  assert.equal(readReleasePointerSync(serverRoot), null);
  assert.equal(await resolveActiveReleaseRoot(serverRoot), serverRoot);
  await assert.rejects(
    writeReleasePointer(serverRoot, { releaseRoot, runId: "partial" }),
    /incomplete release/
  );

  await fs.writeFile(path.join(releaseRoot, "dist", "core.js"), "", "utf8");
  await fs.mkdir(path.join(releaseRoot, "node_modules"));
  await writeReleasePointer(serverRoot, { releaseRoot, runId: "complete" });
  assert.equal(readReleasePointerSync(serverRoot)?.releaseRoot, releaseRoot);
  assert.equal(await resolveActiveReleaseRoot(serverRoot), releaseRoot);
});

test("the stable adapter bootstrap uses the canonical pointer validator", async () => {
  const bootstrap = await fs.readFile(
    path.resolve(import.meta.dirname, "..", "scripts", "adapter-bootstrap.mjs"),
    "utf8"
  );
  assert.match(bootstrap, /readReleasePointerSync\(serverRoot\)/);
  assert.doesNotMatch(bootstrap, /JSON\.parse\(fs\.readFileSync/);
});
