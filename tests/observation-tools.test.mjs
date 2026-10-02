import assert from "node:assert/strict";
import test from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import registerObservationTools, { pointerSchema, sequenceSchema, guiActivateSchema, guiSetTextSchema } from "../dist/tools/impl/observation/observation-tools.js";
import { EvidenceHistory, appendRecording, recordingPage } from "../dist/observation/history.js";
import { imagePointToClient } from "../dist/platform/windows-screenshot.js";
import { mediaProcess, resolveRecordingFile } from "../dist/observation/media.js";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { handleRobloxResponse, resetPrimaryState } from "../dist/bridge/handlers/shared/communication.js";
import { registerClient, getClientById, resetRegistry } from "../dist/bridge/handlers/shared/registry.js";
import { companions } from "../dist/observation/companions.js";
import { videoArtifact } from "../dist/observation/artifacts.js";
import sharp from "sharp";

test("evidence is copied, bounded and explicitly expires", () => {
  const history = new EvidenceHistory(1000, 2), input = { value: 1 };
  history.put(input, "a"); input.value = 2;
  assert.equal(history.get("a").value, 1);
  history.get("a").value = 3;
  assert.equal(history.get("a").value, 1);
  history.put({}, "b"); history.put({}, "c");
  assert.throws(() => history.get("a"), /expired/);
  assert.equal(history.stats().evicted, 1);
  assert.throws(() => history.put("x".repeat(2000)), /byte limit/);
  history.close(); assert.throws(() => history.put({}), /closed/);
});
test("pointer schema rejects ambiguous targets, partial and nonfinite points", () => {
  const base = { observationId: "observation" };
  for (const input of [{}, { x: 2 }, { x: Infinity, y: 3 }, { x: 2, y: 3, target: { path: "workspace" } }]) {
    assert.equal(pointerSchema.safeParse({ ...base, ...input }).success, false);
  }
  assert.equal(pointerSchema.safeParse({ ...base, x: 2, y: 3 }).success, true);
  assert.equal(sequenceSchema.safeParse({ ...base, steps: [{ action: "execute", code: "print(1)" }] }).success, false);
  assert.equal(sequenceSchema.safeParse({ ...base, steps: Array(33).fill({ action: "wait", durationMs: 1 }) }).success, false);
});
test("frame mappings account for scale/crop and reject stale or out-of-bounds points", () => {
  const frame = { status: "fresh", geometryRevision: "rev1", returnedWidth: 500, returnedHeight: 250,
    crop: { x: 10, y: 20, width: 1000, height: 500 } };
  assert.deepEqual(imagePointToClient(frame, 250, 125, "rev1"), { x: 510, y: 270 });
  assert.throws(() => imagePointToClient(frame, 500, 0, "rev1"), /outside/);
  assert.throws(() => imagePointToClient(frame, 1, 1, "rev2"), /stale/);
});
test("background GUI tools require explicit targets and bounded operations", () => {
  const base = { observationId: "obs", target: { path: "game.Players.Test.PlayerGui.Button" } };
  assert.equal(guiActivateSchema.parse(base).event, "Activated");
  assert.equal(guiActivateSchema.safeParse({ ...base, event: "Changed" }).success, false);
  assert.equal(guiActivateSchema.safeParse({ observationId: "obs", x: 10, y: 20 }).success, false);
  assert.equal(guiSetTextSchema.safeParse({ ...base, text: "hé🙂" }).success, true);
  assert.equal(guiSetTextSchema.safeParse({ ...base, text: "x".repeat(8001) }).success, false);
  assert.equal(guiSetTextSchema.safeParse({ ...base, text: "x", submit: true }).success, false);
});
test("recordings retain copied events, report loss and search literal evidence", () => {
  const row = { events: [], bytes: 0, dropped: 0 };
  for (let index = 0; index < 1002; index++) appendRecording(row, { atMs: index, kind: "test", data: { text: `value ${index}` } });
  assert.equal(row.dropped, 2);
  assert.equal(row.events.length, 1000);
  assert.equal(recordingPage(row, 0, 10, "test", "value 1001").events.length, 1);
});
async function fixture(t) {
  resetPrimaryState(); resetRegistry();
  const server = new McpServer({ name: "observation-test", version: "1" });
  registerObservationTools(server, {});
  const client = new Client({ name: "observation-client", version: "1" });
  const [ct, st] = InMemoryTransport.createLinkedPair();
  await server.connect(st); await client.connect(ct);
  t.after(async () => { await client.close(); await server.close(); resetPrimaryState(); resetRegistry(); });
  return client;
}
test("new tool catalog publishes valid schemas through real MCP transport", async t => {
  const client = await fixture(t), catalog = await client.listTools();
  for (const name of ["observe", "console-read", "gui-query", "gui-activate", "gui-set-text", "cursor-click", "input-sequence", "recording-import", "recording-frame", "recording-analyze", "scenario-run", "collector-status", "companion-pair", "video-start", "frame-ocr", "server-source-resolve"]) {
    const tool = catalog.tools.find(tool => tool.name === name);
    assert.equal(tool?.inputSchema.type, "object", name);
    assert.equal(tool?.outputSchema.type, "object", name);
  }
  assert.equal((await client.listResourceTemplates()).resourceTemplates.length, 1);
});

