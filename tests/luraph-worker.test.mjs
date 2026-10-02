import assert from "node:assert/strict";
import http from "node:http";
import { Readable } from "node:stream";
import test from "node:test";
import { createHash } from "node:crypto";

import { requestLuraphDevirtualization } from "../dist/luraph/client.js";
import { POST as postTool } from "../dist/http/routes/api/tool.js";
import {
  MAX_DIRECT_LURAPH_SOURCE_BYTES,
  devirtualizeRawLuraphSource,
  devirtualizeLuraphInputSchema,
  findLuraphScript,
  formatLuraphResultRange,
  readCachedLuraphResult,
  releaseCachedLuraphResult,
  retainLuraphResult,
} from "../dist/tools/impl/advanced/devirtualize-luraph.js";

function listen(server) {
  return new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
}

function close(server) {
  return new Promise((resolve, reject) =>
    server.close((error) => error ? reject(error) : resolve())
  );
}

test("recovery artifact reads preserve bytes, paginate, and enforce client scope", () => {
  const bytes = Buffer.from([0, 255, 13, 10, 42]);
  const resultId = retainLuraphResult({ sourceKind: "indexed", clientId: "a",
    scriptPath: "test", outputFile: "test.bin", source: "preview", sourceTruncated: true,
    artifacts: [{ id: "0", name: "test.bin", byteSize: bytes.length,
      sha256: createHash("sha256").update(bytes).digest("hex"),
      representation: "engine-artifact", validation: "not-independently-validated",
      contentBase64: bytes.toString("base64") }] });
  assert.equal(readCachedLuraphResult({resultId, clientId: "b", artifactId: "0", startLine: 1, maxLines: 1}).ok, false);
  const page = readCachedLuraphResult({resultId, clientId: "a", artifactId: "0", byteOffset: 1, maxBytes: 2, startLine: 1, maxLines: 1});
  assert.deepEqual(Buffer.from(page.structured.contentBase64, "base64"), bytes.subarray(1, 3));
  assert.equal(page.structured.nextByteOffset, 3);
  assert.equal(readCachedLuraphResult({resultId, clientId: "a", artifactId: "0", byteOffset: 99, startLine: 1, maxLines: 1}).ok, false);
  assert.equal(releaseCachedLuraphResult("a", resultId).ok, true);
});

test("v2 worker restores complete primary source and rejects corrupt artifact hashes", async () => {
  let corrupt = false;
  let partial = false;
  const source = "line one\n" + "second line\n".repeat(200);
  const bytes = Buffer.from(source);
  const server = http.createServer((request, response) => {
    request.resume();
    request.on("end", () => response.end(JSON.stringify({
      ok: true, schemaVersion: 2, inputSha256: createHash("sha256").update("input").digest("hex"),
      outputFile: "program.decompiled.luau", source: "line one", sourceTruncated: true,
      recoveryStatus: partial ? "partial" : "unverified", engineExitCode: partial ? 2 : 0,
      diagnostics: partial ? [{code: "engine-nonzero-exit"}] : [],
      artifacts: [{id: "0", name: "program.decompiled.luau",
        byteSize: bytes.length, contentBase64: bytes.toString("base64"),
        sha256: corrupt ? "bad" : createHash("sha256").update(bytes).digest("hex"),
        representation: "structural-source", validation: "not-independently-validated"}],
    })));
  });
  await listen(server);
  const previousUrl = process.env.LURAPH_WORKER_URL;
  const previousToken = process.env.LURAPH_WORKER_TOKEN;
  process.env.LURAPH_WORKER_URL = `http://127.0.0.1:${server.address().port}`;
  process.env.LURAPH_WORKER_TOKEN = "test";
  try {
    const result = await devirtualizeRawLuraphSource({source: "input", sourceName: "test", captureMode: "strict", timeoutSeconds: 30, previewLines: 1});
    assert.equal(result.ok, true);
    assert.equal(result.structured.sourceTruncated, false);
    const page = readCachedLuraphResult({resultId: result.structured.resultId, startLine: 150, maxLines: 1});
    assert.match(page.text, /second line/);
    assert.equal(result.structured.artifacts[0].contentBase64, undefined);
    const relayedRead = await callToolRoute({type: "devirtualize-luraph", operation: "read",
      resultId: result.structured.resultId, artifactId: "0", byteOffset: 9, maxBytes: 6});
    assert.equal(relayedRead.body.structuredContent.contentBase64, bytes.subarray(9, 15).toString("base64"));
    releaseCachedLuraphResult(undefined, result.structured.resultId);
    partial = true;
    const partialResult = await devirtualizeRawLuraphSource({source: "input", sourceName: "partial", captureMode: "strict", timeoutSeconds: 30, previewLines: 1});
    assert.equal(partialResult.ok, true);
    assert.match(partialResult.text, /PARTIAL RECOVERY/);
    const partialRead = readCachedLuraphResult({resultId: partialResult.structured.resultId, startLine: 1, maxLines: 1});
    assert.equal(partialRead.structured.recoveryStatus, "partial");
    assert.equal(partialRead.structured.engineExitCode, 2);
    assert.match(partialRead.text, /PARTIAL RECOVERY/);
    releaseCachedLuraphResult(undefined, partialResult.structured.resultId);
    corrupt = true;
    await assert.rejects(requestLuraphDevirtualization({source: "input", captureMode: "strict"}), /hash verification/);
  } finally {
    if (previousUrl === undefined) delete process.env.LURAPH_WORKER_URL; else process.env.LURAPH_WORKER_URL = previousUrl;
    if (previousToken === undefined) delete process.env.LURAPH_WORKER_TOKEN; else process.env.LURAPH_WORKER_TOKEN = previousToken;
    await close(server);
  }
});

