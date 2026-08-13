return function(context, Bridge)
local ScriptMappingPipeline = context.ScriptMappingPipeline
local PublishScriptMappingStatus = context.PublishScriptMappingStatus
local ResetScriptMappingState = context.ResetScriptMappingState
local StartScriptMapping = context.StartScriptMapping
local StartFailedScriptResync = context.StartFailedScriptResync
local ResumeDeferredScriptMappings = context.ResumeDeferredScriptMappings

    local function CountJobStates()
        local counts = {}
        for _, job in ScriptMappingPipeline.jobs do
            local state = job.state or "unknown"
            counts[state] = (counts[state] or 0) + 1
        end
        return counts
    end

    local function Status(action)
        local workers = ScriptMappingPipeline.workers
        return {
            action = action,
            enabled = ScriptMappingPipeline.disabled ~= true,
            generation = ScriptMappingPipeline.generation,
            sessionId = ScriptMappingPipeline.session and ScriptMappingPipeline.session.id or nil,
            mappingRevision = ScriptMappingPipeline.session and ScriptMappingPipeline.session.revision or nil,
            initialScanRunning = ScriptMappingPipeline.initialScanRunning,
            initialScanFinished = ScriptMappingPipeline.initialScanFinished,
            scanLimit = ScriptMappingPipeline.scanLimit,
            scanNodeLimit = ScriptMappingPipeline.scanNodeLimit,
            scanTruncated = ScriptMappingPipeline.scanTruncated,
            scanOmitted = ScriptMappingPipeline.scanOmitted,
            scanOmittedIsLowerBound = ScriptMappingPipeline.scanTruncated,
            finished = ScriptMappingPipeline:IsFinished(),
            total = ScriptMappingPipeline.total,
            processed = ScriptMappingPipeline.processed,
            skipped = ScriptMappingPipeline.skipped,
            jobStates = CountJobStates(),
            workers = workers and {
                configured = ScriptMappingPipeline.configuredWorkers,
                currentLimit = ScriptMappingPipeline.currentWorkers,
                active = workers.ActiveWorkers,
                queued = math.max(0, workers.QueueTail - workers.QueueHead + 1),
            } or nil,
            uploadQueue = {
                items = math.max(
                    0,
                    ScriptMappingPipeline.upload.tail - ScriptMappingPipeline.upload.head + 1
                ),
                bytes = ScriptMappingPipeline.upload.bytes,
            },
            sourceCache = {
                entries = ScriptMappingPipeline.sourceCacheEntries,
                bytes = ScriptMappingPipeline.sourceCacheBytes,
            },
            sourceBudget = {
                usedBytes = ScriptMappingPipeline.mappedSourceBytes,
                limitBytes = ScriptMappingPipeline.sourceBudgetBytes,
            },
        }
    end

    local function ClientId()
        local clientId = Bridge.ClientId or ScriptMappingPipeline.clientId
        assert(type(clientId) == "string" and clientId ~= "", "Bridge client registration is not ready.")
        return clientId
    end

    local function StartFresh(action)
        local clientId = ClientId()
        ResetScriptMappingState(clientId)
        StartScriptMapping(clientId)
        StartFailedScriptResync()
        ResumeDeferredScriptMappings()
        PublishScriptMappingStatus()
        return Status(action)
    end

    Bridge:BindToTypeStructured("script-index-status", function(_data)
        return Status("status")
    end)

    Bridge:BindToTypeStructured("script-index-start", function(_data)
        if ScriptMappingPipeline.disabled then
            return StartFresh("started")
        end

        if not ScriptMappingPipeline.initialScanRunning and not ScriptMappingPipeline.initialScanFinished then
            local clientId = ClientId()
            StartScriptMapping(clientId)
            StartFailedScriptResync()
            ResumeDeferredScriptMappings()
            PublishScriptMappingStatus()
            return Status("started")
        end

        return Status("already_active")
    end)

    Bridge:BindToTypeStructured("script-index-stop", function(_data)
        if ScriptMappingPipeline.disabled then
            return Status("already_stopped")
        end

        local clientId = ClientId()
        -- Reset invalidates active worker generations, clears pending work and
        -- disconnects the DescendantAdded watcher. Marking the fresh session
        -- disabled then publishes an authoritative empty/completed index.
        ResetScriptMappingState(clientId)
        ScriptMappingPipeline.disabled = true
        ScriptMappingPipeline.stateVersion += 1
        PublishScriptMappingStatus()
        return Status("stopped")
    end)

    Bridge:BindToTypeStructured("script-index-resync", function(_data)
        return StartFresh("resync_started")
    end)
end
