local InstancePath = require("../bridge/instance-path")

local GcExplorer = {}
GcExplorer.__index = GcExplorer

local function ClampInteger(value, fallback, minimum, maximum)
    local parsed = tonumber(value)
    if parsed == nil or parsed ~= parsed then parsed = fallback end
    return math.max(minimum, math.min(maximum, math.floor(parsed)))
end

local function TimestampMillis()
    local ok, value = pcall(function() return DateTime.now().UnixTimestampMillis end)
    return ok and value or os.time() * 1000
end

local function SafePrimitive(value)
    local valueType = type(value)
    return valueType == "string" or valueType == "number" or valueType == "boolean" or value == nil
end

local function IsExecutorClosure(value)
    if type(isexecutorclosure) ~= "function" or type(value) ~= "function" then return false end
    local ok, result = pcall(isexecutorclosure, value)
    return ok and result == true
end

local function GetConstants(value)
    local getter = if type(getconstants) == "function" then getconstants else nil
    if not getter and type(debug) == "table" and type(debug.getconstants) == "function" then
        getter = debug.getconstants
    end
    if not getter then return nil end
    local ok, result = pcall(getter, value)
    return ok and type(result) == "table" and result or nil
end

local function GetUpvalues(value)
    local getter = if type(getupvalues) == "function" then getupvalues else nil
    if not getter and type(debug) == "table" and type(debug.getupvalues) == "function" then
        getter = debug.getupvalues
    end
    if not getter then return nil end
    local ok, result = pcall(getter, value)
    return ok and type(result) == "table" and result or nil
end

local function GetPrototypes(value)
    local getter = if type(getprotos) == "function" then getprotos else nil
    if not getter and type(debug) == "table" and type(debug.getprotos) == "function" then
        getter = debug.getprotos
    end
    if not getter then return nil end
    local ok, result = pcall(getter, value)
    return ok and type(result) == "table" and result or nil
end

local function ContainsPrimitive(collection, expectedValues, scanLimit)
    if type(expectedValues) ~= "table" or #expectedValues == 0 then return true end
    if type(collection) ~= "table" then return false end
    for _, expected in expectedValues do
        local found = false
        local scanned = 0
        for _, actual in pairs(collection) do
            if scanned >= scanLimit then break end
            scanned += 1
            if SafePrimitive(actual) and actual == expected then found = true break end
        end
        if not found then return false end
    end
    return true
end

local function TableSummary(value, scanLimit)
    local entryCount = 0
    local exact = true
    local keyNames = {}
    local keyTypes = {}
    local ok = pcall(function()
        for key in pairs(value) do
            if entryCount >= scanLimit then exact = false break end
            entryCount += 1
            local keyType = typeof(key)
            keyTypes[keyType] = (keyTypes[keyType] or 0) + 1
            if type(key) == "string" and #keyNames < 20 then
                table.insert(keyNames, string.sub(key, 1, 120))
            end
        end
    end)
    table.sort(keyNames)
    local signatureParts = {}
    for keyType, count in keyTypes do table.insert(signatureParts, keyType .. ":" .. tostring(count)) end
    table.sort(signatureParts)
    return {
        entryCount = entryCount,
        entryCountExact = exact and ok,
        keyNames = keyNames,
        keyTypes = keyTypes,
        signature = table.concat(keyNames, "|") .. "#" .. table.concat(signatureParts, ","),
    }
end

local function FunctionSummary(value, TypedValues)
    local summary = TypedValues.FunctionSummary(value)
    local constants = GetConstants(value)
    local upvalues = GetUpvalues(value)
    local prototypes = GetPrototypes(value)
    summary.executorClosure = IsExecutorClosure(value)
    summary.constantCount = constants and #constants or nil
    summary.upvalueCount = upvalues and #upvalues or nil
    summary.prototypeCount = prototypes and #prototypes or nil
    summary.signature = table.concat({
        tostring(summary.hash or ""),
        tostring(summary.source or ""),
        tostring(summary.line or ""),
        tostring(summary.name or ""),
        tostring(summary.constantCount or ""),
        tostring(summary.upvalueCount or ""),
    }, "|")
    return summary
end