test("paired-device video works end-to-end through MCP tools and releases artifacts", async t => {
  const client = await fixture(t);
  const clientId = registerClient({ username: "device-test", userId: 1, placeId: 1, jobId: "test", transport: "http" });
  getClientById(clientId).pendingPollResolve = commands => {
    const command = JSON.parse(commands[0]); assert.equal(command.type, "cursor-state");
    handleRobloxResponse({ id: command.id, success: true, structured: { sessionId: "session" }, output: "{}" }, clientId);
  };
  const call = async (name, args) => {
    const result = await client.callTool({ name, arguments: args }); assert.equal(result.isError, undefined, JSON.stringify(result)); return result.structuredContent;
  };
  const pairing = await call("companion-pair", { clientId, kind: "capture" });
  const credential = companions.claim(pairing.pairingCode, "test-device", "boot", Date.now());
  const started = await call("video-start", { clientId, source: "companion", companionId: pairing.companionId, durationSeconds: 4, fps: 5, sampleRuntime: false });
  const imageBase64 = (await sharp({ create: { width: 320, height: 180, channels: 3, background: "blue" } }).jpeg().toBuffer()).toString("base64");
  for (let index = 0; index < 3; index++) await companions.upload(credential.uploadToken, { sequence: index + 1, ptsMs: index * 250, capturedAtUnixMs: Date.now(), imageBase64, backend: "android-mediaprojection" });
  const current = await call("companion-frame", { companionId: pairing.companionId }); assert(current.evidenceId);
  await call("recording-stop", { recordingId: started.recordingId });
  let status;
  for (let attempt = 0; attempt < 30; attempt++) {
    status = await call("recording-status", { recordingId: started.recordingId });
    if (["stopped", "failed"].includes(status.state)) break; await new Promise(resolve => setTimeout(resolve, 100));
  }
  assert.equal(status.state, "stopped", JSON.stringify(status)); assert.equal(status.metadata.frames, 3);
  const exported = await call("video-export", { recordingId: started.recordingId }); assert(exported.downloadPath.includes(started.recordingId));
  const output = videoArtifact(started.recordingId); assert(output);
  const frame = await call("recording-frame", { recordingId: started.recordingId, atMs: 250 }); assert(frame.evidenceId);
  const scenes = await call("recording-visual-analyze", { recordingId: started.recordingId, timesMs: [0, 500], mode: "scenes" }); assert.equal(scenes.results[0].identical, true);
  await call("recording-release", { recordingId: started.recordingId }); assert.equal(videoArtifact(started.recordingId), undefined);
  await call("companion-revoke", { companionId: pairing.companionId }); assert.throws(() => companions.authorize(credential.uploadToken, "capture"));
});
test("observations preserve structured evidence and isolate resources by MCP connection", async t => {
  const client = await fixture(t);
  const clientId = registerClient({ username: "test", userId: 1, placeId: 1, jobId: "test", transport: "http" });
  const evidence = { observationId: "obs1", sessionId: "session1", geometryRevision: 1, cursor: { held: [] } };
  getClientById(clientId).pendingPollResolve = commands => {
    const command = JSON.parse(commands[0]);
    assert.equal(command.type, "observe");
    handleRobloxResponse({ id: command.id, success: true, structured: evidence, output: JSON.stringify(evidence) }, clientId);
  };
  const result = await client.callTool({ name: "observe", arguments: { clientId } });
  assert.equal(result.isError, undefined, JSON.stringify(result));
  assert.equal(result.structuredContent.sessionId, "session1");
  const resource = await client.readResource({ uri: result.structuredContent.resourceUri });
  assert.deepEqual(JSON.parse(resource.contents[0].text), evidence);
  const other = await fixture(t);
  await assert.rejects(other.readResource({ uri: result.structuredContent.resourceUri }), /expired|another MCP connection/);
});

