import assert from "node:assert/strict";
import fs from "node:fs/promises";
import test from "node:test";

import {
  inspectInstanceInputSchema,
  searchGcInputSchema,
  unifiedInputSchema,
  waitForEventInputSchema,
} from "../dist/tools/impl/advanced/schemas.js";
import {
  callbackInspectInputSchema,
  gcQueryInputSchema,
  gcSnapshotInputSchema,
  propertyAccessInputSchema,
  runtimeActorsInputSchema,
  runtimeCallInputSchema,
  runtimeInspectInputSchema,
  runtimeReadInputSchema,
  runtimeReferencesInputSchema,
  runtimeScriptsInputSchema,
  runtimeWriteInputSchema,
  signalConnectionsInputSchema,
} from "../dist/tools/impl/runtime/schemas.js";
import {
  buildListScriptsResult,
  listScriptsInputSchema,
} from "../dist/tools/impl/advanced/list-scripts.js";
import { formatRuntimeStatus } from "../dist/tools/impl/advanced/runtime-status.js";
import { remoteSpyInputSchema } from "../dist/tools/impl/remote-spy/remote-spy.js";
import { relayToolToApi } from "../dist/tools/factory.js";
import {
  MAX_SEMANTIC_CHUNKS,
  MAX_SEMANTIC_PROVIDER_INPUT_CHARS,
  getSemanticVectorCacheStats,
} from "../dist/semantic/vector-index.js";

test("advanced tool schemas enforce bounded discriminated inputs", () => {
  assert.equal(inspectInstanceInputSchema.safeParse({
    target: { path: "game.Workspace[\"Door Panel\"]" },
  }).success, true);
  assert.equal(inspectInstanceInputSchema.safeParse({
    target: { path: "game.Workspace", pathSegments: ["Workspace"] },
  }).success, false);

  assert.equal(searchGcInputSchema.safeParse({ kind: "function" }).success, false);
  assert.equal(searchGcInputSchema.safeParse({
    kind: "function",
    name: "FireWeapon",
    constants: ["Ammo"],
  }).success, true);
  assert.equal(searchGcInputSchema.safeParse({
    kind: "table",
    keys: ["Token"],
    limit: 2,
  }).success, false);
  assert.equal(searchGcInputSchema.safeParse({
    kind: "table",
    keys: ["Token"],
    limit: 1,
  }).success, true);

  assert.equal(waitForEventInputSchema.safeParse({
    mode: "console",
    contains: "ready",
    timeoutMs: 30000,
  }).success, true);
  assert.equal(waitForEventInputSchema.safeParse({
    mode: "console",
    timeoutMs: 30001,
  }).success, false);
  assert.equal(waitForEventInputSchema.safeParse({
    mode: "attribute",
    target: { path: "game.Workspace.Door" },
    attribute: "Open",
    condition: "equals",
  }).success, false);
  assert.equal(waitForEventInputSchema.safeParse({
    mode: "instance",
    selector: "Part",
    cursor: 10,
  }).success, false);

  assert.equal(unifiedInputSchema.safeParse({
    action: "key",
    key: "E",
    repeatCount: 20,
  }).success, true);
  assert.equal(unifiedInputSchema.safeParse({
    action: "key",
    key: "E",
    repeatCount: 21,
  }).success, false);
  assert.equal(listScriptsInputSchema.safeParse({ cursor: 2, offset: 2 }).success, false);
  assert.equal(remoteSpyInputSchema.safeParse({
    operation: "block",
    direction: "Outgoing",
  }).success, false);
  assert.equal(remoteSpyInputSchema.safeParse({
    operation: "block",
    direction: "Outgoing",
    remoteDebugId: "debug-id",
  }).success, true);

  assert.equal(runtimeInspectInputSchema.safeParse({ handle: "rh_session_1_1" }).success, true);
  assert.equal(runtimeInspectInputSchema.safeParse({ handle: "not a handle" }).success, false);
  assert.equal(runtimeReadInputSchema.safeParse({
    member: "field",
    handle: "rh_session_1_1",
    key: "Inventory",
  }).success, true);
  assert.equal(runtimeWriteInputSchema.safeParse({
    member: "upvalue",
    handle: "rh_session_1_1",
    index: 1,
    value: { type: "number", value: 10 },
  }).success, true);
  assert.equal(runtimeWriteInputSchema.safeParse({
    member: "field",
    handle: "rh_session_1_1",
    key: "Inventory",
  }).success, false);
  assert.equal(runtimeCallInputSchema.safeParse({
    handle: "rh_session_1_1",
    arguments: Array.from({ length: 33 }, () => 1),
  }).success, false);
  assert.equal(gcSnapshotInputSchema.safeParse({
    operation: "create",
    scanLimit: 100000,
  }).success, true);
  assert.equal(gcSnapshotInputSchema.safeParse({
    operation: "create",
    scanLimit: 100001,
  }).success, false);
  assert.equal(gcQueryInputSchema.safeParse({
    snapshotId: "gs_session_1",
    kind: "function",
    sourceContains: "Controller",
  }).success, true);
  assert.equal(runtimeReferencesInputSchema.safeParse({
    snapshotId: "gs_session_1",
    handle: "rh_session_1_1",
    direction: "both",
  }).success, true);
  assert.equal(runtimeScriptsInputSchema.safeParse({
    operation: "list",
    collection: "loaded-modules",
  }).success, true);
  assert.equal(signalConnectionsInputSchema.safeParse({
    operation: "list",
    target: { path: "game.Players.LocalPlayer" },
    signal: "CharacterAdded",
  }).success, true);
  assert.equal(propertyAccessInputSchema.safeParse({
    operation: "write",
    target: { path: "workspace.Part" },
    property: "Transparency",
    value: 0.5,
  }).success, true);
  assert.equal(callbackInspectInputSchema.safeParse({
    operation: "inspect",
    target: { path: "workspace.Function" },
    property: "OnInvoke",
  }).success, true);
  assert.equal(runtimeActorsInputSchema.safeParse({
    operation: "threads",
    handle: "rh_session_1_1",
    target: { path: "workspace.Actor" },
  }).success, false);
});

