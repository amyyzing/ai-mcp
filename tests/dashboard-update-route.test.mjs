import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { pathToFileURL } from "node:url";

const repoRoot = path.resolve(import.meta.dirname, "..");

function responseCapture() {
  const capture = { status: 0, body: "" };
  return {
    capture,
    response: {
      writeHead(status) {
        capture.status = status;
      },
      end(body = "") {
        capture.body += body;
      },
    },
  };
}

test("update status recovers an orphaned active operation", async (t) => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "roblox-mcp-status-route-"));
  const previousHome = process.env.HOME;
  const previousUserProfile = process.env.USERPROFILE;
  process.env.HOME = home;
  process.env.USERPROFILE = home;
  t.after(async () => {
    if (previousHome === undefined) delete process.env.HOME;
    else process.env.HOME = previousHome;
    if (previousUserProfile === undefined) delete process.env.USERPROFILE;
    else process.env.USERPROFILE = previousUserProfile;
    await fs.rm(home, { recursive: true, force: true });
  });

  const statusDirectory = path.join(home, ".roblox-mcp");
  const stagingRoot = path.join(repoRoot, ".roblox-mcp-update-orphaned-run");
  t.after(() => {
    spawnSync("git", ["worktree", "remove", "--force", stagingRoot], {
      cwd: repoRoot,
      stdio: "ignore",
      windowsHide: true,
    });
  });
  const worktree = spawnSync(
    "git",
    ["worktree", "add", "--detach", stagingRoot, "HEAD"],
    { cwd: repoRoot, encoding: "utf8", windowsHide: true }
  );
  assert.equal(worktree.status, 0, worktree.stderr);
  await fs.mkdir(path.join(stagingRoot, "node_modules", "large-package"), {
    recursive: true,
  });
  const abandonedRelease = path.join(
    repoRoot,
    ".roblox-mcp-releases",
    "candidate-orphaned-run"
  );
  t.after(() => fs.rm(abandonedRelease, { recursive: true, force: true }));
  await fs.mkdir(path.join(abandonedRelease, "node_modules", "large-package"), {
    recursive: true,
  });
  await fs.mkdir(statusDirectory, { recursive: true });
  await fs.writeFile(
    path.join(statusDirectory, "update-status.json"),
    `${JSON.stringify({
      state: "running",
      message: "Updating…",
      runId: "orphaned-run",
      startedAt: Date.now() - 20_000,
      updatedAt: Date.now() - 10_000,
    })}\n`,
    "utf8"
  );

  const routeUrl = `${pathToFileURL(
    path.join(repoRoot, "dist", "http", "routes", "api", "update.js")
  ).href}?orphan=${Date.now()}`;
  const route = await import(routeUrl);
  const { capture, response } = responseCapture();
  await route.GET({}, response);
  const body = JSON.parse(capture.body);

  assert.equal(capture.status, 200);
  assert.equal(body.state, "failed");
  assert.equal(body.available, true);
  assert.match(body.message, /try again/i);
  await assert.rejects(fs.access(stagingRoot));
  await assert.rejects(fs.access(abandonedRelease));
  const registered = spawnSync("git", ["worktree", "list", "--porcelain"], {
    cwd: repoRoot,
    encoding: "utf8",
    windowsHide: true,
  });
  assert.equal(registered.status, 0, registered.stderr);
  assert.doesNotMatch(registered.stdout, /roblox-mcp-update-orphaned-run/);
});

