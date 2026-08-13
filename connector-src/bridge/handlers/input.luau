local InstancePath = require("../instance-path")

return function(context, Bridge)
local VirtualInputManager = context.VirtualInputManager

    Bridge:BindToType("type-text-box", function(data)
        local path = data.path
        local text = data.string or data.text
        local enter = data.enter
        local useKeyPress = data.useKeyPress

        local textBox = InstancePath.Resolve({ path = path })
        
        assert(typeof(textBox) == "Instance", "Path did not resolve to a valid Instance.")
        assert(textBox:IsA("TextBox"), "Resolved Instance is not a TextBox.")

        textBox:CaptureFocus()
        task.wait(0.05)
        
        if useKeyPress then
            local success = pcall(function()
                for i = 1, #text do
                    VirtualInputManager:SendTextInput(text:sub(i, i), nil, game)
                    task.wait(0.01)
                end
            end)
            
            if not success and type(keypress) == "function" then
                for i = 1, #text do
                    local char = text:sub(i, i):upper()
                    local byte = char:byte()
                    if byte then
                        keypress(byte)
                        task.wait(0.01)
                        if type(keyrelease) == "function" then
                            keyrelease(byte)
                        end
                    end
                end
            end
        else
            textBox.Text = text
        end

        if enter then
            if useKeyPress then
                if type(keypress) == "function" then
                    keypress(0x0D)
                    task.wait(0.01)
                    if type(keyrelease) == "function" then
                        keyrelease(0x0D)
                    end
                else
                    pcall(function()
                        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Return, false, game)
                        task.wait(0.01)
                        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Return, false, game)
                    end)
                end
            end
            textBox:ReleaseFocus(true)
        else
            textBox:ReleaseFocus(false)
        end

        return {
            status = "success",
            message = "Successfully typed into TextBox."
        }
    end)

    Bridge:BindToType("click-button", function(data)
        local path = data.path
        local action = data.Action or data.action

        local button = InstancePath.Resolve({ path = path })

        assert(typeof(button) == "Instance", "Path did not resolve to a valid Instance.")
        assert(button:IsA("GuiButton"), "Resolved Instance is not a GuiButton (e.g., TextButton or ImageButton).")
        assert(typeof(firesignal) == "function", "Your executor does not support 'firesignal', which is required for this command.")

        local Signals = {"Activated", "MouseButton1Down", "MouseButton2Down", "MouseButton1Click", "MouseButton2Click"}
        
        if action then
            assert(table.find(Signals, action), "Invalid action provided. Valid actions are: " .. table.concat(Signals, ", "))
            firesignal(button[action])
        else
            for _, signalName in pairs(Signals) do
                pcall(function() firesignal(button[signalName]) end)
            end
        end

        return {
            status = "success",
            message = "Successfully fired click signals on Button."
        }
    end)
end
