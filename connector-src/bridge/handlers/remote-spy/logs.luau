local InternalSpy = require("./internal-spy")

return function(_context, Bridge)
    Bridge:BindToType("ensure-remote-spy", function(data)
        local Cobalt, started = InternalSpy.Start()
        local internal = Cobalt.__RobloxMcpInternal == true
        local metadata = internal and Cobalt.shared.McpInternal or nil
        return {
            status = started and "started" or "already_loaded",
            provider = internal and "bundled" or "external",
            message = started
                and "Bundled remote spy started."
                or (internal and "Bundled remote spy is already running." or "External Cobalt remote spy is already running."),
            capabilities = metadata and metadata.capabilities or nil,
            limits = metadata and metadata.limits or nil,
            initialScan = metadata and {
                running = metadata.state.initialScanRunning,
                truncated = metadata.state.initialScanTruncated,
                error = metadata.state.initialScanError,
                incomingConnections = metadata.state.connectionCount,
            } or nil,
        }
    end)

    Bridge:BindToType("get-remote-spy-logs", function(data)
        local Cobalt = getgenv().Cobalt
        assert(Cobalt and Cobalt.shared and Cobalt.shared.Logs, "Cobalt remote spy is not loaded. Call ensure-remote-spy first.")

        local direction = data.direction or "Both"
        local nameFilter = data.remoteNameFilter or ""
        local limit = math.max(1, math.min(tonumber(data.limit) or 10, 100))
        local maxCallsPerRemote = math.max(0, math.min(tonumber(data.maxCallsPerRemote) or 2, 20))
        local summaryOnly = data.summaryOnly == true
        local hasNameFilter = nameFilter ~= ""

        local function ProcessLogs(logTable, directionLabel)
            local results = {}

            for instance, log in logTable do
                if typeof(instance) ~= "Instance" then continue end
                if #results >= limit then break end

                local remoteName = ""
                local remoteClass = ""
                local remotePath = ""
                local remoteDebugId = ""
                pcall(function()
                    remoteName = instance.Name
                    remoteClass = instance.ClassName
                    remotePath = instance:GetFullName()
                end)
                pcall(function() remoteDebugId = instance:GetDebugId() end)

                -- Apply name filter
                if hasNameFilter and not string.find(string.lower(remoteName), string.lower(nameFilter), 1, true) then
                    continue
                end

                -- Get recent calls (raw — LuaEncode handles serialization)
                local recentCalls = {}
                local retainedCalls = #log.Calls
                local totalCalls = tonumber(log.TotalCalls) or retainedCalls
                local startIdx = math.max(1, retainedCalls - maxCallsPerRemote + 1)

                if not summaryOnly then
                    for i = startIdx, retainedCalls do
                        local call = log.Calls[i]
                        if not call then continue end

                        table.insert(recentCalls, {
                            Index = totalCalls - retainedCalls + i,
                            Arguments = call.Arguments,
                            Origin = call.Origin,
                            IsExecutor = call.IsExecutor or false,
                            IsActor = call.IsActor or false,
                            Line = call.Line,
                        })
                    end
                end

                table.insert(results, {
                    RemoteName = remoteName,
                    RemoteClass = remoteClass,
                    RemotePath = remotePath,
                    RemoteDebugId = remoteDebugId,
                    Direction = directionLabel,
                    Method = log.Method,
                    TotalCalls = totalCalls,
                    RetainedCalls = retainedCalls,
                    Ignored = log.Ignored,
                    Blocked = log.Blocked,
                    SupportsBlock = log.SupportsBlock ~= false,
                    RecentCalls = if summaryOnly then nil else recentCalls,
                })
            end

            return results
        end

        local allResults = {}

        if direction == "Outgoing" or direction == "Both" then
            local outgoing = ProcessLogs(Cobalt.shared.Logs.Outgoing, "Outgoing")
            for _, r in outgoing do
                table.insert(allResults, r)
            end
        end

        if direction == "Incoming" or direction == "Both" then
            local incoming = ProcessLogs(Cobalt.shared.Logs.Incoming, "Incoming")
            for _, r in incoming do
                table.insert(allResults, r)
            end
        end

        -- Sort by total calls descending (most active remotes first)
        table.sort(allResults, function(a, b)
            return a.TotalCalls > b.TotalCalls
        end)

        -- Trim to limit
        if #allResults > limit then
            local trimmed = {}
            for i = 1, limit do
                trimmed[i] = allResults[i]
            end
            allResults = trimmed
        end

        return {
            count = #allResults,
            results = allResults
        }
    end)
end