test("the packed update endpoint enables archive-backed updates without Git metadata", async (t) => {
  const destination = await fs.mkdtemp(path.join(os.tmpdir(), "roblox-mcp-pack-"));
  const updateHome = await fs.mkdtemp(path.join(os.tmpdir(), "roblox-mcp-pack-home-"));
  const previousHome = process.env.HOME;
  const previousUserProfile = process.env.USERPROFILE;
  const previousArchiveUrl = process.env.ROBLOX_MCP_UPDATE_ARCHIVE_URL;
  process.env.HOME = updateHome;
  process.env.USERPROFILE = updateHome;
  process.env.ROBLOX_MCP_UPDATE_ARCHIVE_URL = "http://127.0.0.1:1/unavailable.tar.gz";
  t.after(async () => {
    if (previousHome === undefined) delete process.env.HOME;
    else process.env.HOME = previousHome;
    if (previousUserProfile === undefined) delete process.env.USERPROFILE;
    else process.env.USERPROFILE = previousUserProfile;
    if (previousArchiveUrl === undefined) delete process.env.ROBLOX_MCP_UPDATE_ARCHIVE_URL;
    else process.env.ROBLOX_MCP_UPDATE_ARCHIVE_URL = previousArchiveUrl;
    await fs.rm(destination, { recursive: true, force: true });
    await fs.rm(updateHome, { recursive: true, force: true });
  });

  const npmArgs = [
      "pack",
      "--json",
      "--ignore-scripts",
      "--pack-destination",
      destination,
    ];
  const useNpmCli = process.platform === "win32";
  const packed = spawnSync(
    useNpmCli ? process.execPath : "npm",
    useNpmCli
      ? [
          path.join(path.dirname(process.execPath), "node_modules", "npm", "bin", "npm-cli.js"),
          ...npmArgs,
        ]
      : npmArgs,
    {
      cwd: repoRoot,
      encoding: "utf8",
      windowsHide: true,
    }
  );
  assert.equal(packed.status, 0, packed.stderr || packed.stdout);
  const [{ filename }] = JSON.parse(packed.stdout);
  const archive = path.join(destination, filename);
  const extracted = spawnSync("tar", ["-xzf", archive, "-C", destination], {
    encoding: "utf8",
    windowsHide: true,
  });
  assert.equal(extracted.status, 0, extracted.stderr);
  const parentGit = spawnSync("git", ["init", "--quiet"], {
    cwd: destination,
    encoding: "utf8",
    windowsHide: true,
  });
  assert.equal(parentGit.status, 0, parentGit.stderr);

  const route = await import(
    `${pathToFileURL(
      path.join(destination, "package", "dist", "http", "routes", "api", "update.js")
    ).href}?packed=${Date.now()}`
  );
  const getCapture = responseCapture();
  await route.GET({}, getCapture.response);
  const getBody = JSON.parse(getCapture.capture.body);
  assert.equal(getCapture.capture.status, 200);
  assert.equal(getBody.available, true);
  assert.equal(getBody.source, "archive");

  const postCapture = responseCapture();
  await route.POST({}, postCapture.response);
  const postBody = JSON.parse(postCapture.capture.body);
  assert.equal(postCapture.capture.status, 202);
  assert.equal(postBody.source, "archive");

  const statusPath = path.join(updateHome, ".roblox-mcp", "update-status.json");
  let finalStatus = null;
  for (let attempt = 0; attempt < 200; attempt += 1) {
    try {
      finalStatus = JSON.parse(await fs.readFile(statusPath, "utf8"));
      if (finalStatus.state === "failed") break;
    } catch {
      // The detached worker has not written its first state yet.
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  assert.equal(finalStatus?.state, "failed");
  assert.match(finalStatus?.message || "", /download|archive|update/i);
});

test("the standalone update worker rejects traversal without deleting the target", async (t) => {
  const victim = path.join(repoRoot, ".update-worker-preservation-victim");
  t.after(() => fs.rm(victim, { recursive: true, force: true }));
  await fs.mkdir(victim, { recursive: true });
  await fs.writeFile(path.join(victim, "keep.txt"), "preserve me", "utf8");

  const worker = spawnSync(
    process.execPath,
    [
      path.join(repoRoot, "dist", "updater", "dashboard-update-worker.mjs"),
      "--run-id",
      "../../.update-worker-preservation-victim",
      "--core-pid",
      String(process.pid),
      "--core-instance-id",
      "not-used",
    ],
    {
      cwd: repoRoot,
      encoding: "utf8",
      windowsHide: true,
    }
  );
  assert.notEqual(worker.status, 0);
  assert.equal(await fs.readFile(path.join(victim, "keep.txt"), "utf8"), "preserve me");
});

test("a versioned update worker loads its matching release helpers", async (t) => {
  const serverRoot = await fs.mkdtemp(
    path.join(os.tmpdir(), "roblox-mcp-versioned-worker-")
  );
  const releaseDist = path.join(
    serverRoot,
    ".roblox-mcp-releases",
    "active",
    "dist"
  );
  const marker = path.join(serverRoot, "incompatible-root-helper-used");
  t.after(() => fs.rm(serverRoot, { recursive: true, force: true }));

  await fs.mkdir(path.join(serverRoot, "dist", "shared"), { recursive: true });
  await fs.writeFile(
    path.join(serverRoot, "dist", "shared", "update-status.mjs"),
    [
      'import fs from "node:fs";',
      `fs.writeFileSync(${JSON.stringify(marker)}, "used");`,
      'throw new Error("incompatible frozen root helper");',
    ].join("\n"),
    "utf8"
  );
  await fs.cp(
    path.join(repoRoot, "dist", "updater"),
    path.join(releaseDist, "updater"),
    { recursive: true }
  );
  await fs.cp(
    path.join(repoRoot, "dist", "shared"),
    path.join(releaseDist, "shared"),
    { recursive: true }
  );

  const worker = spawnSync(
    process.execPath,
    [
      path.join(releaseDist, "updater", "dashboard-update-worker.mjs"),
      "--run-id",
      "invalid",
      "--core-pid",
      String(process.pid),
      "--core-instance-id",
      "not-used",
    ],
    {
      cwd: serverRoot,
      env: {
        ...process.env,
        HOME: serverRoot,
        USERPROFILE: serverRoot,
        ROBLOX_MCP_SERVER_ROOT: serverRoot,
      },
      encoding: "utf8",
      windowsHide: true,
    }
  );
  assert.notEqual(worker.status, 0);
  await assert.rejects(fs.access(marker));
});
