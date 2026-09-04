local Watch = require("../connector-src/dex/watch")
local DexInspector = require("../connector-src/dex/inspect")
local HandleRegistry = require("../connector-src/runtime/handles")

local function Signal()
    local signal = { connections = {} }
    function signal:Connect(callback)
        local connection = { Connected = true }
        function connection:Disconnect() self.Connected = false end
        connection.callback = callback
        table.insert(self.connections, connection)
        return connection
    end
    function signal:Fire(...)
        for _, connection in ipairs(self.connections) do
            if connection.Connected then connection.callback(...) end
        end
    end
    function signal:Count()
        local count = 0
        for _, connection in ipairs(self.connections) do if connection.Connected then count += 1 end end
        return count
    end
    return signal
end

local function Instance(name)
    local instance = {
        Name = name, ClassName = "Folder", Path = "game.Workspace." .. name, Parent = nil,
        attributes = {}, properties = {}, propertySignals = {}, attributeSignals = {},
        ChildAdded = Signal(), ChildRemoved = Signal(), AncestryChanged = Signal(),
    }
    function instance:GetAttribute(key) return self.attributes[key] end
    function instance:GetPropertyChangedSignal(key)
        if key == "NoSignal" then error("signal unavailable") end
        if not self.propertySignals[key] then self.propertySignals[key] = Signal() end
        return self.propertySignals[key]
    end
    function instance:GetAttributeChangedSignal(key)
        if not self.attributeSignals[key] then self.attributeSignals[key] = Signal() end
        return self.attributeSignals[key]
    end
    function instance:SetProperty(key, value)
        self.properties[key] = value
        if self.propertySignals[key] then self.propertySignals[key]:Fire() end
    end
    function instance:SetAttribute(key, value)
        self.attributes[key] = value
        if self.attributeSignals[key] then self.attributeSignals[key]:Fire() end
    end
    function instance:ConnectionCount()
        local count = self.ChildAdded:Count() + self.ChildRemoved:Count() + self.AncestryChanged:Count()
        for _, signal in pairs(self.propertySignals) do count += signal:Count() end
        for _, signal in pairs(self.attributeSignals) do count += signal:Count() end
        return count
    end
    return instance
end

local now = 10
local first, second, child = Instance("First"), Instance("Second"), Instance("Child")
first.properties.Health = 100
first.properties.NoSignal = 1
first.attributes.State = "idle"
local targets = { first = first, second = second, child = child }
local Inspector = {}
function Inspector:Resolve(target)
    local key = if type(target) == "table" then target.handle else target
    assert(targets[key] ~= nil, "target missing")
    return targets[key]
end
function Inspector:Describe(instance)
    return { Name = instance.Name, ClassName = instance.ClassName, Path = instance.Path, Handle = instance.Name }
end
function Inspector:ReadProperty(instance, name, hidden)
    assert(hidden == false, "watching does not invoke hidden-property APIs")
    if name == "Missing" then return false, nil, "property unavailable" end
    if name == "Parent" then return true, instance.Parent, "ordinary" end
    return true, instance.properties[name], "ordinary"
end
local encodedOptions
local Values = {}
function Values:Encode(value, options)
    encodedOptions = options
    if type(value) == "table" and value.ClassName then
        return { type = "instance", handle = value.Name, ref = { name = value.Name } }
    end
    return { type = type(value), value = if type(value) == "string" then string.sub(tostring(value), 1, options.maxStringBytesPerValue) else value }
end
function Inspector:_encode(value)
    return Values:Encode(value, { maxDepth = 1, maxEntries = 10, maxStringBytesPerValue = 256, expandTables = true })
end
local function New(options)
    options = options or {}
    options.Inspector, options.Values, options.Clock = Inspector, Values, function() return now end
    return Watch.new(options)
end
local function Reject(callback, expected)
    local ok, reason = pcall(callback)
    assert(not ok, "operation should fail")
    if expected then assert(string.find(tostring(reason), expected, 1, true), tostring(reason)) end
end

local watch = New()
local started = watch:Start({ targets = { "first", { handle = "first" } }, properties = { "Health", "Health" },
    attributes = { "State" }, includeChildren = true, includeAncestry = true })
