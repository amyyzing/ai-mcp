local Journal = require("./journal")
local Session = {}
Session.__index = Session
local function now() return os.clock() * 1000 end
local function safe(callback) local ok, value = pcall(callback) return if ok then value else nil end
local function xy(v) return { x = v.X, y = v.Y } end
local function xyz(v) return { x = v.X, y = v.Y, z = v.Z } end
local function short(text, limit)
    if #text <= limit then return text end
    local ok, boundary = pcall(utf8.offset, text, 0, limit + 1)
    return if ok and boundary then string.sub(text, 1, boundary - 1) else string.sub(string.gsub(text, "[^%g ]", "?"), 1, limit)
end

function Session.new(context, bridge)
    local http = game:GetService("HttpService")
    local self = setmetatable({ context = context, bridge = bridge, http = http,
        id = http:GenerateGUID(false), observations = {}, order = {}, actions = {}, actionOrder = {},
        connections = {}, geometryRevision = 0, geometrySignature = "", closed = false,
        journal = Journal.new(1000, function(value) return #http:JSONEncode(value) end),
        instrumentedStates = {}, build = {}, activeAction = nil, focused = context.IsInputFocused(),
        controller = context.InputController, dispatchInput = context.DispatchInput }, Session)
    self.uis, self.gui = game:GetService("UserInputService"), game:GetService("GuiService")
    self.playerGui = context.Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    self.inspector = context.DexInspector
    local function connect(signal, callback) table.insert(self.connections, signal:Connect(callback)) end
    connect(self.uis.InputBegan, function(input, processed)
        self:Emit("input-began", { key = input.KeyCode.Name, inputType = input.UserInputType.Name, position = xy(input.Position), processed = processed })
    end)
    connect(self.uis.InputEnded, function(input) self:Emit("input-ended", { key = input.KeyCode.Name, inputType = input.UserInputType.Name }) end)
    connect(self.uis.WindowFocusReleased, function()
        self.focused = false
        if self.activeAction and self.actions[self.activeAction].desktopInput then self:Cancel(self.activeAction, "desktop-input-focus-lost") end
    end)
    connect(self.uis.WindowFocused, function() self.focused = true end)
    connect(context.LogService.MessageOut, function(message, kind)
        self:Emit("console", { text = short(message, 450), level = kind.Name, source = "LogService.MessageOut", observedAtUnixMs = DateTime.now().UnixTimestampMillis })
    end)
    local history = safe(function() return context.LogService:GetLogHistory() end) or {}
    for index = math.max(1, #history - 199), #history do
        local row = history[index]
        self:Emit("console", { text = short(tostring(row.message or ""), 450), level = row.messageType and row.messageType.Name or "Unknown",
            source = "LogService.GetLogHistory", timestamp = row.timestamp, historical = true })
    end
    context.ObservationSink = function(kind, data) self:Emit(kind, data) end
    return self
end

function Session:ReadConsole(data)
    local cursor, rows, scanned = data.cursor or 0, {}, 0
    local gap = cursor < self.journal.first - 1
    while cursor < self.journal.last and #rows < (data.limit or 10) and scanned < 500 do
        local page = self.journal:Read(cursor, 1)
        cursor = page.nextCursor scanned += 1
        local event = page.events[1]
        if event and event.kind == "console" then
            local entry = event.data
            if (not data.level or entry.level == data.level) and (not data.contains or string.find(string.lower(entry.text or ""), string.lower(data.contains), 1, true)) then
                table.insert(rows, { sequence = event.sequence, atMonotonicMs = event.atMonotonicMs, entry = entry })
            end
        end
    end
    return { sessionId = self.id, clientId = self.bridge.ClientId, entries = rows, nextCursor = cursor,
        latestCursor = self.journal.last, gap = gap, dropped = self.journal.dropped, complete = cursor >= self.journal.last,
        coverage = "Roblox client LogService only; executor-private console entries may not be exposed." }
end

function Session:Emit(kind, data)
    if self.closed then return end
    -- Most callers provide copied scalar metadata. Never preserve raw Instances in history.
    local ok, encoded = pcall(function() return self.http:JSONEncode(data) end)
    self.journal:Push(string.sub(tostring(kind), 1, 100), if ok and #encoded <= 16000 then self.http:JSONDecode(encoded) else { omitted = true, reason = "non-JSON or oversized event" }, now())
end

function Session:Identity(instance)
    if not instance then return nil end
    return safe(function() return self.inspector:Describe(instance) end)
end

function Session:Geometry()
    local camera = workspace.CurrentCamera
    local viewport = if camera then xy(camera.ViewportSize) else { x = 0, y = 0 }
    local inset = safe(function() local a, b = self.gui:GetGuiInset() return { topLeft = xy(a), bottomRight = xy(b) } end)
    local signature = self.http:JSONEncode({ viewport, inset })
    if signature ~= self.geometrySignature then self.geometryRevision += 1 self.geometrySignature = signature end
    return { viewport = viewport, guiInset = inset, revision = self.geometryRevision,
        coordinateSpace = "roblox-screen", focused = self.focused,
        mouseBehavior = tostring(self.uis.MouseBehavior), camera = self:Identity(camera) }
end

function Session:GuiRecord(instance)
    local row = self:Identity(instance)
    if not row then return nil end
    row.bounds = safe(function() return { position = xy(instance.AbsolutePosition), size = xy(instance.AbsoluteSize) } end)
    row.visible = safe(function() return instance.Visible end)
    row.text = safe(function() return short(instance.Text, 450) end)
    row.textSource = if row.text then "gui-property" else nil
    row.active = safe(function() return instance.Active end)
    row.interactable = safe(function() return instance.Interactable end)
    row.backgroundTransparency = safe(function() return instance.BackgroundTransparency end)
    row.interactive = instance:IsA("GuiButton") or instance:IsA("TextBox")
    row.zIndex = instance.ZIndex
    row.canvasPosition = safe(function() return xy(instance.CanvasPosition) end)
    local parent, visible, depth = instance, true, 0
    while parent and depth < 64 do
        if parent:IsA("GuiObject") and not parent.Visible then visible = false end
        if parent:IsA("LayerCollector") and not parent.Enabled then visible = false end
        parent, depth = parent.Parent, depth + 1
    end
    row.effectiveVisible = if not visible then false elseif parent == nil then true else nil
    return row
end

function Session:GuiQuery(data)
    local root = if data.target then self.inspector:Resolve(data.target) else self.playerGui
    assert(root, "PlayerGui is unavailable.")
    local limit, visited, rows = math.clamp(data.limit or 20, 1, 50), 0, {}
    local stack = { { nodes = { root }, index = 1 } }
    while #stack > 0 and visited < (data.scanBudget or 500) and #rows < limit do
        local frame = stack[#stack]
        local item = frame.nodes[frame.index]
        frame.index += 1
        if not item then table.remove(stack) continue end
        visited += 1
        if item:IsA("GuiObject") then
            local row = safe(function() return self:GuiRecord(item) end)
            if row and (not data.interactiveOnly or row.interactive) and (not data.visibleOnly or row.effectiveVisible == true)
                and (not data.text or string.find(string.lower((row.text or "") .. " " .. (row.Name or "")), string.lower(data.text), 1, true)) then
                table.insert(rows, row)
            end
        end
        if #stack < 64 then
            local children = safe(function() return item:GetChildren() end)
            if children and #children > 0 then table.insert(stack, { nodes = children, index = 1 }) end
        end
    end
    return { results = rows, visited = visited, complete = #stack == 0,
        continuation = if #stack > 0 then "Use dex-query for a resumable full inventory." else nil }
end

function Session:HitTest(x, y)
    local hits = {}
    local coreOk, core = pcall(function() return game:GetService("CoreGui"):GetGuiObjectsAtPosition(x, y) end)
    local player = self.playerGui and self.playerGui:GetGuiObjectsAtPosition(x, y) or {}
    for _, group in ipairs({ if coreOk then core else {}, player }) do
        for _, item in ipairs(group) do
            if item ~= self.requestedDot and item ~= self.observedDot and #hits < 25 then table.insert(hits, self:GuiRecord(item)) end
        end
    end
    return { x = x, y = y, coordinateSpace = "roblox-screen", hits = hits, coreGuiChecked = coreOk }
end

function Session:Observe(data)
    assert(not self.closed and self.bridge.Connected, "Observation connection closed.")
    local started, geometry = now(), self:Geometry()
    local observation = { observationId = "obs_" .. self.http:GenerateGUID(false), sessionId = self.id,
        clientId = self.bridge.ClientId, connectorGeneration = self.context.RuntimeHandles.generation,
        placeId = game.PlaceId, jobId = game.JobId,
        registryId = self.context.RuntimeHandles.registryId, scope = "client", geometryRevision = geometry.revision,
        geometry = geometry, collectionStartedAtMs = started, observedAtUnixMs = DateTime.now().UnixTimestampMillis,
        cursor = self.controller:State(), focusedTextBox = self:Identity(self.uis:GetFocusedTextBox()),
        selectedObject = self:Identity(self.gui.SelectedObject), warnings = { "Collection is non-atomic and covers client-visible state." },
        profile = data.profile or "ui-debug", build = table.clone(self.build) }
    if observation.profile == "ui-debug" then observation.interface = self:GuiQuery({ limit = data.limit or 10, visibleOnly = true }) end
    local camera = workspace.CurrentCamera
    if camera then observation.camera = { position = xyz(camera.CFrame.Position), look = xyz(camera.CFrame.LookVector), fieldOfView = camera.FieldOfView } end
    local character = self.context.Players.LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    observation.player = { character = self:Identity(character), health = humanoid and humanoid.Health,
        state = humanoid and tostring(humanoid:GetState()), position = root and xyz(root.Position), velocity = root and xyz(root.AssemblyLinearVelocity) }
    if observation.profile == "gameplay-debug" and root then
        local params = OverlapParams.new() params.MaxParts = data.limit or 20
        local nearby = workspace:GetPartBoundsInRadius(root.Position, data.radius or 30, params)
        observation.nearby = {}
        for _, part in ipairs(nearby) do table.insert(observation.nearby, { entity = self:Identity(part), position = xyz(part.Position), velocity = xyz(part.AssemblyLinearVelocity) }) end
    end
    observation.events = self.journal:Read(data.sinceCursor or self.journal.last, 10)
    observation.collectionFinishedAtMs = now()
    observation.collectionDurationMs = observation.collectionFinishedAtMs - started
    observation.latestEventSequence = self.journal.last
    self.observations[observation.observationId] = observation
    table.insert(self.order, observation.observationId)
    if #self.order > 40 then self.observations[table.remove(self.order, 1)] = nil end
    return observation
end

function Session:Read(id)
    local row = self.observations[id]
    assert(row, "Observation expired or belongs to another connection.")
    return row
end

function Session:ValidateObservation(id)
    local observation = self:Read(id)
    local geometry = self:Geometry()
    assert(geometry.revision == observation.geometryRevision, "Geometry changed; observe again before input.")
    assert(now() - observation.collectionFinishedAtMs < 30000, "Observation is stale; observe again.")
    return geometry
end

function Session:Point(data)
    local geometry = self:ValidateObservation(data.observationId)
    if data.target then
        local target = self.inspector:Resolve(data.target)
        assert(target:IsA("GuiObject"), "Pointer target must be a GuiObject.")
        local row = self:GuiRecord(target)
        assert(row.effectiveVisible == true, "Target visibility is unavailable or hidden.")
        local left, top = target.AbsolutePosition.X, target.AbsolutePosition.Y
        local right, bottom = left + target.AbsoluteSize.X, top + target.AbsoluteSize.Y
        local ancestor = target.Parent
        while ancestor do
            if ancestor:IsA("GuiObject") and ancestor.ClipsDescendants then
                left, top = math.max(left, ancestor.AbsolutePosition.X), math.max(top, ancestor.AbsolutePosition.Y)
                right = math.min(right, ancestor.AbsolutePosition.X + ancestor.AbsoluteSize.X)
                bottom = math.min(bottom, ancestor.AbsolutePosition.Y + ancestor.AbsoluteSize.Y)
            end
            ancestor = ancestor.Parent
        end
        assert(right > left and bottom > top, "Target is fully clipped.")
        for _, fraction in ipairs({ { .5, .5 }, { .2, .2 }, { .8, .2 }, { .2, .8 }, { .8, .8 } }) do
            local x, y = left + (right - left) * fraction[1], top + (bottom - top) * fraction[2]
            local hit = self:HitTest(x, y)
            for _, candidate in ipairs(hit.hits) do
                local object = self.inspector:Resolve({ handle = candidate.Handle })
                if object == target or object:IsDescendantOf(target) then return x, y, target, hit end
                -- CoreGui includes inactive transparent full-screen containers.
                -- They are hit-test results, but do not intercept pointer input.
                if candidate.effectiveVisible == true and (candidate.active or candidate.interactive) then break end
            end
        end
        error("Target is obstructed at sampled points; inspect hit-test evidence.")
    end
    assert(type(data.x) == "number" and type(data.y) == "number", "Provide a GUI target or screen x/y.")
    assert(data.x >= 0 and data.y >= 0 and data.x < geometry.viewport.x and data.y < geometry.viewport.y, "Point is outside the current viewport.")
    return data.x, data.y, nil, self:HitTest(data.x, data.y)
end

function Session:Overlay(enabled)
    if not enabled then if self.overlay then self.overlay:Destroy() self.overlay = nil end return end
    if self.overlay then return end
    local screen = Instance.new("ScreenGui") screen.Name = "MCPPointerEvidence" screen.IgnoreGuiInset = true screen.DisplayOrder = 100000
    local function dot(name, color)
        local frame = Instance.new("Frame") frame.Name = name frame.Size = UDim2.fromOffset(8, 8)
        frame.AnchorPoint = Vector2.new(.5, .5) frame.BackgroundColor3 = color frame.Active = false frame.Parent = screen
        return frame
    end
    self.requestedDot = dot("Requested", Color3.fromRGB(220, 150, 40))
    self.observedDot = dot("Observed", Color3.fromRGB(50, 210, 130))
    screen.Parent = self.playerGui self.overlay = screen
end

function Session:Cancel(id, reason)
    local action = self.actions[id] assert(action, "Unknown action in this connection.")
    if action.state == "running" then
        action.cancelled = true action.failureReason = reason or "cancelled"
        action.releaseFailures = self.controller:ReleaseAll()
    end
    return action
end

function Session:StartAction(data)
    assert(not self.activeAction, "Another action is running.")
    local x, y, target, hit
    if data.kind ~= "sequence" then x, y, target, hit = self:Point(data) else self:ValidateObservation(data.observationId) end
    assert(#self.controller:State().held == 0, "Release existing MCP input before starting an action.")
    local id = "act_" .. self.http:GenerateGUID(false)
    local action = { actionId = id, sessionId = self.id, clientId = self.bridge.ClientId, state = "running",
        beforeObservationId = data.observationId, startedAtMs = now(), dispatch = "pending", hitTest = hit, steps = {} }
    self.actions[id] = action table.insert(self.actionOrder, id)
    if #self.actionOrder > 64 then self.actions[table.remove(self.actionOrder, 1)] = nil end
    self.activeAction, self.context.InputOwner = id, id
    self:Overlay(data.overlay == true)
    task.spawn(function()
        local connections, activated = {}, false
        local function check()
            assert(not action.cancelled and not self.closed and self.bridge.Connected, "Action interrupted.")
            assert(now() - action.startedAtMs < 60000, "Action exceeded 60 seconds.")
            self:ValidateObservation(data.observationId)
        end
        local function wait(seconds)
            local deadline = os.clock() + seconds
            repeat check() task.wait(.02) until os.clock() >= deadline
        end
        local function send(input)
            check()
            action.dispatch = "unknown"
            if (input.action == "mouse" or input.action == "scroll") and not input.relative and input.x ~= nil then
                local geometry = self:Geometry()
                assert(input.x >= 0 and input.y >= 0 and input.x < geometry.viewport.x and input.y < geometry.viewport.y, "Input point is outside the viewport.")
            end
            local result = self.dispatchInput(input, id)
            if self.overlay then
                local cursor = self.controller:State()
                if cursor.requested then self.requestedDot.Position = UDim2.fromOffset(cursor.requested.x, cursor.requested.y) end
                if cursor.observed then self.observedDot.Position = UDim2.fromOffset(cursor.observed.x, cursor.observed.y) end
            end
            action.dispatch, action.backend = "accepted", result.backend
            action.desktopInput = self.controller:UsesDesktopInput()
            table.insert(action.steps, { action = input.action, event = input.event, backend = result.backend, dispatch = result.dispatch })
            self:Emit("action-input", { actionId = id, input = input, result = result })
            return result
        end
        local ok, reason = pcall(function()
            if target and target:IsA("GuiButton") then
                local signal = if data.kind == "activate" then target[data.event or "Activated"] else target.Activated
                table.insert(connections, signal:Connect(function() activated = true end))
            end
            if data.kind == "activate" or data.kind == "set-text" then
                check()
                action.dispatch = "unknown"
                action.method = if data.kind == "activate" then self.controller:Activate(target, data.event or "Activated") else self.controller:SetText(target, data.text)
                action.backend, action.desktopInput, action.dispatch = self.controller.backend, false, "accepted"
                action.signal = if data.kind == "activate" then data.event or "Activated" else nil
                action.note = "Direct client GUI operation, not physical input. Callback/game effects require a postcondition."
                table.insert(action.steps, { action = data.kind, backend = action.backend, method = action.method, dispatch = action.dispatch })
                self:Emit("action-gui", { actionId = id, target = self:Identity(target), method = action.method, signal = action.signal })
            elseif data.kind == "sequence" then
                for _, step in ipairs(data.steps) do
                    check()
                    if step.action == "wait" then wait((step.durationMs or 0) / 1000) else send(step) end
                end
            else
                send({ action = "mouse", event = "move", x = x, y = y })
                if data.kind == "click" then send({ action = "mouse", event = "click", x = x, y = y, button = data.button }) end
                if data.kind == "drag" then
                    send({ action = "mouse", event = "down", x = x, y = y, button = data.button })
                    for _, point in ipairs(data.path) do
                        wait((point.durationMs or 30) / 1000)
                        send({ action = "mouse", event = "move", x = point.x, y = point.y })
                    end
                    local last = data.path[#data.path]
                    send({ action = "mouse", event = "up", x = last.x, y = last.y, button = data.button })
                end
            end
            local deadline = now() + (data.timeoutMs or 1000)
            repeat
                check()
                if data.postcondition then
                    local condition = data.postcondition
                    local object = self.inspector:Resolve(condition.target)
                    local read, value = self.inspector:ReadProperty(object, condition.property, false)
                    action.expectedEffectObserved = read and value == condition.equals
                elseif data.kind == "set-text" then action.expectedEffectObserved = target.Text == data.text
                elseif data.kind ~= "activate" and target and target:IsA("GuiButton") then action.expectedEffectObserved = activated end
                if action.expectedEffectObserved == true or not data.postcondition and not target then break end
                task.wait(.03)
            until now() >= deadline
            if data.kind == "activate" then action.signalObserved = activated else action.inputObserved = activated or nil end
            if activated and data.kind ~= "activate" then self.context.RuntimeCapabilities:RecordUse("input.mouse", action.backend, true, true) end
            action.afterObservationId = self:Observe({ profile = "performance" }).observationId
        end)
        for _, connection in ipairs(connections) do connection:Disconnect() end
        action.releaseFailures = self.controller:ReleaseAll()
        action.state = if action.cancelled then "cancelled" elseif not ok or #action.releaseFailures > 0 then "failed" elseif action.expectedEffectObserved == false or data.kind == "activate" and action.expectedEffectObserved ~= true then "unverified" else "completed"
        action.failureReason = action.failureReason or (if not ok then string.sub(tostring(reason), 1, 300) else nil)
        action.finishedAtMs = now()
        self.activeAction = nil
        if self.context.InputOwner == id then self.context.InputOwner = nil end
        self:Emit("action-finished", action)
    end)
    return action
end

function Session:Destroy()
    if self.activeAction then self:Cancel(self.activeAction, "connector-disconnected") end
    self.closed = true self:Overlay(false)
    for _, connection in ipairs(self.connections) do connection:Disconnect() end
    self.context.ObservationSink = nil
end
return Session
