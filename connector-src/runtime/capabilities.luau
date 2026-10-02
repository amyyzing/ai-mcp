local CapabilityRegistry = {}
CapabilityRegistry.__index = CapabilityRegistry

local function TimestampMillis()
    local ok, value = pcall(function() return DateTime.now().UnixTimestampMillis end)
    return ok and value or os.time() * 1000
end

local function Descriptor(id, available, provider, quality, limits, reason)
    return {
        id = id,
        available = available == true,
        provider = provider,
        quality = available and "best-effort" or "degraded",
        testedAtUnixMs = TimestampMillis(),
        limits = limits,
        degradedReason = if available then nil else (reason or "API is not exposed by this executor."),
        detected = available == true,
        evidence = "presence-only",
        probeExecuted = false,
        behaviorVerified = false,
    }
end

local function IsFunction(value)
    return type(value) == "function"
end

local function FirstFunction(...)
    for _, value in { ... } do
        if IsFunction(value) then return value end
    end
    return nil
end

local function ExecutorIdentity()
    local identify = FirstFunction(identifyexecutor, getexecutorname)
    if not identify then return nil end
    local ok, first, second = pcall(identify)
    if not ok then return { error = tostring(first) } end
    return { name = tostring(first), version = second ~= nil and tostring(second) or nil }
end

function CapabilityRegistry.new(options)
    options = options or {}
    return setmetatable({
        connectorVersion = tostring(options.ConnectorVersion or "1"),
        RequestAvailable = options.RequestAvailable == true,
        HttpRequestProvider = tostring(options.HttpRequestProvider or "unavailable"),
        HttpRequestStatus = options.HttpRequestStatus,
        WebSocketAvailable = options.WebSocketAvailable == true,
        usage = {},
    }, CapabilityRegistry)
end

function CapabilityRegistry:RecordUse(id, provider, success, observed)
    local previous = self.usage[id] or {}
    self.usage[id] = {
        provider = provider, probeExecuted = true, behaviorVerified = observed == true,
        evidence = if observed then "observed-effect" elseif success then "dispatch-returned" else "dispatch-failed",
        lastAttemptAtUnixMs = TimestampMillis(),
        lastSuccessfulUseAtUnixMs = if success then TimestampMillis() else previous.lastSuccessfulUseAtUnixMs,
        currentFailure = if success then nil else "Provider invocation failed.",
    }
end

