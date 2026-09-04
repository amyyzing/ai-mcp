local Scan = require("../connector-src/dex/scan")

local serial = 0
local function Node(name, class)
    serial += 1
    local instance = {
        Name = name, ClassName = class or "Folder", Handle = "fake-" .. serial,
        children = {}, properties = {}, attributes = {}, tags = {}, childReads = 0,
    }
    function instance:GetChildren()
        self.childReads += 1
        if self.failChildren then error("children unavailable") end
        return table.clone(self.children)
    end
    function instance:GetDescendants() error("unbounded enumeration must not be used") end
    function instance:IsA(className) return className == "Instance" or className == self.ClassName end
    function instance:GetAttribute(name) return self.attributes[name] end
    function instance:HasTag(tag) return table.find(self.tags, tag) ~= nil end
    return instance
end

local function Parent(child, parent)
    if child.Parent then
        local index = table.find(child.Parent.children, child)
        if index then table.remove(child.Parent.children, index) end
    end
    child.Parent = parent
    if parent then table.insert(parent.children, child) end
end

local function Path(instance)
    return if instance.Parent then Path(instance.Parent) .. "." .. instance.Name else instance.Name
end

local function Typed(value)
    if type(value) == "table" and value.fakeTyped then return value.fakeTyped end
    if type(value) == "table" and value.Handle then return { type = "instance", handle = value.Handle } end
    return { type = type(value), value = value }
end

local function Fixture(options)
    options = options or {}
    local root, a, b, a1, a2, b1 = Node("workspace"), Node("A"), Node("B"), Node("A1", "Part"), Node("A2", "TextLabel"), Node("B1", "ObjectValue")
    Parent(a, root)
    Parent(b, root)
    Parent(a1, a)
    Parent(a2, a)
    Parent(b1, b)
    a2.Text = "Ready!"
    a1.properties.Health = 100
    a1.attributes.Enabled = true
    a1.tags = { "Inspectable" }
    local registry = {}
    for _, instance in ipairs({ root, a, b, a1, a2, b1 }) do registry[instance.Handle] = instance end
    local Inspector = {}
    function Inspector:Resolve(target)
        if target == "workspace" or (type(target) == "table" and target.path == "workspace") then return root end
        local handle = if type(target) == "table" then target.handle else target
        assert(registry[handle], "unknown target")
        return registry[handle]
    end
    function Inspector:Describe(instance)
        return { Handle = instance.Handle, Name = instance.Name, ClassName = instance.ClassName, Path = Path(instance) }
    end
    function Inspector:ReadProperty(instance, property, hidden)
        assert(hidden == false, "scan must not invoke hidden properties")
        if property == "Unavailable" then return false, nil, "unavailable" end
        if property == "Parent" then return true, instance.Parent, "ordinary" end
        return true, instance.properties[property], "ordinary"
    end
    function Inspector:QueryRecord(instance, data)
        if instance.failProjection then error("projection unavailable") end
        local record = self:Describe(instance)
        if instance.recordBytes then record.recordBytes = instance.recordBytes end
        if instance.extraEntries then
            record.extra = {}
            for index = 1, instance.extraEntries do record.extra[index] = index end
        end
        if data.properties then
            record.Properties = {}
            for _, property in ipairs(data.properties) do
                local ok, value = self:ReadProperty(instance, property, false)
                if ok then
                    record.Properties[property] = Typed(value)
                else
                    record.PropertyErrors = { [property] = "unavailable" }
                    record.PropertyErrorCount = (record.PropertyErrorCount or 0) + 1
                end
            end
        end
        if data.includeAttributes then
            record.Attributes = {}
            for key, value in pairs(instance.attributes) do record.Attributes[key] = Typed(value) end
        end
        if data.includeTags then record.Tags = table.clone(instance.tags) end
        return record
    end
    local clock = { now = 10 }
    options.Inspector = Inspector
    options.Clock = function() return clock.now end
    options.Measure = options.Measure or function(record) return if record.omitted then 60 else record.recordBytes or 150 end
    local scan = Scan.new(options)
    return { scan = scan, root = root, a = a, b = b, a1 = a1, a2 = a2, b1 = b1, registry = registry, clock = clock }
end

