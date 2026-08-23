local HandleRegistry = {}
HandleRegistry.__index = HandleRegistry

local function ClampInteger(value, fallback, minimum, maximum)
    local parsed = tonumber(value)
    if parsed == nil or parsed ~= parsed then parsed = fallback end
    return math.max(minimum, math.min(maximum, math.floor(parsed)))
end

local function Classify(value)
    local valueType = typeof(value)
    if valueType == "table" or valueType == "function" or valueType == "thread" then
        return valueType
    end
    if valueType == "Instance" then return "instance" end
    if valueType == "RBXScriptConnection" then return "connection" end
    if valueType == "RBXScriptSignal" then return "signal" end
    if valueType == "userdata" then return "userdata" end
    return string.lower(valueType)
end

function HandleRegistry.new(options)
    options = options or {}
    local registryId = tostring(options.RegistryId or "runtime")
    registryId = string.gsub(registryId, "[^%w]", "")
    if registryId == "" then registryId = "runtime" end

    return setmetatable({
        registryId = string.sub(registryId, 1, 16),
        generation = 1,
        nextId = 0,
        entries = {},
        activeCount = 0,
        order = {},
        orderCursor = 1,
        reverse = setmetatable({}, { __mode = "k" }),
        weakValues = setmetatable({}, { __mode = "v" }),
        strongValues = {},
        maxHandles = ClampInteger(options.MaxHandles, 50000, 100, 200000),
        defaultTtlSeconds = ClampInteger(options.DefaultTtlSeconds, 1800, 30, 7200),
        clock = options.Clock or os.clock,
        created = 0,
        released = 0,
        expired = 0,
        evicted = 0,
        collected = 0,
        lastSweepAt = -math.huge,
        sweepIntervalSeconds = 1,
    }, HandleRegistry)
end

function HandleRegistry:_now()
    return self.clock()
end

function HandleRegistry:_remove(handle, reason)
    local entry = self.entries[handle]
    if entry == nil then return false end
    self.entries[handle] = nil
    self.activeCount = math.max(0, self.activeCount - 1)
    local value = self.strongValues[handle] or self.weakValues[handle]
    self.strongValues[handle] = nil
    self.weakValues[handle] = nil
    if value ~= nil and self.reverse[value] == handle then
        self.reverse[value] = nil
    end
    if reason == "released" then self.released += 1 end
    if reason == "expired" then self.expired += 1 end
    if reason == "evicted" then self.evicted += 1 end
    if reason == "collected" then self.collected += 1 end
    return true
end

function HandleRegistry:Sweep(force)
    local now = self:_now()
    if force ~= true and now - self.lastSweepAt < self.sweepIntervalSeconds then return 0 end
    self.lastSweepAt = now
    local removed = 0
    for handle, entry in self.entries do
        if self.strongValues[handle] == nil and self.weakValues[handle] == nil then
            if self:_remove(handle, "collected") then removed += 1 end
        elseif entry.expiresAt <= now then
            if self:_remove(handle, "expired") then removed += 1 end
        end
    end
    if #self.order > self.maxHandles * 2 and #self.order > self.activeCount * 2 then
        local compact = {}
        for index = self.orderCursor, #self.order do
            local handle = self.order[index]
            if self.entries[handle] ~= nil then table.insert(compact, handle) end
        end
        self.order = compact
        self.orderCursor = 1
    end
    return removed
end

function HandleRegistry:_count()
    return self.activeCount
end

function HandleRegistry:_evictOldest()
    while self.orderCursor <= #self.order do
        local handle = self.order[self.orderCursor]
        self.orderCursor += 1
        if self.entries[handle] ~= nil then
            self:_remove(handle, "evicted")
            return true
        end
    end
    return false
end

function HandleRegistry:Register(value, kind, metadata, ttlSeconds, pinValue)
    assert(value ~= nil, "Cannot create a runtime handle for nil.")
    self:Sweep()

    local existingHandle = self.reverse[value]
    local existing = existingHandle and self.entries[existingHandle] or nil
    if existing then
        local now = self:_now()
        existing.lastAccess = now
        existing.expiresAt = now + ClampInteger(ttlSeconds, self.defaultTtlSeconds, 30, 7200)
        if metadata ~= nil then existing.metadata = metadata end
        if pinValue ~= false then
            self.strongValues[existingHandle] = value
            existing.pinned = true
        end
        return existingHandle, existing
    end

    while self:_count() >= self.maxHandles do
        assert(self:_evictOldest(), "Runtime handle registry is full and could not evict an entry.")
    end

    self.nextId += 1
    local handle = string.format("rh_%s_%d_%d", self.registryId, self.generation, self.nextId)
    local now = self:_now()
    local entry = {
        handle = handle,
        kind = kind or Classify(value),
        generation = self.generation,
        createdAt = now,
        lastAccess = now,
        expiresAt = now + ClampInteger(ttlSeconds, self.defaultTtlSeconds, 30, 7200),
        metadata = metadata,
        pinned = pinValue ~= false,
    }
    self.entries[handle] = entry
    self.activeCount += 1
    table.insert(self.order, handle)
    self.weakValues[handle] = value
    if pinValue ~= false then self.strongValues[handle] = value end
    self.reverse[value] = handle
    self.created += 1
    return handle, entry
