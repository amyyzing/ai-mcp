return function(_context, Bridge)
    local CollectionEntryScanMax = 500
    local SearchRunning = false

    local function AnyEqual(haystack, needles)
        if type(needles) ~= "table" or #needles == 0 then return true end
        if type(haystack) ~= "table" then return false end
        for _, expected in ipairs(needles) do
            local scanned = 0
            for _, actual in pairs(haystack) do
                if scanned >= CollectionEntryScanMax then break end
                scanned += 1
                if actual == expected then return true end
            end
        end
        return false
    end

    local function IsExecutorClosure(value)
        if type(isexecutorclosure) ~= "function" then return false end
        local ok, result = pcall(isexecutorclosure, value)
        return ok and result == true
    end

    local function FunctionName(value)
        local ok, name = pcall(function() return debug.info(value, "n") end)
        return ok and name or nil
    end

    local function FunctionHash(value)
        local getter = if type(getfunctionhash) == "function" then getfunctionhash else nil
        if not getter then return nil end
        local ok, hash = pcall(getter, value)
        return ok and hash or nil
    end

    local function FunctionConstants(value)
        local getter = if type(getconstants) == "function" then getconstants else nil
        if not getter and debug and type(debug.getconstants) == "function" then getter = debug.getconstants end
        if not getter then return nil end
        local ok, constants = pcall(getter, value)
        return ok and constants or nil
    end

    local function FunctionUpvalues(value)
        local getter = if type(getupvalues) == "function" then getupvalues else nil
        if not getter and debug and type(debug.getupvalues) == "function" then getter = debug.getupvalues end
        if not getter then return nil end
        local ok, upvalues = pcall(getter, value)
        return ok and upvalues or nil
    end

    local function MatchesFunction(value, data)
        if type(value) ~= "function" then return false end
        if data.ignoreExecutor ~= false and IsExecutorClosure(value) then return false end
        if data.name ~= nil and FunctionName(value) ~= data.name then return false end
        if data.hash ~= nil and FunctionHash(value) ~= data.hash then return false end
        if not AnyEqual(FunctionConstants(value), data.constants) then return false end
        if not AnyEqual(FunctionUpvalues(value), data.upvalues) then return false end
        return true
    end

    local function MatchesTable(value, data)
        if type(value) ~= "table" then return false end

        if type(data.keys) == "table" and #data.keys > 0 then
            local found = false
            for _, key in ipairs(data.keys) do
                if rawget(value, key) ~= nil then
                    found = true
                    break
                end
            end
            if not found then return false end
        end

        if type(data.values) == "table" and #data.values > 0 then
            local found = false
            for _, expected in ipairs(data.values) do
                local scanned = 0
                for _, actual in pairs(value) do
                    if scanned >= CollectionEntryScanMax then break end
                    scanned += 1
                    if actual == expected then
                        found = true
                        break
                    end
                end
                if found then break end
            end
            if not found then return false end
        end

        if type(data.keyValuePairs) == "table" then
            for key, expected in pairs(data.keyValuePairs) do
                if rawget(value, key) ~= expected then return false end
            end
        end
        return true
    end

    local function SummarizeFunction(value)
        local source
        local line
        pcall(function() source = debug.info(value, "s") end)
        pcall(function() line = debug.info(value, "l") end)
        local constants = FunctionConstants(value)
        local upvalues = FunctionUpvalues(value)
        return {
            Name = FunctionName(value),
            Source = source,
            Line = line,
            Hash = FunctionHash(value),
            IsExecutorClosure = IsExecutorClosure(value),
            ConstantCount = type(constants) == "table" and #constants or nil,
            UpvalueCount = type(upvalues) == "table" and #upvalues or nil,
        }
    end

    local function SafePreview(value)
        local valueType = typeof(value)
        if valueType == "string" then
            if #value > 200 then return string.sub(value, 1, 200) .. "...(truncated)" end
            return value
        end
        if valueType == "number" or valueType == "boolean" or valueType == "nil" then return value end
        if valueType == "Instance" then
            local ok, fullName = pcall(function() return value:GetFullName() end)
            return ok and fullName or tostring(value)
        end
        return "<" .. valueType .. ">"
    end

    local function SummarizeTable(value, data)
        local summary = {
            EntryCount = 0,
            EntryCountExact = true,
            Keys = {},
        }
        for key in pairs(value) do
            if summary.EntryCount >= CollectionEntryScanMax then
                summary.EntryCountExact = false
                break
            end
            summary.EntryCount += 1
            if #summary.Keys < 20 then table.insert(summary.Keys, SafePreview(key)) end
        end
        summary.EntryCountLowerBound = summary.EntryCount
        summary.EntryScanLimit = CollectionEntryScanMax

        if type(data.previewKeys) == "table" and #data.previewKeys > 0 then
            local preview = {}
            for index = 1, math.min(#data.previewKeys, 30) do
                local key = data.previewKeys[index]
                local foundValue = rawget(value, key)
                preview[tostring(key)] = if data.includeValues == true
                    then SafePreview(foundValue)
                    else foundValue ~= nil
            end
            summary.Preview = preview
        elseif data.includeValues == true then
            local preview = {}
            local count = 0
            for key, foundValue in pairs(value) do
                if count >= 10 then break end
                preview[tostring(SafePreview(key))] = SafePreview(foundValue)
                count += 1
            end
            summary.Preview = preview
        end
        return summary
    end

    local function StructuredFilter(data)
        local filter = {}
        if data.kind == "function" then
            filter.Name = data.name
            filter.Hash = data.hash
            filter.Constants = data.constants
            filter.Upvalues = data.upvalues
            filter.IgnoreExecutor = data.ignoreExecutor ~= false
        else
            filter.Keys = data.keys
            filter.Values = data.values
            filter.KeyValuePairs = data.keyValuePairs
        end

        -- filtergc can only return either every match or its first match. Use
        -- first-result mode so a hostile/large GC cannot make this bridge
        -- retain an unbounded match array.
        local ok, firstMatch = pcall(filtergc, data.kind, filter, true)
        if not ok then return nil, tostring(firstMatch) end
        if data.kind == "function" then
            return type(firstMatch) == "function" and { firstMatch } or {}, nil
        end
        if type(firstMatch) ~= "table" or next(firstMatch) == nil then return {}, nil end
        return { firstMatch }, nil
    end

    local function CompatibilityFilter(data)
        assert(type(getgc) == "function", "Executor supports neither filtergc nor getgc.")
        local ok, values = pcall(getgc, true)
        assert(ok and type(values) == "table", "getgc compatibility fallback failed: " .. tostring(values))

        local scanLimit = math.max(100, math.min(math.floor(tonumber(data.scanLimit) or 10000), 50000))
        local matches = {}
        local matchedCount = 0
        local scanned = 0
        for _, value in ipairs(values) do
            if scanned >= scanLimit then break end
            scanned += 1
            local matchesValue = if data.kind == "function"
                then MatchesFunction(value, data)
                else MatchesTable(value, data)
            if matchesValue then
                matchedCount += 1
                if #matches < 1 then table.insert(matches, value) end
            end
        end
        return matches, scanned, #values > scanLimit, matchedCount
    end

    Bridge:BindToTypeStructured("search-gc", function(data)
        assert(data.kind == "function" or data.kind == "table", "kind must be function or table.")
        local hasCriteria = if data.kind == "function"
            then data.name ~= nil or data.hash ~= nil or (type(data.constants) == "table" and #data.constants > 0) or (type(data.upvalues) == "table" and #data.upvalues > 0)
            else (type(data.keys) == "table" and #data.keys > 0) or (type(data.values) == "table" and #data.values > 0) or (type(data.keyValuePairs) == "table" and next(data.keyValuePairs) ~= nil)
        assert(hasCriteria, "At least one GC search criterion is required.")
        assert(not SearchRunning, "Another search-gc request is already running for this client.")
        SearchRunning = true

        local ok, result = pcall(function()
            local matches
            local fallbackUsed = false
            local structuredError
            local scanned
            local scanTruncated = false
            local matchedCount
            if type(filtergc) == "function" then
                matches, structuredError = StructuredFilter(data)
            end
            if not matches then
                fallbackUsed = true
                matches, scanned, scanTruncated, matchedCount = CompatibilityFilter(data)
            end

            local results = {}
            for _, value in matches do
                local summary = if data.kind == "function"
                    then SummarizeFunction(value)
                    else SummarizeTable(value, data)
                table.insert(results, summary)
            end

            local count = matchedCount or #matches
            local countExact = if fallbackUsed then not scanTruncated else #matches == 0
            return {
                kind = data.kind,
                count = count,
                countIsLowerBound = not countExact,
                limited = if fallbackUsed then scanTruncated or count > 1 else #matches > 0,
                results = results,
                fallbackUsed = fallbackUsed,
                filtergcError = structuredError,
                scanned = scanned,
                scanTruncated = scanTruncated,
                tableEntryScanLimit = CollectionEntryScanMax,
                nativeAllocationNote = if fallbackUsed
                    then "getgc creates an executor-owned full GC snapshot before the bounded scan."
                    else "filtergc runs executor-native traversal in first-result mode; internal traversal allocation is executor-defined.",
            }
        end)
        SearchRunning = false
        if not ok then error(result) end
        return result
    end)
end
