local InstancePath = require("../instance-path")

return function(context, Bridge)
local ScriptMappingPipeline = context.ScriptMappingPipeline
local GetScriptByDebugId = context.GetScriptByDebugId
local DecompileScriptSource = context.DecompileScriptSource
local QueueMappedScriptSource = context.QueueMappedScriptSource

    Bridge:BindToTypeRaw("get-script-content", function(data)
        local source
        local scriptInstance

        --// Handle GC'd script proxies directly because they have no live path. \\--
        if data.debugId then
            scriptInstance = GetScriptByDebugId(data.debugId)
            assert(scriptInstance, "No live script instance found for ScriptProxy with DebugId: " .. tostring(data.debugId))
        elseif data.target then
            scriptInstance = InstancePath.Resolve(data.target)
        else
            error("Provide a strict instance target or script debugId.")
        end

        assert(typeof(scriptInstance) == "Instance", "Script instance is not an instance.")
        assert(scriptInstance:IsA("LuaSourceContainer"), "Script instance is not a LuaSourceContainer (Script, LocalScript, or ModuleScript).")
        assert(not (
            scriptInstance.ClassName == "Script" and
            scriptInstance.RunContext ~= Enum.RunContext.Client
        ), "Script instance is a server-only Script.")

        local scriptHash
        source, _, scriptHash = DecompileScriptSource(
            scriptInstance,
            nil,
            ScriptMappingPipeline.generation,
            ScriptMappingPipeline.clientId
        )
        assert(source, "Failed to decompile script.")
        assert(#source <= 2 * 1024 * 1024, "Decompiled source exceeds the 2 MiB read limit.")

        local debugId = scriptInstance:GetDebugId()
        local mappingJob = ScriptMappingPipeline.jobs[debugId]
        if ScriptMappingPipeline.clientId and (not mappingJob or mappingJob.state ~= "mapped") then
            QueueMappedScriptSource(
                scriptInstance,
                source,
                scriptHash,
                ScriptMappingPipeline.generation,
                debugId
            )
        end

        --// Line range support with bounded default preview \\--
        local totalLines = 1
        local scanPosition = 1
        while true do
            local newlinePosition = source:find("\n", scanPosition, true)
            if not newlinePosition then break end
            totalLines += 1
            scanPosition = newlinePosition + 1
        end
        local maxLines = math.max(1, math.min(tonumber(data.maxLines) or 200, 2000))
        local startLine = data.startLine and math.max(1, math.min(data.startLine, totalLines)) or 1
        local requestedEndLine = data.endLine and math.max(startLine, math.min(data.endLine, totalLines)) or totalLines
        local endLine = math.min(requestedEndLine, startLine + maxLines - 1)

        local sliced = {}
        local lineNumber = 1
        local lineStart = 1
        while lineNumber <= endLine do
            local newlinePosition = source:find("\n", lineStart, true)
            local lineEnd = newlinePosition and newlinePosition - 1 or #source
            if lineNumber >= startLine then
                table.insert(sliced, source:sub(lineStart, lineEnd))
            end
            if not newlinePosition then break end
            lineStart = newlinePosition + 1
            lineNumber += 1
        end

        local footer = ""
        if endLine < requestedEndLine then
            footer = "\n-- Output truncated to " .. maxLines .. " lines. Rerun with startLine=" .. (endLine + 1) .. " or a tighter range to continue."
        end

        return "-- Lines " .. startLine .. "-" .. endLine .. " of " .. totalLines .. "\n" .. table.concat(sliced, "\n") .. footer
    end)
end
