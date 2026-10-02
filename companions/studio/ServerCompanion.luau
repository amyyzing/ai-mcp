-- Install as a ModuleScript in ServerScriptService in a project you control.
-- No client remotes, arbitrary commands, source reads or replicated credentials.
local Companion = {}
Companion.__index = Companion

local function clip(value, maximum)
    local text = tostring(value)
    if #text <= maximum then return text end
    local boundary = maximum
    while boundary > 0 and string.byte(text, boundary + 1) and string.byte(text, boundary + 1) >= 128 and string.byte(text, boundary + 1) < 192 do boundary -= 1 end
    return string.sub(text, 1, boundary)
end

function Companion.Start(options)
    assert(type(options) == "table", "Companion options are required")
    local services = options.Services or {
        Http = game:GetService("HttpService"), Run = game:GetService("RunService"), Logs = game:GetService("LogService"),
        PlaceId = tostring(game.PlaceId), JobId = if game.JobId ~= "" then game.JobId else "studio",
        Now = function() return DateTime.now().UnixTimestampMillis end, Spawn = task.spawn, Wait = task.wait,
    }
    assert(services.Run:IsServer(), "Server companion must run on the project server")
    assert(type(options.URL) == "string" and string.match(options.URL, "^https://[%w%.%-]+[:%d]*/?[%w%-%._/]*$"), "An HTTPS endpoint without query credentials is required")
    assert(type(options.PairingCode) == "string" and #options.PairingCode >= 20, "Create a server pairing with companion-pair")
    local self = setmetatable({ services = services, url = string.gsub(options.URL, "/+$", ""), queue = {}, bytes = 0,
        sequence = 0, dropped = 0, failures = 0, stopped = false, busy = false, build = clip(options.Build or "unknown", 200), connections = {},
        interval = math.clamp(options.IntervalSeconds or 3, 2, 30) }, Companion)
    local pair = self:Request("/companion/claim", { pairingCode = options.PairingCode, label = clip(options.Label or "Roblox project server", 100),
        bootId = services.Http:GenerateGUID(false), deviceUnixMs = services.Now() })
    assert(pair.scope.kind == "server" and pair.scope.placeId == services.PlaceId and (not pair.scope.jobId or pair.scope.jobId == services.JobId), "Pairing scope does not match this project")
    self.token = pair.uploadToken self.expiresAt = pair.expiresAt
    if options.CaptureConsole == true then
        table.insert(self.connections, services.Logs.MessageOut:Connect(function(message, level)
            self:Emit("console", tostring(level.Name), { text = clip(message, 2000), level = level.Name })
        end))
    end
    if options.SourceMap then self:SetSourceMap(options.SourceMap) end
    self:Emit("event", "companion-started", { placeId = services.PlaceId, jobId = services.JobId, build = self.build })
    services.Spawn(function()
        while not self.stopped do
            services.Wait(self.interval * math.min(8, 2 ^ self.failures))
            if self.stopped then break end
            if services.Now() >= self.expiresAt then self:Stop() break end
            self:Flush()
        end
    end)
    return self
end

function Companion:Request(route, payload)
    local headers = { ["Content-Type"] = "application/json" }
    if self.token then headers.Authorization = "Bearer " .. self.token end
    local response = self.services.Http:RequestAsync({ Url = self.url .. route, Method = "POST", Headers = headers, Body = self.services.Http:JSONEncode(payload) })
    assert(response.Success and response.StatusCode == 200, "Companion request was rejected")
    assert(#response.Body < 16000, "Companion response exceeded its limit")
    return self.services.Http:JSONDecode(response.Body)
end

function Companion:Emit(kind, name, data)
    if self.stopped then return false end
    assert(({ console = true, state = true, span = true, event = true, ["source-map"] = true, gap = true })[kind], "Unsupported event kind")
    local event = { kind = kind, name = clip(name, 160), atUnixMs = self.services.Now(), data = data }
    local ok, json = pcall(self.services.Http.JSONEncode, self.services.Http, event)
    if not ok or #json > 8000 then self.dropped += 1 return false end
    -- Round trip now: historical state must not retain caller-owned mutable tables.
    local copied = self.services.Http:JSONDecode(json)
    table.insert(self.queue, { event = copied, bytes = #json }) self.bytes += #json
    while #self.queue > 200 or self.bytes > 128000 do local removed = table.remove(self.queue, 1) self.bytes -= removed.bytes self.dropped += 1 end
    return true
end

function Companion:State(name, value) return self:Emit("state", name, value) end
function Companion:SetBuild(build) self.build = clip(build, 200) end
function Companion:SetSourceMap(mapping)
    local count = 0
    for sourcePath, revision in pairs(mapping) do
        count += 1 if count > 200 then self.dropped += 1 break end
        self:Emit("source-map", sourcePath, revision)
    end
end
function Companion:Span(name, data)
    local started = self.services.Now() local ended = false
    return function(result)
        if ended then return false end ended = true
        return self:Emit("span", name, { startedAtUnixMs = started, durationMs = self.services.Now() - started, input = data, result = result })
    end
end

function Companion:Flush()
    if self.stopped or self.busy then return false end
    self.busy = true
    local events, size = {}, 0
    if self.dropped > 0 then
        table.insert(events, { kind = "gap", name = "dropped-events", atUnixMs = self.services.Now(), data = { count = self.dropped } }) self.dropped = 0
    end
    while #self.queue > 0 and #events < 50 do
        local nextEvent = self.queue[1]
        if size + nextEvent.bytes > 48000 then break end
        table.remove(self.queue, 1) self.bytes -= nextEvent.bytes size += nextEvent.bytes table.insert(events, nextEvent.event)
    end
    self.sequence += 1
    local ok = pcall(self.Request, self, "/companion/telemetry", { sequence = self.sequence, capturedAtUnixMs = self.services.Now(),
        placeId = self.services.PlaceId, jobId = self.services.JobId, build = self.build, events = events })
    if not ok then self.dropped += #events self.failures = math.min(8, self.failures + 1) else self.failures = 0 end
    self.busy = false
    -- A failed/timed-out batch has uncertain delivery. Report the gap instead of duplicating it.
    return ok
end
function Companion:Status() return { stopped = self.stopped, queued = #self.queue, dropped = self.dropped, failures = self.failures, sequence = self.sequence, build = self.build } end
function Companion:Stop()
    if self.stopped then return end self.stopped = true
    for _, connection in ipairs(self.connections) do connection:Disconnect() end
    self.connections = {} self.queue = {} self.bytes = 0 self.token = nil
end
return Companion