function GcExplorer.new(options)
    options = options or {}
    assert(options.Handles ~= nil and options.TypedValues ~= nil, "GcExplorer requires handles and typed values.")
    return setmetatable({
        Handles = options.Handles,
        TypedValues = options.TypedValues,
        snapshots = {},
        snapshotOrder = {},
        nextSnapshot = 0,
        maxSnapshots = ClampInteger(options.MaxSnapshots, 8, 2, 32),
        defaultScanLimit = ClampInteger(options.DefaultScanLimit, 20000, 100, 100000),
        tableScanLimit = ClampInteger(options.TableScanLimit, 250, 50, 10000),
        running = false,
    }, GcExplorer)
end

function GcExplorer:_snapshotId()
    self.nextSnapshot += 1
    return string.format("gs_%s_%d", self.Handles.registryId, self.nextSnapshot)
end

function GcExplorer:_objectRecord(value)
    local kind = self.Handles.Classify(value)
    local summary
    if kind == "function" then
        summary = FunctionSummary(value, self.TypedValues)
    elseif kind == "table" then
        summary = TableSummary(value, self.tableScanLimit)
    elseif kind == "thread" then
        local status
        pcall(function() status = coroutine.status(value) end)
        summary = { status = status, signature = "thread:" .. tostring(status) }
    elseif kind == "instance" then
        local description = InstancePath.Describe(value)
        summary = {
            path = description.Path,
            name = description.Name,
            className = description.ClassName,
            debugId = description.DebugId,
        }
        summary.signature = tostring(summary.className) .. "|" .. tostring(summary.path)
    else
        summary = { robloxType = typeof(value), signature = typeof(value) .. ":" .. tostring(value) }
    end
    -- Snapshot indexing must not make every GC object permanently reachable.
    -- Query results are pinned only when they are actually returned to a tool.
    local handle = self.Handles:Register(value, kind, summary, 3600, false)
    return { handle = handle, kind = kind, summary = summary }
end

function GcExplorer:CreateSnapshot(data)
    assert(type(getgc) == "function", "This executor does not expose getgc; GC snapshots are unavailable.")
    assert(not self.running, "Another GC snapshot is already running for this client.")
    self.running = true

    local ok, result = pcall(function()
        local started = os.clock()
        local valuesOk, values = pcall(getgc, data.includeTables ~= false)
        if not valuesOk then valuesOk, values = pcall(getgc) end
        assert(valuesOk and type(values) == "table", "getgc failed: " .. tostring(values))

        local scanLimit = ClampInteger(data.scanLimit, self.defaultScanLimit, 100, 100000)
        local includeExecutor = data.includeExecutor == true
        local requestedKinds = {}
        for _, kind in data.kinds or {} do requestedKinds[kind] = true end
        local hasKindFilter = next(requestedKinds) ~= nil
        local snapshot = {
            snapshotId = self:_snapshotId(),
            createdAtUnixMs = TimestampMillis(),
            scanLimit = scanLimit,
            totalReturnedByExecutor = #values,
            scanned = 0,
            retained = 0,
            recordFailures = 0,
            recordFailureSamples = {},
            truncated = false,
            includeExecutor = includeExecutor,
            objects = {},
            counts = {},
        }

        for _, value in values do
            if snapshot.scanned >= scanLimit then snapshot.truncated = true break end
            snapshot.scanned += 1
            if snapshot.scanned % 250 == 0 then task.wait() end
            local kind = self.Handles.Classify(value)
            if hasKindFilter and not requestedKinds[kind] then continue end
            if kind == "function" and not includeExecutor and IsExecutorClosure(value) then continue end
            if value == snapshot or value == self.snapshots or value == self.snapshotOrder then continue end
            local recordOk, record = pcall(function() return self:_objectRecord(value) end)
            if recordOk then
                table.insert(snapshot.objects, record)
                snapshot.retained += 1
                snapshot.counts[record.kind] = (snapshot.counts[record.kind] or 0) + 1
            else
                snapshot.recordFailures += 1
                if #snapshot.recordFailureSamples < 5 then
                    table.insert(snapshot.recordFailureSamples, string.sub(tostring(record), 1, 300))
                end
            end
        end

        snapshot.durationMs = math.floor((os.clock() - started) * 1000 + 0.5)
        self.snapshots[snapshot.snapshotId] = snapshot
        table.insert(self.snapshotOrder, snapshot.snapshotId)
        while #self.snapshotOrder > self.maxSnapshots do
            local removed = table.remove(self.snapshotOrder, 1)
            self.snapshots[removed] = nil
        end
        return self:DescribeSnapshot(snapshot)
    end)
    self.running = false
    if not ok then error(result) end
    return result
