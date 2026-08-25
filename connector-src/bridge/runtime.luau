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
    for _, registerHandlers in registrars do
        registerHandlers(context, Bridge)
    end

    Bridge:WaitForDisconnect()

    if ScriptMappingPipeline.bridge == Bridge then
        ScriptMappingPipeline.bridge = nil
    end
    task.wait(1)
end
end
