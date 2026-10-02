-- One provider and release callback per held input. Dispatch is not proof of effect.
local Controller = {}
Controller.__index = Controller

function Controller.new(options)
    return setmetatable({ options = options, held = {}, heldProviders = {}, requested = nil, backend = nil }, Controller)
end

local function desktopProvider(provider)
    return provider ~= nil and provider ~= "roblox-virtual-input" and provider ~= "virtual-input-manager" and provider ~= "text-property" and provider ~= "gui-signal"
end

function Controller:UsesDesktopInput()
    if desktopProvider(self.backend) then return true end
    for _, provider in pairs(self.heldProviders) do if desktopProvider(provider) then return true end end
    return false
end

function Controller:_requireDesktopInput()
    assert(self.options.ExecutorInputAllowed and self.options.ExecutorInputAllowed(),
        "Client-local input is unavailable for this action; desktop input is disabled while Roblox is in the background. No OS input was sent.")
end

function Controller:_use(id, provider, callback)
    local ok, result = pcall(callback)
    if self.options.Record then self.options.Record(id, provider, ok) end
    if ok then self.backend = provider end
    return ok, result
end

function Controller:Position()
    local ok, position = pcall(function() return self.options.UserInputService:GetMouseLocation() end)
    return if ok then { x = position.X, y = position.Y } else nil
end

function Controller:State()
    local held = {}
    for name in pairs(self.held) do table.insert(held, name) end
    table.sort(held)
    return { requested = self.requested, observed = self:Position(), backend = self.backend, held = held,
        focusRequired = false, backgroundPolicy = "client-local-only", effectVerification = "required" }
end

function Controller:Move(x, y, relative)
    assert(not self.closed, "Input controller closed.")
    assert(type(x) == "number" and x == x and math.abs(x) < 100000, "Invalid mouse x.")
    assert(type(y) == "number" and y == y and math.abs(y) < 100000, "Invalid mouse y.")
    local o, ok = self.options, false
    self.requested = { x = x, y = y, relative = relative == true }
    if o.VirtualInput then
        ok = self:_use("input.mouse", "roblox-virtual-input", function()
            if relative then o.VirtualInput:SendMouseDelta(Vector2.new(x, y))
            else o.VirtualInput:SendMousePosition(Vector2.new(x, y)) end
        end)
    end
    if not ok and not relative then
        ok = self:_use("input.mouse", "virtual-input-manager", function() o.VirtualInputManager:SendMouseMoveEvent(x, y, o.Game) end)
    end
    if not ok then
        self:_requireDesktopInput()
        local callback = if relative then o.Environment.mousemoverel else o.Environment.mousemoveabs
        assert(type(callback) == "function", "Requested mouse movement is unavailable.")
        local reason
        ok, reason = self:_use("input.mouse", if relative then "mousemoverel" else "mousemoveabs", function() callback(x, y) end)
        assert(ok, "Mouse movement dispatch failed.")
    end
    return self:State()
end

function Controller:Button(button, down, x, y)
    assert(not self.closed or not down, "Input controller closed.")
    local key = "mouse:" .. button
    if not down and self.held[key] then
        local release = self.held[key]
        release(x, y)
        self.held[key] = nil
        self.heldProviders[key] = nil
        return self:State()
    end
    assert(not down or not self.held[key], "This mouse button is already held by MCP.")
    local index = ({ left = 0, right = 1, middle = 2 })[button]
    assert(index ~= nil, "Unsupported button.")
    local o, release = self.options, nil
    local function try(provider, callback)
        local ok = self:_use("input.mouse", provider, function() callback(down, x, y) end)
        if ok then release = function(rx, ry)
            local current = self:Position()
            local released = self:_use("input.mouse", provider, function() callback(false, rx or (current and current.x) or x, ry or (current and current.y) or y) end)
            assert(released, "Mouse release failed.")
        end end
        return ok
    end
    local sent = false
    if o.VirtualInput then
        sent = try("roblox-virtual-input", function(state, px, py)
            o.VirtualInput:SendMouseButton(Vector2.new(px, py), o.Enum.UserInputType[({ left = "MouseButton1", right = "MouseButton2", middle = "MouseButton3" })[button]], state, 0)
        end)
    end
    if not sent then sent = try("virtual-input-manager", function(state, px, py) o.VirtualInputManager:SendMouseButtonEvent(px, py, index, state, o.Game, 0) end) end
    if not sent then
        self:_requireDesktopInput()
        local prefix = ({ left = "mouse1", right = "mouse2" })[button]
        local press = prefix and o.Environment[prefix .. "press"]
        local up = prefix and o.Environment[prefix .. "release"]
        assert(type(press) == "function" and type(up) == "function", "Mouse button fallback is unavailable.")
        -- Executor button APIs do not take a position: establish it explicitly.
        self:Move(x, y)
        sent = try(prefix, function(state) if state then press() else up() end end)
    end
    assert(sent, "Mouse button dispatch failed; outcome unknown.")
    if down then self.held[key] = release self.heldProviders[key] = self.backend end
    return self:State()
