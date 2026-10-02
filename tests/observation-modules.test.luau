local Controller = require("../connector-src/runtime/input-controller")
local Journal = require("../connector-src/observation/journal")
local Session = require("../connector-src/observation/session")
local events, position = {}, { X = 0, Y = 0 }
local function push(value) table.insert(events, value) end
local controller = Controller.new({
    UserInputService = { GetMouseLocation = function() return position end },
    VirtualInputManager = {}, ExecutorInputAllowed = function() return true end,
    Environment = {
        mousemoveabs = function(x, y) position = { X = x, Y = y } push("move") end,
        mouse1press = function() push("down") end, mouse1release = function() push("up") end,
        mousescroll = function() push("scroll") end,
        keypress = function() push("key-down") end, keyrelease = function() push("key-up") end,
    },
})
controller:Button("left", true, 12, 34)
assert(events[1] == "move" and events[2] == "down", "fallback must position before clicking")
assert(controller:State().observed.x == 12)
assert(#controller:State().held == 1)
assert(#controller:ReleaseAll() == 0 and events[3] == "up")
assert(#controller:State().held == 0)
controller:Scroll(99, 100, 1, true)
assert(events[4] == "move" and events[5] == "scroll", "fallback must position before scrolling")
controller:Key({ Name = "E" }, 69, true)
controller.options.Environment.keypress = function() error("provider changed") end
controller:Key({ Name = "E" }, 69, false)
assert(events[#events] == "key-up", "release must use the provider that held input")
controller.options.ExecutorInputAllowed = function() return false end
assert(not pcall(function() controller:Move(1, 1) end), "unknown or lost focus cannot send OS fallback input")
local sent
controller.options.VirtualInputManager = { SendTextInput = function(_, text) sent = text end }
assert(controller:Text("hé🙂", nil, false) == "simulated-typing" and sent == "hé🙂", "text is sent as a full UTF-8 string")
controller.options.VirtualInputManager = {}
assert(not pcall(function() controller:Text("x", {}, false) end), "property fallback is explicit")
local box = {}
assert(controller:Text("hé🙂", box, true) == "property-assignment" and box.Text == "hé🙂")
assert(not pcall(function() controller:Text(string.char(255), box, true) end))
local releasePoint
controller.options.VirtualInputManager = { SendMouseButtonEvent = function(_, x, y, _, down)
    if not down then releasePoint = { x, y } end
end }
controller:Button("left", true, 1, 2)
controller:Button("left", false, 9, 10)
assert(releasePoint[1] == 9 and releasePoint[2] == 10, "drag must release at the final point, not its starting point")
controller.closed = true
assert(not pcall(function() controller:Button("left", true, 1, 2) end), "no late input after disconnect")
local localEvents, osEvents = {}, 0
local background = Controller.new({
    UserInputService = { GetMouseLocation = function() return position end },
    ExecutorInputAllowed = function() return false end,
    Environment = { mousemoveabs = function() osEvents += 1 end, mouse1press = function() osEvents += 1 end,
        mouse1release = function() osEvents += 1 end, keypress = function() osEvents += 1 end,
        keyrelease = function() osEvents += 1 end, mousescroll = function() osEvents += 1 end },
    VirtualInputManager = {
        SendMouseMoveEvent = function() table.insert(localEvents, "move") end,
        SendMouseButtonEvent = function(_, _, _, _, down) table.insert(localEvents, if down then "down" else "up") end,
        SendKeyEvent = function(_, down) table.insert(localEvents, if down then "key-down" else "key-up") end,
        SendMouseWheelEvent = function() table.insert(localEvents, "scroll") end,
    },
})
background:Move(20, 30)
background:Button("left", true, 20, 30)
background:Key({ Name = "E" }, 69, true)
background:Scroll(20, 30, 1, true)
assert(not background:UsesDesktopInput() and #background:State().held == 2)
background:ReleaseAll(true)
assert(#background:State().held == 2, "focus loss must not release client-local held input")
background:ReleaseAll()
assert(#background:State().held == 0 and osEvents == 0, "background input stays in the client")
assert(background:State().focusRequired == false and background:State().backgroundPolicy == "client-local-only")
background.options.VirtualInputManager = {}
for _, callback in ipairs({
    function() background:Move(1, 2) end,
    function() background:Button("left", true, 1, 2) end,
    function() background:Key({ Name = "E" }, 69, true) end,
    function() background:Scroll(1, 2, 1, true) end,
}) do assert(not pcall(callback), "unsupported background input must fail without desktop fallback") end
assert(osEvents == 0)
background.options.ExecutorInputAllowed = function() return true end
background:Key({ Name = "E" }, 69, true)
assert(background:UsesDesktopInput())
background.options.ExecutorInputAllowed = function() return false end
background:ReleaseAll(true)
assert(osEvents == 2 and #background:State().held == 0, "desktop-held keys still release on focus loss")
local fired, firedArgs
background.options.Environment.firesignal = function(signal, ...) fired = signal firedArgs = table.pack(...) end
local testButton = { IsA = function(_, class) return class == "GuiButton" end, Interactable = true, Active = true,
    Activated = "activated", MouseButton1Click = "click" }
assert(background:Activate(testButton, "Activated") == "signal-dispatch" and fired == "activated")
assert(firedArgs.n == 2 and firedArgs[1] == nil and firedArgs[2] == 1 and not background:UsesDesktopInput())
background:Activate(testButton, "MouseButton1Click")
assert(fired == "click" and firedArgs.n == 0, "dispatch only the requested signal, never both")
assert(not pcall(function() background:Activate(testButton, "Changed") end))
testButton.Interactable = false
assert(not pcall(function() background:Activate(testButton, "Activated") end))
local testBox = { IsA = function(_, class) return class == "TextBox" end, TextEditable = true }
assert(background:SetText(testBox, "hé🙂") == "property-assignment" and testBox.Text == "hé🙂")
assert(not pcall(function() background:SetText(testBox, string.char(255)) end))
assert(not pcall(function() background:SetText(testBox, string.rep("a", 2001)) end))
assert(osEvents == 2, "direct GUI actions never touch desktop input")
local journal = Journal.new(2, function() return 20 end, 100)
local original = { nested = { value = 1 } }
journal:Push("first", original, 1) original.nested.value = 2
assert(journal:Read(0).events[1].data.nested.value == 1, "history must not retain mutable tables")
local read = journal:Read(0) read.events[1].data.nested.value = 3
assert(journal:Read(0).events[1].data.nested.value == 1)
journal:Push("second", {}, 2) journal:Push("third", {}, 3)
local page = journal:Read(0, 1)
assert(page.gap and page.dropped == 1 and page.events[1].sequence == 2 and page.nextCursor == 2)
assert(journal:Read(2).events[1].sequence == 3)
local target = { AbsolutePosition = { X = 10, Y = 20 }, AbsoluteSize = { X = 100, Y = 60 },
    IsA = function() return true end, IsDescendantOf = function() return false end }
local container = { IsDescendantOf = function() return false end }
local blocking = false
local session = setmetatable({ inspector = { Resolve = function(_, value) return if value.handle == "button" then target else container end } }, Session)
session.ValidateObservation = function() return { viewport = { x = 1000, y = 1000 } } end
session.GuiRecord = function() return { effectiveVisible = true } end
session.HitTest = function() return { hits = {
    { Handle = "container", active = blocking, interactive = false, effectiveVisible = true },
    { Handle = "button", active = true, interactive = true, effectiveVisible = true },
} } end
local px, py, selected = session:Point({ observationId = "obs", target = { handle = "button" } })
assert(px == 60 and py == 50 and selected == target, "inactive CoreGui containers must not block a real target")
blocking = true
assert(not pcall(function() session:Point({ observationId = "obs", target = { handle = "button" } }) end), "active GUI blockers must stop the click")
session.journal = journal session.id = "test" session.bridge = { ClientId = "client" }
journal:Push("console", { text = "hello", level = "MessageWarning" }, 4)
local console = session:ReadConsole({ contains = "HELLO", level = "MessageWarning" })
assert(#console.entries == 1 and console.entries[1].entry.text == "hello" and console.gap and console.sessionId == "test")
local empty = session:ReadConsole({ cursor = console.nextCursor })
assert(#empty.entries == 0 and empty.complete)

-- Exercise action completion without a foreground window, not just controller calls.
local workers = {}
setfenv(Session.StartAction, setmetatable({ task = {
    spawn = function(callback) table.insert(workers, callback) end,
    wait = function() end,
} }, { __index = getfenv(Session.StartAction) }))
local listeners = {}
local signal = { Connect = function(_, callback)
    table.insert(listeners, callback)
    return { Disconnect = function() local index = table.find(listeners, callback) if index then table.remove(listeners, index) end end }
end }
local actionTarget = { Text = "Before", Active = true, Interactable = true, Activated = signal,
    IsA = function(_, class) return class == "GuiButton" or class == "GuiObject" end }
background.options.Environment.firesignal = function()
    actionTarget.Text = "After"
    for _, callback in ipairs(listeners) do callback() end
end
local actionSession = setmetatable({ focused = false, controller = background, context = {}, bridge = { Connected = true, ClientId = "test" },
    id = "test", actions = {}, actionOrder = {}, http = { GenerateGUID = function() return tostring(#workers + 1) end },
    inspector = { Resolve = function() return actionTarget end, ReadProperty = function(_, object, property) return true, object[property] end },
}, Session)
actionSession.ValidateObservation = function() return {} end
actionSession.Point = function() return 10, 10, actionTarget, {} end
actionSession.Overlay = function() end
actionSession.Emit = function() end
actionSession.Identity = function() return { Name = "test" } end
actionSession.Observe = function() return { observationId = "after" } end
local function runAction(data)
    local action = actionSession:StartAction(data)
    workers[#workers]()
    return action
end
local waited = runAction({ kind = "sequence", observationId = "before", steps = { { action = "wait", durationMs = 0 } }, timeoutMs = 0 })
assert(waited.state == "completed", "unfocused wait-only actions must complete")
local direct = runAction({ kind = "activate", observationId = "before", target = {}, timeoutMs = 0,
    postcondition = { target = {}, property = "Text", equals = "After" } })
assert(direct.state == "completed" and direct.signalObserved and direct.expectedEffectObserved)
assert(direct.inputObserved == nil and direct.desktopInput == false, "signal activation is not physical input")
local unverified = runAction({ kind = "activate", observationId = "before", target = {}, timeoutMs = 0 })
assert(unverified.state == "unverified", "our own signal listener is not proof of a game effect")
local cancelled = actionSession:StartAction({ kind = "sequence", observationId = "before", steps = {}, timeoutMs = 0 })
actionSession:Cancel(cancelled.actionId)
workers[#workers]()
assert(cancelled.state == "cancelled" and #background:State().held == 0)
assert(osEvents == 2, "unfocused scenarios never used desktop input")
print("Observation/input module tests passed")
