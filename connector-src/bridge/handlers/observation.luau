local Session = require("../../observation/session")

return function(context, Bridge)
    local session = Session.new(context, Bridge)
    local api = {
        Version = 1,
        Emit = function(_, name, value) session:Emit("diagnostic:" .. tostring(name), value) end,
        SetBuild = function(_, manifest)
            assert(type(manifest) == "table" and #session.http:JSONEncode(manifest) < 8000, "Build manifest must fit 8000 bytes.")
            session.build = session.http:JSONDecode(session.http:JSONEncode(manifest))
        end,
        RegisterState = function(_, name, callback)
            assert(type(name) == "string" and #name <= 100 and type(callback) == "function", "Provide a state name and callback.")
            local count = 0 for _ in pairs(session.instrumentedStates) do count += 1 end
            assert(count < 16 or session.instrumentedStates[name], "At most 16 named state exports.")
            session.instrumentedStates[name] = callback
            return function() session.instrumentedStates[name] = nil end
        end,
    }
    getgenv().MCPDiagnostics = api
    local function bind(name, callback) Bridge:BindToTypeStructured(name, callback) end
    bind("observe", function(data) return session:Observe(data) end)
    bind("observation-read", function(data) return session:Read(data.observationId) end)
    bind("console-read", function(data) return session:ReadConsole(data) end)
    bind("gui-query", function(data) return session:GuiQuery(data) end)
    bind("gui-inspect", function(data) return session:GuiRecord(session.inspector:Resolve(data.target)) end)
    bind("gui-hit-test", function(data) return session:HitTest(data.x, data.y) end)
    for _, kind in ipairs({ "activate", "set-text" }) do
        bind("gui-" .. kind, function(data) data.kind = kind return session:StartAction(data) end)
    end
    bind("cursor-state", function() return { sessionId = session.id, clientId = Bridge.ClientId, cursor = context.InputController:State(), geometry = session:Geometry(), activeActionId = session.activeAction } end)
    for _, kind in ipairs({ "move", "click", "drag" }) do
        bind("cursor-" .. kind, function(data) data.kind = kind return session:StartAction(data) end)
    end
    for _, name in ipairs({ "input-sequence", "scenario-run" }) do
        bind(name, function(data) data.kind = "sequence" return session:StartAction(data) end)
    end
    for _, name in ipairs({ "action-status", "scenario-status" }) do
        bind(name, function(data) local action = session.actions[data.actionId] assert(action, "Action expired or connection changed.") return action end)
    end
    for _, name in ipairs({ "action-cancel", "scenario-cancel" }) do bind(name, function(data) return session:Cancel(data.actionId) end) end
    bind("observation-events", function(data)
        local page = session.journal:Read(data.cursor or 0, math.clamp(data.limit or 20, 1, 50))
        page.sessionId = session.id
        return page
    end)
    bind("observation-coverage", function()
        return { sessionId = session.id, scope = "client", atomic = false, profiles = { "ui-debug", "gameplay-debug", "performance" },
            collectors = { gui = "bounded PlayerGui", world = "bounded nearby parts", player = "local character", camera = "current camera",
                console = "events since connection", input = "observed input events", dex = "explicit active watches", diagnostics = "named project events" },
            unavailable = { "server-only state", "streamed-out instances", "historical source without a build manifest" },
            journal = session.journal:Read(session.journal.last, 1) }
    end)
    bind("collector-status", function()
        local exports = {} for name in pairs(session.instrumentedStates) do table.insert(exports, name) end
        return { sessionId = session.id, connected = Bridge.Connected, stateExports = exports, build = session.build,
            eventCounters = session.journal:Read(session.journal.last, 1), observationCount = #session.order, activeActionId = session.activeAction }
    end)
    bind("diagnostic-state", function(data)
        local callback = session.instrumentedStates[data.name] assert(callback, "Named state is not registered.")
        local done, ok, value = false, false, nil
        local worker = task.spawn(function() ok, value = pcall(callback) done = true end)
        local deadline = os.clock() + 2
        while not done and os.clock() < deadline and not session.closed do task.wait(.02) end
        if not done then pcall(task.cancel, worker) error("Named state callback timed out or disconnected.") end
        assert(ok, "Named state callback failed.")
        session:Emit("state:" .. data.name, value)
        return session.journal:Read(session.journal.last - 1, 1)
    end)
    return function()
        session:Destroy()
        if getgenv().MCPDiagnostics == api then getgenv().MCPDiagnostics = nil end
    end
end
