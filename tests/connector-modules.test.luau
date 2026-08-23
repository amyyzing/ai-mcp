local ScriptMappingState = require("../connector-src/mapping/state")
local UploadSession = require("../connector-src/mapping/upload-session")
local DecompilerAttemptState = require("../connector-src/decompiler/attempt-state")
local PreparedScript = require("../connector-src/decompiler/prepared-script")
local WorkerPool = require("../connector-src/utils/worker")
local Concurrency = require("../connector-src/mapping/concurrency")
local JobStatus = require("../connector-src/mapping/job-status")
local FailedResync = require("../connector-src/mapping/failed-resync")
local DecompilerClientFactory = require("../connector-src/decompiler/client")
local HandleRegistry = require("../connector-src/runtime/handles")
local TypedValues = require("../connector-src/runtime/typed-values")
local GcExplorer = require("../connector-src/runtime/gc-explorer")
local CapabilityRegistry = require("../connector-src/runtime/capabilities")
local RegisterRuntimeHandleHandlers = require("../connector-src/bridge/handlers/runtime-handles")

local state = ScriptMappingState.new()
state.configuredWorkers = 24
local firstSession = UploadSession.new("first", 100, 1)
local equalTimestampSession = UploadSession.new("same-time", 100, 2)
assert(equalTimestampSession.startedAt > firstSession.startedAt, "session epochs must be strictly monotonic")
state:Reset("client", firstSession)

local firstJob = state:TrackJob("script-a")
assert(firstJob ~= nil and firstJob.state == "queued")
assert(state:TryStartMapping(firstJob))
assert(not state:TryStartMapping(firstJob), "only one worker may claim a queued job")
assert(not state:CanDeferScanJob(firstJob, state.generation), "active mapping work must survive scan recovery")
state:SetJobState(firstJob, "awaiting_upload")
state:SetJobState(firstJob, "mapped")
assert(state.total == 1 and state.processed == 1 and state.skipped == 0)

local invalidTransitionOk = pcall(function()
    state:SetJobState(firstJob, "queued")
end)
assert(not invalidTransitionOk, "mapped jobs must not transition back to queued")

local capturedSession = state.session
local capturedGeneration = state.generation
local secondSession = UploadSession.new("second", 200, 2)
state:Reset("client", secondSession)
assert(not state:IsActiveSession(capturedSession, capturedGeneration, "client"))
assert(state:IsActiveSession(secondSession, state.generation, "client"))
assert(capturedSession:NextRevision() == 1)
capturedSession:MarkStarted()
assert(not secondSession.started, "an old upload response must not start the new session")
local recoveryJob = state:TrackJob("recovery")
assert(not state:IsFinished(), "mapping cannot finish before the initial scan")
assert(state:CanDeferScanJob(recoveryJob, state.generation))
state:SetJobState(recoveryJob, "awaiting_upload")
assert(not state:CanDeferScanJob(recoveryJob, state.generation))
state.initialScanFinished = true
assert(state:IsFinished(state.total), "projected uploaded sources complete the scan")

local ownerState = ScriptMappingState.new()
local ownerSession = UploadSession.new("owners", 300, 1)
ownerState:Reset("client", ownerSession)
local statusOwner = JobStatus.new(ownerState)
local ownerJob = ownerState:TrackJob("owned-job")
ownerState:SetJobState(ownerJob, "mapping")
ownerState:SetJobState(ownerJob, "awaiting_upload")
assert(statusOwner:MarkMapped("owned-job"))
assert(ownerState.processed == 1 and ownerState.statusDirty)

local concurrencyWorkerLimit
ownerState.workers = {
    SetMaxConcurrent = function(_, limit)
        concurrencyWorkerLimit = limit
    end,
}
local concurrency = Concurrency.new(ownerState, 24)
concurrency:Reduce()
assert(ownerState.currentWorkers == 12 and concurrencyWorkerLimit == 12)
ownerState.successesSinceWorkerAdjustment = 99
concurrency:RecordSuccess()
assert(ownerState.currentWorkers == 13 and concurrencyWorkerLimit == 13)

