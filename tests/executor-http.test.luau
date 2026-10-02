local ExecutorHttp = require("../connector-src/runtime/executor-http")
local CapabilityRegistry = require("../connector-src/runtime/capabilities")

local function Reject(callback, expected)
    local ok, reason = pcall(callback)
    assert(not ok, "request should fail")
    assert(string.find(tostring(reason), expected, 1, true), tostring(reason))
end

local missing, missingProvider, missingStatus = ExecutorHttp.Resolve({})
assert(missing == nil and missingProvider == "unavailable" and missingStatus().candidates == 0)

local received
local request = ExecutorHttp.Resolve({ http = { request = function(options)
    received = options
    return { status_code = "201", body = "created", headers = { example = "header" } }
end } })
local headers = { authorization = "fixture" }
local input = { url = "https://bridge.test/register", method = "POST", headers = headers, body = "payload" }
local response = request(input)
assert(response.StatusCode == 201 and response.Body == "created" and response.Headers.example == "header")
assert(received.Url == input.url and received.Method == input.method and received.Body == input.body)
assert(received.url == received.Url and received.headers == received.Headers)
assert(received.Headers ~= headers and input.Url == nil, "normalization must not mutate caller-owned options")

local probeUrl = "https://bridge.test"
local firstCalls, secondCalls, thirdCalls = 0, 0, 0
local firstFails, secondFails = true, false
local shared = function(options)
    firstCalls += 1
    options.Url = "mutated"
    options.Headers.authorization = "mutated"
    if firstFails then error("native failure containing a private value") end
    return { StatusCode = 200, Body = "first" }
end
local fallback, initialProvider, status = ExecutorHttp.Resolve({
    request = shared,
    http_request = shared, -- alias must not multiply attempts
    syn = { request = function(options)
        secondCalls += 1
        assert(options.Url == probeUrl or options.Url == probeUrl .. "/register" or options.Url == probeUrl .. "/poll")
        assert(options.Headers.authorization == "fixture")
        if secondFails then error("secondary failure") end
        return { Status = 200, ResponseBody = "second" }
    end },
    fluxus = { request = function()
        thirdCalls += 1
        return { StatusCode = 200, Body = "third" }
    end },
}, { ProbeUrl = probeUrl })
assert(initialProvider == "request" and status().candidates == 3 and not status().responseValidated)
assert(fallback({ Url = probeUrl, Method = "GET", Headers = headers }).Body == "second")
assert(firstCalls == 1 and secondCalls == 1 and thirdCalls == 0)
assert(status().provider == "syn.request" and status().responseValidated and status().failedRequests == 1)
local registry = CapabilityRegistry.new({ RequestAvailable = true, HttpRequestProvider = initialProvider, HttpRequestStatus = status })
local capabilities = registry:Probe()
assert(capabilities.httpTransport.provider == "syn.request")
assert(capabilities.capabilities[1].provider == "syn.request", "capabilities must report the selected fallback, not the initial candidate")
assert(capabilities.capabilities[1].available and capabilities.capabilities[1].quality == "best-effort")
assert(not capabilities.capabilities[2].available and capabilities.capabilities[2].quality == "degraded")
local availableCount, unavailableCount = 0, 0
for _, descriptor in ipairs(capabilities.capabilities) do
    if descriptor.available then
        availableCount += 1
        assert(descriptor.degradedReason == nil, "available APIs must not report an unavailable reason: " .. descriptor.id)
    else
        unavailableCount += 1
        assert(type(descriptor.degradedReason) == "string" and descriptor.degradedReason ~= "",
            "missing APIs must retain their explanation: " .. descriptor.id)
    end
end
assert(capabilities.available == availableCount and capabilities.unavailable == unavailableCount)
fallback({ Url = probeUrl .. "/register", Method = "POST", Headers = headers })
assert(firstCalls == 1 and secondCalls == 2)

secondFails = true
Reject(function() fallback({ Url = probeUrl .. "/register", Method = "POST", Headers = headers }) end, "not replayed")
assert(secondCalls == 3 and thirdCalls == 0, "failed POST must not be sent through another API")
Reject(function() fallback({ Url = probeUrl .. "/poll", Method = "GET", Headers = headers }) end, "not replayed")
assert(secondCalls == 4 and thirdCalls == 0, "poll GET drains commands and must not be blindly retried")
assert(fallback({ Url = probeUrl, Method = "GET", Headers = headers }).Body == "third")
assert(status().provider == "fluxus.request" and thirdCalls == 1)

for _, httpStatus in ipairs({ 401, 403, 429, 500, 503 }) do
    local alternatives = 0
    local denied = ExecutorHttp.Resolve({
        request = function() return { StatusCode = httpStatus, Body = "server response" } end,
        http_request = function() alternatives += 1 return { StatusCode = 200 } end,
    }, { ProbeUrl = probeUrl })
    assert(denied({ Url = probeUrl }).StatusCode == httpStatus and alternatives == 0,
        "a real HTTP rejection/outage is not a provider failure")
end

for _, malformed in ipairs({ false, {}, { StatusCode = 0 }, { StatusCode = 0 / 0 },
    { StatusCode = math.huge }, { StatusCode = 200.5 }, { StatusCode = 600 }, { StatusCode = 200, Body = {} } }) do
    local recover = ExecutorHttp.Resolve({
        request = function() return malformed end,
        http_request = function() return { StatusCode = 204 } end,
    }, { ProbeUrl = probeUrl })
    local recovered = recover({ Url = probeUrl })
    assert(recovered.StatusCode == 204 and recovered.Body == "")
end

local noFallback = ExecutorHttp.Resolve({ request = function() error("private-token-marker") end })
local ok, reason = pcall(noFallback, { Url = probeUrl })
assert(not ok and not string.find(tostring(reason), "private-token-marker", 1, true))
Reject(function() noFallback({ Url = probeUrl }) end, "not replayed")

local allBroken = ExecutorHttp.Resolve({ request = function() return {} end, http_request = function() return {} end }, { ProbeUrl = probeUrl })
Reject(function() allBroken({ Url = probeUrl }) end, "No executor HTTP API")
print("Executor HTTP fallback tests passed")
