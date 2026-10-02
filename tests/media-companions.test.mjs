import assert from "node:assert/strict";
import test from "node:test";
import sharp from "sharp";
import { createServer } from "node:http";
import { readFile, access } from "node:fs/promises";
import { CompanionHub } from "../dist/observation/companions.js";
import { normalizeFrame, compareFrames, readFrameText, closeOcr, describeFrames } from "../dist/observation/vision.js";
import { VideoWriter } from "../dist/observation/video.js";
import { probeRecording, extractRecordingFrame } from "../dist/observation/media.js";

const picture = text => sharp(Buffer.from(`<svg width="600" height="180"><rect width="600" height="180" fill="white"/><text x="25" y="100" font-family="Arial" font-size="56" fill="black">${text}</text></svg>`)).jpeg().toBuffer();
const claim = (hub, kind = "capture", owner = "owner") => {
  const pairing = hub.create(owner, kind === "capture" ? { kind, clientId: "client", sessionId: "session" } : { kind, placeId: "123", jobId: "job" });
  return { pairing, credential: hub.claim(pairing.pairingCode, "test-device", "boot", Date.now()) };
};
test("companion pairing is single-use, owner-isolated, scope-restricted and revocable", () => {
  const hub = new CompanionHub(), { pairing, credential } = claim(hub);
  assert.throws(() => hub.claim(pairing.pairingCode, "again", "boot", 0), /already used/);
  assert.throws(() => hub.owned("another-owner", pairing.companionId), /another MCP/);
  assert.throws(() => hub.authorize(credential.uploadToken, "server"), /wrong scope/);
  assert.equal(hub.list("owner")[0].paired, true);
  assert.equal(JSON.stringify(hub.list("owner")).includes(credential.uploadToken), false);
  hub.revoke("owner", pairing.companionId);
  assert.throws(() => hub.authorize(credential.uploadToken, "capture"), /revoked/);
});
test("device upload checks images, monotonic clocks, duplicate sequence and gaps", async () => {
  const hub = new CompanionHub(), { credential } = claim(hub);
  const frame = { sequence: 1, ptsMs: 0, capturedAtUnixMs: Date.now(), backend: "android-mediaprojection", imageBase64: (await picture("MCP READY")).toString("base64") };
  assert.equal((await hub.upload(credential.uploadToken, frame)).accepted, true);
  await assert.rejects(hub.upload(credential.uploadToken, frame), /clock restarted|Duplicate/);
  assert.equal((await hub.upload(credential.uploadToken, { ...frame, sequence: 3, ptsMs: 200 })).dropped, 1);
  await assert.rejects(hub.upload(credential.uploadToken, { ...frame, sequence: 4, ptsMs: 400, imageBase64: Buffer.from("not an image").toString("base64") }));
  assert.equal(hub.list("owner")[0].sequence, 3);
  hub.close("owner");
});
test("revoke during in-flight normalization cannot resurrect a frame", async () => {
  const hub = new CompanionHub(), { credential, pairing } = claim(hub);
  const imageBase64 = (await picture("FRAME")).toString("base64");
  const upload = hub.upload(credential.uploadToken, { sequence: 1, ptsMs: 0, capturedAtUnixMs: Date.now(), backend: "windows-graphics-capture", imageBase64 });
  hub.revoke("owner", pairing.companionId);
  await assert.rejects(upload, /revoked/); assert.equal(hub.list("owner").length, 0);
});
test("project telemetry validates place/job scope, snapshots data and bounds retention", () => {
  const hub = new CompanionHub(), { credential, pairing } = claim(hub, "server");
  const batch = { sequence: 1, capturedAtUnixMs: Date.now(), placeId: "123", jobId: "job", build: "rev1", events: [{ kind: "state", name: "round", atUnixMs: 1, data: { phase: "waiting" } }] };
  assert.throws(() => hub.telemetry(credential.uploadToken, { ...batch, placeId: "456" }), /scope/);
  hub.telemetry(credential.uploadToken, batch); batch.events[0].data.phase = "changed";
  assert.equal(hub.owned("owner", pairing.companionId).events[0].data.phase, "waiting");
  for (let sequence = 2; sequence < 250; sequence++) hub.telemetry(credential.uploadToken, { ...batch, sequence });
  assert.equal(hub.owned("owner", pairing.companionId).events.length, 200);
  assert(hub.list("owner")[0].dropped > 0); hub.close("owner");
});
test("image validation rejects oversized dimensions and non-raster input", async () => {
  await assert.rejects(normalizeFrame(Buffer.from('<svg width="100" height="100"/>')), /JPEG and PNG/);
  await assert.rejects(normalizeFrame(Buffer.alloc(1500001)), /1.5 MB/);
  const huge = await sharp({ create: { width: 5000, height: 4000, channels: 3, background: "white" } }).png().toBuffer();
  await assert.rejects(normalizeFrame(huge), /pixel limit/);
});
test("bundled OCR actually recognizes text with bounds without remote language downloads", async t => {
  t.after(closeOcr);
  const result = await readFrameText(await picture("MCP READY 123"));
  assert.match(result.text, /MCP READY 123/); assert(result.confidence > 60); assert(result.words.some(word => word.bounds.x1 > word.bounds.x0));
});
test("frame comparison distinguishes identical frames from visible change", async () => {
  const a = await picture("BEFORE"), b = await sharp({ create: { width: 600, height: 180, channels: 3, background: "black" } }).jpeg().toBuffer();
  assert.equal((await compareFrames(a, a)).identical, true); assert((await compareFrames(a, b)).changedFraction > 0.7);
});
test("real bundled FFmpeg encodes irregular capture PTS and supports exact frame extraction", async t => {
  const writer = new VideoWriter(); t.after(() => writer.release());
  await writer.append(await picture("FRAME ONE"), 0, 1000);
  await writer.append(await picture("FRAME TWO"), 137, 1137);
  await writer.append(await picture("FRAME THREE"), 490, 1490);
  await assert.rejects(writer.append(await picture("BAD"), 490, 1490), /increase/);
  const video = await writer.finish(), metadata = await probeRecording(video.file);
  assert.deepEqual(metadata.timestamps.map(seconds => Math.round(seconds * 1000)), [0, 137, 490, 590]);
  assert.equal(video.frameCount, 3); assert(video.bytes > 1000);
  const frame = await extractRecordingFrame(video.file, 1); assert.equal((await sharp(frame).metadata()).format, "jpeg");
  await writer.release(); await assert.rejects(access(video.file));
});
test("empty and released video sessions cannot encode or accept late frames", async () => {
  const writer = new VideoWriter(); await assert.rejects(writer.finish(), /No open/);
  await writer.release(); await assert.rejects(writer.append(await picture("late"), 0, 1), /closed/);
});
test("configured vision uses selected frames, requires explicit confirmation and refuses redirects", async t => {
  const previous = { url: process.env.ROBLOX_MCP_VISION_URL, model: process.env.ROBLOX_MCP_VISION_MODEL };
  t.after(() => { for (const [key, value] of [["ROBLOX_MCP_VISION_URL", previous.url], ["ROBLOX_MCP_VISION_MODEL", previous.model]]) if (value === undefined) delete process.env[key]; else process.env[key] = value; });
  let request, redirect = false;
  const server = createServer(async (req, res) => {
    if (redirect) { res.writeHead(302, { Location: "http://example.invalid" }); res.end(); return; }
    const chunks = []; for await (const chunk of req) chunks.push(chunk);
    request = JSON.parse(Buffer.concat(chunks).toString()); res.setHeader("Content-Type", "application/json"); res.end(JSON.stringify({ message: { content: "Visible test frame." } }));
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve)); t.after(() => new Promise(resolve => server.close(resolve)));
  process.env.ROBLOX_MCP_VISION_URL = `http://127.0.0.1:${server.address().port}`; process.env.ROBLOX_MCP_VISION_MODEL = "test-vision";
  const frames = [{ bytes: await picture("TEST"), atMs: 123 }];
  await assert.rejects(describeFrames(frames, "What changed?", false), /confirmUpload/);
  const answer = await describeFrames(frames, "What changed?", true);
  assert.equal(answer.inferred, true); assert.equal(request.messages[1].images.length, 1); assert.match(request.messages[1].content, /123/);
  redirect = true; await assert.rejects(describeFrames(frames, "What changed?", true));
});