local retryNow = 100
local retryState = ScriptMappingState.new()
retryState.configuredWorkers = 4
retryState:Reset("retry-client", UploadSession.new("retry", 400, 1))
local failedResync = FailedResync.new(retryState, {
    Clock = function() return retryNow end,
    IntervalSeconds = 30,
    MaxDelaySeconds = 120,
    BatchSize = 1,
})
local retryStatus = JobStatus.new(retryState, failedResync)
local retryJob = retryState:TrackJob("retry-script")
retryJob.initialProviderId = "luaexpert"
retryState:SetJobState(retryJob, "mapping")
assert(retryStatus:MarkFailed("retry-script", "first failure"))
assert(retryJob.nextResyncAt == 130 and retryState.skipped == 1)
assert(#failedResync:GetDue(129) == 0 and failedResync:GetDue(130)[1] == retryJob)

retryNow = 130
assert(failedResync:Claim(retryJob, retryNow))
assert(retryJob.state == "queued" and retryState.skipped == 0)
assert(retryJob.resyncRounds == 1 and retryJob.initialProviderId == "luaexpert")
retryState:SetJobState(retryJob, "mapping")
assert(retryStatus:MarkFailed("retry-script", "second failure"))
assert(retryJob.nextResyncAt == 190, "failed resyncs should back off exponentially")
retryNow = 190
assert(failedResync:Claim(retryJob, retryNow))
retryState:SetJobState(retryJob, "mapping")
retryState:SetJobState(retryJob, "awaiting_upload")
assert(retryStatus:MarkMapped("retry-script"))
assert(retryJob.nextResyncAt == nil and retryJob.resyncRounds == nil)

local cronThread
local cronWaits = {}
local cronTicks = 0
local fakeCronTask = {
    spawn = function(callback)
        cronThread = coroutine.create(callback)
        assert(coroutine.resume(cronThread))
        return cronThread
    end,
    wait = function(seconds)
        table.insert(cronWaits, seconds)
        coroutine.yield()
    end,
}
local cronResync = FailedResync.new(retryState, {
    TaskLibrary = fakeCronTask,
    IntervalSeconds = 15,
})
cronResync:Start(function()
    cronTicks += 1
end)
cronResync:Start(function()
    error("a second cron must not start")
end)
assert(#cronWaits == 1 and cronTicks == 0)
assert(coroutine.resume(cronThread))
assert(#cronWaits == 2 and cronTicks == 1, "the cron should run once per interval")

local batchState = ScriptMappingState.new()
batchState.configuredWorkers = 2
batchState:Reset("batch-client", UploadSession.new("batch", 450, 1))
local batchNow = 500
local batchResync = FailedResync.new(batchState, {
    Clock = function() return batchNow end,
    IntervalSeconds = 30,
    BatchSize = 2,
})
local firstBatchJob = batchState:TrackJob("a-broken")
local secondBatchJob = batchState:TrackJob("b-healthy")
batchState:SetJobState(firstBatchJob, "mapping")
batchState:SetJobState(secondBatchJob, "mapping")
batchState:SetJobState(firstBatchJob, "failed")
batchState:SetJobState(secondBatchJob, "failed")
batchResync:Schedule(firstBatchJob)
batchResync:Schedule(secondBatchJob)
batchNow = 530
local processedBatchJobs = {}
batchResync:ProcessDue(function(job)
    if job == firstBatchJob then error("unreadable script") end
    table.insert(processedBatchJobs, job.debugId)
end, function(job)
    batchResync:Defer(job)
end)
assert(processedBatchJobs[1] == "b-healthy", "one bad script must not starve later failed retries")
assert(firstBatchJob.nextResyncAt == 560)

local RetryOptions = DecompilerClientFactory({})
local ordinaryPrepared = {}
assert(RetryOptions.TakeRetryServerOptions(ordinaryPrepared) == nil)
local retryPrepared = { retryProviderId = "oracle" }
local firstRetryOptions = RetryOptions.TakeRetryServerOptions(retryPrepared)
assert(firstRetryOptions.requestedProvider == "oracle")
assert(retryPrepared.retryProviderId == nil)
assert(RetryOptions.TakeRetryServerOptions(retryPrepared) == nil, "retry preference must be one-shot")

local prepared = { useDirectBuiltin = true }
assert(DecompilerAttemptState.CanAttemptBuiltIn(prepared, 0, 1))
DecompilerAttemptState.MarkBuiltInAttempted(prepared)
assert(not DecompilerAttemptState.CanAttemptBuiltIn(prepared, 0, 1))
DecompilerAttemptState.DisableBuiltIn(prepared)
assert(prepared.builtinDisabled == true and prepared.useDirectBuiltin == false)

local invalidatedDirect = { useDirectBuiltin = true }
assert(not DecompilerAttemptState.CanAttemptBuiltIn(invalidatedDirect, 10, 1))
local bytecodeReads = 0
local fallbackReady = PreparedScript.MaterializeServerFallback(invalidatedDirect, function()
    bytecodeReads += 1
    return true, "server-bytecode"
end)
assert(fallbackReady and bytecodeReads == 1)
assert(invalidatedDirect.bytecode == "server-bytecode")
assert(invalidatedDirect.builtinDisabled == true and invalidatedDirect.useDirectBuiltin == false)
assert(PreparedScript.MaterializeServerFallback(invalidatedDirect, function()
    bytecodeReads += 1
    return false, "must not re-read"
end))
assert(bytecodeReads == 1, "retries must retain materialized bytecode")

local scheduled = {}
local fakeTask = {
    defer = function(callback)
        table.insert(scheduled, callback)
    end,
}
local ran = {}
local pool = WorkerPool.new({
    MaxConcurrent = 1,
    TaskLibrary = fakeTask,
    MainCallback = function(value)
        table.insert(ran, value)
    end,
})
pool:QueueOperation("old")
assert(pool.ActiveWorkers == 1 and #scheduled == 1)
pool:Reset()
pool:QueueOperation("new")
assert(pool.ActiveWorkers == 1 and #scheduled == 1, "reset must retain active capacity")
table.remove(scheduled, 1)()
assert(pool.ActiveWorkers == 1 and #scheduled == 1, "new work starts only after stale work releases capacity")
table.remove(scheduled, 1)()
assert(pool.ActiveWorkers == 0 and ran[1] == "new" and ran[2] == nil)

local handleClock = 10
local handles = HandleRegistry.new({
    RegistryId = "tests",
    MaxHandles = 3,
    DefaultTtlSeconds = 30,
    Clock = function() return handleClock end,
})
local firstObject = { name = "first" }
local firstHandle = handles:Register(firstObject, "table")
assert(string.match(firstHandle, "^rh_tests_1_"))
assert(handles:Resolve(firstHandle) == firstObject)
assert(handles:Register(firstObject, "table") == firstHandle, "the same object must retain one handle")
local handleStats = handles:Stats()
assert(handleStats.active == 1 and handleStats.byKind.table == 1)

local values = TypedValues.new({ Handles = handles, DefaultEntries = 20 })
local cyclic = { answer = 42 }
cyclic.self = cyclic
local encodedCycle = values:Encode(cyclic, { expandTables = true, maxDepth = 4 })
assert(encodedCycle.type == "table" and encodedCycle.handle ~= nil)
local foundReference = false
for _, entry in encodedCycle.entries do
    if entry.value.type == "reference" then foundReference = true end
end
assert(foundReference, "typed tables must preserve cycles as references")

local encodedFunction = values:Encode(function(value) return value + 1 end)
assert(encodedFunction.type == "handle" and encodedFunction.kind == "function")
local decodedFunction = values:Decode({ type = "handle", handle = encodedFunction.handle })
assert(decodedFunction(4) == 5)
assert(values:Decode({ type = "number", special = "positive-infinity" }) == math.huge)
local decodedCycle = values:Decode(encodedCycle)
assert(decodedCycle.self == decodedCycle and decodedCycle.answer == 42, "typed table cycles must round-trip")

local runtimeCallbacks = {}
local fakeBridge = {
    BindToTypeStructured = function(_, name, callback)
        runtimeCallbacks[name] = callback
    end,
}
RegisterRuntimeHandleHandlers({ RuntimeHandles = handles, RuntimeValues = values }, fakeBridge)
local callableHandle = handles:Register(function(first, second) return first + second, nil end, "function")
local callResult = runtimeCallbacks["runtime-call"]({
    handle = callableHandle,
    arguments = {
        { type = "number", value = 2 },
        { type = "number", value = 3 },
    },
})
assert(callResult.success and callResult.resultCount == 2)
assert(callResult.results[1].value == 5 and callResult.results[2].type == "nil")
local unsupportedIdentity = pcall(function()
    runtimeCallbacks["runtime-call"]({ handle = callableHandle, threadIdentity = 7 })
end)
assert(not unsupportedIdentity, "a requested thread identity must not be silently ignored")
local mutableHandle = handles:Register({ value = 1 }, "table")
local writeResult = runtimeCallbacks["runtime-write"]({
    member = "field",
    handle = mutableHandle,
    key = "value",
    value = { type = "number", value = 9 },
})
assert(writeResult.written and writeResult.previous.value == 1)
local readResult = runtimeCallbacks["runtime-read"]({ member = "field", handle = mutableHandle, key = "value" })
assert(readResult.value.value == 9)

local targetObject = { marker = "target" }
local sourceObject = { target = targetObject }
local targetHandle = handles:Register(targetObject, "table", { signature = "target" }, nil, false)
local sourceHandle = handles:Register(sourceObject, "table", { signature = "source" }, nil, false)
local explorer = GcExplorer.new({ Handles = handles, TypedValues = values })
explorer.snapshots.first = {
    snapshotId = "first",
    objects = {
        { handle = targetHandle, kind = "table", summary = { signature = "target", entryCount = 1 } },
        { handle = sourceHandle, kind = "table", summary = { signature = "source", entryCount = 1 } },
    },
    counts = { table = 2 },
}
explorer.snapshots.second = {
    snapshotId = "second",
    objects = {
        { handle = targetHandle, kind = "table", summary = { signature = "target", entryCount = 1 } },
    },
    counts = { table = 1 },
}
explorer.snapshotOrder = { "first", "second" }
local query = explorer:Query({ snapshotId = "first", kind = "table", limit = 10 })
assert(query.totalMatched == 2 and #query.results == 2)
local references = explorer:References({
    snapshotId = "first",
    handle = targetHandle,
    direction = "incoming",
    limit = 10,
})
assert(references.edgeCount == 1 and references.edges[1].from.handle == sourceHandle)
local difference = explorer:Diff({
    beforeSnapshotId = "first",
    afterSnapshotId = "second",
    sampleLimit = 10,
})
assert(difference.removedCount == 1 and difference.removedSample[1].handle == sourceHandle)

local capabilitySnapshot = CapabilityRegistry.new({ ConnectorVersion = "test" }):Probe()
assert(capabilitySnapshot.connectorVersion == "test")
assert(#capabilitySnapshot.capabilities >= 35)
assert(capabilitySnapshot.available + capabilitySnapshot.unavailable == #capabilitySnapshot.capabilities)

handleClock = 100
handles:Sweep()
assert(handles:Stats().lifetime.expired >= 1 and handles:Stats().active == 0, "expired handles must be reclaimed")

print("connector module lifecycle tests passed")
