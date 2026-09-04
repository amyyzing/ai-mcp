-- Incremental, client-visible instance traversal. No GetDescendants/selector
-- materialization: every visited node, including non-matches, spends a budget.
local Scan = {}
Scan.__index = Scan

local function Integer(value, fallback, minimum, maximum)
    local number = tonumber(value)
    if number == nil or number ~= number then number = fallback end
    return math.clamp(math.floor(number), minimum, maximum)
end

local function Equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for key, value in pairs(a) do if not Equal(value, b[key]) then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end

local function EntryCount(value, depth)
    if type(value) ~= "table" then return 0 end
    if (depth or 0) >= 8 then return 1000, "serialization-depth-limit" end
    local count, tableEntries = 0, 0
    for _, child in pairs(value) do
        tableEntries += 1
        if tableEntries > 256 then return 1000, "serialization-table-entry-limit" end
        local nested, reason = EntryCount(child, (depth or 0) + 1)
        if reason then return 1000, reason end
        count += 1 + nested
        if count > 1000 then break end
    end
    return count
end

local function Contains(value, needle, caseSensitive)
    if type(value) ~= "string" then return false end
    if not caseSensitive then value, needle = string.lower(value), string.lower(needle) end
    return string.find(value, needle, 1, true) ~= nil
end

function Scan.new(options)
    return setmetatable({
        inspector = options.Inspector,
        clock = options.Clock or os.clock,
        measure = options.Measure or function(value) return EntryCount(value) * 80 end,
        newId = options.NewId,
        serial = 0,
        sessions = {},
        ttl = options.TtlSeconds or 300,
        maxSessions = options.MaxSessions or 4,
        maxSnapshotBytes = options.MaxSnapshotBytes or 2 * 1024 * 1024,
        maxSnapshotRecords = options.MaxSnapshotRecords or 3000,
    }, Scan)
end

function Scan:Sweep()
    local now = self.clock()
    for id, session in pairs(self.sessions) do
        if session.expiresAt <= now then self.sessions[id] = nil end
    end
end

function Scan:Destroy()
    table.clear(self.sessions)
end

-- Row budgets alone cannot account for final cursor/status metadata or the
-- client/generation stamps added by the handler. Keep those fields intact and
-- compact only row details when the measured full response needs more room.
function Scan:_fitEnvelope(result, rowKey, maxChars)
    local allowance = maxChars - 350
    if self.measure(result) <= allowance then return result end
    local rows = result[rowKey] or {}
    for index = #rows, 1, -1 do
        local row = rows[index]
        local compact = {
            Handle = row.Handle, snapshotId = row.snapshotId, kind = row.kind,
            omitted = true, reason = "envelope-budget",
        }
        if self.measure(compact) < self.measure(row) then
            rows[index] = compact
            result.detailsOmitted = (result.detailsOmitted or 0) + (row.omitted and 0 or 1)
            result.detailsComplete = false
        end
        if self.measure(result) <= allowance then return result end
    end
    assert(self.measure(result) <= allowance, "Dex page metadata exceeds the output budget; increase maxOutputChars.")
    return result
end

function Scan:_get(id)
    self:Sweep()
    local session = self.sessions[id]
    assert(session, "Dex scan/snapshot expired, was released, was evicted under capacity pressure, or belongs to another connection. Start a new scan.")
    return session
end

function Scan:_start(data, mode)
    self:Sweep()
    local count = 0
    for _ in pairs(self.sessions) do count += 1 end
    -- Finished ephemeral scans keep their last page available for retries until
    -- capacity is needed. Never evict an active traversal or retained snapshot.
    while count >= self.maxSessions do
        local oldest
        for _, existing in pairs(self.sessions) do
            if existing.done and not existing.retain and (not oldest or existing.ordinal < oldest.ordinal) then
                oldest = existing
            end
        end
        if not oldest then break end
        self.sessions[oldest.id] = nil
        count -= 1
    end
    assert(count < self.maxSessions, "Dex scan capacity reached. Release a scan with dex-snapshot operation=release.")
    local root = self.inspector:Resolve(data.root or { path = "workspace" })
    local rootInfo = self.inspector:Describe(root)
    local referenced = mode == "references" and self.inspector:Resolve(data.target) or nil
    self.serial += 1
    local id = "dx_" .. (self.newId and self.newId() or tostring(math.floor(self.clock() * 1000000))) .. "_" .. self.serial
    local session = {
        id = id, mode = mode, revision = 0, ordinal = self.serial, createdAt = self.clock(), expiresAt = self.clock() + self.ttl,
        root = rootInfo, referenced = referenced, options = data,
        stack = { { nodes = { root }, index = 1, depth = 0 } },
        buffered = 1, visited = 0, matched = 0, seen = {}, counts = {},
        readErrors = 0, projectionErrors = 0, depthLimited = false,
        limited = false, reasons = {}, records = {}, byHandle = {}, snapshotBytes = 0,
        retain = mode == "query" and data.retainSnapshot == true, done = false,
        maxNodes = Integer(data.maxNodes, 50000, 1, 100000),
        maxDepth = Integer(data.maxDepth, 64, 0, 100),
    }
    self.sessions[id] = session
    return session