test("list-scripts returns stable bounded metadata pages without source by default", () => {
  const index = {
    clientId: "client",
    placeId: 1,
    jobId: "job",
    hasFinishedMapping: false,
    mappedSources: 3,
    processedSources: 3,
    skippedSources: 1,
    sourcesToMap: 5,
    sourceGap: 2,
    sourceIndexComplete: false,
    mappingSessionId: "mapping-session",
    mappingRevision: 7,
    scripts: [
      {
        debugId: "b",
        path: "game.ReplicatedStorage.Beta",
        source: "return 2",
        sourceHash: "source-b",
        updatedAt: 200,
      },
      {
        debugId: "a",
        path: "game.ReplicatedStorage.Alpha",
        source: "line1\nline2",
        scriptHash: "script-a",
        sourceHash: "source-a",
        updatedAt: 100,
      },
      {
        debugId: "c",
        path: "game.Workspace.Gamma",
        source: "return 3",
        sourceHash: "source-c",
        updatedAt: 300,
      },
    ],
  };

  const first = buildListScriptsResult(index, {
    pathPrefix: "GAME.REPLICATEDSTORAGE",
    limit: 1,
    includeSourcePreview: false,
    sourcePreviewChars: 300,
  });
  assert.equal(first.totalMatched, 2);
  assert.equal(first.scripts[0].name, "Alpha");
  assert.equal(first.scripts[0].lineCount, 2);
  assert.equal(first.scripts[0].sourcePreview, undefined);
  assert.equal(first.nextCursor, 1);
  assert.equal(first.sync.mappingRevision, 7);

  const second = buildListScriptsResult(index, {
    cursor: first.nextCursor,
    limit: 1,
    includeSourcePreview: true,
    sourcePreviewChars: 100,
  });
  assert.equal(second.scripts[0].name, "Beta");
  assert.equal(second.scripts[0].sourcePreview, "return 2");
});

test("runtime status formatter keeps server and connector evidence separated", () => {
  const output = formatRuntimeStatus({
    role: "primary",
    selectedClientId: "client",
    pendingCalls: 0,
    roundTripLatencyMs: 12,
  }, "{capabilities={filtergc=true}}");
  assert.match(output, /roundTripLatencyMs/);
  assert.match(output, /Connector runtime\/capabilities/);
});