end

function HandleRegistry:Resolve(handle, expectedKind, pinValue)
    assert(type(handle) == "string" and handle ~= "", "A runtime handle is required.")
    self:Sweep()
    local entry = self.entries[handle]
    assert(entry ~= nil, "Runtime handle is missing, expired, released, or belongs to another connector generation.")
    local value = self.strongValues[handle] or self.weakValues[handle]
    if value == nil then
        self:_remove(handle, "collected")
        error("Runtime object was garbage-collected before this handle was pinned.")
    end
    if expectedKind ~= nil then
        if type(expectedKind) == "table" then
            local accepted = false
            for _, kind in expectedKind do
                if entry.kind == kind then accepted = true break end
            end
            assert(accepted, "Runtime handle kind is " .. entry.kind .. ", not one of the requested kinds.")
        else
            assert(entry.kind == expectedKind, "Runtime handle kind is " .. entry.kind .. ", not " .. tostring(expectedKind) .. ".")
        end
    end
    local now = self:_now()
    entry.lastAccess = now
    entry.expiresAt = now + self.defaultTtlSeconds
    if pinValue ~= false then
        self.strongValues[handle] = value
        entry.pinned = true
    end
    return value, entry
end

function HandleRegistry:Pin(handle)
    local value, entry = self:Resolve(handle, nil, true)
    return value, entry
end

function HandleRegistry:Unpin(handle)
    local entry = self.entries[handle]
    if not entry then return false end
    self.strongValues[handle] = nil
    entry.pinned = false
    return true
end

function HandleRegistry:Describe(handle)
    local _, entry = self:Resolve(handle)
    return {
        handle = entry.handle,
        kind = entry.kind,
        generation = entry.generation,
        ageSeconds = math.max(0, self:_now() - entry.createdAt),
        idleSeconds = math.max(0, self:_now() - entry.lastAccess),
        expiresInSeconds = math.max(0, entry.expiresAt - self:_now()),
        pinned = entry.pinned == true,
        metadata = entry.metadata,
    }
end

function HandleRegistry:Release(handle)
    return self:_remove(handle, "released")
end

function HandleRegistry:ReleaseMany(handles)
    local released = 0
    local missing = 0
    for _, handle in handles or {} do
        if type(handle) == "string" and self:Release(handle) then
            released += 1
        else
            missing += 1
        end
    end
    return released, missing
end

function HandleRegistry:List(cursor, limit, kind)
    self:Sweep(true)
    cursor = ClampInteger(cursor, 0, 0, 1000000000)
    limit = ClampInteger(limit, 50, 1, 200)
    local handles = {}
    for handle, entry in self.entries do
        if kind == nil or entry.kind == kind then
            table.insert(handles, { handle = handle, entry = entry })
        end
    end
    table.sort(handles, function(a, b) return a.handle < b.handle end)

    local results = {}
    local last = math.min(#handles, cursor + limit)
    for index = cursor + 1, last do
        local item = handles[index]
        table.insert(results, {
            handle = item.handle,
            kind = item.entry.kind,
            generation = item.entry.generation,
            ageSeconds = math.max(0, self:_now() - item.entry.createdAt),
            expiresInSeconds = math.max(0, item.entry.expiresAt - self:_now()),
            pinned = item.entry.pinned == true,
            metadata = item.entry.metadata,
        })
    end
    return {
        total = #handles,
        cursor = cursor,
        nextCursor = last < #handles and last or nil,
        handles = results,
    }
end

function HandleRegistry:Stats()
    self:Sweep(true)
    local byKind = {}
    local active = 0
    local pinned = 0
    for _, entry in self.entries do
        active += 1
        if entry.pinned then pinned += 1 end
        byKind[entry.kind] = (byKind[entry.kind] or 0) + 1
    end
    return {
        registryId = self.registryId,
        generation = self.generation,
        active = active,
        pinned = pinned,
        weak = active - pinned,
        maximum = self.maxHandles,
        defaultTtlSeconds = self.defaultTtlSeconds,
        byKind = byKind,
        lifetime = {
            created = self.created,
            released = self.released,
            expired = self.expired,
            evicted = self.evicted,
            collected = self.collected,
        },
    }
end

function HandleRegistry:RotateGeneration()
    for handle in self.entries do self:_remove(handle, "released") end
    self.generation += 1
    self.nextId = 0
    self.order = {}
    self.orderCursor = 1
    return self.generation
end

HandleRegistry.Classify = Classify

return HandleRegistry
