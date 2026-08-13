local InstancePath = require("../instance-path")

return function(context, Bridge)
local VirtualInputManager = context.VirtualInputManager
local Players = context.Players
local UserInputService = game:GetService("UserInputService")

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
        return keyCode.Value
    end

    local function SendKey(data)
        local keyCode = Enum.KeyCode[data.key]
        assert(keyCode ~= nil, "Unknown Enum.KeyCode: " .. tostring(data.key))
        local state = data.state or "press"
        local repeatCount = math.max(1, math.min(math.floor(tonumber(data.repeatCount) or 1), 20))
        local durationSeconds = math.max(0, math.min((tonumber(data.durationMs) or 40) / 1000, 2))
        durationSeconds = math.min(durationSeconds, 10 / repeatCount)
        local fallbackUsed = false

        local function Send(isDown)
            local ok = pcall(function()
                VirtualInputManager:SendKeyEvent(isDown, keyCode, false, game)
            end)
            if ok then return end

            fallbackUsed = true
            local executorCode = KeyCodeForExecutor(keyCode)
            if isDown then
                assert(type(keypress) == "function", "VirtualInputManager and keypress both failed/unavailable.")
                keypress(executorCode)
            else
                assert(type(keyrelease) == "function", "VirtualInputManager and keyrelease both failed/unavailable.")
                keyrelease(executorCode)
            end
        end

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
        return { status = "sent", action = "key", key = keyCode.Name, state = state, fallbackUsed = fallbackUsed }
    end

    local function SendText(data)
        local text = tostring(data.text or "")
        assert(#text <= 2000, "Text input is limited to 2000 characters.")
        local textBox
        if data.target then
            textBox = InstancePath.Resolve(data.target)
            assert(textBox:IsA("TextBox"), "Text target must resolve to a TextBox.")
            textBox:CaptureFocus()
            task.wait()
        end

        local fallbackUsed = false
        local ok = pcall(function()
            for index = 1, #text do
                VirtualInputManager:SendTextInput(string.sub(text, index, index), nil, game)
                if index % 100 == 0 then task.wait() end
            end
        end)
        if not ok then
            assert(textBox, "VirtualInputManager text input failed and no TextBox fallback target was supplied.")
            textBox.Text = text
            fallbackUsed = true
        end

        if data.submit == true then
            pcall(function()
                VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Return, false, game)
                VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Return, false, game)
            end)
        end
        if textBox then textBox:ReleaseFocus(data.submit == true) end
        return { status = "sent", action = "text", characters = #text, submitted = data.submit == true, fallbackUsed = fallbackUsed }
    end

    local function SendMouse(data)
        local x, y = MousePosition(data)
        local event = data.event
        local button = data.button or "left"
        local buttonIndex = ({ left = 0, right = 1, middle = 2 })[button]
        assert(buttonIndex ~= nil, "Unsupported mouse button.")
        local fallbackUsed = false

        if event == "move" then
            local ok = pcall(function() VirtualInputManager:SendMouseMoveEvent(x, y, game) end)
            if not ok then
                assert(type(mousemoveabs) == "function", "Mouse movement is unsupported by this executor.")
                mousemoveabs(x, y)
                fallbackUsed = true
            end
        else
            local function SendButton(isDown)
                local ok = pcall(function()
                    VirtualInputManager:SendMouseButtonEvent(x, y, buttonIndex, isDown, game, 0)
                end)
                if ok then return end
                fallbackUsed = true
                local fallbackNames = {
                    left = { down = mouse1press, up = mouse1release },
                    right = { down = mouse2press, up = mouse2release },
                }
                local callbacks = fallbackNames[button]
                local callback = callbacks and callbacks[isDown and "down" or "up"]
                assert(type(callback) == "function", "Mouse button input is unsupported by this executor.")
                callback()
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

        return { status = "sent", action = "mouse", event = event, button = button, x = x, y = y, fallbackUsed = fallbackUsed }
    end

    local function SendScroll(data)
        local x, y = MousePosition(data)
        local clicks = math.max(1, math.min(math.floor(tonumber(data.clicks) or 1), 50))
        local isForward = data.direction == "up"
        local fallbackUsed = false
        for _ = 1, clicks do
            local ok = pcall(function()
                VirtualInputManager:SendMouseWheelEvent(x, y, isForward, game)
            end)
            if not ok then
                assert(type(mousescroll) == "function", "Mouse wheel input is unsupported by this executor.")
                mousescroll(isForward and 1 or -1)
                fallbackUsed = true
            end
        end
        return { status = "sent", action = "scroll", direction = data.direction, clicks = clicks, fallbackUsed = fallbackUsed }
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

    Bridge:BindToTypeStructured("input", function(data)
        if data.action == "key" then return SendKey(data) end
        if data.action == "text" then return SendText(data) end
        if data.action == "mouse" then return SendMouse(data) end
        if data.action == "scroll" then return SendScroll(data) end
        if data.action == "proximity-prompt" then return FirePrompt(data) end
        if data.action == "click-detector" then return FireDetector(data) end
        if data.action == "touch" then return FireTouch(data) end
        error("Unsupported input action: " .. tostring(data.action))
    end)
end
