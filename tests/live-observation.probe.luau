-- Opt-in live smoke fixture. No existing connector is unloaded or replaced.
-- Everything owned by this fixture expires after three minutes.
local Handles = require("../connector-src/runtime/handles")
local Values = require("../connector-src/runtime/typed-values")
local Inspector = require("../connector-src/dex/inspect")
local Paths = require("../connector-src/bridge/instance-path")
local Capabilities = require("../connector-src/runtime/capabilities")
local RegisterInput = require("../connector-src/bridge/handlers/unified-input")
local Session = require("../connector-src/observation/session")
local key = "MCPObservationValidation"
assert(getgenv()[key] == nil, "A validation fixture is already active.")
local http = game:GetService("HttpService")
local callbacks, report = {}, { status = "starting" }
local bridge = { Connected = true, ClientId = "isolated-observation-validation",
    BindToTypeStructured = function(_, name, callback) callbacks[name] = callback end }
local handles = Handles.new({ RegistryId = http:GenerateGUID(false), MaxHandles = 500 })
local values = Values.new({ Handles = handles })
local context = { Players = game:GetService("Players"), LogService = game:GetService("LogService"),
    VirtualInputManager = Instance.new("VirtualInputManager"), RuntimeHandles = handles,
    RuntimeValues = values, RuntimeCapabilities = Capabilities.new() }
context.DexInspector = Inspector.new({ InstancePath = Paths, Handles = handles, Values = values })
local cleanupInput = RegisterInput(context, bridge)
-- This fixture must never fall back to desktop input, even if focus changes mid-test.
context.InputController.options.ExecutorInputAllowed = function() return false end
local session = Session.new(context, bridge)
local gui = Instance.new("ScreenGui") gui.Name = "MCPObservationValidation" gui.DisplayOrder = 100000 gui.IgnoreGuiInset = true
local button = Instance.new("TextButton") button.Name = "TestButton" button.Text = "MCP test" button.Size = UDim2.fromOffset(140, 60)
button.Position = UDim2.fromScale(.5, .5) button.Parent = gui
local textBox = Instance.new("TextBox") textBox.Name = "TestTextBox" textBox.Text = "Before"
textBox.Size = UDim2.fromOffset(240, 50) textBox.Position = UDim2.fromScale(.5, .65) textBox.Parent = gui
local activated = button.Activated:Connect(function() button.Text = "MCP clicked" report.activated = true end)
gui.Parent = context.Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
local api, closed = {}, false
local function cleanup()
    if closed then return end closed = true
    bridge.Connected = false session:Destroy() cleanupInput() activated:Disconnect() gui:Destroy()
    context.VirtualInputManager:Destroy()
    if getgenv()[key] == api then getgenv()[key] = nil end
end
api.Cleanup = cleanup
api.Read = function() return report end
api.Run = function()
    report = { status = "running" }
    local observation = session:Observe({ profile = "ui-debug", limit = 3 })
    local handle = context.DexInspector:Describe(button).Handle
    local x, y, target = session:Point({ observationId = observation.observationId, target = { handle = handle } })
    assert(target == button, "Wrong GUI target.")
    report.observation = { sessionId = observation.sessionId, geometryRevision = observation.geometryRevision,
        viewport = observation.geometry.viewport, targetPoint = { x = x, y = y }, focused = observation.geometry.focused }
    report.action = session:StartAction({ kind = "click", observationId = observation.observationId, target = { handle = handle }, timeoutMs = 500,
        postcondition = { target = { handle = handle }, property = "Text", equals = "MCP clicked" } })
    report.status = "action-started"
    return report
end
api.Console = function() return session:ReadConsole({ contains = "MCP live probe", limit = 5 }) end
api.DirectCheck = function()
    button.Text = "MCP test" report.activated = false
    local observation = session:Observe({ profile = "performance" })
    report.directFocused = observation.geometry.focused
    local handle = context.DexInspector:Describe(button).Handle
    report.directAction = session:StartAction({ kind = "activate", observationId = observation.observationId,
        target = { handle = handle }, event = "Activated", timeoutMs = 500,
        postcondition = { target = { handle = handle }, property = "Text", equals = "MCP clicked" } })
    return report.directAction
end
api.TextCheck = function()
    local observation = session:Observe({ profile = "performance" })
    report.textAction = session:StartAction({ kind = "set-text", observationId = observation.observationId,
        target = { handle = context.DexInspector:Describe(textBox).Handle }, text = "Background hé🙂", timeoutMs = 500 })
    return report.textAction
end
api.WaitCheck = function()
    local observation = session:Observe({ profile = "performance" })
    report.waitAction = session:StartAction({ kind = "sequence", observationId = observation.observationId,
        steps = { { action = "wait", durationMs = 250 } }, timeoutMs = 0 })
    return report.waitAction
end
api.CancelCheck = function()
    local observation = session:Observe({ profile = "performance" })
    local action = session:StartAction({ kind = "sequence", observationId = observation.observationId,
        steps = { { action = "wait", durationMs = 1000 } }, timeoutMs = 0 })
    session:Cancel(action.actionId)
    report.cancelledAction = action
    return action
end
getgenv()[key] = api
task.delay(180, cleanup)
report.status = "ready"
