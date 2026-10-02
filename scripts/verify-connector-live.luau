-- Test the current modules through an isolated, temporary real HTTP connection.
-- Bundle with Darklua, execute through get-data-by-code, and call Cleanup afterward.
local BridgeFactory = require("../connector-src/bridge/client")
local ExecutorHttp = require("../connector-src/runtime/executor-http")
local Handles = require("../connector-src/runtime/handles")
local Values = require("../connector-src/runtime/typed-values")
local Encode = require("../connector-src/utils/encode")
local RegisterCore = require("../connector-src/bridge/handlers/core")
local RegisterDex = require("../connector-src/bridge/handlers/dex")

local original = getgenv()
assert(original.__MCP_LiveReliabilityProbe == nil, "A live verification probe is already running.")
local http = game:GetService("HttpService")
local base = tostring(original.BridgeURL or original.bridgeurl or ""):gsub("/+$", "")
assert(base:match("^https?://"), "The active connector must provide its bridge URL.")
local auth = original.MCPAuthToken or original.BridgeAuthToken
assert(type(auth) == "string" and auth ~= "", "Missing in-memory connector pairing credential.")
local globals = {}
local nativeLoad = loadstring
local probeEnvironment
probeEnvironment = setmetatable({
    getgenv = function() return globals end,
    loadstring = function(source)
        local chunk, problem = nativeLoad(source)
        if chunk then setfenv(chunk, probeEnvironment) end
        return chunk, problem
    end,
}, {__index = getfenv()})
for _, register in {BridgeFactory, RegisterCore, RegisterDex} do setfenv(register, probeEnvironment) end
local request = ExecutorHttp.Resolve(original, {ProbeUrl = base})
assert(request, "Executor HTTP is unavailable.")
local api = BridgeFactory({
    HttpService = http, BridgeHTTPURL = base,
    BridgeWebSocketURL = base:gsub("^http", "ws"), BridgeAuthToken = auth,
    BridgeRequestHeaders = function(headers)
        local result = table.clone(headers or {})
        result["X-Roblox-MCP-Token"] = auth
        if globals.MCP_ClientToken then result["X-Roblox-MCP-Client-Token"] = globals.MCP_ClientToken end
        return result
    end,
    Request = request, WebSocketAvailable = false,
    GetRegistrationInfo = function()
        local player = game:GetService("Players").LocalPlayer
        return {type = "register", username = player.Name, userId = player.UserId,
            placeId = game.PlaceId, placeName = "MCP temporary live verification", jobId = game.JobId,
            sessionId = http:GenerateGUID(false)}
    end,
    SanitizeForOutput = function(value) return value end, LuaEncode = Encode,
})
local bridge = api.CreateBridge()
local handles = Handles.new({RegistryId = http:GenerateGUID(false), MaxHandles = 200})
local context = {HttpService = http, LogService = game:GetService("LogService"),
    RuntimeHandles = handles, RuntimeValues = Values.new({Handles = handles})}
local oldDexBridge = original.RobloxMCPDex
local cleanupDex
local installedDexBridge
local stopped = false
local function cleanup()
    if stopped then return end
    stopped = true
    bridge:Disconnect()
    if original.RobloxMCPDex == installedDexBridge then original.RobloxMCPDex = oldDexBridge end
    if cleanupDex then cleanupDex() end
    handles:RotateGeneration()
    original.__MCP_LiveReliabilityProbe = nil
end
local ok, problem = pcall(function()
    RegisterCore(context, bridge)
    cleanupDex = RegisterDex(context, bridge)
    installedDexBridge = globals.RobloxMCPDex
    globals.DexMCP = original.DexMCP
    globals.Probe = {Bridge = bridge, Handles = handles, Globals = globals}
    bridge:BindToTypeStructured("runtime-status", function()
        return {clientId = bridge.ClientId, connected = bridge.Connected, transport = "http",
            commands = bridge:GetCommandStatus(), probe = true}
    end)
    bridge.Ready = true
    original.__MCP_LiveReliabilityProbe = {Cleanup = cleanup, AttachDex = function()
        globals.DexMCP = original.DexMCP
        original.RobloxMCPDex = globals.RobloxMCPDex
    end}
end)
if not ok then cleanup() error(problem, 0) end
task.delay(600, cleanup)
return {temporary = true, transport = "http", ready = bridge.Ready,
    clientId = bridge.ClientId, connectorId = handles.registryId, commands = bridge:GetCommandStatus()}
