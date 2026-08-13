return function(_context, Bridge)
    local function GetRemoteIdentity(instance)
        local identity = {
            name = "",
            path = "",
            debugId = "",
        }
        pcall(function()
            identity.name = instance.Name
            identity.path = instance:GetFullName()
        end)
        pcall(function() identity.debugId = instance:GetDebugId() end)
        return identity
    end

    local function FindRemoteLog(logTable, data)
        local matches = {}
        for instance, log in logTable do
            if typeof(instance) ~= "Instance" then continue end
            local identity = GetRemoteIdentity(instance)
            local matchesTarget
            if type(data.remoteDebugId) == "string" and data.remoteDebugId ~= "" then
                matchesTarget = identity.debugId == data.remoteDebugId
            elseif type(data.remotePath) == "string" and data.remotePath ~= "" then
                matchesTarget = identity.path == data.remotePath
            else
                matchesTarget = identity.name == data.remoteName
            end

            if matchesTarget then
                table.insert(matches, { instance = instance, log = log, identity = identity })
            end
        end

        if #matches == 0 then
            error("Remote not found in " .. tostring(data.direction) .. " logs. Run remote-spy list again to refresh its identity.")
        end
        if #matches > 1 then
            error("Remote selector is ambiguous (" .. #matches .. " matches). Use remoteDebugId from remote-spy list.")
        end
        return matches[1].log, matches[1].identity
    end

    Bridge:BindToType("clear-remote-spy-logs", function(data)
        local Cobalt = getgenv().Cobalt
        assert(Cobalt and Cobalt.shared and Cobalt.shared.ClearLogs, "Cobalt remote spy is not loaded. Call ensure-remote-spy first.")

        Cobalt.shared.ClearLogs()

        return {
            status = "cleared",
            message = "All remote spy logs have been cleared."
        }
    end)

    Bridge:BindToType("block-remote", function(data)
        local Cobalt = getgenv().Cobalt
        assert(Cobalt and Cobalt.shared and Cobalt.shared.Logs, "Cobalt remote spy is not loaded. Call ensure-remote-spy first.")

        local direction = data.direction
        local shouldBlock = data.shouldBlock

        local logTable = Cobalt.shared.Logs[direction]
        assert(logTable, "Invalid direction: " .. tostring(direction))

        local log, identity = FindRemoteLog(logTable, data)
        if shouldBlock and not log.Blocked then
            log:Block()
        elseif not shouldBlock and log.Blocked then
            log:Block() -- toggles
        end

        return {
            status = "success",
            message = (shouldBlock and "Blocked" or "Unblocked") .. " remote: " .. identity.path,
            remoteName = identity.name,
            remotePath = identity.path,
            remoteDebugId = identity.debugId,
            blocked = log.Blocked
        }
    end)

    Bridge:BindToType("ignore-remote", function(data)
        local Cobalt = getgenv().Cobalt
        assert(Cobalt and Cobalt.shared and Cobalt.shared.Logs, "Cobalt remote spy is not loaded. Call ensure-remote-spy first.")

        local direction = data.direction
        local shouldIgnore = data.shouldIgnore

        local logTable = Cobalt.shared.Logs[direction]
        assert(logTable, "Invalid direction: " .. tostring(direction))

        local log, identity = FindRemoteLog(logTable, data)
        if shouldIgnore and not log.Ignored then
            log:Ignore()
        elseif not shouldIgnore and log.Ignored then
            log:Ignore() -- toggles
        end

        return {
            status = "success",
            message = (shouldIgnore and "Ignoring" or "Unignored") .. " remote: " .. identity.path,
            remoteName = identity.name,
            remotePath = identity.path,
            remoteDebugId = identity.debugId,
            ignored = log.Ignored
        }
    end)

    -- Keep Cobalt's implementation details behind one public MCP operation.
    -- The legacy callbacks above remain internal so this dispatcher can reuse
    -- their validated filtering and state-change behavior.
    Bridge:BindToType("remote-spy", function(data)
        local operation = data.operation
        local ensureResult = Bridge.Callbacks["ensure-remote-spy"]({})
        if operation == "status" then
            local Cobalt = getgenv().Cobalt
            local function CountLogs(logTable)
                local count = 0
                if typeof(logTable) ~= "table" then return count end
                for _ in logTable do
                    count += 1
                end
                return count
            end

            return {
                status = "loaded",
                loaded = true,
                provider = ensureResult.provider,
                capabilities = ensureResult.capabilities,
                limits = ensureResult.limits,
                initialScan = ensureResult.initialScan,
                outgoingRemotes = CountLogs(Cobalt.shared and Cobalt.shared.Logs and Cobalt.shared.Logs.Outgoing),
                incomingRemotes = CountLogs(Cobalt.shared and Cobalt.shared.Logs and Cobalt.shared.Logs.Incoming),
            }
        end

        if operation == "list" then
            return Bridge.Callbacks["get-remote-spy-logs"]({
                direction = data.direction,
                remoteNameFilter = data.nameFilter,
                limit = data.limit,
                maxCallsPerRemote = data.maxCallsPerRemote,
                summaryOnly = data.summaryOnly,
            })
        elseif operation == "clear" then
            return Bridge.Callbacks["clear-remote-spy-logs"]({})
        elseif operation == "block" or operation == "unblock" then
            return Bridge.Callbacks["block-remote"]({
                remoteName = data.remoteName,
                remotePath = data.remotePath,
                remoteDebugId = data.remoteDebugId,
                direction = data.direction,
                shouldBlock = operation == "block",
            })
        elseif operation == "ignore" or operation == "unignore" then
            return Bridge.Callbacks["ignore-remote"]({
                remoteName = data.remoteName,
                remotePath = data.remotePath,
                remoteDebugId = data.remoteDebugId,
                direction = data.direction,
                shouldIgnore = operation == "ignore",
            })
        end

        error("Invalid remote-spy operation: " .. tostring(operation))
    end)
end
