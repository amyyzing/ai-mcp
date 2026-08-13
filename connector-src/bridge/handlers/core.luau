return function(context, Bridge)
local LogService = context.LogService

    Bridge:BindToType("execute", function(data)
        setthreadidentity(8)
        local chunk, loadError = loadstring(data.source)
        assert(chunk, "Failed to compile execution source: " .. tostring(loadError))
        chunk()

        return {
            status = "completed",
            operationId = data.operationId or data.id,
            message = "The top-level Luau chunk completed successfully.",
        }
    end)

    Bridge:BindToTypeRaw("get-console-output", function(data)
        local limit = math.max(1, math.min(tonumber(data.limit) or 20, 200))
        local logsOrder = data.logsOrder or "NewestFirst"
        local filter = data.filter
        local hasFilter = typeof(filter) == "string" and filter ~= ""
        local summaryOnly = data.summaryOnly == true

        local logs = LogService:GetLogHistory()
        local results = {}
        local matchedCount = 0
        local countsByLevel = {}
        local scannedCount = 0
        local scanLimited = false
        local MAX_LOG_SCAN = 5000

        local function matchesFilter(logEntry)
            if not hasFilter then return true end
            return string.find(logEntry.message, filter, 1, true) ~= nil
        end

        local MAX_LOG_MESSAGE_CHARS = 500
        local function utf8Prefix(value, maxBytes)
            local parts = {}
            local used = 0
            local ok = pcall(function()
                for _, codepoint in utf8.codes(value) do
                    local character = utf8.char(codepoint)
                    if used + #character > maxBytes then break end
                    table.insert(parts, character)
                    used += #character
                end
            end)
            return ok and table.concat(parts) or string.sub(string.gsub(value, "[^%g ]", "?"), 1, maxBytes)
        end
        local function formatLogMessage(message)
            local output = tostring(message or "")
            if #output > MAX_LOG_MESSAGE_CHARS then
                output = utf8Prefix(output, MAX_LOG_MESSAGE_CHARS)
                    .. "…(+" .. (#output - MAX_LOG_MESSAGE_CHARS) .. " chars omitted)"
            end
            return output
        end

        if logsOrder == "NewestFirst" then
            for i = #logs, 1, -1 do
                if scannedCount >= MAX_LOG_SCAN then scanLimited = true break end
                scannedCount += 1
                local logEntry = logs[i]
                if not matchesFilter(logEntry) then continue end
                
                matchedCount += 1
                local levelName = logEntry.messageType and logEntry.messageType.Name or "Unknown"
                countsByLevel[levelName] = (countsByLevel[levelName] or 0) + 1
                if #results < limit then
                    table.insert(results, logEntry)
                end
            end
        else
            for _, logEntry in logs do
                if scannedCount >= MAX_LOG_SCAN then scanLimited = true break end
                scannedCount += 1
                if not matchesFilter(logEntry) then continue end
                
                matchedCount += 1
                local levelName = logEntry.messageType and logEntry.messageType.Name or "Unknown"
                countsByLevel[levelName] = (countsByLevel[levelName] or 0) + 1
                if #results < limit then
                    table.insert(results, logEntry)
                end
            end
        end

        local outputLines = {}
        if summaryOnly then
            table.insert(outputLines, string.format("Matched %d logs.", matchedCount))
            if scanLimited then table.insert(outputLines, "Log scan capped at 5000 entries.") end
            for levelName, count in countsByLevel do
                table.insert(outputLines, string.format("%s: %d", levelName, count))
            end
            return table.concat(outputLines, "\n")
        end

        table.insert(outputLines, string.format("Displaying %d/%d logs:", #results, matchedCount))
        if scanLimited then table.insert(outputLines, "Log scan capped at 5000 entries.") end

        for _, logEntry in results do
            local levelName = logEntry.messageType and logEntry.messageType.Name or "Unknown"
            table.insert(outputLines, string.format(
                "[%s t=%s] %s",
                levelName, tostring(logEntry.timestamp),
                formatLogMessage(logEntry.message)
            ))
        end

        return table.concat(outputLines, "\n")
    end)

    Bridge:BindToType("get-data-by-code", function(data)
        setthreadidentity(8)
        local dataOutput = table.pack(loadstring(data.source)())

        return dataOutput
    end)
end
