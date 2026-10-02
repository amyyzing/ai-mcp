import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

test("live probe cleanup restores the previous Dex bridge before retiring its adapter", async (t) => {
  const cli = process.env.LUAU_BIN || "luau";
  const probe = spawnSync(cli, ["--help"], { encoding: "utf8" });
  if (probe.error?.code === "ENOENT") return t.skip("Luau CLI required for cleanup checks.");
  const source = await readFile(new URL("../scripts/verify-connector-live.luau", import.meta.url), "utf8");
  const cleanup = source.slice(source.indexOf("local function cleanup()"), source.indexOf("local ok, problem = pcall"));
  const directory = await mkdtemp(path.join(tmpdir(), "mcp-live-cleanup-"));
  try {
    const file = path.join(directory, "test.luau");
    await writeFile(file, `
local installedDexBridge, oldDexBridge = {}, {}
local original = {RobloxMCPDex = installedDexBridge, __MCP_LiveReliabilityProbe = {}}
local stopped, disconnects, rotations, retired = false, 0, 0, 0
local bridge = {Disconnect = function() disconnects += 1 end}
local handles = {RotateGeneration = function() rotations += 1 end}
local cleanupDex = function()
    assert(original.RobloxMCPDex == oldDexBridge, "restore ownership before cleanup invalidates its API")
    installedDexBridge = nil
    retired += 1
end
${cleanup}
cleanup()
cleanup()
assert(original.RobloxMCPDex == oldDexBridge and original.__MCP_LiveReliabilityProbe == nil)
assert(disconnects == 1 and rotations == 1 and retired == 1)
`);
    const result = spawnSync(cli, [file], { encoding: "utf8", timeout: 10000 });
    assert.equal(result.status, 0, result.stdout + result.stderr);
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test("bridge registration races, timeouts and unsupported commands recover explicitly", async (t) => {
  const cli = process.env.LUAU_BIN || "luau";
  const probe = spawnSync(cli, ["--help"], { encoding: "utf8" });
  if (probe.error?.code === "ENOENT") return t.skip("Luau CLI required for connector transport tests.");
  assert.equal(probe.error, undefined);
  const source = await readFile(new URL("../connector-src/bridge/client.luau", import.meta.url), "utf8");
  const directory = await mkdtemp(path.join(tmpdir(), "mcp-transport-test-"));
  try {
    const file = path.join(directory, "test.luau");
    await writeFile(file, `
local clock = 0
local os = { clock = function() return clock end }
local main = coroutine.running()
local globals = {}
local getgenv = function() return globals end
local task = {}
function task.spawn(callback)
    local thread = type(callback) == "thread" and callback or coroutine.create(callback)
    local ok, reason = coroutine.resume(thread)
    assert(ok, tostring(reason))
    return thread
end
function task.wait(seconds)
    if coroutine.running() ~= main then return coroutine.yield() end
    clock += seconds or 0.01
    return seconds or 0.01
end
function task.cancel(thread)
    if coroutine.status(thread) ~= "dead" then coroutine.close(thread) end
end
local function Signal()
    local signal = { connections = {} }
    function signal:Connect(callback)
        local connection = { active = true, callback = callback }
        function connection:Disconnect() self.active = false end
        table.insert(self.connections, connection)
        return connection
    end
    function signal:Fire(value)
        for _, connection in ipairs(self.connections) do
            if connection.active then connection.callback(value) end
        end
    end
    function signal:Count()
        local count = 0
        for _, connection in ipairs(self.connections) do if connection.active then count += 1 end end
        return count
    end
    return signal
end
local Factory = (function() ${source} end)()
local function Fixture(mode)
    clock = 0
    local heartbeat = string.find(mode, "heartbeat", 1, true) ~= nil
    local acknowledged = mode == "ack" or heartbeat
    local suspendProbe, probeThread = false, nil
    local failResponse = false
    local socket = { OnMessage = Signal(), OnClose = Signal(), closed = false, sends = 0 }
    function socket:Send()
        self.sends += 1
        assert(self.OnMessage:Count() == 1, "message listener must be attached before registration Send")
        if mode == "send-error" then error("send failed") end
        if failResponse then error("response send failed") end
        if acknowledged then self.OnMessage:Fire("registered") end
        if mode == "bad-ack" then self.OnMessage:Fire("bad-registration") end
    end
    function socket:Close() self.closed = true self.OnClose:Fire() end
    if mode == "listener-error" then
        function socket.OnClose:Connect() error("listener unavailable") end
    end
    local registrations, sockets = 0, 0
    local api = Factory({
        HttpService = {
            JSONEncode = function() return "encoded" end,
            JSONDecode = function(_, value)
                if value == "registered" then return { type = "registered", clientId = "ws-client", clientToken = "fixture-client-token" } end
                if value == "bad-registration" then return { type = "registered", clientId = "ws-client" } end
                if value == "http-registration" then return { clientId = "http-client", clientToken = "fixture-http-token" } end
                error("malformed message")
            end,
            UrlEncode = function(_, value) return value end,
        },
        BridgeHTTPURL = "https://bridge.test", BridgeWebSocketURL = "wss://bridge.test", BridgeAuthToken = "",
        BridgeRequestHeaders = function(headers) return headers or {} end,
        Request = function(options)
            if string.find(options.Url, "/register", 1, true) then
                registrations += 1
                return { StatusCode = 200, Body = "http-registration" }
            end
            if string.find(options.Url, "/poll", 1, true) then return { StatusCode = 204, Body = "" } end
            if string.find(options.Url, "/respond", 1, true) then return { StatusCode = failResponse and 409 or 200, Body = "" } end
            if suspendProbe then
                probeThread = coroutine.running()
                coroutine.yield()
            end
            return { StatusCode = 200, Body = "ready" }
        end,
        WebSocketAvailable = true,
        WebSocketConnect = function() sockets += 1 return socket end,
        GetRegistrationInfo = function() return {} end,
        SanitizeForOutput = function(value) return value end,
        LuaEncode = function() return "encoded output" end,
    })
    local bridge = api.CreateBridge()
    local calls = 0
    bridge:BindToType("increment", function() calls += 1 return {ok = true} end)
    bridge:DispatchMessage({type = "increment", id = "not-ready"})
    assert(calls == 0 and bridge:GetCommandStatus().rejected == 1, "startup must reject work before handlers are ready")
    bridge.Ready = true
    bridge:DispatchMessage({type = "increment", id = "once"})
    bridge:DispatchMessage({type = "increment", id = "once"})
    assert(calls == 1 and bridge:GetCommandStatus().duplicates == 1, "completed requests must not replay mutations")
    assert(bridge:GetCommandStatus().active == 0, "inline completion must release thread ownership")
    failResponse = true
    bridge:DispatchMessage({type = "increment", id = "failed-delivery"})
    assert(calls == 2 and bridge:GetCommandStatus().responseFailures == 1 and bridge:GetCommandStatus().active == 0)
    failResponse = false
    local blocked, effects = {}, 0
    bridge:BindToType("blocked", function(data)
        blocked[data.id] = coroutine.running()
        coroutine.yield()
        effects += 1
        return {ok = true}
    end)
    for index = 1, 31 do bridge:DispatchMessage({type = "blocked", id = "blocked-" .. index}) end
    bridge:DispatchMessage({type = "blocked", id = "blocked-1"})
    bridge:DispatchMessage({type = "increment", id = "overload"})
    assert(calls == 2 and bridge:GetCommandStatus().active == 31 and bridge:GetCommandStatus().rejected == 2)
    assert(bridge:GetCommandStatus().duplicates == 2, "an in-flight duplicate must not create another worker")
    local saturated
    bridge:BindToTypeStructured("runtime-status", function() saturated = bridge:GetCommandStatus() return saturated end)
    bridge:DispatchMessage({type = "runtime-status", id = "diagnose-full"})
    assert(saturated and saturated.active == 32 and saturated.workMaximum == 31,
        "a saturated connector must reserve room for diagnostics")
    assert(coroutine.resume(blocked["blocked-1"]))
    assert(effects == 1 and bridge:GetCommandStatus().active == 30)
    bridge:DispatchMessage({type = "increment", id = "after-slot-freed"})
    assert(calls == 3 and bridge:GetCommandStatus().active == 30, "one long command must not block unrelated reads")
    if acknowledged then
        assert(bridge.ClientId == "ws-client" and registrations == 0 and not socket.closed,
            "an immediate acknowledgement must not be lost")
        socket.OnMessage:Fire("malformed")
        assert(bridge.Connected, "bad JSON must not escape an event callback")
        local result = bridge:HandleMessage({ type = "new-command", id = "request-1" })
        assert(result.id == "request-1" and result.success == false and string.find(result.error, "Reload", 1, true),
            "unsupported commands must return a response instead of timing out")
        bridge:BindToTypeStructured("known", function() return { ok = true } end)
        assert(bridge:HandleMessage({ type = "known", id = "request-2" }).structured.ok)
        bridge:BindToType("failure", function() error("fixture callback failure") end)
        assert(bridge:HandleMessage({ type = "failure", id = "request-3" }).success == false)
        local alive = bridge.AliveThread
        if heartbeat then
            suspendProbe = true
            local resumed, reason = coroutine.resume(alive, 1)
            assert(resumed, tostring(reason))
            assert(probeThread and coroutine.status(probeThread) == "suspended",
                "heartbeat fixture must suspend the request separately from its timeout owner")
            if mode == "completed-heartbeat" then
                resumed, reason = coroutine.resume(probeThread)
                assert(resumed, tostring(reason))
            elseif mode == "timed-out-heartbeat" then
                clock += 6
            end
            if mode ~= "suspended-heartbeat" then
                resumed, reason = coroutine.resume(alive, 0.05)
                assert(resumed, tostring(reason))
                assert(coroutine.status(probeThread) == "dead", "finished probes must not stay suspended")
                assert(bridge.AliveProbeThread == nil, "finished probes must release ownership before disconnect")
            end
        end
        socket:Close()
        bridge:WaitForDisconnect()
        assert(coroutine.status(alive) == "dead", "disconnect must cancel the liveness thread")
        if heartbeat then
            assert(coroutine.status(probeThread) == "dead", "disconnect must also cancel an in-flight heartbeat request")
            assert(bridge.AliveProbeThread == nil, "disconnect must release probe ownership")
            bridge:Disconnect() -- Repeated cleanup must tolerate already-finished threads.
        end
    else
        assert(bridge.ClientId == "http-client" and registrations == 1,
            "missing/malformed registration or broken socket APIs must fall back to HTTP")
        assert(socket.closed and clock < 6, "failed sockets must close after a bounded registration wait")
        bridge.Connected = false
        bridge:WaitForDisconnect()
        assert(bridge.PollThread == nil, "HTTP cleanup must release the polling worker")
        local again = api.CreateBridge()
        assert(sockets == 1 and again.ClientId == "http-client", "cooldown must avoid reproving a broken socket on every reconnect")
        again:Disconnect()
    end
    for _, thread in pairs(blocked) do assert(coroutine.status(thread) == "dead", "disconnect must cancel owned command workers") end
    assert(effects == 1 and bridge:GetCommandStatus().active == 0 and bridge:GetCommandStatus().cancelled == 30)
    assert(socket.OnMessage:Count() == 0 and socket.OnClose:Count() == 0,
        "success and failed startup cleanup must both release event listeners")
end
for _, mode in ipairs({ "ack", "suspended-heartbeat", "completed-heartbeat", "timed-out-heartbeat",
    "no-ack", "bad-ack", "send-error", "listener-error" }) do Fixture(mode) end
print("Connector transport tests passed")
`, "utf8");
    const result = spawnSync(cli, [file], { encoding: "utf8", timeout: 15000 });
    assert.equal(result.status, 0, result.stdout + result.stderr);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
