local InstancePath = require("../instance-path")
local InputController = require("../../runtime/input-controller")

return function(context, Bridge)
local VirtualInputManager = context.VirtualInputManager
local Players = context.Players
local UserInputService = game:GetService("UserInputService")
local clientInput
local focused
local function isFocused()
    if type(isrbxactive) == "function" then
        local ok, active = pcall(isrbxactive)
        if ok and type(active) == "boolean" then return active end
    end
    return focused
end
context.IsInputFocused = isFocused
-- Probe the actual capability: some clients expose this API outside Studio too.
pcall(function() clientInput = UserInputService:CreateVirtualInput() end)
local controller = InputController.new({
    VirtualInputManager = VirtualInputManager, VirtualInput = clientInput,
    UserInputService = UserInputService, Game = game, Enum = Enum,
    ExecutorInputAllowed = function() return isFocused() == true end,
    Environment = { mousemoveabs = mousemoveabs, mousemoverel = mousemoverel,
        mouse1press = mouse1press, mouse1release = mouse1release,
        mouse2press = mouse2press, mouse2release = mouse2release,
        keypress = keypress, keyrelease = keyrelease, mousescroll = mousescroll, firesignal = firesignal },
    Record = function(id, provider, ok)
        if context.RuntimeCapabilities.RecordUse then context.RuntimeCapabilities:RecordUse(id, provider, ok) end
    end,
})
context.InputController = controller
local focusLost = UserInputService.WindowFocusReleased:Connect(function() focused = false controller:ReleaseAll(true) end)
local focusGained = UserInputService.WindowFocused:Connect(function() focused = true end)
local function result(fields)
    fields.dispatch = "accepted"
    fields.backend = controller.backend
    fields.cursor = controller:State()
    fields.expectedEffectObserved = nil
    return fields