async function callToolRoute(body) {
  const request = Readable.from([JSON.stringify(body)]);
  request.url = "/api/tool";
  request.headers = { "content-type": "application/json" };
  let statusCode = 200;
  let responseBody = "";
  const response = {
    writeHead(code) { statusCode = code; },
    end(chunk = "") { responseBody += String(chunk); },
  };
  await postTool(request, response);
  return { statusCode, body: JSON.parse(responseBody) };
}

test("Luraph schema accepts indexed or direct source and bounds execution", () => {
  assert.equal(devirtualizeLuraphInputSchema.safeParse({
    operation: "run",
    scriptPath: "game.ReplicatedStorage.Protected",
  }).success, true);
  assert.equal(devirtualizeLuraphInputSchema.safeParse({
    operation: "run",
    scriptPath: "game.ReplicatedStorage.Protected",
    captureMode: "unsafe",
  }).success, false);
  assert.equal(devirtualizeLuraphInputSchema.safeParse({
    operation: "run-source",
    source: "return true",
  }).success, true);
  assert.equal(devirtualizeLuraphInputSchema.safeParse({
    operation: "run-source",
    source: "",
  }).success, false);
  assert.equal(devirtualizeLuraphInputSchema.safeParse({
    operation: "run-source",
    source: "x".repeat(MAX_DIRECT_LURAPH_SOURCE_BYTES + 1),
  }).success, false);
  assert.equal(devirtualizeLuraphInputSchema.safeParse({
    operation: "run-source",
    source: "return true",
    sourceName: "bad\nname",
  }).success, false);
  assert.equal(devirtualizeLuraphInputSchema.safeParse({
    operation: "run",
    scriptPath: "game.ReplicatedStorage.Protected",
    timeoutSeconds: 601,
  }).success, false);
  assert.equal(devirtualizeLuraphInputSchema.safeParse({
    operation: "read",
    resultId: "not-a-uuid",
  }).success, false);
});

test("Luraph recovered results are client-scoped, paged, and releasable", () => {
  const source = Array.from({ length: 5 }, (_, index) => `line ${index + 1}`).join("\n");
  const page = formatLuraphResultRange(source, 2, 2);
  assert.equal(page.text, "-- Lines 2-3 of 5\nline 2\nline 3");
  assert.equal(page.nextStartLine, 4);

  const resultId = retainLuraphResult({
    clientId: "client-a",
    sourceKind: "indexed",
    scriptPath: "game.Protected",
    outputFile: "embedded_main.luau",
    source,
    sourceTruncated: false,
  });
  assert.equal(readCachedLuraphResult({
    clientId: "client-b",
    resultId,
    startLine: 1,
    maxLines: 2,
  }).ok, false);
  const read = readCachedLuraphResult({
    clientId: "client-a",
    resultId,
    startLine: 1,
    maxLines: 2,
  });
  assert.equal(read.ok, true);
  assert.match(read.text, /nextStartLine|startLine=3/);
  assert.equal(releaseCachedLuraphResult("client-a", resultId).ok, true);
  assert.equal(readCachedLuraphResult({
    clientId: "client-a",
    resultId,
    startLine: 1,
    maxLines: 2,
  }).ok, false);
});