function CapabilityRegistry:Probe()
    local debugLibrary = type(debug) == "table" and debug or {}
    local httpStatus = self.HttpRequestStatus and self.HttpRequestStatus() or nil
    local descriptors = {
        Descriptor("transport.request", self.RequestAvailable, httpStatus and httpStatus.provider or self.HttpRequestProvider, "best-effort"),
        Descriptor("transport.websocket", self.WebSocketAvailable, "executor-api", "best-effort"),
        Descriptor("script.loadstring", IsFunction(loadstring), "executor-api", "exact"),
        Descriptor("script.decompile", IsFunction(decompile), "executor-api", "best-effort"),
        Descriptor("script.bytecode", IsFunction(getscriptbytecode), "executor-api", "best-effort"),
        Descriptor("script.hash", IsFunction(getscripthash), "executor-api", "best-effort"),
        Descriptor("runtime.gc-snapshot", IsFunction(getgc), "executor-api", "best-effort"),
        Descriptor("runtime.gc-filter", IsFunction(filtergc), "executor-api", "best-effort"),
        Descriptor("runtime.function-hash", IsFunction(getfunctionhash), "executor-api", "best-effort"),
        Descriptor("runtime.function-constants", IsFunction(getconstants) or IsFunction(debugLibrary.getconstants), "executor-api", "best-effort"),
        Descriptor("runtime.function-set-constant", IsFunction(setconstant) or IsFunction(debugLibrary.setconstant), "executor-api", "best-effort"),
        Descriptor("runtime.function-upvalues", IsFunction(getupvalues) or IsFunction(debugLibrary.getupvalues), "executor-api", "best-effort"),
        Descriptor("runtime.function-set-upvalue", IsFunction(setupvalue) or IsFunction(debugLibrary.setupvalue), "executor-api", "best-effort"),
        Descriptor("runtime.function-prototypes", IsFunction(getprotos) or IsFunction(debugLibrary.getprotos), "executor-api", "best-effort"),
        Descriptor("runtime.calling-script", IsFunction(getcallingscript), "executor-api", "best-effort"),
        Descriptor("runtime.executor-closure", IsFunction(isexecutorclosure), "executor-api", "best-effort"),
        Descriptor("runtime.environments", IsFunction(getrenv) or IsFunction(getsenv) or IsFunction(getfenv), "executor-api", "best-effort"),
        Descriptor("runtime.scripts", IsFunction(getscripts), "executor-api", "best-effort"),
        Descriptor("runtime.running-scripts", IsFunction(getrunningscripts), "executor-api", "best-effort"),
        Descriptor("runtime.loaded-modules", IsFunction(getloadedmodules), "executor-api", "best-effort"),
        Descriptor("runtime.nil-instances", IsFunction(getnilinstances), "executor-api", "best-effort"),
        Descriptor("runtime.all-instances", IsFunction(getinstances), "executor-api", "best-effort"),
        Descriptor("runtime.script-closure", IsFunction(getscriptclosure), "executor-api", "best-effort"),
        Descriptor("runtime.thread-identity-read", IsFunction(getthreadidentity) or IsFunction(getidentity) or IsFunction(getthreadcontext), "executor-api", "best-effort"),
        Descriptor("runtime.thread-identity-write", IsFunction(setthreadidentity) or IsFunction(setidentity) or IsFunction(setthreadcontext), "executor-api", "best-effort"),
        Descriptor("signal.connections", IsFunction(getconnections), "executor-api", "best-effort"),
        Descriptor("callback.inspect", IsFunction(getcallbackvalue), "executor-api", "best-effort"),
        Descriptor("property.hidden-read", IsFunction(gethiddenproperty), "executor-api", "best-effort"),
        Descriptor("property.hidden-write", IsFunction(sethiddenproperty), "executor-api", "best-effort"),
        Descriptor("property.scriptable", IsFunction(setscriptable) or IsFunction(isscriptable), "executor-api", "best-effort"),
        Descriptor("hook.function", IsFunction(hookfunction), "executor-api", "best-effort"),
        Descriptor("hook.metamethod", IsFunction(hookmetamethod), "executor-api", "best-effort"),
        Descriptor("hook.namecall-method", IsFunction(getnamecallmethod), "executor-api", "best-effort"),
        Descriptor("hook.raw-metatable", IsFunction(getrawmetatable), "executor-api", "best-effort"),
        Descriptor("hook.new-c-closure", IsFunction(newcclosure), "executor-api", "best-effort"),
        Descriptor("actor.list", IsFunction(getactors), "executor-api", "best-effort"),
        Descriptor("actor.threads", IsFunction(getactorthreads), "executor-api", "best-effort"),
        Descriptor("actor.execute", IsFunction(run_on_actor) or IsFunction(runonactor), "executor-api", "best-effort"),
        Descriptor("input.fire-signal", IsFunction(firesignal), "executor-api", "best-effort"),
        Descriptor("input.fire-prompt", IsFunction(fireproximityprompt), "executor-api", "best-effort"),
        Descriptor("input.fire-click-detector", IsFunction(fireclickdetector), "executor-api", "best-effort"),
        Descriptor("input.fire-touch", IsFunction(firetouchinterest), "executor-api", "best-effort"),
    }

    local byCategory = {}
    local available = 0
    for _, descriptor in descriptors do
        local use = self.usage[descriptor.id]
        if use then for key, value in pairs(use) do descriptor[key] = value end end
        if descriptor.id == "transport.request" and httpStatus and httpStatus.responseValidated then
            descriptor.evidence = "validated-http-response"
            descriptor.probeExecuted = true
            descriptor.behaviorVerified = true
        end
        local category = string.match(descriptor.id, "^([^.]+)") or "other"
        byCategory[category] = byCategory[category] or { available = 0, unavailable = 0 }
        if descriptor.available then
            available += 1
            byCategory[category].available += 1
        else
            byCategory[category].unavailable += 1
        end
        descriptor.connectorVersion = self.connectorVersion
    end

    return {
        executor = ExecutorIdentity(),
        connectorVersion = self.connectorVersion,
        testedAtUnixMs = TimestampMillis(),
        available = available,
        unavailable = #descriptors - available,
        byCategory = byCategory,
        capabilities = descriptors,
        httpTransport = httpStatus,
        providerUses = self.usage,
    }
end

return CapabilityRegistry
