import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const repoRoot = path.resolve(import.meta.dirname, "..");
const moduleUrl = new URL("../src/shared/update-status.mjs", import.meta.url).href;

test("update status uses operation IDs and an exclusive worker lock", async (t) => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "roblox-mcp-status-"));
  t.after(() => fs.rm(home, { recursive: true, force: true }));
  const source = `
    import assert from "node:assert/strict";
    import crypto from "node:crypto";
    const status = await import(${JSON.stringify(moduleUrl)});
    await status.writeUpdateStatus({ state: "running", message: "one", runId: "run-one" });
    assert.equal(
      await status.writeUpdateStatus(
        { state: "failed", message: "stale", runId: "run-zero" },
        { expectedRunId: "run-zero" }
      ),
      false
    );
    assert.equal((await status.readUpdateStatus()).message, "one");
    await status.acquireUpdateLock("run-one");
    await assert.rejects(status.acquireUpdateLock("run-two"), /already running/);
    assert.equal(status.updateWorkerIsRunning(await status.readUpdateLock()), true);
    assert.equal(
      status.updateWorkerIsRunning({
        workerPid: process.pid,
        runId: crypto.randomUUID(),
        createdAt: Date.now()
      }),
      false
    );
    assert.equal(await status.releaseUpdateLock("run-two"), false);
    assert.equal(await status.releaseUpdateLock("run-one"), true);
    await (await import("node:fs/promises")).writeFile(
      status.UPDATE_LOCK_PATH,
      JSON.stringify({ runId: "stale", workerPid: 2147483647, createdAt: 1 })
    );
    await status.acquireUpdateLock("terminal-run", {
      commandToken: "terminal-update-runtime.mjs"
    });
    assert.equal(
      (await status.readUpdateLock()).commandToken,
      "terminal-update-runtime.mjs"
    );
    assert.equal(await status.releaseUpdateLock("terminal-run"), true);
  `;
  await execFileAsync(process.execPath, ["--input-type=module", "-e", source], {
    cwd: repoRoot,
    env: { ...process.env, HOME: home, USERPROFILE: home },
  });
});
