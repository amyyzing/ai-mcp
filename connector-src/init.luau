-- Source entrypoint for connector.luau. Build the standalone artifact with
-- `npm run build:connector`; edit connector-src modules, not the generated file.
-- Wait before claiming the singleton guard. Multiple loader copies may wait,
-- but only the first one resumed after game load may initialize the runtime.
if not game:IsLoaded() then
    game.Loaded:Wait()
end

--// Variables \\--
if getgenv().MCP_Loaded == true or getgenv().MCP_Loading == true then
    return
end

getgenv().MCP_Loading = true
task.delay(30, function()
    if getgenv().MCP_Loaded ~= true then
        getgenv().MCP_Loading = nil
    end
end)

local BridgeURL = getgenv().BridgeURL or getgenv().bridgeurl or ... or "localhost:16384"
BridgeURL = tostring(BridgeURL):gsub("/+$", "")
local BridgeHTTPURL
local BridgeWebSocketURL
if string.match(BridgeURL, "^https://") then
    BridgeHTTPURL = BridgeURL
    BridgeWebSocketURL = "wss://" .. string.sub(BridgeURL, 9)
elseif string.match(BridgeURL, "^http://") then
    BridgeHTTPURL = BridgeURL
    BridgeWebSocketURL = "ws://" .. string.sub(BridgeURL, 8)
elseif string.match(BridgeURL, "^wss://") then
    BridgeWebSocketURL = BridgeURL
    BridgeHTTPURL = "https://" .. string.sub(BridgeURL, 7)
elseif string.match(BridgeURL, "^ws://") then
    BridgeWebSocketURL = BridgeURL
    BridgeHTTPURL = "http://" .. string.sub(BridgeURL, 6)
else
    BridgeHTTPURL = "http://" .. BridgeURL
    BridgeWebSocketURL = "ws://" .. BridgeURL
end
getgenv().BridgeURL = BridgeURL
getgenv().bridgeurl = BridgeURL
local BridgeAuthToken = getgenv().MCPAuthToken or getgenv().BridgeAuthToken
if type(BridgeAuthToken) ~= "string" then BridgeAuthToken = "" end

local function BridgeRequestHeaders(headers)
    local result = {}
    for name, value in headers or {} do
        result[name] = value
    end
    if BridgeAuthToken ~= "" then
        result["X-Roblox-MCP-Token"] = BridgeAuthToken
    end
    local clientToken = getgenv().MCP_ClientToken
    if type(clientToken) == "string" and clientToken ~= "" then
        result["X-Roblox-MCP-Client-Token"] = clientToken
    end
    return result
end

--// Services \\--
local cloneref = cloneref or function(x) return x end

local VirtualInputManager: VirtualInputManager = cloneref(Instance.new("VirtualInputManager"))
local MarketplaceService: MarketplaceService = cloneref(game:GetService("MarketplaceService"))
local CoreGui: CoreGui = cloneref(game:GetService("CoreGui"))
local CorePackages: CorePackages = cloneref(game:GetService("CorePackages"))
local ScriptContext: ScriptContext = cloneref(game:GetService("ScriptContext"))
local HttpService: HttpService = cloneref(game:GetService("HttpService"))
local LogService: LogService = cloneref(game:GetService("LogService"))
local Players: Players = cloneref(game:GetService("Players"))
local TweenService: TweenService = cloneref(game:GetService("TweenService"))

--// Libraries \\--

