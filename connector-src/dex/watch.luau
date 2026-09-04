local Watch = {}
Watch.__index = Watch

local DESCRIPTION_FIELDS = { "Handle", "Name", "ClassName", "Path", "DebugId" }
local RESPONSE_OVERHEAD = 350
local registrySerial = 0

local function Integer(value, fallback, minimum, maximum)
    local number = tonumber(value)
    if number == nil or number ~= number then number = fallback end
    return math.clamp(math.floor(number), minimum, maximum)
end

local function Short(value, limit)
    local ok, rendered = pcall(tostring, value)
    if not ok then return "unavailable" end
    local last = limit or 200
    if #rendered <= last then return rendered end
    while last > 0 do
        local byte = string.byte(rendered, last + 1)
        if byte == nil or byte < 128 or byte >= 192 then break end
        last -= 1
    end
    return string.sub(rendered, 1, last)
end

local function List(value, label, maximum, names)
    if value == nil then return {} end
    assert(type(value) == "table", label .. " must be an array.")
    local result, seen, count = {}, {}, 0
    for key, item in pairs(value) do
        count += 1
        assert(count <= maximum, label .. " exceeds " .. maximum .. " entries.")
        assert(type(key) == "number" and key >= 1 and key % 1 == 0 and key <= maximum,
            label .. " must be a dense array.")
        if names then
            assert(type(item) == "string" and #item > 0 and #item <= 128,
                label .. " entries must be nonempty names up to 128 bytes.")
        end
    end
    for index = 1, count do
        local item = value[index]
        assert(item ~= nil, label .. " must be a dense array.")
        if not seen[item] then
            seen[item] = true
            table.insert(result, item)
        end
    end
    return result
end

-- Count recursively before JSON encoding so pages also fit the bridge sanitizer.
-- The fallback byte estimate includes worst-case JSON escaping of strings.
local function Size(value, state)
    if type(value) == "string" then
        state.bytes += 2
        for index = 1, #value do
            local byte = string.byte(value, index)
            -- ASCII needs escaping only for quotes, slashes and controls.
            -- Keep a conservative allowance for non-ASCII JSON encoders.
            state.bytes += if byte == 34 or byte == 92 then 2 elseif byte < 32 or byte >= 127 then 6 else 1
        end
        return
    end
    if type(value) ~= "table" then
        state.bytes += 32
        return
    end
    if state.seen[value] then
        state.entries = 1000
        return
    end
    state.seen[value] = true
    state.bytes += 2
    for key, child in pairs(value) do
        state.entries += 1
        if state.entries > 850 then return end
        Size(key, state)
        Size(child, state)
        if state.entries > 850 then return end
        state.bytes += 2
    end
    state.seen[value] = nil
end

