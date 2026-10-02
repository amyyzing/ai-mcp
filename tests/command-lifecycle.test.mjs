import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";
import {
  DispatchAndWaitForResponse, GetResponseOfIdFromClient, WaitForResponseAfterSend,
  httpResponseResolvers, requestToClientId, resetPrimaryState, setInstanceRole,
} from "../dist/bridge/handlers/shared/communication.js";
import { getClientById, registerClient, resetRegistry } from "../dist/bridge/handlers/shared/registry.js";
import { WS as registerRelay } from "../dist/http/routes/mcp-relay.js";

function fixture(t) {
  resetPrimaryState();
  resetRegistry();
  setInstanceRole("primary");
  t.after(() => { resetPrimaryState(); resetRegistry(); });
  const clientId = registerClient({
    username: "lifecycle-fixture", userId: 1, placeId: 1, placeName: "fixture",
    jobId: "fixture", transport: "http",
  });
  return { clientId, client: getClientById(clientId) };
}

test("timeout withdraws only the undelivered HTTP command and preserves other work", async (t) => {
  const { clientId, client } = fixture(t);
  client.pendingHttpCommands.push(JSON.stringify({id: "other", type: "execute"}));
  const pending = DispatchAndWaitForResponse("execute", {source: "return"}, clientId, 10);
  assert.equal(client.pendingHttpCommands.length, 2);
  const { response } = await pending;
  assert.equal(response.delivery, "not-delivered");
  assert.match(response.error, /Timed out/);
  assert.deepEqual(client.pendingHttpCommands.map(command => JSON.parse(command).id), ["other"]);
  assert.equal(requestToClientId.size, 0);
  assert.equal(httpResponseResolvers.size, 0);
});

test("timeout after polling preserves the unknown execution outcome", async (t) => {
  const { clientId, client } = fixture(t);
  client.pendingPollResolve = commands => assert.equal(commands.length, 1);
  const { response } = await DispatchAndWaitForResponse("execute", {source: "return"}, clientId, 10);
  assert.equal(response.delivery, "unknown");
  assert.equal(client.pendingHttpCommands.length, 0);
});

test("a duplicate custom send never dispatches twice or replaces the original waiter", async (t) => {
  fixture(t);
  const original = GetResponseOfIdFromClient("duplicate", 1000);
  let sends = 0;
  const result = await WaitForResponseAfterSend("duplicate", () => sends++, 1000);
  assert.match(result.error, /Duplicate pending/);
  assert.equal(sends, 0);
  httpResponseResolvers.get("duplicate")({id: "duplicate", output: "original"});
  assert.equal((await original).output, "original");
});

test("relay cancellation and disconnect withdraw queued work with origin checks", (t) => {
  const { clientId, client } = fixture(t);
  function relay() {
    const socket = new EventEmitter();
    socket.readyState = 1;
    socket.send = () => {};
    registerRelay(socket);
    return socket;
  }
  const owner = relay(), stranger = relay();
  owner.emit("message", JSON.stringify({id: "cancelled", type: "execute", targetClientId: clientId}));
  stranger.emit("message", JSON.stringify({type: "cancel-relay-request", targetRequestId: "cancelled"}));
  assert.equal(client.pendingHttpCommands.length, 1);
  owner.emit("message", JSON.stringify({type: "cancel-relay-request", targetRequestId: "cancelled"}));
  assert.equal(client.pendingHttpCommands.length, 0);
  owner.emit("message", JSON.stringify({id: "disconnected", type: "execute", targetClientId: clientId}));
  owner.emit("close");
  assert.equal(client.pendingHttpCommands.length, 0);
  assert.equal(requestToClientId.size, 0);
  stranger.emit("close");
});

test("reset withdraws both local and relayed undelivered commands", async (t) => {
  const { clientId, client } = fixture(t);
  const pending = DispatchAndWaitForResponse("execute", {source: "return"}, clientId, 1000);
  requestToClientId.set("relayed", clientId);
  client.pendingHttpCommands.push(JSON.stringify({id: "relayed", type: "execute"}));
  resetPrimaryState();
  assert.equal(client.pendingHttpCommands.length, 0);
  assert.match((await pending).response.error, /reset/);
});