end

function GcExplorer:DescribeSnapshot(snapshot)
    return {
        snapshotId = snapshot.snapshotId,
        createdAtUnixMs = snapshot.createdAtUnixMs,
        durationMs = snapshot.durationMs,
        scanLimit = snapshot.scanLimit,
        totalReturnedByExecutor = snapshot.totalReturnedByExecutor,
        scanned = snapshot.scanned,
        retained = snapshot.retained,
        recordFailures = snapshot.recordFailures,
        recordFailureSamples = snapshot.recordFailureSamples,
        truncated = snapshot.truncated,
        includeExecutor = snapshot.includeExecutor,
        counts = snapshot.counts,
    }
end

function GcExplorer:GetSnapshot(snapshotId)
    local snapshot = self.snapshots[snapshotId]
    assert(snapshot ~= nil, "Unknown or released GC snapshot: " .. tostring(snapshotId))
    return snapshot
end

function GcExplorer:ListSnapshots()
    local results = {}
    for _, snapshotId in self.snapshotOrder do
        local snapshot = self.snapshots[snapshotId]
        if snapshot then table.insert(results, self:DescribeSnapshot(snapshot)) end
    end
    return { snapshots = results, maximumSnapshots = self.maxSnapshots, running = self.running }
end

function GcExplorer:ReleaseSnapshot(snapshotId)
    local existed = self.snapshots[snapshotId] ~= nil
    self.snapshots[snapshotId] = nil
    for index = #self.snapshotOrder, 1, -1 do
        if self.snapshotOrder[index] == snapshotId then table.remove(self.snapshotOrder, index) end
    end
    return { snapshotId = snapshotId, released = existed }
end

local function HasTableKeys(value, keys)
    if type(keys) ~= "table" or #keys == 0 then return true end
    if type(value) ~= "table" then return false end
    for _, key in keys do
        if rawget(value, key) == nil then return false end
    end
    return true
end

function GcExplorer:_matches(record, value, data)
    if data.kind and record.kind ~= data.kind then return false end
    local summary = record.summary or {}
    if data.name and summary.name ~= data.name then return false end
    if data.hash and summary.hash ~= data.hash then return false end
    if data.sourceContains then
        if type(summary.source) ~= "string" or not string.find(summary.source, data.sourceContains, 1, true) then return false end
    end
    if data.signatureContains then
        if type(summary.signature) ~= "string" or not string.find(summary.signature, data.signatureContains, 1, true) then return false end
    end
    if data.minEntries and (summary.entryCount or -1) < data.minEntries then return false end
    if data.maxEntries and (summary.entryCount or math.huge) > data.maxEntries then return false end
    if record.kind == "function" then
        if data.ignoreExecutor ~= false and summary.executorClosure == true then return false end
        if not ContainsPrimitive(GetConstants(value), data.constants, self.tableScanLimit) then return false end
        if not ContainsPrimitive(GetUpvalues(value), data.upvalues, self.tableScanLimit) then return false end
    elseif record.kind == "table" then
        if not HasTableKeys(value, data.keys) then return false end
        if not ContainsPrimitive(value, data.values, self.tableScanLimit) then return false end
        if type(data.keyValuePairs) == "table" then
            for key, expected in data.keyValuePairs do
                if rawget(value, key) ~= expected then return false end
            end
        end
    end
    return true
end

