import assert from "node:assert/strict";
import http from "node:http";
import test from "node:test";

import { requestLuraphDevirtualization } from "../dist/luraph/client.js";
import {
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

test("Luraph schema requires an indexed path and bounds execution", () => {
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
