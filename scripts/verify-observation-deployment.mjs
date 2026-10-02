// Read-only deployment verification. Credentials are consumed in memory, never printed.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
const [base, service] = process.argv.slice(2);
if (!base || !service || new URL(base).protocol !== "https:") throw new Error("Usage: node scripts/verify-observation-deployment.mjs HTTPS_URL RAILWAY_SERVICE_ID");
let variables;
try { variables = JSON.parse(execFileSync(process.env.RAILWAY_BIN || (process.platform === "win32" ? "railway.exe" : "railway"), ["variables", "--service", service, "--json"], { encoding: "utf8", windowsHide: true, stdio: ["ignore", "pipe", "pipe"] })); }
catch { throw new Error("Could not read selected Railway service configuration."); }
const agentToken = variables.ROBLOX_MCP_AUTH_TOKEN;
const connectorToken = variables.ROBLOX_MCP_CONNECTOR_TOKEN;
assert(agentToken && connectorToken && agentToken !== connectorToken, "Distinct agent/connector credentials are required.");
const headers = token => ({ Authorization: `Bearer ${token}` });
const get = (route, token) => fetch(new URL(route, base), { headers: token ? headers(token) : undefined, signal: AbortSignal.timeout(15000) });
const health = await get("/health"); assert.equal(health.status, 200);
assert.equal((await health.json()).status, "ready");
const loader = await get("/loader.luau"); assert.equal(loader.status, 200);
assert((await loader.text()).includes("loadstring"));
assert.equal((await get("/script.luau")).status, 403);
assert.equal((await get("/api/status", connectorToken)).status, 403);
const connector = await get("/script.luau", connectorToken); assert.equal(connector.status, 200);
const hash = text => createHash("sha256").update(text).digest("hex");
const expectedHash = hash(await readFile(new URL("../connector.luau", import.meta.url)));
assert.equal(hash(await connector.text()), expectedHash, "Hosted connector differs from local generated artifact.");
const client = new Client({ name: "deployment-verifier", version: "1" });
try {
  await client.connect(new StreamableHTTPClientTransport(new URL("/mcp", base), { requestInit: { headers: headers(agentToken) } }));
  const catalog = await client.listTools();
  assert.equal(catalog.tools.length, 103);
  for (const name of ["console-read", "observe", "recording-start", "cursor-click", "gui-activate", "gui-set-text", "scenario-run", "companion-pair", "frame-ocr", "video-start", "server-telemetry-read", "recording-visual-analyze"]) assert(catalog.tools.some(tool => tool.name === name));
  const resources = await client.listResourceTemplates();
  assert(resources.resourceTemplates.some(template => template.uriTemplate === "roblox://evidence/{id}"));
  const clients = await client.callTool({ name: "list-clients", arguments: {} });
  console.log(JSON.stringify({ health: "ready", toolCount: catalog.tools.length, connectorSha256: expectedHash,
    credentialSeparation: "verified", evidenceResource: "verified", connectedClients: clients.structuredContent?.clients?.length ?? 0 }));
} finally { await client.close(); }