end

function Scan:_limit(session, reason)
    session.limited = true
    session.reasons[reason] = true
end

function Scan:_matches(instance, session)
    local filter = session.options.filters or {}
    if filter.nameContains and not Contains(instance.Name, filter.nameContains, filter.caseSensitive) then return false end
    if filter.className and instance.ClassName ~= filter.className then return false end
    if filter.isA and not instance:IsA(filter.isA) then return false end
    if filter.tag and not instance:HasTag(filter.tag) then return false end
    if filter.attribute then
        local value = instance:GetAttribute(filter.attribute.name)
        if value == nil then return false end
        if filter.attribute.equals ~= nil and value ~= filter.attribute.equals then return false end
    end
    if filter.textContains then
        if not (instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox")) then return false end
        if not Contains(instance.Text, filter.textContains, filter.caseSensitive) then return false end
    end
    return true
end

function Scan:_record(instance, session, depth)
    if session.mode == "references" then
        local links = {}
        for index, property in ipairs(session.options.properties or {}) do
            if index > 20 then break end
            local ok, value = self.inspector:ReadProperty(instance, property, false)
            if ok and value == session.referenced then table.insert(links, property) end
        end
        if #links == 0 then return nil end
        local result = self.inspector:Describe(instance)
        result.ReferenceProperties = links
        result.Depth = depth
        return result
    end
    if not self:_matches(instance, session) then return nil end
    local result = self.inspector:QueryRecord(instance, session.options)
    result.Depth = depth
    local parent = instance.Parent
    if parent then result.ParentHandle = self.inspector:Describe(parent).Handle end
    return result
end

function Scan:_prune(session)
    while #session.stack > 0 do
        local frame = session.stack[#session.stack]
        if frame.index <= #frame.nodes then break end
        session.buffered -= #frame.nodes
        table.remove(session.stack)
    end
end

function Scan:_visit(session)
    self:_prune(session)
    if #session.stack == 0 then return nil end
    if session.visited >= session.maxNodes then
        self:_limit(session, "node-limit")
        table.clear(session.stack)
        return nil
    end
    local frame = session.stack[#session.stack]
    local instance = frame.nodes[frame.index]
    frame.index += 1
    session.visited += 1
    if session.seen[instance] then return nil end
    session.seen[instance] = true

    local okChildren, children = pcall(function() return instance:GetChildren() end)
    if okChildren then
        if #children > 0 then
            if frame.depth >= session.maxDepth then
                session.depthLimited = true
            elseif session.buffered + #children > 100000 then
                self:_limit(session, "frontier-limit")
            else
                table.insert(session.stack, { nodes = children, index = 1, depth = frame.depth + 1 })
                session.buffered += #children
            end
        end
    else
        session.readErrors += 1
    end

    local ok, record = pcall(function() return self:_record(instance, session, frame.depth) end)
    if not ok then session.readErrors += 1 return nil end
    if not record then return nil end
    session.matched += 1
    local class = record.ClassName or "Unknown"
    session.counts[class] = (session.counts[class] or 0) + 1
    if record.PropertyErrorCount or record.AttributeError or record.TagError or record.PropertiesOmitted
        or record.AttributesLimited or record.TagsLimited or record.Truncated then
        session.projectionErrors += 1
    end
    if session.retain then
        local bytes = self.measure(record)
        if #session.records >= self.maxSnapshotRecords or session.snapshotBytes + bytes > self.maxSnapshotBytes then
            self:_limit(session, "snapshot-retention-limit")
        else
            table.insert(session.records, record)
            session.byHandle[record.Handle] = record
            session.snapshotBytes += bytes
        end
    end
    return record
end

function Scan:Query(data, mode)
    mode = mode or "query"
    local session
    if data.cursor then
        local id, revision = string.match(data.cursor, "^(.-):(%d+)$")
        assert(id, "Invalid Dex continuation cursor.")
        session = self:_get(id)
        assert(session.mode == mode, "This cursor belongs to another Dex tool.")
        revision = tonumber(revision)
        if session.lastInput == revision then return session.lastResponse end
        assert(revision == session.revision and not session.done, "Stale or completed Dex cursor. Use nextCursor from the last response.")
    else
        session = self:_start(data, mode)
    end
    session.expiresAt = self.clock() + self.ttl
    local inputRevision = session.revision
    local limit = Integer(data.limit, 25, 1, 100)
    local scanBudget = Integer(data.scanBudget, 1000, 1, 10000)
    local maxChars = Integer(data.maxChars, 20000, 2000, 60000)
    local deadline = self.clock() + Integer(data.timeBudgetMs, 8, 1, 50) / 1000
    local results, usedChars, usedEntries, detailsOmitted = {}, 1000, 100, 0
    local startVisited = session.visited
    repeat
        local record = session.pending
        session.pending = nil
        if not record then record = self:_visit(session) end
        if record then
            -- root.results[index] places every row at sanitizer depth two.
            local bytes = self.measure(record)
            local entries, serializationReason = EntryCount(record, 2)
            if serializationReason or bytes + usedChars > maxChars or entries + usedEntries > 850 then
                if #results > 0 then session.pending = record break end
                record = {
                    Handle = record.Handle, Name = string.sub(record.Name or "", 1, 100),
                    ClassName = record.ClassName, omitted = true,
                    reason = serializationReason or "page-budget",
                    note = "Record details omitted; use dex-inspect with fewer fields.",
                }
                bytes, entries = self.measure(record), EntryCount(record, 2)
                detailsOmitted += 1
            end
            table.insert(results, record)
            usedChars += bytes
            usedEntries += entries
        end
        self:_prune(session)
    until #results >= limit or #session.stack == 0 or session.visited - startVisited >= scanBudget or self.clock() >= deadline
    self:_prune(session)
    session.done = #session.stack == 0 and session.pending == nil
    if session.done then
        session.finishedAt = self.clock()
        table.clear(session.seen)
        session.referenced = nil
    end
    session.revision += 1
    local reasons = {}
    for reason in pairs(session.reasons) do table.insert(reasons, reason) end
    table.sort(reasons)
    local result = {
        scanId = session.id, snapshotId = session.retain and session.id or nil,
        results = results, returned = #results,
        visitedThisPage = session.visited - startVisited, visited = session.visited, matched = session.matched,
        done = session.done, complete = session.done and not session.limited and session.readErrors == 0,
        nextCursor = not session.done and (session.id .. ":" .. session.revision) or nil,
        limited = session.limited, limitReasons = reasons, depthLimited = session.depthLimited,
        readErrors = session.readErrors, projectionErrors = session.projectionErrors,
        projectionComplete = session.projectionErrors == 0,
        retainedRecords = #session.records, capturedAt = session.createdAt, expiresInSeconds = self.ttl,
        detailsComplete = detailsOmitted == 0, detailsOmitted = detailsOmitted,
        replayRetention = "Completed non-retained scans may be evicted when new scans need capacity.",
        scope = "client-visible, non-atomic; streamed-out and server-only descendants are not observable",
        enumerationNote = "Per-page budgets include non-matches. GetChildren is an atomic engine allocation; very wide parents can exceed a time slice.",
    }
    if mode == "references" then result.coverage = "Only supplied readable Instance-valued properties; not arbitrary Lua/GC references." end
    result = self:_fitEnvelope(result, "results", maxChars)
    session.complete = result.complete
    session.lastInput, session.lastResponse = inputRevision, result
    return result
end

local function PublicSnapshot(session)
    return {
        snapshotId = session.id, root = { Handle = session.root.Handle, Name = session.root.Name }, retained = #session.records,
        matched = session.matched, visited = session.visited, done = session.done,
        complete = session.complete == true, capturedAt = session.createdAt, finishedAt = session.finishedAt,
    }
end

function Scan:Snapshots(data)
    self:Sweep()
    if data.operation == "list" then
        local snapshots = {}
        for _, session in pairs(self.sessions) do
            local item = PublicSnapshot(session)
            item.snapshotRetained = session.retain
            table.insert(snapshots, item)
        end
        table.sort(snapshots, function(a, b) return a.snapshotId < b.snapshotId end)
        return self:_fitEnvelope({
            snapshots = snapshots, capacity = self.maxSessions, ttlSeconds = self.ttl,
            detailsComplete = true, detailsOmitted = 0,
        }, "snapshots", Integer(data.maxChars, 20000, 2000, 60000))
    end
    if data.operation == "release" then
        local exists = self.sessions[data.snapshotId] ~= nil
        self.sessions[data.snapshotId] = nil
        return { released = exists, snapshotId = data.snapshotId }
    end
    local cursor = Integer(data.cursor, 0, 0, 1000000)
    local limit = Integer(data.limit, 25, 1, 100)
    local maxChars = Integer(data.maxChars, 20000, 2000, 60000)
    local rows, bytes, entries, detailsOmitted = {}, 1000, 100, 0
    local function add(row)
        -- Both root.results[index] and root.changes[index] add two levels.
        -- Deep projected diffs must not be silently damaged by the serializer.
        local size = self.measure(row)
        local count, serializationReason = EntryCount(row, 2)
        if serializationReason or bytes + size > maxChars or entries + count > 850 then
            if #rows > 0 then return false end
            row = {
                Handle = row.Handle, kind = row.kind, fields = row.fields, omitted = true,
                reason = serializationReason or "page-budget",
                note = "Page the before/after snapshots or inspect this handle with fewer fields for details.",
            }
            size, count = self.measure(row), EntryCount(row, 2)
            detailsOmitted += 1
        end
        table.insert(rows, row)
        bytes += size
        entries += count
        return true
    end
    if data.operation == "page" then
        local session = self:_get(data.snapshotId)
        assert(session.retain, "This scan did not retain a snapshot. Start dex-query with retainSnapshot=true.")
        local position = cursor
        while position < #session.records and #rows < limit do
            if not add(session.records[position + 1]) then break end
            position += 1
        end
        return self:_fitEnvelope({
            snapshot = PublicSnapshot(session), results = rows, cursor = cursor,
            nextCursor = position < #session.records and position or nil,
            detailsComplete = detailsOmitted == 0, detailsOmitted = detailsOmitted,
        }, "results", maxChars)
    end
    assert(data.operation == "diff", "Unknown Dex snapshot operation.")
    local before, after = self:_get(data.beforeId), self:_get(data.afterId)
    assert(before.retain and after.retain, "Both scans must retain snapshots.")
    assert(before.mode == "query" and after.mode == "query", "Only retained Dex queries can be compared.")
    assert(before.complete and after.complete, "Diff requires completed, uncapped scans without traversal errors; continue or narrow both scans first.")
    assert(before.projectionErrors == 0 and after.projectionErrors == 0, "Diff requires fully captured projections; use fewer fields or resolve reported property errors.")
    assert(before.root.Handle == after.root.Handle, "Snapshots must have the same root instance.")
    for _, field in ipairs({ "filters", "properties", "includeAttributes", "includeTags", "maxDepth" }) do
        assert(Equal(before.options[field], after.options[field]), "Snapshot projection/scope differs: " .. field)
    end
    local position, examined = cursor, 0
    local total = #before.records + #after.records
    while position < total and #rows < limit and examined < 2000 do
        local row
        if position < #before.records then
            local old = before.records[position + 1]
            local current = after.byHandle[old.Handle]
            if not current then
                row = { kind = "removed", Handle = old.Handle, before = old }
            elseif not Equal(old, current) then
                local fields, changes = {}, {}
                for key, value in pairs(old) do
                    if not Equal(value, current[key]) then
                        table.insert(fields, key)
                        changes[key] = { before = value, after = current[key] }
                    end
                end
                for key, value in pairs(current) do
                    if old[key] == nil then table.insert(fields, key) changes[key] = { after = value } end
                end
                table.sort(fields)
                row = {
                    kind = old.ParentHandle ~= current.ParentHandle and "moved" or "changed",
                    Handle = old.Handle, fields = fields, changes = changes,
                }
            end
        else
            local current = after.records[position - #before.records + 1]
            if not before.byHandle[current.Handle] then row = { kind = "added", Handle = current.Handle, after = current } end
        end
        if row and not add(row) then break end
        position += 1
        examined += 1
    end
    return self:_fitEnvelope({
        beforeId = before.id, afterId = after.id, changes = rows,
        cursor = cursor, nextCursor = position < total and position or nil, examined = examined,
        complete = position >= total, atomic = false,
        detailsComplete = detailsOmitted == 0, detailsOmitted = detailsOmitted,
        note = "Differences cover captured projections only. Removed means no longer observed in this scope, not proof of destruction.",
    }, "changes", maxChars)
end

return Scan