end

    local function MousePosition(data)
        if data.x ~= nil or data.y ~= nil then
            assert(type(data.x) == "number" and type(data.y) == "number", "Provide both x and y, or omit both.")
            return math.floor(data.x), math.floor(data.y)
        end
        local position = UserInputService:GetMouseLocation()
        return math.floor(position.X), math.floor(position.Y)
    end

    local function KeyCodeForExecutor(keyCode)
        local name = keyCode.Name
        if #name == 1 then return string.byte(string.upper(name)) end
        local virtualKeys = {
            Backspace = 0x08,
            Tab = 0x09,
            Return = 0x0D,
            LeftShift = 0x10,
            RightShift = 0x10,
            LeftControl = 0x11,
            RightControl = 0x11,
            LeftAlt = 0x12,
            RightAlt = 0x12,
            Escape = 0x1B,
            Space = 0x20,
            PageUp = 0x21,
            PageDown = 0x22,
            End = 0x23,
            Home = 0x24,
            Left = 0x25,
            Up = 0x26,
            Right = 0x27,
            Down = 0x28,
            Insert = 0x2D,
            Delete = 0x2E,
        }
        if virtualKeys[name] then return virtualKeys[name] end
        local functionNumber = string.match(name, "^F(%d+)$")
        if functionNumber then
            local number = tonumber(functionNumber)
            if number and number >= 1 and number <= 12 then return 0x6F + number end
        end
        error("No verified executor virtual-key mapping for " .. name)
    end

    local function SendKey(data)
        local keyCode = Enum.KeyCode[data.key]
        assert(keyCode ~= nil, "Unknown Enum.KeyCode: " .. tostring(data.key))
        local state = data.state or "press"
        local repeatCount = math.max(1, math.min(math.floor(tonumber(data.repeatCount) or 1), 20))
        local durationSeconds = math.max(0, math.min((tonumber(data.durationMs) or 40) / 1000, 2))
        durationSeconds = math.min(durationSeconds, 10 / repeatCount)
        local mapped, executorCode = pcall(KeyCodeForExecutor, keyCode)
        local function Send(isDown) controller:Key(keyCode, if mapped then executorCode else nil, isDown) end

        for _ = 1, repeatCount do
            if state == "down" then
                Send(true)
            elseif state == "up" then
                Send(false)
            else
                Send(true)
                if durationSeconds > 0 then task.wait(durationSeconds) end
                Send(false)
            end
        end
        return result({ status = "sent", action = "key", key = keyCode.Name, state = state })
    end

    local function SendText(data)
        local text = tostring(data.text or "")
        assert(utf8.len(text) and utf8.len(text) <= 2000 and #text <= 8000, "Text input requires up to 2000 UTF-8 characters.")
        local textBox
        if data.target then
            textBox = InstancePath.Resolve(data.target)
            assert(textBox:IsA("TextBox"), "Text target must resolve to a TextBox.")
            textBox:CaptureFocus()
            task.wait()
        end

        assert(not textBox or UserInputService:GetFocusedTextBox() == textBox, "Text focus changed before dispatch.")
        local method = controller:Text(text, textBox, data.allowPropertyFallback == true)

        if data.submit == true then
            if not textBox then SendKey({ key = "Return" }) end
        end
        if textBox then textBox:ReleaseFocus(data.submit == true) end
        return result({ status = "sent", action = "text", characters = utf8.len(text), bytes = #text,
            submitted = data.submit == true, method = method, fallbackUsed = method == "property-assignment" })
    end

    local function SendMouse(data)
        local x, y = MousePosition(data)
        local event = data.event
        local button = data.button or "left"
        local buttonIndex = ({ left = 0, right = 1, middle = 2 })[button]
        assert(buttonIndex ~= nil, "Unsupported mouse button.")
        if event == "move" then
            controller:Move(x, y, data.relative == true)
        else
            local function SendButton(isDown)
                controller:Button(button, isDown, x, y)
            end

            if event == "down" then
                SendButton(true)
            elseif event == "up" then
                SendButton(false)
            elseif event == "click" then
                SendButton(true)
                task.wait(0.04)
                SendButton(false)
            else
                error("Unsupported mouse event: " .. tostring(event))
            end
        end

        return result({ status = "sent", action = "mouse", event = event, button = button, x = x, y = y })
    end

    local function SendScroll(data)
        local x, y = MousePosition(data)
        local clicks = math.max(1, math.min(math.floor(tonumber(data.clicks) or 1), 50))
        local isForward = data.direction == "up"
        controller:Scroll(x, y, clicks, isForward)
        return result({ status = "sent", action = "scroll", direction = data.direction, clicks = clicks, x = x, y = y })
    end

    local function FirePrompt(data)
        local prompt = InstancePath.Resolve(data.target)
        assert(prompt:IsA("ProximityPrompt"), "Target must be a ProximityPrompt.")
        local holdDuration = math.max(0, math.min(tonumber(data.holdDuration) or prompt.HoldDuration, 10))
        if type(fireproximityprompt) == "function" then
            fireproximityprompt(prompt, holdDuration)
            return { status = "fired", action = "proximity-prompt", target = InstancePath.Describe(prompt), fallbackUsed = false }
        end

        local began = pcall(function() prompt:InputHoldBegin() end)
        assert(began, "Executor does not support fireproximityprompt or ProximityPrompt input methods.")
        if holdDuration > 0 then task.wait(holdDuration) end
        prompt:InputHoldEnd()
        return { status = "fired", action = "proximity-prompt", target = InstancePath.Describe(prompt), fallbackUsed = true }
    end

    local function FireDetector(data)
        local detector = InstancePath.Resolve(data.target)
        assert(detector:IsA("ClickDetector"), "Target must be a ClickDetector.")
        local distance = math.max(0, math.min(tonumber(data.distance) or 0, 10000))
        if type(fireclickdetector) == "function" then
            fireclickdetector(detector, distance)
            return { status = "fired", action = "click-detector", target = InstancePath.Describe(detector), fallbackUsed = false }
        end

        assert(type(firesignal) == "function", "Executor supports neither fireclickdetector nor firesignal.")
        firesignal(detector.MouseClick, Players.LocalPlayer)
        return { status = "fired", action = "click-detector", target = InstancePath.Describe(detector), fallbackUsed = true }
    end

    local function FireTouch(data)
        assert(type(firetouchinterest) == "function", "Executor does not support firetouchinterest.")
        local first = InstancePath.Resolve(data.first)
        local second = InstancePath.Resolve(data.second)
        assert(first:IsA("BasePart") and second:IsA("BasePart"), "Both touch targets must be BaseParts.")
        local state = data.state or "tap"
        if state == "begin" or state == "tap" then firetouchinterest(first, second, 0) end
        if state == "tap" then task.wait() end
        if state == "end" or state == "tap" then firetouchinterest(first, second, 1) end
        return {
            status = "fired",
            action = "touch",
            state = state,
            first = InstancePath.Describe(first),
            second = InstancePath.Describe(second),
        }
    end

    local function dispatch(data)
        if data.action == "key" then return SendKey(data) end
        if data.action == "text" then return SendText(data) end
        if data.action == "mouse" then return SendMouse(data) end
        if data.action == "scroll" then return SendScroll(data) end
        if data.action == "proximity-prompt" then return FirePrompt(data) end
        if data.action == "click-detector" then return FireDetector(data) end
        if data.action == "touch" then return FireTouch(data) end
        error("Unsupported input action: " .. tostring(data.action))
    end
    context.DispatchInput = function(data, owner)
        assert(not context.InputOwner or context.InputOwner == owner, "Another MCP action owns input; cancel it or wait.")
        local ok, value = pcall(dispatch, data)
        if not ok then controller:ReleaseAll() error(value, 0) end
        return value
    end
    Bridge:BindToTypeStructured("input", function(data) return context.DispatchInput(data) end)
    return function()
        controller.closed = true
        controller:ReleaseAll()
        focusLost:Disconnect()
        focusGained:Disconnect()
        if context.InputController == controller then context.InputController = nil context.DispatchInput = nil context.IsInputFocused = nil end
    end
end
