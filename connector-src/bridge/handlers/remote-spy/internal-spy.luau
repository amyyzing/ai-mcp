local InternalSpy = {}

local MAX_REMOTES_PER_DIRECTION = 128
local MAX_CALLS_PER_REMOTE = 25
local MAX_ARGUMENTS_PER_CALL = 20
local MAX_SNAPSHOT_ENTRIES = 100
local MAX_SNAPSHOT_DEPTH = 3
local MAX_STRING_BYTES = 1000
local MAX_SNAPSHOT_STRING_BYTES = 8 * 1024
local MAX_INCOMING_CONNECTIONS = 512
local MAX_INITIAL_SCAN_NODES = 20000

local function TruncateUtf8(value, maxBytes)
    if #value <= maxBytes then return value end
    if maxBytes <= 0 then return "" end
    local suffix = "...(truncated)"
    if maxBytes <= #suffix then return string.sub(suffix, 1, maxBytes) end
    local contentBytes = maxBytes - #suffix
    local ok, boundary = pcall(utf8.offset, value, 0, contentBytes + 1)
    if not ok then return string.sub("<invalid UTF-8 string>", 1, maxBytes) end
    return string.sub(value, 1, (boundary or (contentBytes + 1)) - 1) .. suffix
end

local function SnapshotValue(value, budget, depth, seen)
    if budget.entries >= MAX_SNAPSHOT_ENTRIES then return "<snapshot entry limit>" end

    local valueType = typeof(value)
    if valueType == "nil" then return { Type = "nil" } end
    if valueType == "string" then
        local available = math.max(0, MAX_SNAPSHOT_STRING_BYTES - budget.stringBytes)
        if available == 0 then return "<snapshot string limit>" end
        local result = TruncateUtf8(value, math.min(MAX_STRING_BYTES, available))
        budget.stringBytes += #result
        return result
    end
    if valueType == "boolean" or valueType == "number" or valueType == "Instance" then return value end
    if valueType ~= "table" then return tostring(value) end
    if depth >= MAX_SNAPSHOT_DEPTH then return "<snapshot depth limit>" end
    if seen[value] then return "<cycle>" end

    seen[value] = true
    local copy = {}
    for key, child in pairs(value) do
        if budget.entries >= MAX_SNAPSHOT_ENTRIES then break end
        budget.entries += 1
        local keyType = typeof(key)
        local safeKey = key
        if keyType == "string" then
            safeKey = SnapshotValue(key, budget, depth + 1, seen)
        elseif keyType ~= "number" then
            safeKey = SnapshotValue(tostring(key), budget, depth + 1, seen)
        end
        copy[safeKey] = SnapshotValue(child, budget, depth + 1, seen)
    end
    seen[value] = nil
    return copy
end

local function SnapshotArguments(...)
    local supplied = select("#", ...)
    local retained = math.min(supplied, MAX_ARGUMENTS_PER_CALL)
    local result = {}
    local budget = { entries = 0, stringBytes = 0 }
    local seen = {}
    for index = 1, retained do
        result[index] = SnapshotValue(select(index, ...), budget, 0, seen)
    end
    return result, supplied, supplied > retained
end

local function CountEntries(value)
    local count = 0
    for _ in pairs(value) do count += 1 end
    return count
end

local function NewLog(method, canBlock)
    local log = {
        Method = method,
        Calls = {},
        TotalCalls = 0,
        Ignored = false,
        Blocked = false,
        SupportsBlock = canBlock,
    }

    function log:Block()
        assert(self.SupportsBlock, "Incoming calls cannot be blocked by the bundled passive listener.")
        self.Blocked = not self.Blocked
    end

    function log:Ignore()
        self.Ignored = not self.Ignored
    end

    return log
end

