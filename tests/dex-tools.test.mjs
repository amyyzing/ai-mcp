import assert from "node:assert/strict";
import test from "node:test";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { hostInspectionCapabilities } from "../dist/tools/impl/advanced/runtime-status.js";
import registerDexTools from "../dist/tools/impl/dex/dex-tools.js";
import {
  dexInspectInputSchema,
  dexOutputSchema,
  dexQueryInputSchema,
  dexReferencesInputSchema,
  dexRevealInputSchema,
  dexSelectionInputSchema,
  dexSnapshotInputSchema,
  dexTargetSchema,
  dexWatchInputSchema,
} from "../dist/tools/impl/dex/schemas.js";

const target = { path: "workspace[\"Door Panel\"]" };
const invalid = (schema, value) => assert.equal(schema.safeParse(value).success, false);

test("Dex target and inspection schemas preserve strict paths and bounded batches", () => {
  assert.equal(dexTargetSchema.safeParse(target).success, true);
  assert.equal(dexTargetSchema.safeParse({ handle: "rh_session_1_2" }).success, true);
  invalid(dexTargetSchema, { ...target, handle: "rh_session_1_2" });
  invalid(dexTargetSchema, { path: "workspace", pathSegments: ["Workspace"] });
  invalid(dexTargetSchema, { handle: "not a handle" });
  invalid(dexTargetSchema, { ...target, code: "return workspace" });
  const value = dexInspectInputSchema.parse({ targets: [target] });
  assert.equal(value.profile, "auto");
  assert.equal(value.includeHidden, false);
  assert.equal(value.childOffset, 0);
  assert.equal(value.childLimit, 20);
  assert.equal(value.maxOutputChars, 20000);
  assert.equal(value.includeAncestors, true);
  invalid(dexInspectInputSchema, { targets: [] });
  invalid(dexInspectInputSchema, { targets: Array(21).fill(target) });
  invalid(dexInspectInputSchema, { targets: [target], properties: ["Parent.Name"] });
  invalid(dexInspectInputSchema, { targets: [target], properties: Array(81).fill("Name") });
  invalid(dexInspectInputSchema, { targets: [target], childOffset: -1 });
  invalid(dexInspectInputSchema, { targets: [target], childLimit: 101 });
});

test("Dex scans distinguish initial requests from captured-scan continuations", () => {
  const value = dexQueryInputSchema.parse({ filters: { attribute: { name: "Ready", equals: false } } });
  assert.equal(value.root.path, "workspace");
  assert.equal(value.filters.caseSensitive, false);
  assert.equal(value.limit, 25);
  assert.equal(value.scanBudget, 1000);
  assert.equal(value.timeBudgetMs, 8);
  assert.equal(value.maxDepth, 64);
  assert.equal(value.maxNodes, 50000);
  assert.equal(value.retainSnapshot, false);
  const resumed = dexQueryInputSchema.parse({ cursor: "dex_scan_1", limit: 7 });
  assert.equal(resumed.limit, 7);
  for (const key of ["root", "filters", "properties", "includeTags", "retainSnapshot", "maxDepth", "maxNodes"]) {
    assert.equal(Object.hasOwn(resumed, key), false);
  }
  for (const extra of [{ root: target }, { filters: {} }, { properties: [] }, { retainSnapshot: false }, { maxDepth: 1 }]) {
    invalid(dexQueryInputSchema, { cursor: "dex_scan_1", ...extra });
  }
  for (const extra of [{ limit: 101 }, { scanBudget: 10001 }, { timeBudgetMs: 51 }, { maxDepth: 101 }, { maxNodes: 100001 }, { properties: Array(21).fill("Name") }]) {
    invalid(dexQueryInputSchema, extra);
  }
  invalid(dexQueryInputSchema, { filters: { attribute: { name: "Ready", equals: {} } } });
  invalid(dexQueryInputSchema, { filters: { nameContains: "x".repeat(201) } });
  invalid(dexQueryInputSchema, { cursor: "x".repeat(161) });
});

test("Dex references require an initial target but preserve captured scope on resume", () => {
  const value = dexReferencesInputSchema.parse({ target });
  assert.equal(value.root.path, "workspace");
  assert.deepEqual(value.properties, ["Value", "PrimaryPart", "Adornee", "Part0", "Part1", "Attachment0", "Attachment1", "CameraSubject", "CurrentCamera"]);
  invalid(dexReferencesInputSchema, {});
  invalid(dexReferencesInputSchema, { target, retainSnapshot: true });
  invalid(dexReferencesInputSchema, { cursor: "dex_ref_1", target });
  invalid(dexReferencesInputSchema, { target, properties: Array(21).fill("Value") });
  const resumed = dexReferencesInputSchema.parse({ cursor: "dex_ref_1" });
  assert.equal(Object.hasOwn(resumed, "target"), false);
  assert.equal(Object.hasOwn(resumed, "properties"), false);
});