end

function Controller:Key(code, executorCode, down)
    assert(not self.closed or not down, "Input controller closed.")
    local key, o = "key:" .. code.Name, self.options
    if not down and self.held[key] then self.held[key]() self.held[key] = nil self.heldProviders[key] = nil return self:State() end
    assert(not down or not self.held[key], "This key is already held by MCP.")
    local providers = {}
    if o.VirtualInput then table.insert(providers, { "roblox-virtual-input", function(state) o.VirtualInput:SendKey(state, code, false) end }) end
    table.insert(providers, { "virtual-input-manager", function(state) o.VirtualInputManager:SendKeyEvent(state, code, false, o.Game) end })
    table.insert(providers, { "executor-key", function(state)
        if state then self:_requireDesktopInput() end
        assert(type(executorCode) == "number", "No executor key mapping is available.")
        assert(type(o.Environment.keypress) == "function" and type(o.Environment.keyrelease) == "function", "Paired key APIs unavailable.")
        local callback = if state then o.Environment.keypress else o.Environment.keyrelease
        assert(type(callback) == "function", "Key API unavailable.")
        callback(executorCode)
    end })
    for _, provider in ipairs(providers) do
        local ok = self:_use("input.key", provider[1], function() provider[2](down) end)
        if ok then
            if down then self.held[key] = function()
                assert(self:_use("input.key", provider[1], function() provider[2](false) end), "Key release failed.")
            end self.heldProviders[key] = provider[1] end
            return self:State()
        end
    end
    error("Key dispatch failed; outcome unknown.")
end

function Controller:Text(text, textBox, directFallback)
    assert(not self.closed, "Input controller closed.")
    assert(utf8.len(text) ~= nil, "Text must be valid UTF-8.")
    local o = self.options
    if o.VirtualInput and self:_use("input.text", "roblox-virtual-input", function() o.VirtualInput:SendTextInput(text) end) then return "simulated-typing" end
    if self:_use("input.text", "virtual-input-manager", function() o.VirtualInputManager:SendTextInput(text, nil, o.Game) end) then return "simulated-typing" end
    assert(textBox and directFallback, "Text input unavailable; explicit TextBox assignment fallback was not enabled.")
    textBox.Text = text
    self.backend = "text-property"
    return "property-assignment"
end

function Controller:Scroll(x, y, clicks, forward)
    assert(not self.closed, "Input controller closed.")
    local o = self.options
    for _ = 1, clicks do
        if not self:_use("input.scroll", "virtual-input-manager", function() o.VirtualInputManager:SendMouseWheelEvent(x, y, forward, o.Game) end) then
            self:_requireDesktopInput()
            assert(type(o.Environment.mousescroll) == "function", "Scroll API unavailable.")
            self:Move(x, y)
            assert(self:_use("input.scroll", "mousescroll", function() o.Environment.mousescroll(if forward then 1 else -1) end), "Scroll dispatch failed.")
        end
    end
    return self:State()
end

function Controller:Activate(button, event)
    assert(not self.closed, "Input controller closed.")
    assert(button:IsA("GuiButton") and button.Interactable ~= false and button.Active, "Target button is not interactable.")
    assert(event == "Activated" or event == "MouseButton1Click" or event == "MouseButton2Click", "Unsupported GUI activation signal.")
    local fire = self.options.Environment.firesignal
    assert(type(fire) == "function", "Direct GUI activation is unavailable on this executor; no pointer fallback was attempted.")
    local ok = self:_use("input.fire-signal", "gui-signal", function()
        if event == "Activated" then fire(button.Activated, nil, 1) else fire(button[event]) end
    end)
    assert(ok, "GUI signal dispatch failed; outcome unknown. Do not blindly retry.")
    return "signal-dispatch"
end

function Controller:SetText(box, text)
    assert(not self.closed, "Input controller closed.")
    assert(box:IsA("TextBox") and box.TextEditable ~= false, "Target must be an editable TextBox.")
    local length = utf8.len(text)
    assert(length and length <= 2000 and #text <= 8000, "Text requires up to 2000 UTF-8 characters.")
    box.Text = text
    self.backend = "text-property"
    return "property-assignment"
end

function Controller:ReleaseAll(desktopOnly)
    local failed = {}
    for name, release in pairs(self.held) do
        if not desktopOnly or desktopProvider(self.heldProviders[name]) then
            if pcall(release) then self.held[name] = nil self.heldProviders[name] = nil else table.insert(failed, name) end
        end
    end
    return failed
end

return Controller
