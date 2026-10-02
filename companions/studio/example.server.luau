-- Place this Script and the ServerCompanion ModuleScript in ServerScriptService.
-- Enable HTTP Requests in Game Settings > Security. Do not put the code in ReplicatedStorage.
-- Create companion-pair with kind="server", your placeId, and optionally the jobId first.
local Companion = require(script.Parent.ServerCompanion)
local diagnostics = Companion.Start({
    URL = "https://YOUR-MCP-HOST",
    PairingCode = "REPLACE-WITH-ONE-USE-SERVER-PAIRING-CODE",
    Build = "your-source-revision",
    CaptureConsole = true,
    SourceMap = {
        ["ServerScriptService.GameLogic"] = { path = "src/server/GameLogic.server.luau", revision = "your-source-revision" },
    },
})
diagnostics:State("round", { phase = "waiting" })
local finishSpan = diagnostics:Span("startup", {})
finishSpan({ ready = true })
game:BindToClose(function() diagnostics:Flush() diagnostics:Stop() end)