assert(started.connectionCount == 5 and #started.targets == 1, "duplicates must not multiply observations")
assert(started.expiresAt == 310 and started.nextCursor == 0)
assert(watch:Poll({ watcherId = started.watcherId }).nextCursor == 0, "baseline must not emit change events")
assert(encodedOptions.maxEntries == 10 and encodedOptions.maxDepth == 1, "watch callbacks use the injected bounded encoder")
first:SetProperty("Health", 75)
first:SetAttribute("State", "active")
first:SetAttribute("State", nil)
first.ChildAdded:Fire(child)
first.ChildRemoved:Fire(child)
first.Parent = second
first.Path = "game.Workspace.Second.First"
first.AncestryChanged:Fire(first, second)
local page = watch:Poll({ watcherId = started.watcherId, limit = 2 })
assert(#page.events == 2 and page.nextCursor == 2 and page.hasMore)
assert(page.events[1].kind == "property" and page.events[1].oldValue.value == 100 and page.events[1].newValue.value == 75)
assert(page.events[2].kind == "attribute" and page.events[2].oldValue.value == "idle" and page.events[2].newValue.value == "active")
local rest = watch:Poll({ watcherId = started.watcherId, cursor = page.nextCursor, limit = 10, maxChars = 60000 })
assert(#rest.events == 4 and rest.nextCursor == 6 and not rest.hasMore)
assert(rest.events[1].newValue.type == "nil", "removed attributes preserve typed nil")
assert(rest.events[2].oldValue.type == "nil" and rest.events[2].newValue.type == "instance")
assert(rest.events[3].oldValue.type == "instance" and rest.events[3].newValue.type == "nil")
assert(rest.events[4].oldValue.type == "nil" and rest.events[4].newValue.handle == "Second")
assert(rest.events[4].oldPath ~= rest.events[4].newPath, "ancestry observations retain both display paths")
assert(#watch:Poll({ watcherId = started.watcherId, cursor = 6 }).events == 0)
Reject(function() watch:Poll({ watcherId = started.watcherId, cursor = 99 }) end, "newer")
watch:Stop({ watcherId = started.watcherId })
assert(first:ConnectionCount() == 0)
first:SetProperty("Health", 1)
assert(watch:Poll({ watcherId = started.watcherId }).reason == "stopped")

local ring = watch:Start({ targets = { "first" }, properties = { "Health" }, maxEvents = 3 })
for value = 1, 7 do first:SetProperty("Health", value) end
local overrun = watch:Poll({ watcherId = ring.watcherId, cursor = 0, limit = 2 })
assert(overrun.droppedEvents == 4 and overrun.gapEvents == 4 and overrun.cursorExpired)
assert(overrun.earliestAvailableCursor == 5 and overrun.events[1].cursor == 5 and overrun.nextCursor == 6)
assert(overrun.events[1].oldValue.value == 4, "ring eviction must not lose last-value baseline")
local last = watch:Poll({ watcherId = ring.watcherId, cursor = overrun.nextCursor })
assert(#last.events == 1 and last.events[1].cursor == 7 and last.gapEvents == 0 and not last.hasMore)
watch:Stop({ watcherId = ring.watcherId })

local partial = watch:Start({ targets = { "first" }, properties = { "Missing", "NoSignal", "Health" } })
assert(partial.connectionCount == 1 and #partial.warnings == 2)
assert(partial.warnings[1].error == "property unavailable")
watch:Stop({ watcherId = partial.watcherId })
Reject(function() watch:Start({ targets = { "first" }, properties = { "Missing", "NoSignal" } }) end, "No requested")
assert(first:ConnectionCount() == 0)
Reject(function() watch:Start({ targets = { "first", "missing" }, properties = { "Health" } }) end, "target missing")
assert(first:ConnectionCount() == 0, "resolution errors must not orphan earlier targets")
Reject(function() watch:Start({ targets = { "first" } }) end, "Select")
Reject(function() watch:Start({ targets = { [2] = "first" }, properties = { "Health" } }) end, "dense")
local tooMany = {}
for index = 1, 21 do tooMany[index] = "Property" .. index end
Reject(function() watch:Start({ targets = { "first" }, properties = tooMany }) end, "exceeds")

local expire = watch:Start({ targets = { "first" }, properties = { "Health" }, ttlSeconds = 2 })
now += 3
assert(watch:Sweep() == 1 and first:ConnectionCount() == 0, "idle expiry disconnects without poll")
local expired = watch:Poll({ watcherId = expire.watcherId })
assert(expired.expired and not expired.active and expired.reason == "expired" and #expired.events == 0)
local callbackExpiry = watch:Start({ targets = { "first" }, properties = { "Health" }, ttlSeconds = 1 })
now += 2
first:SetProperty("Health", 2)
assert(first:ConnectionCount() == 0 and watch:Poll({ watcherId = callbackExpiry.watcherId }).expired)

local limited = New({ MaxWatchers = 1 })
limited:Start({ targets = { "first" }, properties = { "Health" } })
Reject(function() limited:Start({ targets = { "second" }, includeChildren = true }) end, "limit")
limited:Destroy()
assert(first:ConnectionCount() == 0 and second:ConnectionCount() == 0)
Reject(function() limited:Start({ targets = { "first" }, properties = { "Health" } }) end, "destroyed")

local oversize = New({ Measure = function(value)
    for _, event in ipairs(value.events or {}) do if not event.omitted then return 100000 end end
    return 1000
end })
local small = oversize:Start({ targets = { "first" }, properties = { "Health" } })
first:SetProperty("Health", 3)
first:SetProperty("Health", 4)
local omitted = oversize:Poll({ watcherId = small.watcherId, maxChars = 2000 })
assert(#omitted.events == 1 and omitted.events[1].omitted and omitted.nextCursor == 1 and omitted.hasMore)
local nextOmission = oversize:Poll({ watcherId = small.watcherId, cursor = 1, maxChars = 2000 })
assert(nextOmission.nextCursor == 2 and not nextOmission.hasMore, "oversized event cannot stall pagination")
oversize:Destroy()

local measured = New({ Measure = function() return 1 end })
local many = measured:Start({ targets = { "first" }, properties = { "Health" }, maxEvents = 500 })
for value = 1, 100 do first:SetProperty("Health", value) end
local capped = measured:Poll({ watcherId = many.watcherId, limit = 100, maxChars = 60000 })
assert(#capped.events > 0 and #capped.events < 100 and capped.hasMore, "entry budget applies independently of JSON bytes")
local cappedNext = measured:Poll({ watcherId = many.watcherId, cursor = capped.nextCursor, limit = 100, maxChars = 60000 })
assert(cappedNext.nextCursor > capped.nextCursor)
measured:Destroy()

-- Callback failures are bounded diagnostics, not exceptions escaping a signal.
local faultyInspector = table.clone(Inspector)
local faulty = Watch.new({ Inspector = faultyInspector, Values = Values, Clock = function() return now end })
local failure = faulty:Start({ targets = { "first" }, properties = { "Health" } })
function faultyInspector:ReadProperty() error("property read failed") end
first:SetProperty("Health", 5)
local failurePage = faulty:Poll({ watcherId = failure.watcherId })
assert(#failurePage.events == 1 and failurePage.events[1].newValue.type == "unavailable")
faulty:Destroy()

local generationOne = New({ NewId = function() return "generation-one" end })
local oldGeneration = generationOne:Start({ targets = { "first" }, properties = { "Health" } })
generationOne:Destroy()
local generationTwo = New({ NewId = function() return "generation-two" end })
local newGeneration = generationTwo:Start({ targets = { "first" }, properties = { "Health" } })
assert(oldGeneration.watcherId ~= newGeneration.watcherId, "reconnects must not reuse watcher IDs")
Reject(function() generationTwo:Poll({ watcherId = oldGeneration.watcherId }) end, "Unknown")
generationTwo:Destroy()
local fallbackOne, fallbackTwo = New(), New()
local fallbackFirst = fallbackOne:Start({ targets = { "first" }, properties = { "Health" } })
local fallbackSecond = fallbackTwo:Start({ targets = { "first" }, properties = { "Health" } })
assert(fallbackFirst.watcherId ~= fallbackSecond.watcherId, "test fallback IDs differ even when clocks are identical")
fallbackOne:Destroy()
fallbackTwo:Destroy()

local wrapperBudget = New({ Measure = function(value)
    return 500 + #(value.events or {}) * 1000
end })
local wrapperWatch = wrapperBudget:Start({ targets = { "first" }, properties = { "Health" } })
first:SetProperty("Health", 7)
first:SetProperty("Health", 8)
local wrapperPage = wrapperBudget:Poll({ watcherId = wrapperWatch.watcherId, maxChars = 2800 })
assert(#wrapperPage.events == 1 and wrapperPage.hasMore,
    "response must leave 350 bytes for metadata appended by the bridge wrapper")
assert(wrapperBudget.Measure(wrapperPage) + 350 <= 2800)
wrapperBudget:Destroy()

local minimumBudget = New({ Measure = function(value)
    local bytes = 500
    for _, event in ipairs(value.events or {}) do bytes += if event.omitted then 50 else 1300 end
    return bytes
end })
local minimumWatch = minimumBudget:Start({ targets = { "first" }, properties = { "Health" } })
first:SetProperty("Health", 9)
local minimumPage = minimumBudget:Poll({ watcherId = minimumWatch.watcherId, maxChars = 2000 })
assert(minimumPage.events[1].omitted and minimumPage.nextCursor == 1,
    "wrapper reserve applies even at the minimum allowed page size")
assert(minimumBudget.Measure(minimumPage) + 350 <= 2000)
minimumBudget:Destroy()

local partialInspector = table.clone(Inspector)
local partialEncoding = { type = "font", family = "rbxasset://bounded-family" }
function partialInspector:_encode(value)
    if value == "partial" then return partialEncoding, true end
    return Inspector._encode(self, value)
end
function partialInspector:Describe(value)
    local description = Inspector.Describe(self, value)
    description.DisplayTruncated = true
    description.PathDisplayOnly = true
    description.Path = "already bounded " .. utf8.char(0x1F642)
    return description
end
first.properties.Health = "partial"
local partialValues = Watch.new({ Inspector = partialInspector, Clock = function() return now end })
local partialStart = partialValues:Start({ targets = { "first" }, properties = { "Health" } })
assert(partialStart.targets[1].DisplayTruncated and partialStart.targets[1].PathDisplayOnly)
assert(partialStart.targets[1].Path == partialInspector:Describe(first).Path)
first:SetProperty("Health", "complete")
first:SetProperty("Health", "partial")
local partialPage = partialValues:Poll({ watcherId = partialStart.watcherId, maxChars = 60000 })
assert(partialPage.events[1].oldValue.truncated and not partialPage.events[1].newValue.truncated,
    "partial baseline values must be labelled in subsequent change events")
assert(partialPage.events[2].newValue.truncated, "partial encoder results must remain explicit in event payloads")
assert(partialPage.events[2].target.DisplayTruncated and partialPage.events[2].target.PathDisplayOnly)
assert(partialEncoding.truncated == nil, "marking a partial value must not mutate the Inspector-owned encoding")
partialValues:Destroy()

local weakTarget, weakLinked, weakChild, weakParent = Instance("WeakTarget"), Instance("WeakLinked"), Instance("WeakChild"), Instance("WeakParent")
weakTarget.Path = string.rep("a", 998) .. utf8.char(0x1F642)
weakTarget.Linked = weakLinked
weakTarget.Parent = weakParent
local registry = HandleRegistry.new({ RegistryId = "weakwatch", Clock = function() return now end })
local guardedCodec = {}
function guardedCodec:Encode(value, options)
    assert(not (type(value) == "table" and value.ClassName), "Instance encoding must not reach the pinning general codec")
    return Values:Encode(value, options)
end
local weakInspector = DexInspector.new({
    Handles = registry,
    Values = guardedCodec,
    Typeof = function(value)
        return if type(value) == "table" and value.ClassName then "Instance" else typeof(value)
    end,
    InstancePath = {
        Resolve = function() return weakTarget end,
        Describe = function(value) return Inspector:Describe(value) end,
    },
})
local weakWatch = Watch.new({ Inspector = weakInspector, Clock = function() return now end })
local weakStart = weakWatch:Start({ targets = { { path = "weak" } }, properties = { "Linked" }, includeChildren = true, includeAncestry = true })
assert(weakStart.targets[1].DisplayTruncated and weakStart.targets[1].PathDisplayOnly)
assert(weakStart.targets[1].Path == weakInspector:Describe(weakTarget).Path and utf8.len(weakStart.targets[1].Path) ~= nil,
    "watch descriptions must preserve the Inspector's bounded valid UTF-8 path")
weakTarget.Linked = weakChild
weakTarget:GetPropertyChangedSignal("Linked"):Fire()
weakTarget.ChildAdded:Fire(weakChild)
weakTarget.ChildRemoved:Fire(weakChild)
weakTarget.Parent = weakLinked
weakTarget.AncestryChanged:Fire(weakTarget, weakLinked)
local weakPage = weakWatch:Poll({ watcherId = weakStart.watcherId, maxChars = 60000 })
assert(#weakPage.events == 4 and weakPage.events[1].oldValue.type == "instance" and weakPage.events[1].newValue.type == "instance")
assert(weakPage.events[2].newValue.type == "instance" and weakPage.events[3].oldValue.type == "instance")
assert(weakPage.events[4].newValue.type == "instance" and weakPage.events[4].changedParent.type == "instance")
assert(next(registry.strongValues) == nil, "observations must never pin referenced or child Instances")
for _, entry in pairs(registry.entries) do assert(entry.pinned == false) end
weakWatch:Destroy()
assert(weakTarget:ConnectionCount() == 0 and next(registry.strongValues) == nil)

-- Account for the entire JSON envelope, including keys and escaped strings.
local function JsonBytes(value)
    local kind = type(value)
    if kind == "nil" then return 4 end
    if kind == "boolean" then return value and 4 or 5 end
    if kind == "number" then return #tostring(value) end
    if kind == "string" then
        local bytes = 2
        for index = 1, #value do
            local byte = string.byte(value, index)
            bytes += if byte == 34 or byte == 92 then 2 elseif byte < 32 then 6 else 1
        end
        return bytes
    end
    assert(kind == "table")
    local array = #value > 0
    for key in pairs(value) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #value then array = false break end
    end
    local bytes, count = 2, 0
    for key, child in pairs(value) do
        if count > 0 then bytes += 1 end
        bytes += JsonBytes(child)
        if not array then bytes += JsonBytes(tostring(key)) + 1 end
        count += 1
    end
    return bytes
end

local function AssertStartBudget(result, budget)
    assert(JsonBytes(result) + 350 <= budget, "startup must leave room for bridge metadata")
    local stamped = table.clone(result)
    stamped.clientId = "12345678-1234-1234-1234-123456789abc"
    stamped.connectorGeneration, stamped.placeId, stamped.observedAtUnixMs = 1234567890, 2338325648, 1788540000000
    assert(JsonBytes(stamped) <= budget, "stamped startup response must fit the requested output budget")
end

local ordinaryBudget = New({ Measure = JsonBytes })
local ordinaryStart = ordinaryBudget:Start({ targets = { "first" }, properties = { "Health", "Missing" }, maxChars = 2000 })
AssertStartBudget(ordinaryStart, 2000)
assert(ordinaryStart.targets[1].Path == first.Path and #ordinaryStart.warnings == 1)
assert(ordinaryStart.targetDetailsOmitted == 0 and ordinaryStart.targetsOmitted == 0 and ordinaryStart.warningsOmitted == 0,
    "small startup responses should keep their full descriptions and diagnostics")
ordinaryBudget:Destroy()

local function CheckStartBudget(measure, budget, escapedHandles)
    local inspector, instances, requested, properties = table.clone(Inspector), {}, {}, { "Health" }
    for index = 1, 19 do properties[index + 1] = "Missing" .. index .. string.rep('\001"\\', 39) end
    for index = 1, 10 do
        local instance = Instance("Budget" .. index)
        instance.properties.Health = 100
        instance.WatchHandle = string.rep(if escapedHandles then "\001" else "h", 58) .. index
        instance.Path = string.rep('\001"\\' .. utf8.char(0x1F642), 68)
        instances[index], requested[index] = instance, index
    end
    function inspector:Resolve(target) return instances[target] end
    function inspector:Describe(instance)
        return {
            Handle = instance.WatchHandle, Name = string.rep(utf8.char(0x1F642), 32),
            ClassName = "Folder", Path = instance.Path, DebugId = string.rep("\001", 128),
            PathDisplayOnly = true, DisplayTruncated = true,
        }
    end
    function inspector:ReadProperty(instance, name, hidden)
        if name ~= "Health" then return false, nil, string.rep('\001"\\', 66) end
        return Inspector.ReadProperty(self, instance, name, hidden)
    end
    local budgetWatch = Watch.new({
        Inspector = inspector, Measure = measure, Clock = function() return now end,
        NewId = function() return string.rep("\001", 80) end,
    })
    local result = budgetWatch:Start({ targets = requested, properties = properties, attributes = { "State" }, maxChars = budget })
    AssertStartBudget(result, budget or 20000)
    assert(budgetWatch:_fits(result, budget or 20000))
    assert(result.active and result.nextCursor == 0 and result.expiresAt == now + 300 and result.maxEvents == 200)
    assert(result.connectionCount == 20 and result.observedPropertyCount == 10 and result.observedAttributeCount == 10)
    assert(#result.targets + result.targetsOmitted == 10 and #result.warnings + result.warningsOmitted == 190)
    local compacted = result.targetsOmitted
    for index, target in ipairs(result.targets) do
        assert(target.Handle == instances[index].WatchHandle, "retained target handles must stay exact and ordered")
        if target.omitted then
            compacted += 1
            assert(target.Path == nil)
        else
            assert(target.Path == instances[index].Path and utf8.len(target.Path) ~= nil)
        end
    end
    assert(compacted == result.targetDetailsOmitted and compacted > 0)
    if escapedHandles and budget == 2000 then assert(result.targetsOmitted > 0, "even compact rows may need omission") end
    local retained = budgetWatch.watchers[result.watcherId]
    assert(#retained.warnings == 20 and retained.warningsOmitted == 170,
        "response trimming must not mutate the watcher's retained diagnostics")
    for _, instance in ipairs(instances) do
        assert(instance:ConnectionCount() == 2, "response omissions must not remove subscriptions")
        instance:SetProperty("Health", 42)
    end
    local observed = budgetWatch:Poll({ watcherId = result.watcherId, limit = 1, maxChars = 60000 })
    assert(observed.latestCursor == 10 and observed.nextCursor == 1 and observed.events[1].newValue.value == 42)
    assert(not observed.events[1].omitted, "startup response trimming must not alter the queued observations")
    assert(budgetWatch:Stop({ watcherId = result.watcherId }).reason == "stopped")
    for _, instance in ipairs(instances) do assert(instance:ConnectionCount() == 0) end
    budgetWatch:Destroy()
end

CheckStartBudget(JsonBytes, 2000, false)
CheckStartBudget(JsonBytes, nil, false) -- default budget also needs enforcement
CheckStartBudget(JsonBytes, 2000, true)
CheckStartBudget(nil, 2000, true)
CheckStartBudget(function() error("JSON measurement unavailable") end, 2000, true)
for _, invalid in ipairs({ -1, 0 / 0, math.huge, "invalid" }) do
    CheckStartBudget(function() return invalid end, 2000, true)
end

local impossibleBudget = New({ MaxWatchers = 1, Measure = function() return 100000 end })
Reject(function()
    impossibleBudget:Start({ targets = { "first" }, properties = { "Health" }, maxChars = 2000 })
end, "cannot fit")
assert(next(impossibleBudget.watchers) == nil and first:ConnectionCount() == 0,
    "startup budgeting failures must not orphan subscriptions or consume watcher slots")
impossibleBudget.Measure = JsonBytes
assert(impossibleBudget:Start({ targets = { "first" }, properties = { "Health" }, maxChars = 2000 }).active)
impossibleBudget:Destroy()

watch:Destroy()
assert(first:ConnectionCount() == 0 and second:ConnectionCount() == 0)
print("Dex watcher tests passed")