test("direct Luraph results can be paged and released without a Roblox client", () => {
  const resultId = retainLuraphResult({
    sourceKind: "raw",
    scriptPath: "pasted-script.luau",
    outputFile: "program.decompiled.luau",
    source: "line 1\nline 2",
    sourceTruncated: false,
  });
  const read = readCachedLuraphResult({
    resultId,
    startLine: 1,
    maxLines: 1,
  });
  assert.equal(read.ok, true);
  assert.equal(read.structured.sourceKind, "raw");
  assert.equal(releaseCachedLuraphResult(undefined, resultId).ok, true);
});

test("Luraph script selection accepts exact paths and ScriptProxy IDs", () => {
  const index = {
    scripts: [
      { path: "game.A", debugId: "one", source: "a" },
      { path: "game.B", debugId: "two", source: "b" },
    ],
  };
  assert.equal(findLuraphScript(index, "game.B")?.source, "b");
  assert.equal(findLuraphScript(index, "<ScriptProxy: one>")?.source, "a");
  assert.equal(findLuraphScript(index, "game.Missing"), undefined);
});

test("Luraph worker client uses the configured private HTTP service and token", async () => {
  let received;
  const server = http.createServer((request, response) => {
    let body = "";
    request.setEncoding("utf8");
    request.on("data", (chunk) => { body += chunk; });
    request.on("end", () => {
      received = {
        url: request.url,
        authorization: request.headers.authorization,
        body: JSON.parse(body),
      };
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(JSON.stringify({
        ok: true,
        outputFile: "embedded_main.luau",
        source: "return true",
        sourceChars: 11,
        quality: { compileChecked: true, finalPayloadExecuted: false },
      }));
    });
  });
  await listen(server);
  const address = server.address();
  const previousUrl = process.env.LURAPH_WORKER_URL;
  const previousToken = process.env.LURAPH_WORKER_TOKEN;
  process.env.LURAPH_WORKER_URL = `http://127.0.0.1:${address.port}/worker-root`;
  process.env.LURAPH_WORKER_TOKEN = "test-token";
  try {
    const result = await requestLuraphDevirtualization({
      source: "protected",
      captureMode: "strict",
      timeoutSeconds: 30,
      maxResultChars: 12000,
    });
    assert.equal(result.source, "return true");
    assert.equal(received.url, "/worker-root/devirtualize");
    assert.equal(received.authorization, "Bearer test-token");
    assert.equal(received.body.captureMode, "strict");
    assert.equal(received.body.timeoutSeconds, 30);
    assert.equal(received.body.maxResultChars, 12000);

    const direct = await devirtualizeRawLuraphSource({
      source: "direct protected source",
      sourceName: "pasted-script.luau",
      captureMode: "strict",
      timeoutSeconds: 30,
      previewLines: 20,
    });
    assert.equal(direct.ok, true);
    assert.equal(direct.structured.sourceKind, "raw");
    assert.equal(direct.structured.scriptPath, "pasted-script.luau");
    assert.equal(received.body.source, "direct protected source");
    assert.equal(readCachedLuraphResult({
      resultId: direct.structured.resultId,
      startLine: 1,
      maxLines: 20,
    }).ok, true);
    assert.equal(releaseCachedLuraphResult(undefined, direct.structured.resultId).ok, true);

    const relayed = await callToolRoute({
      type: "devirtualize-luraph",
      operation: "run-source",
      source: "HTTP relayed protected source",
      captureMode: "strict",
      timeoutSeconds: 30,
      previewLines: 20,
    });
    assert.equal(relayed.statusCode, 200);
    assert.equal(relayed.body.clientId, undefined);
    assert.equal(relayed.body.structuredContent.sourceKind, "raw");
    assert.equal(received.body.source, "HTTP relayed protected source");
    const released = await callToolRoute({
      type: "devirtualize-luraph",
      operation: "release",
      resultId: relayed.body.structuredContent.resultId,
    });
    assert.equal(released.body.error, undefined);
  } finally {
    if (previousUrl === undefined) delete process.env.LURAPH_WORKER_URL;
    else process.env.LURAPH_WORKER_URL = previousUrl;
    if (previousToken === undefined) delete process.env.LURAPH_WORKER_TOKEN;
    else process.env.LURAPH_WORKER_TOKEN = previousToken;
    await close(server);
  }
});

test("Luraph worker client rejects missing configuration", async () => {
  const previous = process.env.LURAPH_WORKER_URL;
  delete process.env.LURAPH_WORKER_URL;
  try {
    await assert.rejects(
      requestLuraphDevirtualization({ source: "x", captureMode: "strict" }),
      /Luraph worker is not configured/
    );
  } finally {
    if (previous !== undefined) process.env.LURAPH_WORKER_URL = previous;
  }
});
