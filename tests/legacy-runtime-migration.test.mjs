import assert from "node:assert/strict";
import http from "node:http";
import test from "node:test";

import {
  legacyServerRequiresShutdown,
  waitForLegacyServerShutdown,
} from "../scripts/legacy-runtime-migration.mjs";

async function listenWithInfo(info) {
  const server = http.createServer((request, response) => {
    if (request.url !== "/api/server-info") {
      response.writeHead(404).end();
      return;
    }
    response.writeHead(200, { "Content-Type": "application/json" });
    response.end(JSON.stringify(info));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return server;
}

test("legacy server-info is detected for the one-time architecture migration", async () => {
  const server = await listenWithInfo({ version: "0.9.0", clientCount: 1 });
  const port = server.address().port;
  assert.equal(await legacyServerRequiresShutdown(port), true);
  await new Promise((resolve) => server.close(resolve));
  await assert.doesNotReject(waitForLegacyServerShutdown(port, 500));
});

test("the background-core server-info shape is never treated as legacy", async (t) => {
  const server = await listenWithInfo({
    architecture: "background-core",
    pid: process.pid,
    instanceId: "test",
  });
  t.after(() => server.close());
  assert.equal(
    await legacyServerRequiresShutdown(server.address().port),
    false
  );
});
