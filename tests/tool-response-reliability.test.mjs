import assert from "node:assert/strict";
import test from "node:test";
import {
  handleRobloxResponse, resetPrimaryState, setInstanceRole,
} from "../dist/bridge/handlers/shared/communication.js";
import {
  getClientById, registerClient, resetRegistry,
} from "../dist/bridge/handlers/shared/registry.js";
import {
  describeResponse, dispatchFailureResponse, relayToolToApi, responseText, sendAndWait,
} from "../dist/tools/factory.js";

test("relay preserves failed analysis freshness and the error flag", async () => {
  const previous = globalThis.fetch;
  globalThis.fetch = async () => new Response(JSON.stringify({result:"superseded",isError:true,structuredContent:{ok:false,freshness:{state:"superseded"}}}),{headers:{"Content-Type":"application/json"}});
  try { const result=await relayToolToApi("code-check",{});assert.equal(result.isError,true);assert.equal(result.structuredContent.freshness.state,"superseded"); }
  finally {globalThis.fetch=previous;}
});

function fixture(t) {
  resetPrimaryState();
  resetRegistry();
  setInstanceRole("primary");
  t.after(() => {
    resetPrimaryState();
    resetRegistry();
    setInstanceRole("primary");
  });
  const clientId = registerClient({
    username: "response-test", userId: 1, placeId: 1, jobId: "test",
    sessionId: "response-fixture", transport: "http",
  });
  const client = getClientById(clientId);
  return {
    clientId,
    reply(response, options = {}) {
      client.pendingPollResolve = (commands) => {
        assert.equal(commands.length, 1);
        const { id } = JSON.parse(commands[0]);
        assert.equal(handleRobloxResponse({ ...response, id }, clientId), true);
      };
      return sendAndWait({ type: "test-probe", data: {}, clientId, timeoutMs: 1000, ...options });
    },
  };
}

test("text tools reject explicit failures even when output and a success message exist", async (t) => {
  const client = fixture(t);
  for (const failure of [{ success: false }, { isError: true }, { error: "read failed" }]) {
    const result = await client.reply({ output: "partial data", ...failure }, {
      failureField: "error",
      successMessage: () => assert.fail("an explicit failure must not reach the success callback"),
    });
    assert.equal(result.isError, true);
    assert.match(result.content[0].text, /Failed to test-probe/);
  }
});

test("text tools accept structured-only objects but do not fabricate missing output", async (t) => {
  const client = fixture(t);
  const result = await client.reply({ success: true, structured: { available: true } });
  assert.equal(result.isError, undefined);
  assert.deepEqual(JSON.parse(result.content[0].text), { available: true });
  for (const structured of [null, [], "not an object"]) {
    assert.equal((await client.reply({ success: true, structured })).isError, true);
  }
  assert.equal((await client.reply({ success: true }, { failureField: "error" })).isError, true);
  const acknowledgment = await client.reply({ success: true }, {
    failureField: "error", successMessage: () => "Acknowledged.",
  });
  assert.equal(acknowledgment.isError, undefined);
  assert.equal(acknowledgment.content[0].text, "Acknowledged.");
  assert.equal(responseText({ output: "", structured: { available: true } }), "");
});

test("dispatch errors distinguish a registered client from a missing primary connection", (t) => {
  const { clientId } = fixture(t);
  assert.equal(dispatchFailureResponse("request-id", clientId), undefined);
  const registered = dispatchFailureResponse(null, clientId);
  assert.equal(registered.isError, true);
  assert.match(registered.content[0].text, /registered, but dispatch failed/);
  assert.match(registered.content[0].text, /not automatically replayed/);
  setInstanceRole("secondary");
  const secondary = dispatchFailureResponse(null, clientId);
  assert.equal(secondary.isError, true);
  assert.match(secondary.content[0].text, /primary bridge connection/);
});

test("relay rejects non-object or malformed JSON without retrying the request", async (t) => {
  const replies = ["null", "[]", "true", "42", '"text"', "{"];
  let calls = 0;
  t.mock.method(globalThis, "fetch", async () => new Response(replies[calls++], { status: 200 }));
  for (let index = 0; index < replies.length; index += 1) {
    const result = await relayToolToApi("test-probe", {}, 1000);
    assert.equal(result.isError, true);
    assert.match(result.content[0].text, /non-object JSON|invalid JSON/);
    assert.equal(calls, index + 1);
  }
});

test("malformed response descriptions stay bounded and serializing them cannot throw", () => {
  const cyclic = {};
  cyclic.self = cyclic;
  assert.equal(responseText({ structured: cyclic }), undefined);
  assert.equal(describeResponse(cyclic), "unserializable response");
  assert.equal(describeResponse({ error: "x".repeat(2000) }).length, 500);
  assert.match(describeResponse(undefined), /outcome before retrying/);
});
