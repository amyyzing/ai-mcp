import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import fs from "node:fs/promises";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { runStagedUpdate } from "../scripts/update-runner.mjs";
import { inspectArchive } from "../scripts/update-source.mjs";

async function freePort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  const port = typeof address === "object" && address ? address.port : 0;
  await new Promise((resolve) => server.close(resolve));
  return port;
}

function candidateCoreSource() {
  return [
    'import http from "node:http";',
    'const port = Number(process.env.ROBLOX_MCP_PORT);',
    'const server = http.createServer((request, response) => {',
    '  if (request.url !== "/api/server-info") { response.writeHead(404); response.end(); return; }',
    '  response.writeHead(200, { "Content-Type": "application/json" });',
    '  response.end(JSON.stringify({ architecture: "background-core", pid: process.pid, instanceId: "archive-core", version: "archive-test" }));',
    '});',
    'server.listen(port, "127.0.0.1");',
    'process.on("SIGTERM", () => server.close(() => process.exit(0)));',
  ].join("\n");
}

test("archive inspection rejects excessive expanded content", async (t) => {
  const parent = await fs.mkdtemp(path.join(os.tmpdir(), "roblox-mcp-archive-limit-"));
  t.after(() => fs.rm(parent, { recursive: true, force: true }));
  const root = path.join(parent, "release");
  const archivePath = path.join(parent, "release.tar.gz");
  await fs.mkdir(root);
  await fs.writeFile(path.join(root, "payload.bin"), Buffer.alloc(2048));
  const archived = spawnSync(
    "tar",
    ["-czf", archivePath, "-C", parent, path.basename(root)],
    { encoding: "utf8", windowsHide: true }
  );
  assert.equal(archived.status, 0, archived.stderr);
  await assert.rejects(
    inspectArchive(archivePath, { maxExtractedBytes: 1024 }),
    /expands beyond/
  );
});

test("archive updates keep the harness bootstrap stable and activate a versioned release", async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "roblox-mcp-archive-root-"));
  const sourceParent = await fs.mkdtemp(path.join(os.tmpdir(), "roblox-mcp-archive-source-"));
  const sourceRoot = path.join(sourceParent, "roblox-mcp-main");
  const archivePath = path.join(sourceParent, "latest.tar.gz");
  const corePort = await freePort();
  let result;
  let archiveServer;
  t.after(async () => {
    if (result?.corePid) {
      try {
        process.kill(result.corePid, "SIGTERM");
        for (let attempt = 0; attempt < 40; attempt += 1) {
          try {
            process.kill(result.corePid, 0);
          } catch {
            break;
          }
          await new Promise((resolve) => setTimeout(resolve, 50));
        }
      } catch {
        // The test core may already have exited.
      }
    }
    if (archiveServer) {
      await new Promise((resolve) => archiveServer.close(resolve));
    }
    await fs.rm(root, {
      recursive: true,
      force: true,
      maxRetries: 10,
      retryDelay: 100,
    });
    await fs.rm(sourceParent, { recursive: true, force: true });
  });

  await fs.mkdir(path.join(root, "dist"), { recursive: true });
  await fs.writeFile(path.join(root, "dist", "index.js"), "stable bootstrap\n", "utf8");
  await fs.mkdir(path.join(sourceRoot, "scripts"), { recursive: true });
  await fs.writeFile(
    path.join(sourceRoot, "package.json"),
    `${JSON.stringify({
      name: "archive-update-fixture",
      version: "2.0.0",
      type: "module",
      scripts: { build: "node build.mjs" },
    }, null, 2)}\n`,
    "utf8"
  );
  await fs.writeFile(
    path.join(sourceRoot, "scripts", "build-server.mjs"),
    "// archive updater validation marker\n",
    "utf8"
  );
  await fs.writeFile(
    path.join(sourceRoot, "build.mjs"),
    [
      'import fs from "node:fs/promises";',
      'await fs.mkdir("dist", { recursive: true });',
      'await fs.mkdir("node_modules", { recursive: true });',
      `await fs.writeFile("dist/core.js", ${JSON.stringify(candidateCoreSource())});`,
      'await fs.writeFile("dist/adapter.js", "export {};\\n");',
      'await fs.writeFile("dist/index.js", "release bootstrap\\n");',
    ].join("\n"),
    "utf8"
  );
  const archived = spawnSync(
    "tar",
    ["-czf", archivePath, "-C", sourceParent, path.basename(sourceRoot)],
    { encoding: "utf8", windowsHide: true }
  );
  assert.equal(archived.status, 0, archived.stderr);

  const archiveBytes = await fs.readFile(archivePath);
  archiveServer = http.createServer((request, response) => {
    if (request.url !== "/latest.tar.gz") {
      response.writeHead(404).end();
      return;
    }
    response.writeHead(200, {
      "Content-Type": "application/gzip",
      "Content-Length": String(archiveBytes.length),
    });
    response.end(archiveBytes);
  });
  await new Promise((resolve, reject) => {
    archiveServer.once("error", reject);
    archiveServer.listen(0, "127.0.0.1", resolve);
  });
  const address = archiveServer.address();
  const archiveUrl = `http://127.0.0.1:${address.port}/latest.tar.gz`;
  const statuses = [];

  result = await runStagedUpdate({
    serverRoot: root,
    runId: "archive-test",
    corePort,
    archiveUrl,
    expectedSha256: createHash("sha256").update(archiveBytes).digest("hex"),
    packageRunner: "npm",
    status: async (message, extra) => statuses.push({ message, ...extra }),
  });

  assert.equal(result.source, "archive");
  assert.match(result.revision, /^archive-[a-f0-9]{12}$/);
  assert.equal(
    await fs.readFile(path.join(root, "dist", "index.js"), "utf8"),
    "stable bootstrap\n"
  );
  const pointer = JSON.parse(
    await fs.readFile(path.join(root, ".roblox-mcp-current.json"), "utf8")
  );
  assert.equal(pointer.releaseRoot, result.releaseRoot);
  assert.ok(pointer.releaseRoot.startsWith(path.join(root, ".roblox-mcp-releases")));
  assert.equal(
    await fs.readFile(path.join(pointer.releaseRoot, "dist", "index.js"), "utf8"),
    "release bootstrap\n"
  );
  assert.ok(statuses.some((entry) => entry.source === "archive"));
});