local base64_encode
do
    -- Lua 5.1+ base64 v3.0 (c) 2009 by Alex Kloss <alexthkloss@web.de>
    -- licensed under the terms of the LGPL2
    
    -- character table string
    local b='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    
    -- encoding
    base64_encode = base64encode or function(data)
        return ((data:gsub('.', function(x) 
            local r,b='',x:byte()
            for i=8,1,-1 do r=r..(b%2^i-b%2^(i-1)>0 and '1' or '0') end
            return r;
        end)..'0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
            if (#x < 6) then return '' end
            local c=0
            for i=1,6 do c=c+(x:sub(i,i)=='1' and 2^(6-i) or 0) end
            return b:sub(c+1,c+1)
        end)..({ '', '==', '=' })[#data%3+1])
    end
end

--// Functions \\--
local getscriptbytecode = getscriptbytecode or function(_) error("Unable to get script bytecode.") end
local GetScriptHash = type(getscripthash) == "function" and getscripthash or nil
local BuiltInDecompile = type(decompile) == "function" and decompile or nil

local LuaEncode = require("./utils/encode")

--// Bounded serialization: cap depth / entries / string length and render
--// Instances as their path so structured tool responses can't flood the
--// model context with raw dumps before the server-side char limit applies. \\--
local SANITIZE_MAX_DEPTH = 8
local SANITIZE_MAX_ENTRIES_PER_TABLE = 256
local SANITIZE_MAX_TOTAL_ENTRIES = 2000
local SANITIZE_MAX_STRING_BYTES = 500
local SANITIZE_MAX_TOTAL_STRING_BYTES = 128 * 1024

local function SanitizeString(value, budget)
    value = tostring(value)
    local allowance = math.max(0, math.min(SANITIZE_MAX_STRING_BYTES, budget.stringBytes))
    if allowance == 0 then return "<string omitted: output budget reached>" end

    local parts = {}
    local usedBytes = 0
    local validUtf8 = pcall(function()
        for _, codepoint in utf8.codes(value) do
            local character = utf8.char(codepoint)
            if usedBytes + #character > allowance then break end
            table.insert(parts, character)
            usedBytes += #character
        end
    end)
    local prefix
    if validUtf8 then
        prefix = table.concat(parts)
    else
        prefix = string.sub(string.gsub(value, "[^%g ]", "?"), 1, allowance)
        usedBytes = #prefix
    end

    budget.stringBytes = math.max(0, budget.stringBytes - usedBytes)
    return #prefix < #value and (prefix .. "...(truncated)") or prefix
end

local function SanitizeForOutput(value, depth, seen, budget)
    depth = depth or 0
    budget = budget or {
        entries = SANITIZE_MAX_TOTAL_ENTRIES,
        stringBytes = SANITIZE_MAX_TOTAL_STRING_BYTES,
    }
    local valueType = typeof(value)

    if valueType == "Instance" then
        local ok, full = pcall(function() return value:GetFullName() end)
        return SanitizeString(ok and full or value, budget)
    elseif valueType == "string" then
        return SanitizeString(value, budget)
    elseif valueType == "number" then
        if value ~= value then return "<nan>" end
        if value == math.huge then return "<infinity>" end
        if value == -math.huge then return "<-infinity>" end
        return value
    elseif valueType == "boolean" or valueType == "nil" then
        return value
    elseif valueType ~= "table" then
        -- functions, userdata, threads, Vector3, CFrame, etc.
        local ok, rendered = pcall(tostring, value)
        return SanitizeString(ok and rendered or "<unprintable value>", budget)
    end

    if depth >= SANITIZE_MAX_DEPTH then
        return "<table: max depth reached>"
    end

    seen = seen or {}
    if seen[value] then
        return "<cyclic table>"
    end
    seen[value] = true

    local result = {}
    local arrayLength = #value
    local isArray = arrayLength > 0
    if isArray then
        local inspectedKeys = 0
        for key in pairs(value) do
            inspectedKeys += 1
            if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > arrayLength then
                isArray = false
                break
            end
            if inspectedKeys >= SANITIZE_MAX_ENTRIES_PER_TABLE + 1 then break end
        end
    end

    if isArray then
        local limit = math.min(arrayLength, SANITIZE_MAX_ENTRIES_PER_TABLE)
        local included = 0
        for index = 1, limit do
            if budget.entries <= 0 then break end
            budget.entries -= 1
            included += 1
            result[index] = SanitizeForOutput(value[index], depth + 1, seen, budget)
        end
        if arrayLength > included then
            result[included + 1] = {
                __omitted = tostring(arrayLength - included) .. " additional array entries omitted",
            }
        end
        seen[value] = nil
        return result
    end

    local count = 0
    local omitted = false
    for k, v in pairs(value) do
        if count >= SANITIZE_MAX_ENTRIES_PER_TABLE or budget.entries <= 0 then
            omitted = true
            break
        end
        count += 1
        budget.entries -= 1
        -- Non-array JSON objects require string keys. Converting every other
        -- key also avoids sparse/mixed numeric tables that JSONEncode rejects.
        local key = SanitizeString(typeof(k) == "string" and k or tostring(k), budget)
        result[key] = SanitizeForOutput(v, depth + 1, seen, budget)
    end
    if omitted then
        result["__omitted"] = "additional entries omitted"
    end

    seen[value] = nil
    return result
end

--// Strip the decompiler banner line (e.g. "-- Decompiled with lua.expert")
--// so it doesn't repeat as noise across every script read/grep/search. \\--
local function StripDecompilerBanner(source)
    if typeof(source) ~= "string" then return source end
    return (string.gsub(source, "^%s*%-%-[^\n]*[Dd]ecompiled[^\n]*\n", "", 1))
end

local getnilinstances = getnilinstances or function() return {} end

--// Compatibility Check \\--
local ExecutorRequest, HttpRequestProvider = require("./runtime/executor-http").Resolve(getgenv())

-- Executors expose WebSocket under several common names. Resolve the actual
-- connect function once, then let the bridge test whether it can really open.
local function ResolveWebSocketConnect()
    if typeof(WebSocket) == "table" then
        if type(WebSocket.connect) == "function" then return WebSocket.connect end
        if type(WebSocket.Connect) == "function" then return WebSocket.Connect end
    end
    if typeof(websocket) == "table" then
        if type(websocket.connect) == "function" then return websocket.connect end
        if type(websocket.Connect) == "function" then return websocket.Connect end
    end
    if typeof(syn) == "table" and typeof(syn.websocket) == "table" then
        if type(syn.websocket.connect) == "function" then return syn.websocket.connect end
        if type(syn.websocket.Connect) == "function" then return syn.websocket.Connect end
    end
    return nil
end

local WebSocketConnect = ResolveWebSocketConnect()
local WebSocketAvailable = WebSocketConnect ~= nil and getgenv().DisableWebSocket ~= true

--// Registration Info \\--
local function GenerateSessionGuid()
    local success, guid = pcall(function()
        return HttpService:GenerateGUID(false)
    end)
    if success and type(guid) == "string" and guid ~= "" then
        return guid
    end
    return tostring(os.clock()) .. "-" .. tostring(math.random(1, 1000000000))
end

local function GetClientIdentityKey()
    local player = Players.LocalPlayer
    return table.concat({
        tostring(game.PlaceId or 0),
        tostring(game.JobId or ""),
        tostring(player and player.UserId or 0),
    }, ":")
end

local function GetStableClientSessionId()
    local identityKey = GetClientIdentityKey()
    if type(getgenv().MCP_ClientSessionId) ~= "string" or getgenv().MCP_ClientIdentityKey ~= identityKey then
        getgenv().MCP_ClientSessionId = GenerateSessionGuid()
        getgenv().MCP_ClientIdentityKey = identityKey
    end
    return getgenv().MCP_ClientSessionId
end

local function GetRegistrationInfo()
    local player = Players.LocalPlayer
    local placeName = "Unknown"
    pcall(function()
        local productInfo = MarketplaceService:GetProductInfo(game.PlaceId)
        placeName = productInfo.Name
    end)
    return {
        type = "register",
        username = player and player.Name or "Unknown",
        userId = player and player.UserId or 0,
        placeId = game.PlaceId,
        jobId = game.JobId,
        placeName = placeName,
        sessionId = GetStableClientSessionId(),
        clientToken = getgenv().MCP_ClientToken,
    }
end

-- Shared executor-runtime services live for the full connector session rather
-- than one transport, so handles survive WebSocket/HTTP reconnects.
local RuntimeHandles = require("./runtime/handles").new({
    RegistryId = GenerateSessionGuid(),
    MaxHandles = getgenv().MCP_RuntimeMaxHandles,
    DefaultTtlSeconds = getgenv().MCP_RuntimeHandleTtlSeconds,
})
local RuntimeValues = require("./runtime/typed-values").new({
    Handles = RuntimeHandles,
    DefaultDepth = getgenv().MCP_RuntimeValueDepth,
    DefaultEntries = getgenv().MCP_RuntimeValueEntries,
    DefaultStringBytes = getgenv().MCP_RuntimeValueStringBytes,
})
local RuntimeCapabilities = require("./runtime/capabilities").new({
    ConnectorVersion = "3",
    RequestAvailable = ExecutorRequest ~= nil,
    HttpRequestProvider = HttpRequestProvider,
    WebSocketAvailable = WebSocketAvailable,
})
local GcExplorer = require("./runtime/gc-explorer").new({
    Handles = RuntimeHandles,
    TypedValues = RuntimeValues,
    MaxSnapshots = getgenv().MCP_GcMaxSnapshots,
    DefaultScanLimit = getgenv().MCP_GcDefaultScanLimit,
    TableScanLimit = getgenv().MCP_GcTableScanLimit,
})
local ToastHost = require("./ui/toast-host")({
    CoreGui = CoreGui,
    TweenService = TweenService,
})

--// Bridge client \\--
local BridgeClient = require("./bridge/client")({
    HttpService = HttpService,
    BridgeHTTPURL = BridgeHTTPURL,
    BridgeWebSocketURL = BridgeWebSocketURL,
    BridgeAuthToken = BridgeAuthToken,
    BridgeRequestHeaders = BridgeRequestHeaders,
    Request = ExecutorRequest,
    HttpGet = function(url) return game:HttpGet(url) end,
    WebSocketAvailable = WebSocketAvailable,
    WebSocketConnect = WebSocketConnect,
    GetRegistrationInfo = GetRegistrationInfo,
    SanitizeForOutput = SanitizeForOutput,
    LuaEncode = LuaEncode,
})
local CreateBridge = BridgeClient.CreateBridge

--// Script source mapping modules \\--
local WorkerPool = require("./utils/worker")
local ScriptMappingState = require("./mapping/state")
local UploadSession = require("./mapping/upload-session")
local DecompilerAttemptState = require("./decompiler/attempt-state")
local PreparedScript = require("./decompiler/prepared-script")
local ScriptMappingPipeline = ScriptMappingState.new()
local ScriptMappingWorkerCount = math.max(
    1,
    math.min(math.floor(tonumber(getgenv().MCP_ScriptMappingWorkers) or 24), 64)
)
local MappingConcurrency = require("./mapping/concurrency").new(
    ScriptMappingPipeline,
    ScriptMappingWorkerCount
)
local FailedScriptResyncInterval = math.max(
    5,
    math.min(tonumber(getgenv().MCP_FailedScriptResyncInterval) or 30, 600)
)
local FailedScriptResync = require("./mapping/failed-resync").new(ScriptMappingPipeline, {
    IntervalSeconds = FailedScriptResyncInterval,
    MaxDelaySeconds = math.max(FailedScriptResyncInterval, 300),
    BatchSize = math.max(
        1,
        math.min(math.floor(tonumber(getgenv().MCP_FailedScriptResyncBatchSize) or 8), 32)
    ),
})
local MappingJobStatus = require("./mapping/job-status").new(
    ScriptMappingPipeline,
    FailedScriptResync
)
local UploadClient = require("./mapping/upload-client")({
    ScriptMappingPipeline = ScriptMappingPipeline,
    HttpService = HttpService,
    BridgeHTTPURL = BridgeHTTPURL,
    BridgeRequestHeaders = BridgeRequestHeaders,
    Request = ExecutorRequest,
    JobStatus = MappingJobStatus,
})
local DecompilerClient = require("./decompiler/client")({
    ScriptMappingPipeline = ScriptMappingPipeline,
    HttpService = HttpService,
    BridgeHTTPURL = BridgeHTTPURL,
    BridgeRequestHeaders = BridgeRequestHeaders,
    Request = ExecutorRequest,
    StripDecompilerBanner = StripDecompilerBanner,
    base64_encode = base64_encode,
    BuiltInDecompile = BuiltInDecompile,
    GetScriptHash = GetScriptHash,
    DecompilerAttemptState = DecompilerAttemptState,
    PreparedScript = PreparedScript,
    Concurrency = MappingConcurrency,
})
local MappingLifecycle = require("./mapping/lifecycle")({
    ScriptMappingPipeline = ScriptMappingPipeline,
    WorkerPool = WorkerPool,
    UploadSession = UploadSession,
    GenerateSessionGuid = GenerateSessionGuid,
    CoreGui = CoreGui,
    CorePackages = CorePackages,
    ScriptContext = ScriptContext,
    getnilinstances = getnilinstances,
    WorkerCount = ScriptMappingWorkerCount,
    Concurrency = MappingConcurrency,
    JobStatus = MappingJobStatus,
    FailedResync = FailedScriptResync,
    UploadClient = UploadClient,
    DecompilerClient = DecompilerClient,
})
local StartUploadQueue = UploadClient.StartUploadQueue
local function PublishScriptMappingStatus()
    MappingJobStatus:Publish()
end
local StartScriptMapping = MappingLifecycle.StartScriptMapping
local StartFailedScriptResync = MappingLifecycle.StartFailedScriptResync
local ResetScriptMappingState = MappingLifecycle.ResetScriptMappingState
local ResumeDeferredScriptMappings = MappingLifecycle.ResumeDeferredScriptMappings
local GetScriptByDebugId = MappingLifecycle.GetScriptByDebugId
local QueueMappedScriptSource = MappingLifecycle.QueueMappedScriptSource
local DecompileScriptSource = MappingLifecycle.DecompileScriptSource

local function WaitForBridgeClientId(Bridge)
    local deadline = os.clock() + 5
    repeat
        if Bridge.ClientId then
            return Bridge.ClientId
        end
        if not Bridge.Connected then
            return nil
        end
        task.wait(0.05)
    until os.clock() > deadline

    return nil
end

getgenv().MCP_Loaded = true
getgenv().MCP_Loading = nil
local runtimeSuccess, runtimeError = pcall(function()
    require("./bridge/runtime")({
        CreateBridge = CreateBridge,
        WaitForBridgeClientId = WaitForBridgeClientId,
        ScriptMappingPipeline = ScriptMappingPipeline,
        StartUploadQueue = StartUploadQueue,
        PublishScriptMappingStatus = PublishScriptMappingStatus,
        ResetScriptMappingState = ResetScriptMappingState,
        StartScriptMapping = StartScriptMapping,
        StartFailedScriptResync = StartFailedScriptResync,
        ResumeDeferredScriptMappings = ResumeDeferredScriptMappings,
        GetScriptByDebugId = GetScriptByDebugId,
        DecompileScriptSource = DecompileScriptSource,
        QueueMappedScriptSource = QueueMappedScriptSource,
        LogService = LogService,
        MarketplaceService = MarketplaceService,
        VirtualInputManager = VirtualInputManager,
        Players = Players,
        LuaEncode = LuaEncode,
        WebSocketAvailable = WebSocketAvailable,
        RequestAvailable = ExecutorRequest ~= nil,
        HttpRequestProvider = HttpRequestProvider,
        RuntimeHandles = RuntimeHandles,
        RuntimeValues = RuntimeValues,
        RuntimeCapabilities = RuntimeCapabilities,
        GcExplorer = GcExplorer,
        ToastHost = ToastHost,
    })
end)
if not runtimeSuccess then
    getgenv().MCP_Loaded = nil
    getgenv().MCP_Loading = nil
    error(runtimeError)
end
