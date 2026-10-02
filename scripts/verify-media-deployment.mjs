// Opt-in integration smoke test against the selected deployment. Creates only a clearly
// labeled synthetic connector and session-owned artifacts, then revokes/releases them.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import sharp from "sharp";
import WebSocket from "ws";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
const [base, service] = process.argv.slice(2);
if (!base || !service || new URL(base).protocol !== "https:") throw new Error("Usage: node scripts/verify-media-deployment.mjs HTTPS_URL RAILWAY_SERVICE_ID");
let variables;
try { variables = JSON.parse(execFileSync(process.env.RAILWAY_BIN || "railway", ["variables", "--service", service, "--json"], { encoding: "utf8", windowsHide: true, stdio: ["ignore", "pipe", "pipe"] })); }
catch { throw new Error("Could not read selected Railway service configuration."); }
const headers = token => ({ Authorization: `Bearer ${token}`, "Content-Type": "application/json" });
const post = async (route, data, token) => {
  const response = await fetch(new URL(route, base), { method: "POST", headers: headers(token || ""), body: JSON.stringify(data), signal: AbortSignal.timeout(15000) });
  assert.equal(response.status, 200, `Unexpected HTTP ${response.status} at ${route}`); return response.json();
};
const sessionId = randomUUID(), socketURL = new URL(base); socketURL.protocol = "wss:"; socketURL.pathname = "/";
const socket = new WebSocket(socketURL, { headers: headers(variables.ROBLOX_MCP_CONNECTOR_TOKEN), handshakeTimeout: 10000 });
const registered = new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("Synthetic connector registration timed out")), 15000);
  socket.on("error", error => { clearTimeout(timeout); reject(error); });
  socket.on("open", () => socket.send(JSON.stringify({ type: "register", username: "MCP_media_validation_fixture", placeName: "Synthetic media validation (not a game)", userId: 0, placeId: 0, jobId: "fixture", sessionId })));
  socket.on("message", raw => {
    const message = JSON.parse(raw.toString());
    if (message.type === "registered") { clearTimeout(timeout); resolve(message.clientId); }
    else if (message.type === "cursor-state") socket.send(JSON.stringify({ id: message.id, success: true, structured: { sessionId }, output: "{}" }));
    else if (message.id) socket.send(JSON.stringify({ id: message.id, success: false, error: "Synthetic fixture supports only cursor-state" }));
  });
});
const client = new Client({ name: "media-deployment-smoke", version: "1" });
let recordingId, captureId, serverId;
const call = async (name, args = {}) => { const result = await client.callTool({ name, arguments: args }); assert.equal(result.isError, undefined, `${name}: ${result.content?.[0]?.text}`); return result.structuredContent; };
try {
  const clientId = await registered;
  await client.connect(new StreamableHTTPClientTransport(new URL("/mcp", base), { requestInit: { headers: headers(variables.ROBLOX_MCP_AUTH_TOKEN) } }));
  const pair = await call("companion-pair", { kind: "capture", clientId }); captureId = pair.companionId;
  const credential = await post("/companion/claim", { pairingCode: pair.pairingCode, label: "Synthetic image fixture", bootId: randomUUID(), deviceUnixMs: Date.now() });
  const started = await call("video-start", { source: "companion", companionId: captureId, clientId, durationSeconds: 20, sampleRuntime: false }); recordingId = started.recordingId;
  const image = await sharp(Buffer.from('<svg width="600" height="180"><rect width="600" height="180" fill="white"/><text x="25" y="100" font-family="Arial" font-size="56" fill="black">MCP READY 123</text></svg>')).jpeg().toBuffer();
  for (let index = 0; index < 3; index++) await post("/companion/frame", { sequence: index + 1, ptsMs: index * 250, capturedAtUnixMs: Date.now(), backend: "android-mediaprojection", imageBase64: image.toString("base64") }, credential.uploadToken);
  const frame = await call("companion-frame", { companionId: captureId });
  const ocr = await call("frame-ocr", { evidenceId: frame.evidenceId }); assert.match(ocr.text, /MCP READY 123/);
  await call("recording-stop", { recordingId });
  let status;
  for (let attempt = 0; attempt < 20; attempt++) {
    status = await call("recording-status", { recordingId }); if (["stopped", "failed"].includes(status.state)) break;
    await new Promise(resolve => setTimeout(resolve, 1000));
  }
  assert.equal(status.state, "stopped", status.failureReason);
  const exported = await call("video-export", { recordingId });
  const video = await fetch(new URL(exported.downloadPath, base), { headers: { ...headers(variables.ROBLOX_MCP_AUTH_TOKEN), Range: "bytes=0-63" } }); assert.equal(video.status, 206); assert.equal((await video.arrayBuffer()).byteLength, 64);
  assert.equal((await fetch(new URL(exported.downloadPath, base), { headers: headers(credential.uploadToken) })).status, 403);
  const project = await call("companion-pair", { kind: "server", placeId: "0", jobId: "fixture" }); serverId = project.companionId;
  const projectCredential = await post("/companion/claim", { pairingCode: project.pairingCode, label: "Synthetic project fixture", bootId: randomUUID(), deviceUnixMs: Date.now() });
  await post("/companion/telemetry", { sequence: 1, capturedAtUnixMs: Date.now(), placeId: "0", jobId: "fixture", build: "fixture-revision",
    events: [{ kind: "source-map", name: "Fixture", atUnixMs: Date.now(), data: { path: "fixture.luau", revision: "fixture-revision" } }] }, projectCredential.uploadToken);
  const source = await call("server-source-resolve", { companionId: serverId, path: "Fixture" }); assert.equal(source.mapping.data.path, "fixture.luau");
  const vision = await call("vision-status");
  console.log(JSON.stringify({ hostedOcr: "recognized test text", video: "encoded three frames; authenticated byte-range download verified", uploadCredentialIsolation: "verified", serverSourceMapping: "verified", configuredVision: vision.configured, fixture: "synthetic; not a live Android or Studio test" }));
} finally {
  for (const [name, args] of [["recording-release", { recordingId }], ["companion-revoke", { companionId: captureId }], ["companion-revoke", { companionId: serverId }]]) {
    if (Object.values(args).every(Boolean)) await call(name, args).catch(() => {});
  }
  await client.close(); socket.close(); setTimeout(() => socket.terminate(), 1000).unref();
}