local function Reject(callback, expected)
    local ok, message = pcall(callback)
    assert(not ok, "operation should fail")
    if expected then assert(string.find(tostring(message), expected, 1, true), tostring(message)) end
end

local function Drain(scan, data, mode)
    local rows, pages, page = {}, {}, scan:Query(data, mode)
    repeat
        table.insert(pages, page)
        for _, record in ipairs(page.results) do table.insert(rows, record) end
        if not page.nextCursor then break end
        assert(#pages < 1000, "pagination must terminate")
        page = scan:Query({ cursor = page.nextCursor, limit = data.limit, scanBudget = data.scanBudget, maxChars = data.maxChars }, mode)
    until false
    return rows, page, pages
end

local fixture = Fixture()
local rows, finished, pages = Drain(fixture.scan, { limit = 2, scanBudget = 2 })
assert(#rows == 6 and #pages == 3 and finished.done and finished.complete)
local expected = { fixture.root, fixture.a, fixture.a1, fixture.a2, fixture.b, fixture.b1 }
local seen = {}
for index, record in ipairs(rows) do
    assert(record.Handle == expected[index].Handle, "DFS pagination must keep traversal order")
    assert(not seen[record.Handle], "DFS pagination must not duplicate nodes")
    seen[record.Handle] = true
end
assert(finished.visited == 6 and finished.matched == 6 and not finished.nextCursor)
assert(rows[1].Depth == 0 and rows[3].Depth == 2 and rows[3].ParentHandle == fixture.a.Handle)
fixture.scan:Destroy()

local movingTree = Fixture()
local movingFirst = movingTree.scan:Query({ limit = 2 })
Parent(movingTree.a1, movingTree.b)
local movingSeen, movingCount, movingPage = {}, 0, movingFirst
repeat
    for _, row in ipairs(movingPage.results) do
        assert(not movingSeen[row.Handle], "reparenting during a non-atomic scan must not duplicate rows")
        movingSeen[row.Handle] = true
        movingCount += 1
    end
    if not movingPage.nextCursor then break end
    movingPage = movingTree.scan:Query({ cursor = movingPage.nextCursor, limit = 2 })
until false
assert(movingCount == 6 and movingPage.matched == 6 and movingPage.visited == 7)
movingTree.scan:Destroy()

local unmatched = Fixture()
local empty, exhausted, searchPages = Drain(unmatched.scan, { filters = { nameContains = "not-present" }, scanBudget = 1 })
assert(#empty == 0 and #searchPages == 6 and exhausted.complete and exhausted.visited == 6)
for _, page in ipairs(searchPages) do assert(page.visitedThisPage == 1, "unmatched nodes must spend scan budget") end
unmatched.scan:Destroy()

local depth = Fixture()
local shallow, shallowEnd = Drain(depth.scan, { maxDepth = 0, retainSnapshot = true })
assert(#shallow == 1 and shallow[1].Handle == depth.root.Handle and shallowEnd.depthLimited)
assert(shallowEnd.complete and not shallowEnd.limited, "explicit maxDepth scope is complete within that depth")
assert(depth.a.childReads == 0 and depth.b.childReads == 0)
depth.scan:Destroy()

local bounded = Fixture()
local limitedRows, limitedEnd = Drain(bounded.scan, { maxNodes = 2, limit = 1, retainSnapshot = true })
assert(#limitedRows == 2 and limitedEnd.done and limitedEnd.limited and not limitedEnd.complete)
assert(table.find(limitedEnd.limitReasons, "node-limit") and limitedEnd.visited == 2)
local fullRows, exactEnd = Drain(bounded.scan, { maxNodes = 6 })
assert(#fullRows == 6 and exactEnd.complete and not exactEnd.limited, "exact cap at end is not truncation")
bounded.scan:Destroy()

local failed = Fixture()
failed.a.failChildren = true
local _, failedEnd = Drain(failed.scan, {})
assert(failedEnd.done and not failedEnd.complete and failedEnd.readErrors == 1)
failed.scan:Destroy()

local cursors = Fixture()
local firstPage = cursors.scan:Query({ limit = 1 })
local secondPage = cursors.scan:Query({ cursor = firstPage.nextCursor, limit = 1 })
local replay = cursors.scan:Query({ cursor = firstPage.nextCursor, limit = 99 })
assert(replay == secondPage and replay.results[1].Handle == cursors.a.Handle, "retry must replay exactly the prior response")
local thirdPage = cursors.scan:Query({ cursor = secondPage.nextCursor, limit = 1 })
assert(thirdPage.results[1].Handle == cursors.a1.Handle)
Reject(function() cursors.scan:Query({ cursor = firstPage.nextCursor }) end, "Stale")
Reject(function() cursors.scan:Query({ cursor = thirdPage.nextCursor }, "references") end, "another Dex tool")
Reject(function() cursors.scan:Query({ cursor = "bad" }) end, "Invalid")
cursors.scan:Destroy()

local ttl = Fixture({ TtlSeconds = 2, MaxSessions = 1 })
local expiring = ttl.scan:Query({ limit = 1 })
Reject(function() ttl.scan:Query({}) end, "capacity")
ttl.clock.now += 3
ttl.scan:Sweep()
assert(#ttl.scan:Snapshots({ operation = "list" }).snapshots == 0)
Reject(function() ttl.scan:Query({ cursor = expiring.nextCursor }) end, "expired")
local replacement = ttl.scan:Query({ limit = 1 })
local released = ttl.scan:Snapshots({ operation = "release", snapshotId = replacement.scanId })
assert(released.released and not ttl.scan:Snapshots({ operation = "release", snapshotId = replacement.scanId }).released)
Reject(function() ttl.scan:Query({ cursor = replacement.nextCursor }) end, "released")
ttl.scan:Destroy()

local ephemeral = Fixture({ MaxSessions = 2 })
local ephemeralFirst = ephemeral.scan:Query({ limit = 3 })
local ephemeralLast = ephemeral.scan:Query({ cursor = ephemeralFirst.nextCursor, limit = 3 })
assert(ephemeralLast.done)
local _, ephemeralSecond = Drain(ephemeral.scan, {})
assert(ephemeral.scan:Query({ cursor = ephemeralFirst.nextCursor }) == ephemeralLast,
    "completed scans must preserve last-page replay before capacity pressure")
local _, ephemeralThird = Drain(ephemeral.scan, {})
assert(#ephemeral.scan:Snapshots({ operation = "list" }).snapshots == 2)
Reject(function() ephemeral.scan:Query({ cursor = ephemeralFirst.nextCursor }) end, "expired")
assert(ephemeral.scan.sessions[ephemeralSecond.scanId] and ephemeral.scan.sessions[ephemeralThird.scanId],
    "capacity pressure evicts only the oldest completed ephemeral scan")
for _ = 1, 8 do assert(select(2, Drain(ephemeral.scan, {})).done) end
assert(#ephemeral.scan:Snapshots({ operation = "list" }).snapshots == 2,
    "unrelated completed queries must not exhaust scan capacity")
ephemeral.scan:Destroy()

local protected = Fixture({ MaxSessions = 2 })
local active = protected.scan:Query({ limit = 1 })
local _, saved = Drain(protected.scan, { retainSnapshot = true })
Reject(function() protected.scan:Query({}) end, "capacity")
assert(protected.scan.sessions[active.scanId] and protected.scan.sessions[saved.snapshotId],
    "active scans and retained snapshots must never be auto-evicted")
protected.scan:Destroy()

local retained = Fixture({ MaxSnapshotRecords = 2 })
local allRetainedRows, retainedEnd = Drain(retained.scan, { retainSnapshot = true })
assert(#allRetainedRows == 6 and retainedEnd.retainedRecords == 2 and not retainedEnd.complete)
assert(table.find(retainedEnd.limitReasons, "snapshot-retention-limit"))
local retainedPage = retained.scan:Snapshots({ operation = "page", snapshotId = retainedEnd.snapshotId, limit = 1 })
assert(#retainedPage.results == 1 and retainedPage.nextCursor == 1)
local retainedLast = retained.scan:Snapshots({ operation = "page", snapshotId = retainedEnd.snapshotId, cursor = 1 })
assert(#retainedLast.results == 1 and not retainedLast.nextCursor)
Reject(function() retained.scan:Snapshots({ operation = "diff", beforeId = retainedEnd.snapshotId, afterId = retainedEnd.snapshotId }) end, "completed")
retained.scan:Destroy()

local retentionBytes = Fixture({ MaxSnapshotBytes = 200 })
local _, byteEnd = Drain(retentionBytes.scan, { retainSnapshot = true })
assert(byteEnd.retainedRecords == 1 and byteEnd.limited and not byteEnd.complete)
retentionBytes.scan:Destroy()

local projections = Fixture()
local _, projectionEnd = Drain(projections.scan, { retainSnapshot = true, properties = { "Unavailable" } })
assert(projectionEnd.complete and not projectionEnd.projectionComplete and projectionEnd.projectionErrors == 6,
    "traversal completeness must be separate from capture/projection completeness")
Reject(function() projections.scan:Snapshots({ operation = "diff", beforeId = projectionEnd.snapshotId, afterId = projectionEnd.snapshotId }) end, "fully captured")
projections.scan:Destroy()

local snapshots = Fixture({ MaxSessions = 12 })
local spec = { retainSnapshot = true, properties = { "Health" }, includeAttributes = true, includeTags = true }
local _, before = Drain(snapshots.scan, spec)
snapshots.a1.properties.Health = 70
Parent(snapshots.a2, snapshots.b)
Parent(snapshots.b1, nil)
local added = Node("Added", "Part")
Parent(added, snapshots.root)
snapshots.registry[added.Handle] = added
local _, after = Drain(snapshots.scan, spec)
local diffRows, cursor = {}, 0
repeat
    local page = snapshots.scan:Snapshots({ operation = "diff", beforeId = before.snapshotId, afterId = after.snapshotId, cursor = cursor, limit = 1 })
    for _, row in ipairs(page.changes) do diffRows[row.Handle] = row end
    cursor = page.nextCursor
    assert(page.complete == (cursor == nil))
until cursor == nil
assert(diffRows[snapshots.a1.Handle].kind == "changed")
assert(table.find(diffRows[snapshots.a1.Handle].fields, "Properties"))
assert(diffRows[snapshots.a1.Handle].changes.Properties.before.Health.value == 100)
assert(diffRows[snapshots.a1.Handle].changes.Properties.after.Health.value == 70)
assert(diffRows[snapshots.a2.Handle].kind == "moved")
assert(diffRows[snapshots.b1.Handle].kind == "removed" and diffRows[added.Handle].kind == "added")
local same = snapshots.scan:Snapshots({ operation = "diff", beforeId = after.snapshotId, afterId = after.snapshotId })
assert(#same.changes == 0 and same.complete)
local _, differentRoot = Drain(snapshots.scan, { root = snapshots.a.Handle, retainSnapshot = true, properties = { "Health" }, includeAttributes = true, includeTags = true })
Reject(function() snapshots.scan:Snapshots({ operation = "diff", beforeId = after.snapshotId, afterId = differentRoot.snapshotId }) end, "same root")
local _, differentProjection = Drain(snapshots.scan, { retainSnapshot = true, properties = { "Other" } })
Reject(function() snapshots.scan:Snapshots({ operation = "diff", beforeId = after.snapshotId, afterId = differentProjection.snapshotId }) end, "scope differs")
local _, differentDepth = Drain(snapshots.scan, { retainSnapshot = true, properties = { "Health" }, includeAttributes = true, includeTags = true, maxDepth = 0 })
Reject(function() snapshots.scan:Snapshots({ operation = "diff", beforeId = after.snapshotId, afterId = differentDepth.snapshotId }) end, "maxDepth")
local incomplete = snapshots.scan:Query({ retainSnapshot = true, limit = 1 })
Reject(function() snapshots.scan:Snapshots({ operation = "diff", beforeId = after.snapshotId, afterId = incomplete.snapshotId }) end, "completed")
local _, noRetain = Drain(snapshots.scan, {})
Reject(function() snapshots.scan:Snapshots({ operation = "page", snapshotId = noRetain.scanId }) end, "did not retain")
snapshots.scan:Destroy()

local references = Fixture()
references.b1.properties.Value = references.a1
references.a.properties.Adornee = references.a1
references.b.properties.Other = references.a1
local refRows, refEnd = Drain(references.scan, { target = references.a1.Handle, properties = { "Value", "Adornee", "Unavailable" }, scanBudget = 1, retainSnapshot = true }, "references")
assert(#refRows == 2 and refEnd.complete and refEnd.visited == 6)
assert(refRows[1].Handle == references.a.Handle and refRows[1].ReferenceProperties[1] == "Adornee")
assert(refRows[2].Handle == references.b1.Handle and refRows[2].ReferenceProperties[1] == "Value")
assert(string.find(refEnd.coverage, "Only supplied", 1, true), "incoming references must explain coverage")
assert(refEnd.snapshotId == nil and refEnd.retainedRecords == 0, "references cannot retain incomparable snapshots")
references.scan:Destroy()

local filters = Fixture()
local tagRows = Drain(filters.scan, { filters = { isA = "Part", tag = "Inspectable", attribute = { name = "Enabled", equals = true } } })
assert(#tagRows == 1 and tagRows[1].Handle == filters.a1.Handle)
local textRows = Drain(filters.scan, { filters = { textContains = "ready", className = "TextLabel" } })
assert(#textRows == 1 and textRows[1].Handle == filters.a2.Handle)
filters.scan:Destroy()

local output = Fixture()
output.root.recordBytes, output.a.recordBytes = 700, 700
local outputFirst = output.scan:Query({ limit = 100, maxChars = 2000 })
assert(#outputFirst.results == 1 and outputFirst.visitedThisPage == 2 and outputFirst.nextCursor)
local outputSecond = output.scan:Query({ cursor = outputFirst.nextCursor, limit = 1, maxChars = 2000 })
assert(#outputSecond.results == 1 and outputSecond.results[1].Handle == output.a.Handle)
assert(outputSecond.visitedThisPage == 0, "pending record is delivered once without revisiting the instance")
output.scan:Destroy()

local huge = Fixture()
huge.root.recordBytes = 5000
local hugeFirst = huge.scan:Query({ limit = 1, maxChars = 2000, retainSnapshot = true })
assert(#hugeFirst.results == 1 and hugeFirst.results[1].omitted and hugeFirst.results[1].Handle == huge.root.Handle)
local hugeNext = huge.scan:Query({ cursor = hugeFirst.nextCursor, limit = 1, maxChars = 2000 })
assert(hugeNext.results[1].Handle == huge.a.Handle, "oversized first record must advance")
local hugeSnapshot = huge.scan:Snapshots({ operation = "page", snapshotId = hugeFirst.snapshotId, maxChars = 2000, limit = 1 })
assert(hugeSnapshot.results[1].omitted and hugeSnapshot.nextCursor == 1)
huge.scan:Destroy()

local entries = Fixture({ Measure = function() return 1 end })
entries.root.extraEntries = 900
local entriesFirst = entries.scan:Query({ limit = 1, maxChars = 60000 })
assert(entriesFirst.results[1].omitted, "recursive sanitizer budget is independent of byte measurement")
entries.scan:Destroy()

-- Mirror the bridge's structural limits against complete response envelopes,
-- not only row-local depths; the enclosing array contributes two levels.
local function AssertSanitizerShape(value, depth, total)
    depth, total = depth or 0, total or { entries = 0 }
    if type(value) ~= "table" then return end
    assert(depth < 8, "bridge would replace this table at depth eight")
    local perTable = 0
    for _, child in pairs(value) do
        perTable += 1
        total.entries += 1
        assert(perTable <= 256 and total.entries <= 2000, "bridge would truncate table entries")
        AssertSanitizerShape(child, depth + 1, total)
    end
end

local function ColorSequence(red)
    return { fakeTyped = { type = "colorSequence", keypoints = {
        { time = 0, value = { type = "color3", r = red, g = 0, b = 0 } },
    } } }
end
local deep = Fixture()
deep.a1.properties.Color = ColorSequence(0)
local deepSpec = { retainSnapshot = true, properties = { "Color" }, filters = { className = "Part" } }
local _, deepBefore = Drain(deep.scan, deepSpec)
deep.a1.properties.Color = ColorSequence(1)
local _, deepAfter = Drain(deep.scan, deepSpec)
local deepDiff = deep.scan:Snapshots({ operation = "diff", beforeId = deepBefore.snapshotId, afterId = deepAfter.snapshotId })
assert(deepDiff.complete and not deepDiff.detailsComplete and deepDiff.detailsOmitted == 1)
assert(deepDiff.changes[1].omitted and deepDiff.changes[1].reason == "serialization-depth-limit")
assert(deepDiff.changes[1].Handle == deep.a1.Handle and table.find(deepDiff.changes[1].fields, "Properties"),
    "explicit deep-detail omissions must retain exact identity and changed field names")
AssertSanitizerShape(deepDiff)
for _, snapshotId in ipairs({ deepBefore.snapshotId, deepAfter.snapshotId }) do
    local page = deep.scan:Snapshots({ operation = "page", snapshotId = snapshotId })
    assert(page.detailsComplete and page.detailsOmitted == 0 and not page.results[1].omitted,
        "before/after snapshots remain available without the extra diff wrapping")
    AssertSanitizerShape(page)
end
deep.scan:Destroy()

local perTable = Fixture({ Measure = function() return 1 end })
perTable.root.extraEntries = 257
local perTableFirst = perTable.scan:Query({ limit = 1, retainSnapshot = true })
assert(perTableFirst.results[1].omitted and perTableFirst.results[1].reason == "serialization-table-entry-limit")
assert(not perTableFirst.detailsComplete and perTableFirst.detailsOmitted == 1)
AssertSanitizerShape(perTableFirst)
local perTableSnapshot = perTable.scan:Snapshots({ operation = "page", snapshotId = perTableFirst.snapshotId, limit = 1 })
assert(perTableSnapshot.results[1].omitted and not perTableSnapshot.detailsComplete)
AssertSanitizerShape(perTableSnapshot)
perTable.scan:Destroy()

-- JSON byte accounting includes quotes, keys, delimiters and escaped control
-- characters, unlike the small constant measurement used by traversal tests.
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

local wire = Fixture({ Measure = JsonBytes, NewId = function() return "12345678-1234-1234-1234-123456789abc" end })
local function AssertWirePage(page)
    assert(JsonBytes(page) + 350 <= 2000, "full scan envelope must reserve 350 bytes for transport stamps")
    AssertSanitizerShape(page)
end
for index, instance in ipairs({ wire.root, wire.a, wire.b, wire.a1, wire.a2, wire.b1 }) do
    instance.Name = string.rep("long-name-", 12) .. index
    instance.Handle = "rh_123456789abcdef0_1_" .. index
    instance.properties.Note = string.rep('"\\\n', 50)
end
wire.root.Name = string.rep('"\\', 64)
local wireSpec = { properties = { "Note" }, retainSnapshot = true, maxChars = 2000 }
local wireRows, wireBefore, wirePages = Drain(wire.scan, wireSpec)
assert(#wireRows == 6)
for _, page in ipairs(wirePages) do AssertWirePage(page) end
wire.a1.properties.Note = string.rep('"\\\n', 49) .. "changed"
local _, wireAfter, afterPages = Drain(wire.scan, wireSpec)
for _, page in ipairs(afterPages) do AssertWirePage(page) end
local wireSnapshot = wire.scan:Snapshots({ operation = "page", snapshotId = wireBefore.snapshotId, maxChars = 2000 })
AssertWirePage(wireSnapshot)
local wireDiff = wire.scan:Snapshots({ operation = "diff", beforeId = wireBefore.snapshotId, afterId = wireAfter.snapshotId, maxChars = 2000 })
AssertWirePage(wireDiff)
Drain(wire.scan, { retainSnapshot = true, maxChars = 2000 })
Drain(wire.scan, { retainSnapshot = true, maxChars = 2000 })
local wireList = wire.scan:Snapshots({ operation = "list", maxChars = 2000 })
assert(#wireList.snapshots == 4, "bounded snapshot listing must preserve every release identifier")
local explicitOmissions = 0
for _, item in ipairs(wireList.snapshots) do
    assert(type(item.snapshotId) == "string")
    if item.omitted then
        explicitOmissions += 1
        assert(item.reason == "envelope-budget")
    else
        assert(item.root.Handle ~= nil and item.root.Path == nil and item.root.FullName == nil,
            "snapshot metadata should not duplicate full path strings")
    end
end
assert(explicitOmissions > 0 and wireList.detailsOmitted == explicitOmissions and not wireList.detailsComplete)
AssertWirePage(wireList)
wire.scan:Destroy()

print("Dex scan tests passed")
