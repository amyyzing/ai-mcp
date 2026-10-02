local Companion = require("../companions/studio/ServerCompanion")
local requests, serial, encoded, now = {}, 0, {}, 1000
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {} for key, item in pairs(value) do result[key] = copy(item) end return result
end
local disconnected, callback, fail = false, nil, false
local services = { Run = { IsServer = function() return true end }, PlaceId = "123", JobId = "job",
    Now = function() return now end, Spawn = function() end, Wait = function() end,
    Logs = { MessageOut = { Connect = function(_, fn) callback = fn return { Disconnect = function() disconnected = true end } end } },
    Http = {
        GenerateGUID = function() return "test-boot" end,
        JSONEncode = function(_, value) serial += 1 local key = tostring(serial) encoded[key] = copy(value) return key end,
        JSONDecode = function(_, key) return copy(encoded[key]) end,
        RequestAsync = function(_, request)
            if fail then error("network failed") end
            table.insert(requests, copy(request))
            if string.find(request.Url, "/claim", 1, true) then
                encoded.pair = { scope = { kind = "server", placeId = "123", jobId = "job" }, uploadToken = "test-upload-only", expiresAt = 999999 }
                return { Success = true, StatusCode = 200, Body = "pair" }
            end
            encoded.ack = { accepted = true } return { Success = true, StatusCode = 200, Body = "ack" }
        end,
    },
}
local companion = Companion.Start({ Services = services, URL = "https://test.invalid", PairingCode = string.rep("x", 24), CaptureConsole = true,
    Build = "rev1", SourceMap = { ["ServerScriptService.Test"] = { path = "src/test.luau", revision = "rev1" } } })
assert(requests[1].Headers.Authorization == nil)
local state = { phase = "waiting" } companion:State("round", state) state.phase = "changed"
callback("console text", { Name = "MessageWarning" })
local finish = companion:Span("operation", {}) now = 1250 finish({ ok = true }) assert(not finish({}))
assert(companion:Flush())
assert(requests[2].Headers.Authorization == "Bearer test-upload-only")
local batch = encoded[requests[2].Body]
assert(batch.build == "rev1" and batch.placeId == "123" and batch.jobId == "job")
assert(batch.events[3].data.phase == "waiting", "historical state must be copied")
assert(batch.events[4].kind == "console" and batch.events[5].data.durationMs == 250)
for index = 1, 250 do companion:State("bounded", { index = index }) end
assert(companion:Status().queued == 200 and companion:Status().dropped == 50)
fail = true assert(not companion:Flush()) assert(companion:Status().failures == 1)
fail = false assert(companion:Flush()) assert(companion:Status().failures == 0)
companion:Stop() assert(disconnected and companion.token == nil and companion:Status().queued == 0)
assert(not companion:State("late", {}) and not companion:Flush())
services.Run.IsServer = function() return false end
assert(not pcall(Companion.Start, { Services = services, URL = "https://test.invalid", PairingCode = string.rep("x", 24) }))
print("Server companion module tests passed")