function InternalSpy.Start()
    local environment = getgenv()
    local existing = environment.Cobalt
    if existing and existing.shared and existing.shared.Logs then
        return existing, false
    end

    local state = {
        Logs = {
            Outgoing = setmetatable({}, { __mode = "k" }),
            Incoming = setmetatable({}, { __mode = "k" }),
        },
        connections = setmetatable({}, { __mode = "k" }),
        connectionCount = 0,
        initialScanRunning = false,
        initialScanTruncated = false,
        capabilities = {
            outgoingNamecall = false,
            incomingEventSignals = false,
            incomingFunctions = false,
            incomingBlocking = false,
        },
    }

    local cobalt = {
        __RobloxMcpInternal = true,
        version = 1,
        shared = {},
    }

    local function ClearLogs()
        state.Logs = {
            Outgoing = setmetatable({}, { __mode = "k" }),
            Incoming = setmetatable({}, { __mode = "k" }),
        }
        cobalt.shared.Logs = state.Logs
    end

    local function GetOrCreateLog(direction, instance, method, canBlock)
        local logs = state.Logs[direction]
        local log = logs[instance]
        if log then return log end
        if CountEntries(logs) >= MAX_REMOTES_PER_DIRECTION then return nil end
        log = NewLog(method, canBlock)
        logs[instance] = log
        return log
    end

    local function Record(direction, instance, method, canBlock, ...)
        local log = GetOrCreateLog(direction, instance, method, canBlock)
        if not log or log.Ignored then return log end

        local arguments, argumentCount, argumentsTruncated = SnapshotArguments(...)
        local isExecutor = false
        if type(checkcaller) == "function" then
            local ok, value = pcall(checkcaller)
            isExecutor = ok and value == true
        end
        table.insert(log.Calls, {
            Arguments = arguments,
            ArgumentCount = argumentCount,
            ArgumentsTruncated = argumentsTruncated or nil,
            IsExecutor = isExecutor,
            CapturedAt = os.clock(),
        })
        log.TotalCalls += 1
        if #log.Calls > MAX_CALLS_PER_REMOTE then table.remove(log.Calls, 1) end
        return log
    end

    local function AttachIncoming(instance)
        if state.connections[instance] or state.connectionCount >= MAX_INCOMING_CONNECTIONS then return end

        local signal
        local method
        local className = instance.ClassName
        if className == "RemoteEvent" or className == "UnreliableRemoteEvent" then
            signal = instance.OnClientEvent
            method = "OnClientEvent"
        elseif className == "BindableEvent" then
            signal = instance.Event
            method = "Event"
        else
            return
        end

        local ok, connection = pcall(function()
            return signal:Connect(function(...)
                pcall(Record, "Incoming", instance, method, false, ...)
            end)
        end)
        if ok and connection then
            state.connections[instance] = connection
            state.connectionCount += 1
        end
    end

    local outgoingMethods = {
        FireServer = true,
        InvokeServer = true,
        Fire = true,
        Invoke = true,
    }

    if type(hookmetamethod) == "function" and type(getnamecallmethod) == "function" then
        local originalNamecall
        local function NamecallHook(instance, ...)
            local methodOk, method = pcall(getnamecallmethod)
            if methodOk and typeof(instance) == "Instance" and outgoingMethods[method] then
                local recordOk, log = pcall(Record, "Outgoing", instance, method, true, ...)
                if recordOk and log and log.Blocked then return nil end
            end
            return originalNamecall(instance, ...)
        end
        local wrapped = NamecallHook
        if type(newcclosure) == "function" then
            local wrapOk, wrappedResult = pcall(newcclosure, NamecallHook)
            if wrapOk and type(wrappedResult) == "function" then wrapped = wrappedResult end
        end
        local ok, original = pcall(hookmetamethod, game, "__namecall", wrapped)
        if ok and type(original) == "function" then
            originalNamecall = original
            state.capabilities.outgoingNamecall = true
        else
            state.capabilities.outgoingError = "hookmetamethod failed"
        end
    else
        state.capabilities.outgoingError = "executor lacks hookmetamethod/getnamecallmethod"
    end

    cobalt.shared.Logs = state.Logs
    cobalt.shared.ClearLogs = ClearLogs
    cobalt.shared.McpInternal = {
        capabilities = state.capabilities,
        limits = {
            remotesPerDirection = MAX_REMOTES_PER_DIRECTION,
            callsPerRemote = MAX_CALLS_PER_REMOTE,
            argumentsPerCall = MAX_ARGUMENTS_PER_CALL,
            snapshotEntriesPerCall = MAX_SNAPSHOT_ENTRIES,
            snapshotStringBytesPerCall = MAX_SNAPSHOT_STRING_BYTES,
            incomingConnections = MAX_INCOMING_CONNECTIONS,
            initialScanNodes = MAX_INITIAL_SCAN_NODES,
        },
        state = state,
    }
    environment.Cobalt = cobalt

    local descendantOk, descendantConnection = pcall(function()
        return game.DescendantAdded:Connect(AttachIncoming)
    end)
    if descendantOk and descendantConnection then
        state.descendantConnection = descendantConnection
        state.capabilities.incomingEventSignals = true
    else
        state.capabilities.incomingError = "could not observe new descendants"
    end
    state.initialScanRunning = true
    task.spawn(function()
        local ok, scanError = pcall(function()
            local queue = { game }
            local head = 1
            local visited = 0
            while head <= #queue and visited < MAX_INITIAL_SCAN_NODES do
                local current = queue[head]
                head += 1
                visited += 1
                AttachIncoming(current)
                local childrenOk, children = pcall(function() return current:GetChildren() end)
                if childrenOk then
                    for _, child in ipairs(children) do
                        if #queue >= MAX_INITIAL_SCAN_NODES then
                            state.initialScanTruncated = true
                            break
                        end
                        table.insert(queue, child)
                    end
                end
                if visited % 250 == 0 then task.wait() end
            end
            state.initialScanTruncated = state.initialScanTruncated or head <= #queue
        end)
        if not ok then
            state.initialScanError = TruncateUtf8(tostring(scanError), 500)
        end
        state.initialScanRunning = false
    end)

    return cobalt, true
end

return InternalSpy
