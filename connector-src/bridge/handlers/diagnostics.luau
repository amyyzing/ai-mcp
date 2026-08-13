return function(context, Bridge)
local ScriptMappingPipeline = context.ScriptMappingPipeline

    local function CountJobStates()
        local counts = {}
        for _, job in ScriptMappingPipeline.jobs do
            local state = job.state or "unknown"
            counts[state] = (counts[state] or 0) + 1
        end
        return counts
    end

    local function PendingUploadCount()
        return math.max(0, ScriptMappingPipeline.upload.tail - ScriptMappingPipeline.upload.head + 1)
    end

    Bridge:BindToTypeStructured("runtime-status", function(_data)
        local workerState
        if ScriptMappingPipeline.workers then
            workerState = {
                configured = ScriptMappingPipeline.configuredWorkers,
                currentLimit = ScriptMappingPipeline.currentWorkers,
                active = ScriptMappingPipeline.workers.ActiveWorkers,
                queued = math.max(
                    0,
                    ScriptMappingPipeline.workers.QueueTail - ScriptMappingPipeline.workers.QueueHead + 1
                ),
            }
        end

        return {
            clientId = Bridge.ClientId,
            transport = Bridge.WebSocket and "ws" or "http",
            connected = Bridge.Connected == true,
            place = {
                placeId = game.PlaceId,
                gameId = game.GameId,
                placeVersion = game.PlaceVersion,
                jobId = game.JobId,
            },
            scriptIndex = {
                enabled = ScriptMappingPipeline.disabled ~= true,
                generation = ScriptMappingPipeline.generation,
                initialScanRunning = ScriptMappingPipeline.initialScanRunning,
                initialScanFinished = ScriptMappingPipeline.initialScanFinished,
                scanLimit = ScriptMappingPipeline.scanLimit,
                scanNodeLimit = ScriptMappingPipeline.scanNodeLimit,
                scanTruncated = ScriptMappingPipeline.scanTruncated,
                scanOmitted = ScriptMappingPipeline.scanOmitted,
                scanOmittedIsLowerBound = ScriptMappingPipeline.scanTruncated,
                total = ScriptMappingPipeline.total,
                processed = ScriptMappingPipeline.processed,
                skipped = ScriptMappingPipeline.skipped,
                finished = ScriptMappingPipeline:IsFinished(),
                jobStates = CountJobStates(),
                uploadQueue = {
                    items = PendingUploadCount(),
                    bytes = ScriptMappingPipeline.upload.bytes,
                },
                workers = workerState,
                sourceCache = {
                    entries = ScriptMappingPipeline.sourceCacheEntries,
                    bytes = ScriptMappingPipeline.sourceCacheBytes,
                },
                sourceBudget = {
                    usedBytes = ScriptMappingPipeline.mappedSourceBytes,
                    limitBytes = ScriptMappingPipeline.sourceBudgetBytes,
                },
            },
            capabilities = {
                request = type(request) == "function",
                websocket = context.WebSocketAvailable == true,
                loadstring = type(loadstring) == "function",
                setthreadidentity = type(setthreadidentity) == "function",
                decompile = type(decompile) == "function",
                getscriptbytecode = type(getscriptbytecode) == "function",
                getscripthash = type(getscripthash) == "function",
                filtergc = type(filtergc) == "function",
                getgc = type(getgc) == "function",
                getconstants = type(getconstants) == "function",
                getupvalues = type(getupvalues) == "function",
                getfunctionhash = type(getfunctionhash) == "function",
                firesignal = type(firesignal) == "function",
                fireproximityprompt = type(fireproximityprompt) == "function",
                fireclickdetector = type(fireclickdetector) == "function",
                firetouchinterest = type(firetouchinterest) == "function",
                keypress = type(keypress) == "function",
                keyrelease = type(keyrelease) == "function",
                virtualInputManager = context.VirtualInputManager ~= nil,
                remoteSpyLoaded = getgenv().Cobalt ~= nil,
                remoteSpyProvider = getgenv().Cobalt and (
                    getgenv().Cobalt.__RobloxMcpInternal == true and "bundled" or "external"
                ) or "not_started",
            },
        }
    end)
end