test("Dex snapshot and watch operations reject ambiguous or unbounded requests", () => {
  assert.deepEqual(dexSnapshotInputSchema.parse({ operation: "list" }), { operation: "list", maxOutputChars: 20000 });
  assert.equal(dexSnapshotInputSchema.parse({ operation: "page", snapshotId: "ds_1" }).cursor, 0);
  assert.equal(dexSnapshotInputSchema.parse({ operation: "diff", beforeId: "ds_1", afterId: "ds_2" }).limit, 25);
  invalid(dexSnapshotInputSchema, { operation: "list", snapshotId: "ds_1" });
  invalid(dexSnapshotInputSchema, { operation: "diff", beforeId: "ds_1" });
  invalid(dexSnapshotInputSchema, { operation: "release" });
  invalid(dexSnapshotInputSchema, { operation: "page", snapshotId: "ds_1", cursor: -1 });
  const watch = dexWatchInputSchema.parse({ operation: "start", targets: [target] });
  assert.equal(watch.includeChildren, true);
  assert.equal(watch.includeAncestry, true);
  assert.equal(watch.ttlSeconds, 300);
  assert.equal(watch.maxEvents, 200);
  assert.equal(dexWatchInputSchema.parse({ operation: "poll", watcherId: "dw_1" }).limit, 50);
  invalid(dexWatchInputSchema, { operation: "list" });
  invalid(dexWatchInputSchema, { operation: "start", targets: Array(11).fill(target) });
  invalid(dexWatchInputSchema, { operation: "start", targets: [target], ttlSeconds: 29 });
  invalid(dexWatchInputSchema, { operation: "start", targets: [target], maxEvents: 501 });
  invalid(dexWatchInputSchema, { operation: "stop", watcherId: "dw_1", targets: [target] });
  invalid(dexWatchInputSchema, { operation: "poll", watcherId: "dw_1", cursor: -1 });
});

test("Dex tools register read-only bounded tools with structured output and scoped semantics", () => {
  const tools = new Map();
  registerDexTools({ registerTool(name, config, handler) { tools.set(name, { config, handler }); } }, {});
  assert.deepEqual([...tools.keys()], ["dex-selection", "dex-reveal", "dex-inspect", "dex-query", "dex-snapshot", "dex-references", "dex-watch"]);
  const examples = {
    "dex-selection": {},
    "dex-reveal": { target },
    "dex-inspect": { targets: [target] },
    "dex-query": {},
    "dex-snapshot": { operation: "list" },
    "dex-references": { target },
    "dex-watch": { operation: "start", targets: [target] },
  };
  for (const [name, { config, handler }] of tools) {
    assert.equal(config.annotations.readOnlyHint, name !== "dex-reveal");
    assert.equal(config.annotations.destructiveHint, false);
    assert.equal(config.annotations.idempotentHint, ["dex-inspect", "dex-selection", "dex-reveal"].includes(name));
    assert.equal(config.inputSchema.safeParse(examples[name]).success, true);
    assert.equal(config.outputSchema, dexOutputSchema);
    assert.equal(typeof handler, "function");
    assert.match(config.description, /client/i);
  }
  assert.deepEqual(dexOutputSchema.parse({ items: [], cursor: "next" }), { items: [], cursor: "next" });
  const advertisedQuery = tools.get("dex-query").config.inputSchema;
  assert.deepEqual(advertisedQuery.parse({ cursor: "dx_test:1" }), { cursor: "dx_test:1" });
  invalid(advertisedQuery, { cursor: "dx_test:1", properties: [] });
  invalid(tools.get("dex-watch").config.inputSchema, { operation: "start" });
});

test("Dex selection handoff accepts handles without allowing mixed identities", () => {
  assert.equal(dexSelectionInputSchema.parse({}).limit, 25);
  invalid(dexSelectionInputSchema, { limit: 51 });
  assert.equal(dexRevealInputSchema.safeParse({ target: { handle: "rh_test_1_1" } }).success, true);
  invalid(dexRevealInputSchema, { target: { handle: "rh_test_1_1", path: "workspace" } });
  invalid(dexQueryInputSchema, { filters: { attribute: { name: "Ready", equals: null } } });
});

test("Screenshot capabilities distinguish the MCP host from the Roblox device", () => {
  const linux = hostInspectionCapabilities("linux", "primary");
  assert.equal(linux.screenshotAvailable, false);
  assert.equal(linux.screenshotBackend, "unavailable");
  assert.deepEqual(linux.alternatives, ["dex-query", "dex-inspect", "dex-selection"]);
  assert.match(linux.note, /not a pixel-level screenshot/);
  assert.equal(hostInspectionCapabilities("win32", "primary").screenshotAvailable, true);
  const relay = hostInspectionCapabilities("win32", "secondary");
  assert.equal(relay.screenshotAvailable, null);
  assert.equal(relay.screenshotLocation, "primary-host");
  assert.equal(relay.screenshotBackend, "primary-host-dependent");
});

test("Dex schemas publish through the real MCP protocol without losing operation variants", async () => {
  const server = new McpServer({ name: "dex-test", version: "1.0.0" });
  const client = new Client({ name: "dex-test-client", version: "1.0.0" });
  const [serverTransport, clientTransport] = InMemoryTransport.createLinkedPair();
  registerDexTools(server, {});
  try {
    await server.connect(serverTransport);
    await client.connect(clientTransport);
    const catalog = await client.listTools();
    assert.equal(catalog.tools.length, 7);
    for (const tool of catalog.tools) {
      assert.equal(tool.inputSchema.type, "object");
      assert.equal(tool.outputSchema.type, "object");
    }
    const query = catalog.tools.find((tool) => tool.name === "dex-query");
    assert.match(JSON.stringify(query.inputSchema), /"cursor"/);
    assert.match(JSON.stringify(query.inputSchema), /"root"/);
    const watch = catalog.tools.find((tool) => tool.name === "dex-watch");
    for (const operation of ["start", "poll", "stop"]) {
      assert.match(JSON.stringify(watch.inputSchema), new RegExp(`"${operation}"`));
    }
  } finally {
    await client.close();
    await server.close();
  }
});
