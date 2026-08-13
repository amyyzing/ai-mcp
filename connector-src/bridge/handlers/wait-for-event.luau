local InstancePath = require("../instance-path")
local InternalRemoteSpy = require("./remote-spy/internal-spy")

local JOURNAL_KEY = "__ROBLOX_MCP_EVENT_JOURNAL_V2"
local LEGACY_JOURNAL_KEY = "__ROBLOX_MCP_EVENT_JOURNAL_V1"
local MAX_EVENTS = 500
local MAX_EXISTING_INSTANCE_SCAN = 5000
local MAX_CONSOLE_MESSAGE_CHARS = 2000
local MAX_SELECTOR_MATCHES = 1000
local MAX_SELECTOR_SCANS = 5
local MAX_SELECTOR_WAITS = 1
local MAX_SELECTOR_PENDING = 2000
local MAX_REMOTE_LOGS_SCANNED = 5000
local MAX_REMOTE_WAITS = 2

return function(context, Bridge)
local LogService = context.LogService
    local activeSelectorWaits = 0
    local activeRemoteWaits = 0

    local environment = getgenv()
    local journal = environment[JOURNAL_KEY]
    if type(journal) ~= "table" or journal.version ~= 2 then
        if type(journal) == "table" and type(journal.connections) == "table" then
            for _, connection in journal.connections do pcall(function() connection:Disconnect() end) end
        end
        journal = {
            version = 2,
            nextCursor = 0,
            events = {},
            head = 1,
            count = 0,
            connections = {},
        }
        environment[JOURNAL_KEY] = journal
    end
    local legacyJournal = environment[LEGACY_JOURNAL_KEY]
    if type(legacyJournal) == "table" and type(legacyJournal.connections) == "table" then
        for _, connection in legacyJournal.connections do
            pcall(function() connection:Disconnect() end)
        end
    end
    environment[LEGACY_JOURNAL_KEY] = nil

    local function Push(kind, event)
        journal.nextCursor += 1
        event.kind = kind
        event.cursor = journal.nextCursor
        event.observedAt = os.clock()
        local index
        if journal.count < MAX_EVENTS then
            index = ((journal.head + journal.count - 1) % MAX_EVENTS) + 1
            journal.count += 1
        else
            index = journal.head
            journal.head = (journal.head % MAX_EVENTS) + 1
        end
        journal.events[index] = event
        return event
    end

    local function JournalEventAt(offset)
        if offset < 1 or offset > journal.count then return nil end
        local index = ((journal.head + offset - 2) % MAX_EVENTS) + 1
        return journal.events[index]
    end

    local function EarliestEvent()
        return JournalEventAt(1)
    end

    local function EnsureConsoleJournal()
        if journal.connections.console then return end
        local ok, connection = pcall(function()
            return LogService.MessageOut:Connect(function(message, messageType)
                message = tostring(message)
                if #message > MAX_CONSOLE_MESSAGE_CHARS then
                    message = string.sub(message, 1, MAX_CONSOLE_MESSAGE_CHARS) .. "...(truncated)"
                end
                Push("console", {
                    message = message,
                    level = messageType and messageType.Name or tostring(messageType or "Unknown"),
                })
            end)
        end)
        if ok then journal.connections.console = connection end
    end

    local function MinimalInstanceDescription(instance)
        local ok, description = pcall(InstancePath.Describe, instance)
        if not ok then return nil end
        return {
            Name = description.Name,
            ClassName = description.ClassName,
            Path = description.Path,
            DebugId = description.DebugId,
        }
    end

    local function EnsureInstanceJournal()
        if journal.connections.instance then return end
        journal.connections.instance = game.DescendantAdded:Connect(function(instance)
            local description = MinimalInstanceDescription(instance)
            if not description then return end
            Push("instance", description)
        end)
    end

    local function Contains(value, query, caseSensitive)
        if type(query) ~= "string" or query == "" then return true end
        value = tostring(value or "")
        if not caseSensitive then
            value = string.lower(value)
            query = string.lower(query)
        end
        return string.find(value, query, 1, true) ~= nil
    end

    local function MatchesConsole(event, data)
        if event.kind ~= "console" then return false end
        if data.level and string.lower(tostring(event.level)) ~= string.lower(data.level) then return false end
        return Contains(event.message, data.contains, data.caseSensitive == true)
    end

    local function MatchesInstance(event, data, rootPath)
        if event.kind ~= "instance" then return false end
        if data.name and event.Name ~= data.name then return false end
        if data.className and event.ClassName ~= data.className then return false end
        if not Contains(event.Path, data.pathContains, false) then return false end
        if rootPath then
            local eventPath = event.Path or ""
            if eventPath ~= rootPath then
                if string.sub(eventPath, 1, #rootPath) ~= rootPath then return false end
                local boundary = string.sub(eventPath, #rootPath + 1, #rootPath + 1)
                if boundary ~= "." and boundary ~= "[" then return false end
            end
        end
        return true
    end

    local function CursorExpired(cursor)
        local first = EarliestEvent()
        return first ~= nil and cursor < first.cursor - 1
    end

    local function WaitForJournal(data, matcher)
        local timeoutSeconds = math.max(0.1, math.min((tonumber(data.timeoutMs) or 5000) / 1000, 30))
        local startCursor = tonumber(data.cursor)
        if startCursor == nil then startCursor = journal.nextCursor end
        startCursor = math.max(0, math.floor(startCursor))
        local expired = CursorExpired(startCursor)
        local deadline = os.clock() + timeoutSeconds

        repeat
            for offset = 1, journal.count do
                local event = JournalEventAt(offset)
                if event.cursor > startCursor and matcher(event) then
                    return {
                        matched = true,
                        cursor = event.cursor,
                        event = event,
                        cursorExpired = expired,
                    }
                end
            end
            task.wait(0.05)
        until os.clock() >= deadline

        return {
            matched = false,
            timedOut = true,
            cursor = journal.nextCursor,
            cursorExpired = expired,
            earliestAvailableCursor = EarliestEvent() and EarliestEvent().cursor or journal.nextCursor,
        }
    end

    local function ExistingConsole(data)
        local ok, logs = pcall(function() return LogService:GetLogHistory() end)
        if not ok then return nil end
        local minimum = math.max(1, #logs - MAX_EVENTS + 1)
        for index = #logs, minimum, -1 do
            local log = logs[index]
            local event = {
                kind = "console",
                cursor = journal.nextCursor,
                message = string.sub(tostring(log.message or ""), 1, MAX_CONSOLE_MESSAGE_CHARS),
                level = log.messageType and log.messageType.Name or "Unknown",
                timestamp = log.timestamp,
                existing = true,
            }
            if MatchesConsole(event, data) then return event end
        end
        return nil
    end

    local function DescriptionMatches(description, data)
        return MatchesInstance({
            kind = "instance",
            Name = description.Name,
            ClassName = description.ClassName,
            Path = description.Path,
        }, data)
    end

    local function QuerySelector(root, selector)
        local instances = root:QueryDescendants(selector)
        assert(
            #instances <= MAX_SELECTOR_MATCHES,
            "Selector matched over " .. tostring(MAX_SELECTOR_MATCHES) .. " instances; narrow the selector/root."
        )
        return instances
    end

    local function ExistingInstance(data, root)
        if data.selector then
            local instances = QuerySelector(root, data.selector)
            for _, instance in ipairs(instances) do
                local description = InstancePath.Describe(instance)
                if DescriptionMatches(description, data) then return description end
            end
            return nil
        end

        local queue = { root }
        local head = 1
        local scanned = 0
        while head <= #queue and scanned < MAX_EXISTING_INSTANCE_SCAN do
            local instance = queue[head]
            head += 1
            scanned += 1
            local description = InstancePath.Describe(instance)
            if DescriptionMatches(description, data) then return description end
            for _, child in ipairs(instance:GetChildren()) do
                if #queue >= MAX_EXISTING_INSTANCE_SCAN then break end
                table.insert(queue, child)
            end
        end
        return nil
    end

    local function WaitForSelector(data, root)
        assert(activeSelectorWaits < MAX_SELECTOR_WAITS, "Too many selector waits are already active.")
        activeSelectorWaits += 1
        local connection
        local success, result = pcall(function()
            local pendingInstances = {}
            local pendingCount = 0
            local pendingOverflow = false
            local selectorDirty = false
            connection = root.DescendantAdded:Connect(function(instance)
                if pendingInstances[instance] then return end
                if pendingCount >= MAX_SELECTOR_PENDING then
                    pendingOverflow = true
                    return
                end
                pendingInstances[instance] = true
                pendingCount += 1
                selectorDirty = true
            end)

            if data.includeExisting == true then
                for _, instance in ipairs(QuerySelector(root, data.selector)) do
                    local description = InstancePath.Describe(instance)
                    if DescriptionMatches(description, data) then
                        description.kind = "instance"
                        description.existing = true
                        return { matched = true, cursor = journal.nextCursor, event = description }
                    end
                end
            end

            local timeoutSeconds = math.max(0.1, math.min((tonumber(data.timeoutMs) or 5000) / 1000, 30))
            local deadline = os.clock() + timeoutSeconds
            local selectorScans = 0
            repeat
                if selectorDirty and selectorScans < MAX_SELECTOR_SCANS then
                    assert(not pendingOverflow, "Too many descendants were added while waiting; narrow the selector/root.")
                    selectorDirty = false
                    selectorScans += 1
                    local candidates = pendingInstances
                    pendingInstances = {}
                    pendingCount = 0
                    for _, instance in ipairs(QuerySelector(root, data.selector)) do
                        if candidates[instance] then
                            local description = InstancePath.Describe(instance)
                            if DescriptionMatches(description, data) then
                                local event = Push("instance", description)
                                return {
                                    matched = true,
                                    cursor = event.cursor,
                                    event = event,
                                    selectorScans = selectorScans,
                                }
                            end
                        end
                    end
                end
                task.wait(0.05)
            until os.clock() >= deadline
            return {
                matched = false,
                timedOut = true,
                cursor = journal.nextCursor,
                selectorScans = selectorScans,
                selectorScanLimitReached = selectorScans >= MAX_SELECTOR_SCANS,
            }
        end)
        if connection then connection:Disconnect() end
        activeSelectorWaits -= 1
        if not success then error(result) end
        return result
    end

    local function AttributeMatches(condition, value, expected)
        if condition == "exists" then return value ~= nil end
        if condition == "equals" then return value == expected end
        return true
    end

    local function WaitForAttribute(data)
        local target = InstancePath.Resolve(data.target)
        local attribute = data.attribute
        local condition = data.condition or "changed"
        if condition == "equals" then assert(data.equals ~= nil, "equals value is required.") end
        local current = target:GetAttribute(attribute)
        if data.includeExisting == true and condition ~= "changed" and AttributeMatches(condition, current, data.equals) then
            return {
                matched = true,
                cursor = journal.nextCursor,
                event = {
                    kind = "attribute",
                    target = InstancePath.Describe(target),
                    attribute = attribute,
                    value = current,
                    existing = true,
                },
            }
        end

        local matchedEvent
        local connection = target:GetAttributeChangedSignal(attribute):Connect(function()
            local value = target:GetAttribute(attribute)
            if not AttributeMatches(condition, value, data.equals) then return end
            matchedEvent = Push("attribute", {
                target = InstancePath.Describe(target),
                attribute = attribute,
                value = value,
            })
        end)
        local timeoutSeconds = math.max(0.1, math.min((tonumber(data.timeoutMs) or 5000) / 1000, 30))
        local deadline = os.clock() + timeoutSeconds
        repeat task.wait(0.05) until matchedEvent or os.clock() >= deadline
        connection:Disconnect()

        if matchedEvent then
            return { matched = true, cursor = matchedEvent.cursor, event = matchedEvent }
        end
        return { matched = false, timedOut = true, cursor = journal.nextCursor }
    end

    local function RemoteDirections(direction)
        if direction == "Incoming" then return { "Incoming" } end
        if direction == "Outgoing" then return { "Outgoing" } end
        return { "Outgoing", "Incoming" }
    end

    local function RemoteEvent(instance, log, direction, existing)
        return {
            kind = "remote",
            direction = direction,
            remote = InstancePath.Describe(instance),
            method = log.Method,
            totalCalls = tonumber(log.TotalCalls) or (type(log.Calls) == "table" and #log.Calls or 0),
            existing = existing or nil,
        }
    end

    local function WaitForRemote(data)
        assert(activeRemoteWaits < MAX_REMOTE_WAITS, "Too many remote waits are already active.")
        activeRemoteWaits += 1
        local ok, result = pcall(function()
        local Cobalt = InternalRemoteSpy.Start()
        assert(Cobalt and Cobalt.shared and Cobalt.shared.Logs, "Bundled remote spy could not be started.")
        local baseline = { Incoming = {}, Outgoing = {} }
        local directions = RemoteDirections(data.direction)
        local baselineScanned = 0

        for _, direction in ipairs(directions) do
            local logs = Cobalt.shared.Logs[direction]
            if type(logs) == "table" then
                for instance, log in pairs(logs) do
                    baselineScanned += 1
                    assert(baselineScanned <= MAX_REMOTE_LOGS_SCANNED, "Remote spy has too many captured remotes; narrow nameContains/direction or clear logs.")
                    if typeof(instance) ~= "Instance" then continue end
                    if not Contains(instance.Name, data.nameContains, false) then continue end
                    local count = tonumber(log.TotalCalls) or (type(log.Calls) == "table" and #log.Calls or 0)
                    baseline[direction][instance] = count
                    if data.includeExisting == true and count > 0 then
                        local event = RemoteEvent(instance, log, direction, true)
                        event.cursor = journal.nextCursor
                        return { matched = true, cursor = event.cursor, event = event }
                    end
                end
            end
        end

        local timeoutSeconds = math.max(0.1, math.min((tonumber(data.timeoutMs) or 5000) / 1000, 30))
        local deadline = os.clock() + timeoutSeconds
        repeat
            local scanned = 0
            for _, direction in ipairs(directions) do
                local logs = Cobalt.shared.Logs[direction]
                if type(logs) ~= "table" then continue end
                for instance, log in pairs(logs) do
                    scanned += 1
                    assert(scanned <= MAX_REMOTE_LOGS_SCANNED, "Remote spy has too many captured remotes; narrow nameContains/direction or clear logs.")
                    if typeof(instance) ~= "Instance" then continue end
                    if not Contains(instance.Name, data.nameContains, false) then continue end
                    local count = tonumber(log.TotalCalls) or (type(log.Calls) == "table" and #log.Calls or 0)
                    if count > (baseline[direction][instance] or 0) then
                        local event = Push("remote", RemoteEvent(instance, log, direction, false))
                        return { matched = true, cursor = event.cursor, event = event }
                    end
                    baseline[direction][instance] = count
                end
            end
            task.wait(0.1)
        until os.clock() >= deadline
        return { matched = false, timedOut = true, cursor = journal.nextCursor }
        end)
        activeRemoteWaits -= 1
        if not ok then error(result) end
        return result
    end

    Bridge:BindToTypeStructured("wait-for-event", function(data)
        if data.mode == "console" then
            EnsureConsoleJournal()
            if data.includeExisting == true then
                local existing = ExistingConsole(data)
                if existing then return { matched = true, cursor = existing.cursor, event = existing } end
            end
            return WaitForJournal(data, function(event) return MatchesConsole(event, data) end)
        elseif data.mode == "instance" then
            local root = data.root and InstancePath.Resolve(data.root) or game
            if data.selector then return WaitForSelector(data, root) end
            EnsureInstanceJournal()
            if data.includeExisting == true then
                local existing = ExistingInstance(data, root)
                if existing then
                    existing.kind = "instance"
                    existing.existing = true
                    return { matched = true, cursor = journal.nextCursor, event = existing }
                end
            end
            local rootPath = root == game and nil or InstancePath.StablePath(root)
            return WaitForJournal(data, function(event) return MatchesInstance(event, data, rootPath) end)
        elseif data.mode == "attribute" then
            return WaitForAttribute(data)
        elseif data.mode == "remote" then
            return WaitForRemote(data)
        end
        error("Unsupported wait mode: " .. tostring(data.mode))
    end)
end