function GcExplorer:Query(data)
    local snapshot = self:GetSnapshot(data.snapshotId)
    local cursor = ClampInteger(data.cursor, 0, 0, 1000000000)
    local limit = ClampInteger(data.limit, 25, 1, 200)
    local results = {}
    local matched = 0
    local staleHandles = 0
    local recordsScanned = 0
    for _, record in snapshot.objects do
        recordsScanned += 1
        if recordsScanned % 500 == 0 then task.wait() end
        local ok, value = pcall(function() return self.Handles:Resolve(record.handle, nil, false) end)
        if not ok then staleHandles += 1 continue end
        local matchesOk, matches = pcall(function() return self:_matches(record, value, data) end)
        if not matchesOk or not matches then continue end
        if matched >= cursor and #results < limit then
            self.Handles:Pin(record.handle)
            table.insert(results, record)
        end
        matched += 1
    end
    local nextCursor = cursor + #results
    return {
        snapshotId = snapshot.snapshotId,
        totalMatched = matched,
        cursor = cursor,
        nextCursor = nextCursor < matched and nextCursor or nil,
        staleHandles = staleHandles,
        recordsScanned = recordsScanned,
        results = results,
    }
end

function GcExplorer:Diff(data)
    local before = self:GetSnapshot(data.beforeSnapshotId)
    local after = self:GetSnapshot(data.afterSnapshotId)
    local beforeSet = {}
    local afterSet = {}
    local beforeByKind = {}
    local afterByKind = {}
    for _, record in before.objects do
        beforeSet[record.handle] = record
        beforeByKind[record.kind] = (beforeByKind[record.kind] or 0) + 1
    end
    for _, record in after.objects do
        afterSet[record.handle] = record
        afterByKind[record.kind] = (afterByKind[record.kind] or 0) + 1
    end

    local sampleLimit = ClampInteger(data.sampleLimit, 50, 0, 200)
    local added = {}
    local removed = {}
    local addedCount = 0
    local removedCount = 0
    local retainedCount = 0
    for handle, record in afterSet do
        if beforeSet[handle] then
            retainedCount += 1
        else
            addedCount += 1
            if #added < sampleLimit then table.insert(added, record) end
        end
    end
    for handle, record in beforeSet do
        if not afterSet[handle] then
            removedCount += 1
            if #removed < sampleLimit then table.insert(removed, record) end
        end
    end
    return {
        beforeSnapshotId = before.snapshotId,
        afterSnapshotId = after.snapshotId,
        addedCount = addedCount,
        removedCount = removedCount,
        retainedCount = retainedCount,
        addedSample = added,
        removedSample = removed,
        countsByKind = { before = beforeByKind, after = afterByKind },
    }
end

function GcExplorer:Statistics(data)
    local snapshot = self:GetSnapshot(data.snapshotId)
    local functionsBySource = {}
    local tableSignatures = {}
    local largestTables = {}
    for _, record in snapshot.objects do
        local summary = record.summary or {}
        if record.kind == "function" then
            local source = tostring(summary.source or "<unknown>")
            functionsBySource[source] = (functionsBySource[source] or 0) + 1
        elseif record.kind == "table" then
            local signature = tostring(summary.signature or "<unknown>")
            tableSignatures[signature] = (tableSignatures[signature] or 0) + 1
            table.insert(largestTables, record)
        end
    end
    table.sort(largestTables, function(a, b)
        return (a.summary.entryCount or 0) > (b.summary.entryCount or 0)
    end)
    while #largestTables > ClampInteger(data.largestTableLimit, 20, 0, 100) do table.remove(largestTables) end
    return {
        snapshotId = snapshot.snapshotId,
        counts = snapshot.counts,
        functionsBySource = functionsBySource,
        tableSignatures = tableSignatures,
        largestTables = largestTables,
        handleRegistry = self.Handles:Stats(),
    }
end

local function IsReferenceValue(value)
    local valueType = typeof(value)
    return valueType == "table"
        or valueType == "function"
        or valueType == "thread"
        or valueType == "Instance"
        or valueType == "RBXScriptConnection"
        or valueType == "RBXScriptSignal"
        or valueType == "userdata"
end

