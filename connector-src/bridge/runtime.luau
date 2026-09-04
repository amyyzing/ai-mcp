return function(context)
local CreateBridge = context.CreateBridge
local WaitForBridgeClientId = context.WaitForBridgeClientId
local ScriptMappingPipeline = context.ScriptMappingPipeline
local StartUploadQueue = context.StartUploadQueue
local PublishScriptMappingStatus = context.PublishScriptMappingStatus
local ResetScriptMappingState = context.ResetScriptMappingState
local StartScriptMapping = context.StartScriptMapping
local StartFailedScriptResync = context.StartFailedScriptResync
local ResumeDeferredScriptMappings = context.ResumeDeferredScriptMappings
local ToastHost = context.ToastHost
--// Main Loop \\--
while true do
    local success, Bridge = pcall(CreateBridge)
    
    if not success then
        task.wait(3)
        continue
    end

    local clientId = WaitForBridgeClientId(Bridge)
    if clientId then
        pcall(function()
            ToastHost:ShowConnected(Bridge.WebSocket and "ws" or "http")
        end)
        ScriptMappingPipeline.bridge = Bridge
        StartUploadQueue()

        local mappingStateReset = ScriptMappingPipeline.clientId ~= clientId
        if mappingStateReset then
            ResetScriptMappingState(clientId)
        end

        local initialMappingEnabled = (
            getgenv().EnableInitialScriptDecompMapping == true or
            getgenv().DisableInitialScriptDecompMapping == false
        ) and getgenv().DisableInitialScriptDecompMapping ~= true

        if initialMappingEnabled or (not mappingStateReset and ScriptMappingPipeline.disabled ~= true) then
            StartScriptMapping(clientId)
            StartFailedScriptResync()
            ResumeDeferredScriptMappings()
            PublishScriptMappingStatus()
        else
            ScriptMappingPipeline.clientId = clientId
            ScriptMappingPipeline.disabled = true
            ScriptMappingPipeline.stateVersion += 1
            PublishScriptMappingStatus()
        end
    end

    local registrars = {
        require("./handlers/core"),
        require("./handlers/scripts"),
        require("./handlers/instances"),
        require("./handlers/remote-spy/logs"),
        require("./handlers/remote-spy/control"),
        require("./handlers/input"),
        require("./handlers/diagnostics"),
        require("./handlers/inspect-instance"),
        require("./handlers/dex"),
        require("./handlers/script-index"),
        require("./handlers/search-gc"),
        require("./handlers/runtime-capabilities"),
        require("./handlers/runtime-handles"),
        require("./handlers/runtime-inventory"),
        require("./handlers/runtime-extended"),
        require("./handlers/gc-explorer"),
        require("./handlers/signal-connections"),
        require("./handlers/unified-input"),
        require("./handlers/wait-for-event"),
    }
    local cleanups = {}
    local handlersOk, handlersError = pcall(function()
        for _, registerHandlers in registrars do
            local cleanup = registerHandlers(context, Bridge)
            if type(cleanup) == "function" then table.insert(cleanups, cleanup) end
        end
        Bridge:WaitForDisconnect()
    end)
    for index = #cleanups, 1, -1 do pcall(cleanups[index]) end

    if ScriptMappingPipeline.bridge == Bridge then
        ScriptMappingPipeline.bridge = nil
    end
    if not handlersOk then
        Bridge.Connected = false
        for _, thread in { Bridge.AliveThread, Bridge.PollThread } do
            pcall(task.cancel, thread)
        end
        pcall(function() if Bridge.WebSocket then Bridge.WebSocket:Close() end end)
        error(handlersError, 0)
    end
    task.wait(1)
end
end