test("instrumented recording samples autonomously and preserves session boundaries", async t => {
  const client = await fixture(t);
  const clientId = registerClient({ username: "recording-test", userId: 1, placeId: 1, jobId: "test", transport: "http" });
  let observations = 0;
  function respond(commands) {
    getClientById(clientId).pendingPollResolve = respond;
    for (const raw of commands) {
      const command = JSON.parse(raw);
      const data = command.type === "observe" ? { observationId: `obs${++observations}`, sessionId: observations < 3 ? "a" : "b",
        collectionStartedAtMs: observations * 1000, latestEventSequence: 0 } : { sessionId: "a", events: [], latestCursor: 0, nextCursor: 0, gap: false };
      handleRobloxResponse({ id: command.id, success: true, structured: data, output: JSON.stringify(data) }, clientId);
    }
  }
  getClientById(clientId).pendingPollResolve = respond;
  const start = await client.callTool({ name: "recording-start", arguments: { clientId, durationSeconds: 3, intervalMs: 500 } });
  assert.equal(start.isError, undefined);
  await new Promise(resolve => setTimeout(resolve, 1400));
  const status = await client.callTool({ name: "recording-status", arguments: { recordingId: start.structuredContent.recordingId } });
  assert.equal(status.structuredContent.state, "failed");
  assert.match(status.structuredContent.failureReason, /session changed/);
  assert.equal(status.structuredContent.retainedEvents, 2);
});

test("background GUI operations preserve target, action identity and effect evidence through MCP", async t => {
  const client = await fixture(t);
  const clientId = registerClient({ username: "background-test", userId: 1, placeId: 1, jobId: "test", transport: "http" });
  const target = { handle: "rh_background_1_1" };
  for (const [name, input] of [["gui-activate", { event: "MouseButton1Click" }], ["gui-set-text", { text: "hé🙂" }]]) {
    getClientById(clientId).pendingPollResolve = commands => {
      const command = JSON.parse(commands[0]);
      assert.equal(command.type, name);
      assert.deepEqual(command.target, target);
      assert.equal(command.observationId, "obs-background");
      for (const [key, value] of Object.entries(input)) assert.equal(command[key], value);
      handleRobloxResponse({ id: command.id, success: true,
        structured: { actionId: "background-action", state: "running", desktopInput: false, expectedEffectObserved: false }, output: "{}" }, clientId);
    };
    const result = await client.callTool({ name, arguments: { clientId, observationId: "obs-background", target, ...input } });
    assert.equal(result.isError, undefined);
    assert.equal(result.structuredContent.actionId, "background-action");
    assert.equal(result.structuredContent.expectedEffectObserved, false);
    assert.equal(result.structuredContent.desktopInput, false);
  }
});

test("media workers report missing providers and use asynchronous bounded child output", async () => {
  assert.equal((await mediaProcess(process.execPath, ["-e", "process.stdout.write('worker-ok')"])).toString(), "worker-ok");
  await assert.rejects(mediaProcess("nonexistent-mcp-ffprobe-provider", []), /provider unavailable/);
});

test("media imports require an explicit directory and reject sibling files", async t => {
  const directory = await mkdtemp(path.join(tmpdir(), "mcp-media-scope-"));
  const originalRoot = process.env.ROBLOX_MCP_RECORDING_ROOT;
  t.after(async () => { if (originalRoot === undefined) delete process.env.ROBLOX_MCP_RECORDING_ROOT; else process.env.ROBLOX_MCP_RECORDING_ROOT = originalRoot; await rm(directory, { recursive: true, force: true }); });
  const file = path.join(directory, "fixture.mp4"); await writeFile(file, "fixture");
  delete process.env.ROBLOX_MCP_RECORDING_ROOT;
  await assert.rejects(resolveRecordingFile(file), /RECORDING_ROOT/);
  process.env.ROBLOX_MCP_RECORDING_ROOT = directory;
  assert.equal(await resolveRecordingFile(file), file);
  // Use a known existing sibling directory, not a nonexistent path.
  process.env.ROBLOX_MCP_RECORDING_ROOT = process.cwd();
  await assert.rejects(resolveRecordingFile(file), /outside/);
});