function GcExplorer:References(data)
    local snapshot = self:GetSnapshot(data.snapshotId)
    local target = self.Handles:Resolve(data.handle)
    local direction = data.direction or "both"
    local edgeLimit = ClampInteger(data.limit, 100, 1, 500)
    local objectScanLimit = ClampInteger(data.scanLimit, 20000, 100, 100000)
    local perObjectLimit = ClampInteger(data.perObjectScanLimit, 250, 10, 10000)
    local edges = {}
    local objectsScanned = 0
    local entriesScanned = 0
    local truncated = false

    local function AddOutgoing(relation, found, detail)
        if #edges >= edgeLimit then truncated = true return false end
        if not IsReferenceValue(found) then return true end
        table.insert(edges, {
            direction = "outgoing",
            fromHandle = data.handle,
            relation = relation,
            detail = detail,
            to = self.TypedValues:Encode(found),
        })
        return true
    end

    local function AddIncoming(record, relation, detail)
        if #edges >= edgeLimit then truncated = true return false end
        self.Handles:Pin(record.handle)
        table.insert(edges, {
            direction = "incoming",
            from = {
                type = "handle",
                kind = record.kind,
                handle = record.handle,
                summary = record.summary,
            },
            relation = relation,
            detail = detail,
            toHandle = data.handle,
        })
        return true
    end

    if direction == "outgoing" or direction == "both" then
        local targetType = typeof(target)
        if targetType == "table" then
            local scanned = 0
            for key, value in next, target do
                if scanned >= perObjectLimit or #edges >= edgeLimit then truncated = true break end
                scanned += 1
                entriesScanned += 1
                AddOutgoing("table-key", key, { key = self.TypedValues:Encode(key) })
                if not AddOutgoing("table-value", value, { key = self.TypedValues:Encode(key) }) then break end
            end
        elseif targetType == "function" then
            for key, value in pairs(GetUpvalues(target) or {}) do
                if #edges >= edgeLimit then truncated = true break end
                AddOutgoing("upvalue", value, { index = self.TypedValues:Encode(key) })
            end
            for key, value in pairs(GetPrototypes(target) or {}) do
                if #edges >= edgeLimit then truncated = true break end
                AddOutgoing("prototype", value, { index = self.TypedValues:Encode(key) })
            end
        end
        local getMeta = if type(getrawmetatable) == "function" then getrawmetatable else getmetatable
        local metaOk, metatable = pcall(getMeta, target)
        if metaOk and metatable ~= nil then AddOutgoing("metatable", metatable, nil) end
    end

    if (direction == "incoming" or direction == "both") and #edges < edgeLimit then
        for _, record in snapshot.objects do
            if objectsScanned >= objectScanLimit or #edges >= edgeLimit then truncated = true break end
            objectsScanned += 1
            if objectsScanned % 250 == 0 then task.wait() end
            if record.handle == data.handle then continue end
            local resolved, source = pcall(function()
                return self.Handles:Resolve(record.handle, nil, false)
            end)
            if not resolved then continue end
            local sourceType = typeof(source)
            if sourceType == "table" then
                local scanned = 0
                local scanOk = pcall(function()
                    for key, value in next, source do
                        if scanned >= perObjectLimit or #edges >= edgeLimit then truncated = true break end
                        scanned += 1
                        entriesScanned += 1
                        if rawequal(key, target) then AddIncoming(record, "table-key", nil) end
                        if rawequal(value, target) then
                            AddIncoming(record, "table-value", { key = self.TypedValues:Encode(key) })
                        end
                    end
                end)
                if not scanOk then continue end
            elseif sourceType == "function" then
                for key, value in pairs(GetUpvalues(source) or {}) do
                    if rawequal(value, target) then
                        AddIncoming(record, "upvalue", { index = self.TypedValues:Encode(key) })
                    end
                    if #edges >= edgeLimit then break end
                end
                for key, value in pairs(GetPrototypes(source) or {}) do
                    if rawequal(value, target) then
                        AddIncoming(record, "prototype", { index = self.TypedValues:Encode(key) })
                    end
                    if #edges >= edgeLimit then break end
                end
            end
            local getMeta = if type(getrawmetatable) == "function" then getrawmetatable else getmetatable
            local metaOk, metatable = pcall(getMeta, source)
            if metaOk and rawequal(metatable, target) then AddIncoming(record, "metatable", nil) end
        end
    end

    return {
        snapshotId = snapshot.snapshotId,
        targetHandle = data.handle,
        direction = direction,
        edges = edges,
        edgeCount = #edges,
        objectsScanned = objectsScanned,
        entriesScanned = entriesScanned,
        truncated = truncated,
    }
end

return GcExplorer
