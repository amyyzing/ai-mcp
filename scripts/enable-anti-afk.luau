-- Hot-enable the same default-on module on an already connected older connector.
local install = require("../connector-src/runtime/anti-afk")
local player = assert(game:GetService("Players").LocalPlayer, "Local player is not ready.")
local user = game:GetService("VirtualUser")
local api = install({Player = player, KeepAlive = function()
    user:CaptureController()
    user:ClickButton2(Vector2.zero)
end})
return api.GetStatus()
