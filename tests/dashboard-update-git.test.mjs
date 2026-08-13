import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  advanceCheckout,
  assertFastForward,
  inspectCleanCheckout,
  restoreCheckout,
} from "../scripts/dashboard-update-git.mjs";

function run(root, command, args) {
  const useNpmCli = process.platform === "win32" && command === "npm";
  const executable = useNpmCli ? process.execPath : command;
  const commandArgs = useNpmCli
    ? [path.join(path.dirname(process.execPath), "node_modules", "npm", "bin", "npm-cli.js"), ...args]
    : args;
  const result = spawnSync(executable, commandArgs, {
    cwd: root,
    encoding: "utf8",
    windowsHide: true,
  });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  return result.stdout.trim();
}

async function writeRelease(root, version) {
  await fs.writeFile(
    path.join(root, "package.json"),
    `${JSON.stringify({
      name: "update-release-fixture",
      version,
      scripts: { build: "node build.mjs" },
    }, null, 2)}\n`,
    "utf8"
  );
  await fs.writeFile(
    path.join(root, "build.mjs"),
    `import fs from "node:fs";\nfs.mkdirSync("dist", { recursive: true });\nfs.writeFileSync("dist/runtime.txt", ${JSON.stringify(version)});\n`,
    "utf8"
  );
  await fs.writeFile(path.join(root, ".gitignore"), "dist/\n", "utf8");
}

test("advancing the release also advances manifests and future builds", async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "roblox-mcp-git-release-"));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  run(root, "git", ["init", "--quiet"]);
  run(root, "git", ["config", "user.name", "Updater Test"]);
  run(root, "git", ["config", "user.email", "updater@example.invalid"]);

  await writeRelease(root, "1.0.0");
  run(root, "git", ["add", "."]);
  run(root, "git", ["commit", "--quiet", "-m", "old release"]);
  const previousCommit = run(root, "git", ["rev-parse", "HEAD"]);

  await writeRelease(root, "2.0.0");
  run(root, "git", ["add", "."]);
  run(root, "git", ["commit", "--quiet", "-m", "new release"]);
  const targetCommit = run(root, "git", ["rev-parse", "HEAD"]);
  run(root, "git", ["reset", "--hard", previousCommit]);

  assert.equal(inspectCleanCheckout(root).commit, previousCommit);
  assertFastForward(root, previousCommit, targetCommit);
  advanceCheckout(root, targetCommit, previousCommit);
  assert.equal(JSON.parse(await fs.readFile(path.join(root, "package.json"))).version, "2.0.0");

  run(root, "npm", ["run", "build", "--ignore-scripts"]);
  assert.equal(
    await fs.readFile(path.join(root, "dist", "runtime.txt"), "utf8"),
    "2.0.0"
  );

  restoreCheckout(root, previousCommit, targetCommit);
  assert.equal(JSON.parse(await fs.readFile(path.join(root, "package.json"))).version, "1.0.0");
});

test("a clean commit created during staging is never rewound", async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "roblox-mcp-git-commit-"));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  run(root, "git", ["init", "--quiet"]);
  run(root, "git", ["config", "user.name", "Updater Test"]);
  run(root, "git", ["config", "user.email", "updater@example.invalid"]);
  await writeRelease(root, "1.0.0");
  run(root, "git", ["add", "."]);
  run(root, "git", ["commit", "--quiet", "-m", "original"]);
  const inspectedCommit = inspectCleanCheckout(root).commit;

  await fs.writeFile(path.join(root, "user.txt"), "new committed work\n", "utf8");
  run(root, "git", ["add", "."]);
  run(root, "git", ["commit", "--quiet", "-m", "user commit"]);
  const userCommit = run(root, "git", ["rev-parse", "HEAD"]);

  assert.throws(
    () => advanceCheckout(root, inspectedCommit, inspectedCommit),
    /changed while the update/
  );
  assert.equal(run(root, "git", ["rev-parse", "HEAD"]), userCommit);
  assert.equal(await fs.readFile(path.join(root, "user.txt"), "utf8"), "new committed work\n");
});

test("a tracked edit made during staging is never overwritten", async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "roblox-mcp-git-edit-"));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  run(root, "git", ["init", "--quiet"]);
  run(root, "git", ["config", "user.name", "Updater Test"]);
  run(root, "git", ["config", "user.email", "updater@example.invalid"]);
  await writeRelease(root, "1.0.0");
  run(root, "git", ["add", "."]);
  run(root, "git", ["commit", "--quiet", "-m", "old release"]);
  const previousCommit = run(root, "git", ["rev-parse", "HEAD"]);
  await writeRelease(root, "2.0.0");
  run(root, "git", ["add", "."]);
  run(root, "git", ["commit", "--quiet", "-m", "new release"]);
  const targetCommit = run(root, "git", ["rev-parse", "HEAD"]);
  run(root, "git", ["reset", "--hard", previousCommit]);

  inspectCleanCheckout(root);
  await fs.writeFile(path.join(root, "build.mjs"), "user edit during staging\n", "utf8");
  assert.throws(
    () => advanceCheckout(root, targetCommit, previousCommit),
    /local changes/
  );
  assert.equal(
    await fs.readFile(path.join(root, "build.mjs"), "utf8"),
    "user edit during staging\n"
  );
  assert.equal(run(root, "git", ["rev-parse", "HEAD"]), previousCommit);
});
