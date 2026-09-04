import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

const read = (name) => readFile(new URL(`../${name}`, import.meta.url), "utf8");
async function runLuau(t, source) {
  const cli = process.env.LUAU_BIN || "luau";
  const probe = spawnSync(cli, ["--help"], { encoding: "utf8" });
  if (probe.error?.code === "ENOENT") return t.skip("Luau CLI is required for bridge behavior checks.");
  assert.equal(probe.error, undefined);
  const dir = await mkdtemp(path.join(tmpdir(), "dex-bridge-test-"));
  try {
    const file = path.join(dir, "test.luau");
    await writeFile(file, source);
    const result = spawnSync(cli, [file], { encoding: "utf8", timeout: 15000 });
    assert.equal(result.status, 0, result.stdout + result.stderr);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

test("Dex bridge selection/reveal preserve identity, metadata, limits and lifecycle", async (t) => {
  const handler = (await read("connector-src/bridge/handlers/dex.luau")).replace(/^local \w+ = require\([^\n]+\)\r?\n/gm, "");
  await runLuau(t, `
local globals, callbacks = {}, {}
local getgenv = function() return globals end
local HttpService = {JSONEncode = function(_, value) return string.rep("x", value._size or 100) end, GenerateGUID = function() return "test-guid" end}
local game = {PlaceId = 42, GetService = function() return HttpService end}
local DateTime = {now = function() return {UnixTimestampMillis = 123456} end}
local task = {spawn = function() end}
local destroyed = 0
local fakeInspector = {
  Describe = function(_, instance) return {Handle = instance.Handle, Name = "Twin", _size = instance._size} end,
  Resolve = function(_, target) return target end,
  Inspect = function() return {results = {}} end,
}
local Inspector = {new = function() return fakeInspector end}
local InstancePath = {}
local Scan = {new = function(options)
  assert(options.NewId() == "test-guid")
  return {Query = function(_, _, mode) return {mode = mode or "query"} end, Snapshots = function() return {} end, Destroy = function() destroyed += 1 end}
end}
local Watch = {new = function(options)
  assert(options.NewId() == "test-guid")
  return {Start = function() return {} end, Poll = function() return {} end, Stop = function() return {} end, Destroy = function() destroyed += 1 end}
end}
local register = (function() ${handler} end)()
local bridge = {ClientId = "client-a", Connected = true, BindToTypeStructured = function(_, name, callback) callbacks[name] = callback end}
local cleanup = register({RuntimeHandles = {generation = 7}, RuntimeValues = {}}, bridge)
local api = globals.RobloxMCPDex
assert(api.Version == 1 and api.ClientId == "client-a")
assert(not pcall(callbacks["dex-selection"], {}))
local selected = {}
for index = 1, 100 do selected[index] = {Handle = "rh_test_" .. index} end
local ready, revealed = true, nil
globals.DexMCP = {
  Version = 1, GetSelection = function() return selected end,
  GetStatus = function() return {Ready = ready, SelectionCount = 105, SelectionTruncated = true} end,
  Reveal = function(instance) revealed = instance return true end,
}
local first = callbacks["dex-selection"]({limit = 25})
assert(#first.results == 25 and first.nextOffset == 25)
assert(first.selectionCount == 105 and first.availableSelectionCount == 100 and first.selectionTruncated)
assert(first.clientId == "client-a" and first.connectorGeneration == 7 and first.placeId == 42 and first.observedAtUnixMs == 123456)
local last = callbacks["dex-selection"]({offset = 95, limit = 25})
assert(#last.results == 5 and last.nextOffset == nil and last.selectionTruncated)
selected[1]._size = 5000
local bounded = callbacks["dex-selection"]({maxChars = 2000, limit = 1})
assert(bounded.results[1].omitted and bounded.results[1].Handle == selected[1].Handle and bounded.nextOffset == 1)
local target = {handle = "rh_exact_1"}
assert(callbacks["dex-reveal"]({target = target}).revealed and revealed == target)
ready = false
assert(not pcall(callbacks["dex-reveal"], {target = target}))
ready = true
globals.DexMCP.Reveal = function() return false, "not indexed" end
assert(not pcall(callbacks["dex-reveal"], {target = target}))
assert(callbacks["dex-references"]({}).mode == "references")
assert(not pcall(callbacks["dex-watch"], {operation = "invalid"}))
local replacement = {}
globals.RobloxMCPDex = replacement
cleanup()
assert(destroyed == 2 and globals.RobloxMCPDex == replacement)
assert(not pcall(api.Describe, selected[1]))
assert(not pcall(callbacks["dex-inspect"], {}))
`);
});

test("Dex paths reject duplicate identities and legacy tree work counts nonmatches", async (t) => {
  const paths = await read("connector-src/bridge/instance-path.luau");
  const instances = (await read("connector-src/bridge/handlers/instances.luau")).replace(/^local InstancePath = require\([^\n]+\)\r?\n/, "");
  await runLuau(t, `
local typeof = function(value) return type(value) == "table" and value._instance and "Instance" or type(value) end
local os = {clock = function() return 0 end}
local function instance(name, class, parent)
  local obj = {Name = name, ClassName = class, Parent = parent, _instance = true, children = {}}
  function obj:GetChildren() return self.children end
  function obj:FindFirstChild(childName) for _, child in self.children do if child.Name == childName then return child end end end
  function obj:IsA(className) return self.ClassName == className or className == "Instance" end
  function obj:GetFullName() return self.Name end
  function obj:GetDebugId() return self.Name end
  if parent then table.insert(parent.children, obj) end
  return obj
end
local game = instance("game", "DataModel")
local workspace = instance("Workspace", "Workspace", game)
local first = instance("Twin", "Part", workspace)
instance("Twin", "Part", workspace)
local InstancePath = (function() ${paths} end)()
assert(InstancePath.Resolve({path = "workspace.Twin"}) == first)
local ok, reason = pcall(InstancePath.Resolve, {path = "workspace.Twin"}, true)
assert(not ok and string.find(reason, "Ambiguous", 1, true))
local unique = instance("Door Panel", "Part", workspace)
assert(InstancePath.Resolve({path = 'workspace["Door Panel"]'}, true) == unique)
local callbacks = {}
local register = (function() ${instances} end)()
register({}, {BindToType = function(_, name, callback) callbacks[name] = callback end})
local tree = callbacks["get-descendants-tree"]({root = "workspace", maxDepth = 0})
assert(#tree.Children == 0 and tree.VisitedDescendants == 0)
for index = 1, 5100 do instance("Unmatched" .. index, "Folder", workspace) end
local bounded = callbacks["get-descendants-tree"]({root = "workspace", maxDepth = 2, classFilter = "Script"})
assert(bounded.VisitedDescendants == 5000 and bounded.TraversalLimited)
local summary = callbacks["get-descendants-tree"]({root = "workspace", maxDepth = 2, classFilter = "Script", summaryOnly = true})
assert(summary.VisitedDescendants == 5000 and summary.TraversalLimited and summary.MatchedDescendants == 0)
`);
});

test("connector setup failure still runs registered Dex cleanup", async (t) => {
  const runtime = await read("connector-src/bridge/runtime.luau");
  const lifecycle = runtime.slice(runtime.indexOf("    local cleanups = {}"), runtime.lastIndexOf("    task.wait(1)"));
  assert.ok(lifecycle.includes("handlersOk"));
  await runLuau(t, `
local cleaned, closed, cancelled, waited = 0, false, 0, false
local task = {cancel = function() cancelled += 1 end}
local Bridge = {Connected = true, AliveThread = {}, PollThread = {},
  WebSocket = {Close = function() closed = true end},
  WaitForDisconnect = function() waited = true end,
}
local context, ScriptMappingPipeline = {}, {bridge = Bridge}
local registrars = {
  function() return function() cleaned += 1 end end,
  function() error("setup failed") end,
}
local ok, reason = pcall(function() ${lifecycle} end)
assert(not ok and string.find(reason, "setup failed", 1, true))
assert(cleaned == 1 and closed and cancelled == 2 and not waited)
assert(not Bridge.Connected and ScriptMappingPipeline.bridge == nil)
`);
});