function Watch.new(options)
    options = options or {}
    assert(options.Inspector ~= nil and type(options.Inspector._encode) == "function", "Dex watch requires an Inspector with bounded value encoding.")
    registrySerial += 1
    local clock = options.Clock or os.clock
    -- Production injects a GUID; the process-local fallback also distinguishes
    -- standalone registries created at the same fake/test clock instant.
    local registryId = if options.NewId then options.NewId() else tostring(math.floor(clock() * 1000000)) .. "-" .. registrySerial
    assert(type(registryId) == "string" and #registryId > 0 and #registryId <= 80, "Dex watch registry ID must be 1-80 bytes.")
    return setmetatable({
        Inspector = options.Inspector,
        Clock = clock,
        registryId = registryId,
        Measure = options.Measure,
        maxWatchers = Integer(options.MaxWatchers, 8, 1, 8),
        watchers = {},
        finished = {},
        finishedOrder = {},
        serial = 0,
        destroyed = false,
    }, Watch)
end

function Watch:_describe(instance)
    local ok, description = pcall(function() return self.Inspector:Describe(instance) end)
    if not ok or type(description) ~= "table" then return { unavailable = true } end
    local result = {
        PathDisplayOnly = description.PathDisplayOnly ~= false,
        DisplayTruncated = description.DisplayTruncated,
    }
    for _, field in ipairs(DESCRIPTION_FIELDS) do
        if type(description[field]) == "string" then
            -- Inspector already bounds these fields using UTF-8-safe prefixes.
            result[field] = description[field]
        end
    end
    return result
end

function Watch:_encode(value)
    -- Inspector keeps Instance handles weak; the general codec pins them.
    local ok, encoded, partial = pcall(function() return self.Inspector:_encode(value) end)
    if ok and type(encoded) == "table" then
        if partial == true then
            encoded = table.clone(encoded)
            encoded.truncated = true
        end
        return encoded
    end
    return { type = "unavailable", error = if ok then "Invalid encoded value." else Short(encoded) }
end

function Watch:_read(instance, name, attribute)
    if attribute then
        return pcall(function() return instance:GetAttribute(name) end)
    end
    local called, ok, value, detail = pcall(function() return self.Inspector:ReadProperty(instance, name, false) end)
    if not called then return false, ok end
    return ok, if ok then value else detail
end

function Watch:_warning(watcher, kind, name, reason)
    if #watcher.warnings < 20 then
        table.insert(watcher.warnings, { kind = kind, name = name, error = Short(reason) })
    else
        watcher.warningsOmitted += 1
    end
end

function Watch:_finish(watcher, reason)
    if not watcher.active then return end
    watcher.active = false
    for _, connection in ipairs(watcher.connections) do
        pcall(function() connection:Disconnect() end)
    end
    watcher.connections = {}
    watcher.events = {}
    self.watchers[watcher.id] = nil
    self.finished[watcher.id] = {
        watcherId = watcher.id,
        active = false,
        expired = reason == "expired",
        reason = reason,
        nextCursor = watcher.latestCursor,
        latestCursor = watcher.latestCursor,
        droppedEvents = watcher.droppedEvents,
        expiresAt = watcher.expiresAt,
    }
    table.insert(self.finishedOrder, watcher.id)
    if #self.finishedOrder > 32 then self.finished[table.remove(self.finishedOrder, 1)] = nil end
end

-- The connector calls Sweep periodically as well as before each public operation.
function Watch:Sweep()
    local now, expired = self.Clock(), 0
    for _, watcher in pairs(self.watchers) do
        if now >= watcher.expiresAt then
            self:_finish(watcher, "expired")
            expired += 1
        end
    end
    return expired
end

function Watch:_push(watcher, event)
    if not watcher.active then return end
    if self.Clock() >= watcher.expiresAt then
        self:_finish(watcher, "expired")
        return
    end
    watcher.latestCursor += 1
    event.cursor = watcher.latestCursor
    event.observedAt = self.Clock()
    local index
    if watcher.count < watcher.capacity then
        index = ((watcher.head + watcher.count - 1) % watcher.capacity) + 1
        watcher.count += 1
    else
        index = watcher.head
        watcher.head = (watcher.head % watcher.capacity) + 1
        watcher.droppedEvents += 1
    end
    watcher.events[index] = event
end

function Watch:_connect(watcher, kind, name, getSignal, callback)
    local ok, connection = pcall(function()
        return getSignal():Connect(function(...)
            if not watcher.active then return end
            if self.Clock() >= watcher.expiresAt then
                self:_finish(watcher, "expired")
                return
            end
            local succeeded, reason = pcall(callback, ...)
            if not succeeded then
                self:_push(watcher, { kind = "observation-error", source = kind, name = name, error = Short(reason) })
            end
        end)
    end)
    if ok and connection ~= nil then
        table.insert(watcher.connections, connection)
        return true
    end
    self:_warning(watcher, kind, name, if ok then "Signal did not return a connection." else connection)
    return false
end

function Watch:_watchValue(watcher, instance, name, attribute)
    local kind = if attribute then "attribute" else "property"
    local ok, initial = self:_read(instance, name, attribute)
    if not ok then
        self:_warning(watcher, kind, name, initial)
        return
    end
    local previous = self:_encode(initial)
    local connected = self:_connect(watcher, kind, name, function()
        return if attribute then instance:GetAttributeChangedSignal(name) else instance:GetPropertyChangedSignal(name)
    end, function()
        local readable, value = self:_read(instance, name, attribute)
        local encoded = if readable then self:_encode(value) else { type = "unavailable", error = Short(value) }
        self:_push(watcher, {
            kind = kind,
            name = name,
            target = self:_describe(instance),
            oldValue = previous,
            newValue = encoded,
        })
        previous = encoded
    end)
    if connected then
        local field = if attribute then "observedAttributeCount" else "observedPropertyCount"
        watcher[field] += 1
    end
end

function Watch:Start(data)
    assert(not self.destroyed, "Dex watcher has been destroyed.")
    data = data or {}
    self:Sweep()
    local targets = List(data.targets, "targets", 10, false)
    local properties = List(data.properties, "properties", 20, true)
    local attributes = List(data.attributes, "attributes", 20, true)
    assert(#targets > 0, "At least one watch target is required.")
    assert(#properties + #attributes > 0 or data.includeChildren == true or data.includeAncestry == true,
        "Select properties, attributes, children, or ancestry to watch.")
    local count = 0
    for _ in pairs(self.watchers) do count += 1 end
    assert(count < self.maxWatchers, "Dex watcher limit reached; stop an existing watcher first.")

    -- Resolve every target before connecting anything, so a bad target cannot leak subscriptions.
    local instances, seen = {}, {}
    for _, target in ipairs(targets) do
        local instance = self.Inspector:Resolve(target)
        assert(instance ~= nil, "Watch target was not found.")
        if not seen[instance] then
            seen[instance] = true
            table.insert(instances, instance)
        end
    end
    self.serial += 1
    local watcher = {
        id = "dex-watch-" .. self.registryId .. "-" .. self.serial,
        active = true,
        capacity = Integer(data.maxEvents, 200, 1, 500),
        expiresAt = self.Clock() + Integer(data.ttlSeconds, 300, 1, 3600),
        connections = {}, events = {}, head = 1, count = 0, latestCursor = 0, droppedEvents = 0,
        warnings = {}, warningsOmitted = 0, observedPropertyCount = 0, observedAttributeCount = 0,
    }
    self.watchers[watcher.id] = watcher
    local descriptions = {}
    local ok, reason = pcall(function()
        for _, instance in ipairs(instances) do
            table.insert(descriptions, self:_describe(instance))
            for _, name in ipairs(properties) do self:_watchValue(watcher, instance, name, false) end
            for _, name in ipairs(attributes) do self:_watchValue(watcher, instance, name, true) end
            if data.includeChildren == true then
                for _, kind in ipairs({ "child-added", "child-removed" }) do
                    self:_connect(watcher, kind, nil, function()
                        return if kind == "child-added" then instance.ChildAdded else instance.ChildRemoved
                    end, function(child)
                        self:_push(watcher, {
                            kind = kind,
                            target = self:_describe(instance),
                            oldValue = self:_encode(if kind == "child-removed" then child else nil),
                            newValue = self:_encode(if kind == "child-added" then child else nil),
                        })
                    end)
                end
            end
            if data.includeAncestry == true then
                local readable, parent = self:_read(instance, "Parent", false)
                local previous = if readable then self:_encode(parent) else { type = "unavailable" }
                local previousPath = self:_describe(instance).Path
                self:_connect(watcher, "ancestry", nil, function() return instance.AncestryChanged end,
                    function(changed, changedParent)
                        local nowReadable, nowParent = self:_read(instance, "Parent", false)
                        local encoded = if nowReadable then self:_encode(nowParent) else { type = "unavailable" }
                        local target = self:_describe(instance)
                        self:_push(watcher, {
                            kind = "ancestry", target = target, changedInstance = self:_describe(changed),
                            changedParent = self:_encode(changedParent),
                            oldValue = previous, newValue = encoded, oldPath = previousPath, newPath = target.Path,
                        })
                        previous, previousPath = encoded, target.Path
                    end)
            end
        end
        assert(#watcher.connections > 0, "No requested watch signals were available.")
    end)
    if not ok then
        self:_finish(watcher, "start-failed")
        error(reason)
    end
    local result = {
        watcherId = watcher.id, active = true, nextCursor = 0, expiresAt = watcher.expiresAt,
        maxEvents = watcher.capacity, targets = descriptions, connectionCount = #watcher.connections,
        observedPropertyCount = watcher.observedPropertyCount, observedAttributeCount = watcher.observedAttributeCount,
        warnings = table.clone(watcher.warnings), warningsOmitted = watcher.warningsOmitted,
        targetDetailsOmitted = 0, targetsOmitted = 0,
    }
    local maxChars = Integer(data.maxChars, 20000, 2000, 60000)
    -- Trim response-only metadata, never the observations or retained warnings.
    -- Prefer keeping exact handles so omitted descriptions can be inspected later.
    for index = #result.targets, 1, -1 do
        if self:_fits(result, maxChars) then break end
        result.targets[index] = { Handle = result.targets[index].Handle, omitted = true }
        result.targetDetailsOmitted += 1
    end
    while #result.warnings > 0 and not self:_fits(result, maxChars) do
        table.remove(result.warnings)
        result.warningsOmitted += 1
    end
    while #result.targets > 0 and not self:_fits(result, maxChars) do
        table.remove(result.targets)
        result.targetsOmitted += 1
    end
    if not self:_fits(result, maxChars) then
        self:_finish(watcher, "start-failed")
        error("Watch startup metadata cannot fit the requested output budget.")
    end
    return result
end

function Watch:_fits(value, maxChars)
    maxChars = math.max(0, maxChars - RESPONSE_OVERHEAD)
    local state = { entries = 0, bytes = 0, seen = {} }
    Size(value, state)
    if state.entries > 850 then return false end
    if self.Measure then
        local ok, bytes = pcall(self.Measure, value)
        if ok and type(bytes) == "number" and bytes >= 0 and bytes < math.huge then return bytes <= maxChars end
    end
    return state.bytes <= maxChars
end

function Watch:Poll(data)
    data = data or {}
    self:Sweep()
    local watcher = self.watchers[data.watcherId]
    if not watcher then
        local finished = self.finished[data.watcherId]
        assert(finished ~= nil, "Unknown Dex watcher; start a new watcher.")
        local result = table.clone(finished)
        result.events, result.hasMore = {}, false
        return result
    end
    local cursor = Integer(data.cursor, 0, 0, 9007199254740991)
    assert(cursor <= watcher.latestCursor, "Watch cursor is newer than the latest event.")
    local limit = Integer(data.limit, 100, 1, 100)
    local maxChars = Integer(data.maxChars, 20000, 2000, 60000)
    local earliest = watcher.latestCursor - watcher.count + 1
    local gap = math.max(0, earliest - 1 - cursor)
    local result = {
        watcherId = watcher.id, active = true, expired = false, expiresAt = watcher.expiresAt,
        events = {}, nextCursor = math.max(cursor, earliest - 1), latestCursor = watcher.latestCursor,
        earliestAvailableCursor = earliest, droppedEvents = watcher.droppedEvents,
        gapEvents = gap, cursorExpired = gap > 0, hasMore = false,
    }
    for offset = 1, watcher.count do
        local event = watcher.events[((watcher.head + offset - 2) % watcher.capacity) + 1]
        if event.cursor <= cursor then continue end
        if #result.events >= limit then break end
        local priorCursor = result.nextCursor
        table.insert(result.events, event)
        result.nextCursor = event.cursor
        result.hasMore = event.cursor < watcher.latestCursor
        if not self:_fits(result, maxChars) then
            table.remove(result.events)
            result.nextCursor = priorCursor
            if #result.events > 0 then break end
            -- An event larger than a page must not permanently block the cursor.
            table.insert(result.events, { cursor = event.cursor, kind = event.kind, omitted = true, reason = "output-budget" })
            result.nextCursor = event.cursor
        end
    end
    result.hasMore = result.nextCursor < watcher.latestCursor
    return result
end

function Watch:Stop(data)
    data = data or {}
    self:Sweep()
    local watcher = self.watchers[data.watcherId]
    if watcher then self:_finish(watcher, "stopped") end
    local finished = self.finished[data.watcherId]
    assert(finished ~= nil, "Unknown Dex watcher.")
    return table.clone(finished)
end

function Watch:Destroy()
    self.destroyed = true
    for _, watcher in pairs(self.watchers) do self:_finish(watcher, "destroyed") end
end

return Watch
