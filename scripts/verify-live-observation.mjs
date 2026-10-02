// Opt-in Windows -> Railway smoke test. Never injects input or replaces the connector.
// Captures only the explicitly selected Roblox process; credentials stay in memory.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { enumRobloxWindows, closeCaptureWorker } from "../dist/platform/windows-screenshot.js";
import { startWindowCapture } from "../dist/platform/windows-capture.js";

const [base, service, clientId, pidText] = process.argv.slice(2);
const pid = Number(pidText);
if (!base || new URL(base).protocol !== "https:" || !service || !clientId || !Number.isInteger(pid) || pid < 1)
  throw new Error("Usage: node scripts/verify-live-observation.mjs HTTPS_URL RAILWAY_SERVICE_ID CLIENT_ID ROBLOX_PID");
let variables;
try {
  variables = JSON.parse(execFileSync(process.env.RAILWAY_BIN || "railway", ["variables", "--service", service, "--json"], {
    encoding: "utf8", windowsHide: true, stdio: ["ignore", "pipe", "pipe"], timeout: 20000,
  }));
} catch { throw new Error("Could not read selected Railway service configuration."); }
const headers = token => ({ Authorization: `Bearer ${token}`, "Content-Type": "application/json" });
const post = async (path, data, token = "") => {
  const response = await fetch(new URL(path, base), {
    method: "POST", headers: headers(token), body: JSON.stringify(data), signal: AbortSignal.timeout(15000),
  });
  assert.equal(response.status, 200, `${path}: HTTP ${response.status}`);
  return response.json();
};
const client = new Client({ name: "live-observation-smoke", version: "1" });
const call = async (name, args = {}) => {
  const result = await client.callTool({ name, arguments: args });
  assert.ok(!result.isError, `${name}: ${result.content?.[0]?.text}`);
  return result.structuredContent;
};
let recordingId, companionId, capture, report;
const cleanupFailures = [];
try {
  const binding = (await enumRobloxWindows()).find(window => window.pid === pid);
  assert.ok(binding, "Selected Roblox process has no capturable window.");
  await client.connect(new StreamableHTTPClientTransport(new URL("/mcp", base), {
    requestInit: { headers: headers(variables.ROBLOX_MCP_AUTH_TOKEN) },
  }));
  await call("list-clients");
  const cursor = await call("cursor-state", { clientId });
  assert.ok(cursor.sessionId, "Connected client needs the observation connector.");
  const pair = await call("companion-pair", { kind: "capture", clientId });
  companionId = pair.companionId;
  const credential = await post("/companion/claim", {
    pairingCode: pair.pairingCode, label: "Live Roblox WGC verification", bootId: randomUUID(), deviceUnixMs: Date.now(),
  });
  const started = await call("video-start", { clientId, source: "companion", companionId, durationSeconds: 20, fps: 3, sampleRuntime: true });
  recordingId = started.recordingId;
  const evidenceDirectory = await mkdtemp(join(tmpdir(), "mcp-live-capture-"));
  const snapshot = join(evidenceDirectory, "roblox-first-frame.jpg");
  let first = true, geometry;
  capture = await startWindowCapture(binding, { fps: 3, seconds: 5, width: 1280 }, async frame => {
    if (first) {
      first = false; geometry = { width: frame.width, height: frame.height, sourceWidth: frame.sourceWidth, sourceHeight: frame.sourceHeight };
      await writeFile(snapshot, Buffer.from(frame.imageBase64, "base64"));
    }
    await post("/companion/frame", {
      sequence: frame.sequence, ptsMs: frame.ptsMs, capturedAtUnixMs: frame.capturedAtUnixMs,
      backend: "windows-graphics-capture", coordinateSpace: "window", imageBase64: frame.imageBase64,
    }, credential.uploadToken);
  });
  const captured = await capture.done;
  await call("recording-stop", { recordingId });
  let status;
  for (let attempt = 0; attempt < 20; attempt++) {
    status = await call("recording-status", { recordingId });
    if (["stopped", "failed"].includes(status.state)) break;
    await new Promise(resolve => setTimeout(resolve, 1000));
  }
  assert.equal(status.state, "stopped", status.failureReason);
  const analysis = await call("recording-analyze", { recordingId });
  assert.ok(analysis.counts.observation >= 2, "Expected multiple actual runtime samples.");
  assert.ok(analysis.counts["video-frame"] >= 2, "Expected multiple actual window frames.");
  assert.equal(analysis.counts.gap || 0, 0, "Runtime collection had a gap.");
  const frame = await call("companion-frame", { companionId });
  const ocr = await call("frame-ocr", { evidenceId: frame.evidenceId });
  const scenes = await call("recording-visual-analyze", { recordingId, mode: "scenes", timesMs: [0, 10000] });
  assert.equal(scenes.results.length, 1);
  const exported = await call("video-export", { recordingId });
  const downloadURL = new URL(exported.downloadPath, base);
  const video = await fetch(downloadURL, { headers: { ...headers(variables.ROBLOX_MCP_AUTH_TOKEN), Range: "bytes=0-63" }, signal: AbortSignal.timeout(15000) });
  assert.equal(video.status, 206);
  assert.equal((await video.arrayBuffer()).byteLength, 64);
  const denied = await fetch(downloadURL, { headers: headers(credential.uploadToken), signal: AbortSignal.timeout(15000) });
  assert.equal(denied.status, 403);
  const vision = await call("vision-status");
  report = { clientId, pid, sessionId: cursor.sessionId, focused: cursor.geometry?.focused,
    captured, geometry, recorded: analysis.counts, recordingDrops: status.dropped, encoding: status.metadata.encoding,
    ocr: { text: ocr.text.slice(0, 400), wordCount: ocr.words.length }, sceneComparison: scenes.results,
    authenticatedDownload: "206 with 64 bytes", uploadCredentialIsolation: "403 verified", configuredVision: vision.configured,
    snapshot,
  };
} finally {
  capture?.stop();
  if (capture) await capture.done.catch(() => {});
  for (const [name, args] of [["recording-release", { recordingId }], ["companion-revoke", { companionId }]]) {
    if (Object.values(args).every(Boolean)) await call(name, args).catch(() => cleanupFailures.push(name));
  }
  await client.close();
  closeCaptureWorker();
}
assert.deepEqual(cleanupFailures, [], "Could not verify all test artifact cleanup operations.");
console.log(JSON.stringify({ ...report, artifacts: "Hosted recording and pairing released; only local preview retained." }));
