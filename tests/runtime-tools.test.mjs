import assert from "node:assert/strict";
import test from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import {
  handleRobloxResponse, resetPrimaryState, setInstanceRole,
} from "../dist/bridge/handlers/shared/communication.js";
import {
  getClientById, registerClient, resetRegistry,
} from "../dist/bridge/handlers/shared/registry.js";
import registerRuntimeTools from "../dist/tools/impl/runtime/runtime-tools.js";

async function fixture(t) {
  resetPrimaryState();
  resetRegistry();
  setInstanceRole("primary");
  const server = new McpServer({ name: "runtime-schema-test", version: "1" });
  registerRuntimeTools(server, {});
  const client = new Client({ name: "runtime-schema-client", version: "1" });
  t.after(async () => {
    await client.close();
    await server.close();
    resetPrimaryState();
    resetRegistry();
    setInstanceRole("primary");
  });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  await server.connect(serverTransport);
  await client.connect(clientTransport);
  return client;
}

test("production runtime tools publish object output schemas through the MCP SDK", async (t) => {
  const client = await fixture(t);
  const { tools } = await client.listTools();
  assert(tools.some((tool) => tool.name === "executor-capabilities"));
  assert(tools.some((tool) => tool.name === "runtime-inspect"));
  for (const tool of tools) {
    assert.equal(tool.outputSchema?.type, "object", `${tool.name} must publish an object output schema`);
    if (tool.outputSchema.additionalProperties !== true) {
      assert.deepEqual(tool.outputSchema.additionalProperties, {}, `${tool.name} must preserve runtime fields`);
    }
  }
});

test("production executor-capabilities preserves structured output in an MCP round-trip", async (t) => {
  const client = await fixture(t);
  const clientId = registerClient({
    username: "runtime-schema-test", userId: 1, placeId: 1, jobId: "test",
    sessionId: "runtime-schema-fixture", transport: "http",
  });
  const structured = {
    connectorVersion: "3",
    capabilities: [{ id: "transport.request", available: true, quality: "best-effort" }],
    httpTransport: { provider: "fixture", candidates: 1, responseValidated: true, failedRequests: 0 },
  };
  let dispatched = 0;
  getClientById(clientId).pendingPollResolve = (commands) => {
    dispatched += 1;
    assert.equal(commands.length, 1);
    const command = JSON.parse(commands[0]);
    assert.equal(command.type, "executor-capabilities");
    assert.equal(handleRobloxResponse({
      id: command.id, success: true, output: JSON.stringify(structured), structured,
    }, clientId), true);
  };
  const result = await client.callTool({
    name: "executor-capabilities", arguments: { clientId },
  });
  assert.equal(dispatched, 1);
  assert.equal(result.isError, undefined, JSON.stringify(result.content));
  assert.deepEqual(result.structuredContent, structured);
  assert.match(result.content[0].text, /responseValidated/);
});