test("HTTP tool relay preserves structuredContent for output-schema tools", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response(JSON.stringify({
    result: "page",
    structuredContent: { totalMatched: 2, scripts: [] },
  }), { headers: { "Content-Type": "application/json" } });
  try {
    const response = await relayToolToApi("list-scripts", {});
    assert.deepEqual(response.structuredContent, { totalMatched: 2, scripts: [] });
    assert.equal(response.content[0].text, "page");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("semantic and connector resource budgets are explicit and bounded", async () => {
  assert.equal(MAX_SEMANTIC_CHUNKS, 5000);
  assert.equal(MAX_SEMANTIC_PROVIDER_INPUT_CHARS, 4 * 1024 * 1024);
  assert.deepEqual(getSemanticVectorCacheStats(), {
    sessions: 0,
    vectors: 0,
    vectorValues: 0,
  });

  const [init, lifecycle, searchGc, remoteSpy, internalSpy] = await Promise.all([
    fs.readFile(new URL("../connector-src/init.luau", import.meta.url), "utf8"),
    fs.readFile(new URL("../connector-src/mapping/lifecycle.luau", import.meta.url), "utf8"),
    fs.readFile(new URL("../connector-src/bridge/handlers/search-gc.luau", import.meta.url), "utf8"),
    fs.readFile(new URL("../connector-src/bridge/handlers/remote-spy/logs.luau", import.meta.url), "utf8"),
    fs.readFile(new URL("../connector-src/bridge/handlers/remote-spy/internal-spy.luau", import.meta.url), "utf8"),
  ]);
  assert.match(init, /SANITIZE_MAX_TOTAL_ENTRIES = 2000/);
  assert.match(init, /SANITIZE_MAX_TOTAL_STRING_BYTES = 128 \* 1024/);
  assert.match(init, /utf8\.codes/);
  assert.match(init, /BridgeWebSocketURL = "wss:\/\/"/);
  assert.doesNotMatch(lifecycle, /QueryDescendants\("LuaSourceContainer"\)/);
  assert.match(lifecycle, /scanNodeLimit/);
  assert.match(searchGc, /filtergc, data\.kind, filter, true/);
  assert.doesNotMatch(remoteSpy, /HttpGet|loadstring/);
  assert.match(remoteSpy, /InternalSpy\.Start/);
  assert.match(remoteSpy, /for i = startIdx, retainedCalls do/);
  assert.doesNotMatch(internalSpy, /HttpGet|loadstring/);
  assert.match(internalSpy, /MAX_CALLS_PER_REMOTE = 25/);
  assert.match(internalSpy, /MAX_SNAPSHOT_ENTRIES = 100/);
  assert.match(internalSpy, /MAX_SNAPSHOT_STRING_BYTES = 8 \* 1024/);
  assert.match(internalSpy, /log\.TotalCalls \+= 1/);
  assert.match(internalSpy, /MAX_INITIAL_SCAN_NODES = 20000/);
});

test("strict connector paths replace loadstring in read and UI handlers", async () => {
  const files = await Promise.all([
    "connector-src/bridge/instance-path.luau",
    "connector-src/bridge/handlers/instances.luau",
    "connector-src/bridge/handlers/input.luau",
  ].map((path) => fs.readFile(new URL(`../${path}`, import.meta.url), "utf8")));
  for (const source of files) assert.doesNotMatch(source, /loadstring\s*\(/);
  assert.match(files[0], /Path root must be exactly game or workspace/);

  const runtime = await fs.readFile(
    new URL("../connector-src/bridge/runtime.luau", import.meta.url),
    "utf8"
  );
  assert.match(runtime, /EnableInitialScriptDecompMapping == true/);
  assert.match(runtime, /DisableInitialScriptDecompMapping == false/);

  const instances = await fs.readFile(
    new URL("../connector-src/bridge/handlers/instances.luau", import.meta.url),
    "utf8"
  );
  assert.match(instances, /MAX_SUMMARY_VISITED = 20000/);
  assert.match(instances, /MAX_SELECTOR_MATCHES = 1000/);
  assert.match(instances, /Another instance selector search is already running/);
  assert.match(instances, /Marketplace metadata unavailable/);
});

test("execution is acknowledged and remote-spy mutations use collision-safe identity", async () => {
  const core = await fs.readFile(
    new URL("../connector-src/bridge/handlers/core.luau", import.meta.url),
    "utf8"
  );
  const executeHandler = core.match(
    /Bridge:BindToType\("execute",[\s\S]*?Bridge:BindToTypeRaw/
  )?.[0] ?? "";
  assert.match(executeHandler, /status\s*=\s*"completed"/);
  assert.doesNotMatch(executeHandler, /task\.defer/);
  assert.match(executeHandler, /Failed to compile execution source/);

  const [logs, control] = await Promise.all([
    fs.readFile(
      new URL("../connector-src/bridge/handlers/remote-spy/logs.luau", import.meta.url),
      "utf8"
    ),
    fs.readFile(
      new URL("../connector-src/bridge/handlers/remote-spy/control.luau", import.meta.url),
      "utf8"
    ),
  ]);
  assert.match(logs, /RemotePath\s*=\s*remotePath/);
  assert.match(logs, /RemoteDebugId\s*=\s*remoteDebugId/);
  assert.match(control, /remoteDebugId/);
  assert.match(control, /selector is ambiguous/);
});
