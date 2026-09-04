import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const repoRoot = path.resolve(import.meta.dirname, "..");

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

async function waitForCore(url) {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`${url}/api/server-info`);
      if (response.ok) return;
    } catch {
      // Still starting.
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error("Versioned release core did not start.");
}

test("a versioned core resolves installation artifacts from the stable server root", async (t) => {
  const serverRoot = await fs.mkdtemp(path.join(os.tmpdir(), "roblox-mcp-versioned-"));
  const releaseRoot = path.join(serverRoot, ".roblox-mcp-releases", "route-test");
  await fs.mkdir(path.join(serverRoot, "scripts"), { recursive: true });
  await fs.mkdir(releaseRoot, { recursive: true });
  const directoryLinkType = process.platform === "win32" ? "junction" : "dir";
  await fs.symlink(
    path.join(repoRoot, "dist"),
    path.join(releaseRoot, "dist"),
    directoryLinkType
  );
  await fs.symlink(
    path.join(repoRoot, "node_modules"),
    path.join(releaseRoot, "node_modules"),
    directoryLinkType
  );
  await fs.writeFile(
    path.join(serverRoot, "connector.luau"),
    "-- connector from stable installation root",
    "utf8"
  );
  await fs.writeFile(
    path.join(serverRoot, "scripts", "install-harnesses.mjs"),
    `console.log(JSON.stringify([{
      id: "route-test",
      name: "Route Test",
      group: "test",
      detected: true,
      reason: "stable installer path"
    }]));\n`,
    "utf8"
  );

  const port = await freePort();
  const core = spawn(process.execPath, [path.join(releaseRoot, "dist", "core.js")], {
    cwd: releaseRoot,
    env: {
      ...process.env,
      ROBLOX_MCP_PORT: String(port),
      ROBLOX_MCP_HOST: "127.0.0.1",
      ROBLOX_MCP_AUTH_TOKEN: "",
      ROBLOX_MCP_CONNECTOR_TOKEN: "",
      RAILWAY_PUBLIC_DOMAIN: "",
      ROBLOX_MCP_SERVER_ROOT: serverRoot,
    },
    stdio: "ignore",
  });
  t.after(async () => {
    core.kill("SIGTERM");
    await fs.rm(serverRoot, { recursive: true, force: true });
  });
  const baseUrl = `http://127.0.0.1:${port}`;
  await waitForCore(baseUrl);

  const health = await fetch(`${baseUrl}/health`);
  assert.equal(health.status, 200);
  assert.deepEqual(await health.json(), { status: "ready" });

  const connector = await fetch(`${baseUrl}/script.luau`);
  assert.equal(connector.status, 200);
  assert.equal(
    await connector.text(),
    "-- connector from stable installation root"
  );

  const hostedLoader = await fetch(`${baseUrl}/loader.luau`);
  assert.equal(hostedLoader.status, 503);
  assert.equal(hostedLoader.headers.get("cache-control"), "no-store");
  const hostedLoaderSource = await hostedLoader.text();
  assert.match(hostedLoaderSource, /configure ROBLOX_MCP_CONNECTOR_TOKEN/);
  assert.doesNotMatch(hostedLoaderSource, /getgenv\(\)\.MCPAuthToken/);
  assert.match(hostedLoaderSource, /\/script\.luau/);

  const session = await fetch(`${baseUrl}/api/admin-session`);
  assert.equal(session.status, 200);
  const { token } = await session.json();
  const setup = await fetch(`${baseUrl}/api/client-setup`, {
    headers: { "x-roblox-mcp-admin-token": token },
  });
  assert.equal(setup.status, 200);
  const payload = await setup.json();
  assert.equal(payload.harnessError, null);
  assert.equal(payload.harnesses[0].id, "route-test");
});
