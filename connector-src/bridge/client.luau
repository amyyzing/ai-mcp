return function(context)
local HttpService = context.HttpService
local BridgeHTTPURL = context.BridgeHTTPURL
local BridgeWebSocketURL = context.BridgeWebSocketURL
local BridgeAuthToken = context.BridgeAuthToken
local BridgeRequestHeaders = context.BridgeRequestHeaders
local Request = context.Request
local HttpGet = context.HttpGet
local WebSocketAvailable = context.WebSocketAvailable
local WebSocketConnect = context.WebSocketConnect
local GetRegistrationInfo = context.GetRegistrationInfo
local SanitizeForOutput = context.SanitizeForOutput
local LuaEncode = context.LuaEncode
local websocketRetryAfter = 0
local websocketRetryDelay = 30
local MAX_ACTIVE_COMMANDS = 32
local MAX_RECENT_COMMANDS = 256

local function EncodeBridgeResponse(response)
    local ok, encoded = pcall(function()
        return HttpService:JSONEncode(response)
    end)
    if ok then return encoded end
    return HttpService:JSONEncode({
        id = type(response) == "table" and response.id or nil,
        success = false,
        error = "Failed to serialize connector response: " .. string.sub(tostring(encoded), 1, 300),
    })
end

--// Base Bridge Class \\--
local BaseBridge = {}; do
    BaseBridge.__index = BaseBridge

    function BaseBridge:GetCommandStatus()
        local active, oldest = 0, 0
        for _, command in pairs(self.CommandThreads or {}) do
            active += 1
            oldest = math.max(oldest, os.clock() - command.startedAt)
        end
        return {
            ready = self.Ready == true, active = active, maximum = MAX_ACTIVE_COMMANDS,
            workMaximum = MAX_ACTIVE_COMMANDS - 1,
            oldestRunningSeconds = oldest,
            completed = self.CommandsCompleted or 0, failed = self.CommandsFailed or 0,
            duplicates = self.CommandDuplicates or 0, rejected = self.CommandsRejected or 0,
            responseFailures = self.ResponseFailures or 0, cancelled = self.CommandsCancelled or 0,
            cancellationFailures = self.CancellationFailures or 0,
        }
    end

    function BaseBridge:SendResponse(response)
        if not self.Connected or response == nil then return end
        local ok = pcall(function()
            if self.WebSocket then
                self.WebSocket:Send(EncodeBridgeResponse(response))
            else
                response.clientId = self.ClientId
                local sent = Request({
                    Url = BridgeHTTPURL .. "/respond?clientId=" .. HttpService:UrlEncode(self.ClientId),
                    Method = "POST",
                    Headers = BridgeRequestHeaders({ ["Content-Type"] = "application/json" }),
                    Body = EncodeBridgeResponse(response),
                })
                assert(sent.StatusCode == 200 or sent.StatusCode == 204, "Bridge rejected response.")
            end
        end)
        if not ok then self.ResponseFailures = (self.ResponseFailures or 0) + 1 end
        -- A failed delivery never replays the command or its side effects.
    end

    function BaseBridge:DispatchMessage(data)
        if not self.Connected or type(data) ~= "table" or type(data.type) ~= "string"
            or type(data.id) ~= "string" or data.id == "" or #data.id > 160 then return end
        self.CommandThreads = self.CommandThreads or {}
        self.RecentCommands = self.RecentCommands or {}
        self.RecentCommandOrder = self.RecentCommandOrder or {}
        if self.CommandThreads[data.id] or self.RecentCommands[data.id] then
            self.CommandDuplicates = (self.CommandDuplicates or 0) + 1
            if self.RecentCommands[data.id] then
                self:SendResponse(self:FormatResponse("Request already completed; it was not replayed. Inspect the outcome before issuing a new request.", data.id, true))
            end
            return
        end
        local rejection
        -- Keep one slot available to diagnose a saturated connector.
        local limit = data.type == "runtime-status" and MAX_ACTIVE_COMMANDS or MAX_ACTIVE_COMMANDS - 1
        if not self.Ready then rejection = "Connector is still initializing; no command was executed."
        elseif self:GetCommandStatus().active >= limit then
            rejection = "Connector command limit reached; no command was executed. Wait for running commands to finish."
        end
        if rejection then
            self.CommandsRejected = (self.CommandsRejected or 0) + 1
            self:SendResponse(self:FormatResponse(rejection, data.id, true))
            return
        end
        local thread = coroutine.create(function()
            local ok, response = pcall(self.HandleMessage, self, data)
            if not ok then response = self:FormatResponse(response, data.id, true) end
            self.CommandsCompleted = (self.CommandsCompleted or 0) + 1
            if response and response.success == false then self.CommandsFailed = (self.CommandsFailed or 0) + 1 end
            self.RecentCommands[data.id] = true
            table.insert(self.RecentCommandOrder, data.id)
            if #self.RecentCommandOrder > MAX_RECENT_COMMANDS then
                self.RecentCommands[table.remove(self.RecentCommandOrder, 1)] = nil
            end
            self:SendResponse(response)
            self.CommandThreads[data.id] = nil
        end)
        -- Register before spawn, which can finish inline on some executors.
        self.CommandThreads[data.id] = { thread = thread, startedAt = os.clock() }
        task.spawn(thread)
    end

    function BaseBridge:Disconnect()
        self.Connected = false
        self.Ready = false
        for id, command in pairs(self.CommandThreads or {}) do
            self.CommandThreads[id] = nil
            if command.thread ~= coroutine.running() then
                local cancelled = pcall(task.cancel, command.thread)
                if cancelled then self.CommandsCancelled = (self.CommandsCancelled or 0) + 1
                else self.CancellationFailures = (self.CancellationFailures or 0) + 1 end
            end
        end
        for _, name in { "AliveThread", "AliveProbeThread", "PollThread" } do
            local thread = self[name]
            self[name] = nil
            if thread and thread ~= coroutine.running() then pcall(task.cancel, thread) end
        end
        for _, connection in pairs(self.Connections or {}) do pcall(function() connection:Disconnect() end) end
        self.Connections = {}
        if self.WebSocket then pcall(function() self.WebSocket:Close() end) end
    end
    
    function BaseBridge:BindToType(type, callback)
        self.Callbacks[type] = callback
    end

    function BaseBridge:BindToTypeRaw(type, callback)
        self.Callbacks[type] = callback
        self.RawCallbacks = self.RawCallbacks or {}
        self.RawCallbacks[type] = true
    end

    function BaseBridge:BindToTypeStructured(type, callback)
        self.Callbacks[type] = callback
        self.StructuredCallbacks = self.StructuredCallbacks or {}
        self.StructuredCallbacks[type] = true
    end

    function BaseBridge:CreateAlias(type, aliases)
        for _, alias in aliases do
            self.Callbacks[alias] = self.Callbacks[type]
            if self.RawCallbacks and self.RawCallbacks[type] then
                self.RawCallbacks[alias] = true
            end
            if self.StructuredCallbacks and self.StructuredCallbacks[type] then
                self.StructuredCallbacks[alias] = true
            end
        end
    end

    function BaseBridge:HandleMessage(data)
        if self.Callbacks[data.type] then
            local success, result = pcall(function()
                return self.Callbacks[data.type](data)
            end)

            if success and result == nil then
                return nil
            end

            if not success then
                return self:FormatResponse(result, data.id, true)
            end

            if self.RawCallbacks and self.RawCallbacks[data.type] then
                return {
                    output = tostring(result),
                    success = true,
                    id = data.id
                }
            end

            return self:FormatResponse(
                result,
                data.id,
                false,
                self.StructuredCallbacks and self.StructuredCallbacks[data.type] == true
            )
        end
        return self:FormatResponse(
            "Unsupported connector command: " .. string.sub(tostring(data.type), 1, 100)
                .. ". Reload the current MCP connector in this client.",
            data.id,
            true
        )
    end
    
    function BaseBridge:FormatResponse(message, id, isError, includeStructured)
        if isError then
            return {
                error = tostring(message),
                success = false,
                id = id
            }
        end
        
        local output = SanitizeForOutput(message)
        if typeof(output) ~= "table" then
            output = { output }
        end
    
        local response = {
            output = LuaEncode(output, {
                Prettify = false
            }),
            success = true,
            id = id
        }
        if includeStructured then
            response.structured = output
        end
        return response
    end
    
    function BaseBridge:IsAlive()
        local success, result = pcall(function()
            local response
            local thread = task.spawn(function()
                local success, data
                if Request then
                    success, data = pcall(Request, {
                        Url = BridgeHTTPURL,
                        Method = "GET",
                        Headers = BridgeRequestHeaders()
                    })
                else
                    success, data = pcall(function()
                        return { StatusCode = 200, Body = HttpGet(BridgeHTTPURL) }
                    end)
                end

                if success then
                    response = data
                end
            end)
            self.AliveProbeThread = thread

            local start = os.clock()
            repeat task.wait(0.05) until response ~= nil or os.clock() - start > 5
            if self.AliveProbeThread == thread then self.AliveProbeThread = nil end

            if response == nil then
                task.cancel(thread)
                return false
            end
    
            -- 426 = Upgrade Required (WebSocket), 200 = HTTP mode
            if response.StatusCode == 426 or response.StatusCode == 200 then
                return true
            end
    
            return false
        end)
    
        if not success then
            return false
        end
    
        return result
    end
end

--// WebSocket Bridge \\--
local WebSocketBridge = setmetatable({}, {__index = BaseBridge}); do
    WebSocketBridge.__index = WebSocketBridge

    function WebSocketBridge.new()
        local self = setmetatable({}, WebSocketBridge)
    
        --// Yield until the server is alive with exponential backoff \\--
        local retryDelay = 0.5
        local maxRetryDelay = 5
        local maxAttempts = 10
        local attempts = 0
        
        while not self:IsAlive() do
            attempts += 1
            if attempts >= maxAttempts then
                error("Failed to connect to bridge server after " .. maxAttempts .. " attempts")
            end
            task.wait(retryDelay)
            retryDelay = math.min(retryDelay * 1.5, maxRetryDelay)
        end
    
        --// Connect to the server with timeout \\--
        local wsConnection = nil
        local connectionFinished = false
        local connectionThread = task.spawn(function()
            local success, result = pcall(function()
                local websocketUrl = BridgeWebSocketURL
                if BridgeAuthToken ~= "" then
                    websocketUrl ..= "?token=" .. HttpService:UrlEncode(BridgeAuthToken)
                end
                return WebSocketConnect(websocketUrl)
            end)
            if success then
                wsConnection = result
            end
            connectionFinished = true
        end)
        
        local connectionStart = os.clock()
        repeat task.wait(0.05) until wsConnection ~= nil or connectionFinished or os.clock() - connectionStart > 5
        
        if wsConnection == nil then
            if not connectionFinished then
                task.cancel(connectionThread)
            end
            error(connectionFinished and "WebSocket connection failed" or "WebSocket connection timed out after 5 seconds")
        end
        
        self.WebSocket = wsConnection
        self.Connected = true
        self.Callbacks = {}
        self.ClientId = nil
        self.Connections = {}

        -- Attach listeners before Send: some executors deliver the reply inline.
        local registered = pcall(function()
            self.Connections.message = self.WebSocket.OnMessage:Connect(function(message)
                local ok, data = pcall(function() return HttpService:JSONDecode(message) end)
                if not ok or type(data) ~= "table" then return end
                if data.type == "registered" then
                    if type(data.clientId) ~= "string" or data.clientId == ""
                        or type(data.clientToken) ~= "string" or data.clientToken == "" then return end
                    self.ClientId = data.clientId
                    self.ClientToken = data.clientToken
                    getgenv().MCP_ClientToken = data.clientToken
                    return
                end
                self:DispatchMessage(data)
            end)
            self.Connections.close = self.WebSocket.OnClose:Connect(function()
                self.Connected = false
            end)
            self.WebSocket:Send(HttpService:JSONEncode(GetRegistrationInfo()))
            local deadline = os.clock() + 5
            while self.Connected and not self.ClientId and os.clock() < deadline do task.wait(0.05) end
            assert(self.Connected and self.ClientId, "WebSocket registration was not acknowledged.")
        end)
        if not registered then
            self:Disconnect()
            error("WebSocket registration failed or timed out; trying HTTP transport.")
        end

        self.AliveThread = task.spawn(function()
            local consecutiveFailures = 0
            while task.wait(1) do
                if not self.Connected then
                    break
                end

                if self:IsAlive() then
                    consecutiveFailures = 0
                    continue
                end

                consecutiveFailures += 1
                if consecutiveFailures < 3 then
                    continue
                end
                
                self.Connected = false
                break
            end
    
            pcall(function()
                self.WebSocket:Close()
            end)
        end)
    
        return self
    end
    
    function WebSocketBridge:WaitForDisconnect()
        while self.Connected do
            task.wait(0.1)
        end
        self:Disconnect()
    end
end

--// HTTP Polling Bridge \\--
local HTTPBridge = setmetatable({}, {__index = BaseBridge}); do
    HTTPBridge.__index = HTTPBridge
    
    function HTTPBridge.new()
        assert(Request, "This executor exposes neither a working WebSocket nor a supported HTTP request API.")
        local self = setmetatable({}, HTTPBridge)
    
        --// Yield until the server is alive with exponential backoff \\--
        local retryDelay = 0.5
        local maxRetryDelay = 5
        local maxAttempts = 10
        local attempts = 0
        
        while not self:IsAlive() do
            attempts += 1
            if attempts >= maxAttempts then
                error("Failed to connect to bridge server after " .. maxAttempts .. " attempts")
            end
            task.wait(retryDelay)
            retryDelay = math.min(retryDelay * 1.5, maxRetryDelay)
        end
    
        self.Connected = true
        self.Callbacks = {}
        self.PollInterval = 0.1
        self.ClientId = nil

        --// Register with the server \\--
        local registered, registrationError = pcall(function()
            local regResponse = Request({
                Url = BridgeHTTPURL .. "/register",
                Method = "POST",
                Headers = BridgeRequestHeaders({ ["Content-Type"] = "application/json" }),
                Body = HttpService:JSONEncode(GetRegistrationInfo()),
            })
            if regResponse.StatusCode == 200 and regResponse.Body then
                local regData = HttpService:JSONDecode(regResponse.Body)
                self.ClientId = regData.clientId
                self.ClientToken = regData.clientToken
                getgenv().MCP_ClientToken = regData.clientToken
            end
        end)
        if not registered or type(self.ClientId) ~= "string" or self.ClientId == ""
            or type(self.ClientToken) ~= "string" or self.ClientToken == "" then
            self.Connected = false
            error("Bridge HTTP registration failed: " .. tostring(registrationError or "server rejected registration"))
        end
    
        --// Start polling thread \\--
        self.PollThread = task.spawn(function()
            local consecutiveFailures = 0
            
            while self.Connected do
                local gotCommands = false
                local success, _ = pcall(function()
                    local pollUrl = BridgeHTTPURL .. "/poll"
                    if self.ClientId then
                        pollUrl = pollUrl .. "?clientId=" .. self.ClientId
                    end
                    local response = Request({
                        Url = pollUrl,
                        Method = "GET",
                        Headers = BridgeRequestHeaders()
                    })

                    --// Server might be down \\--
                    if response.StatusCode ~= 204 and response.StatusCode ~= 200 then
                        consecutiveFailures += 1
                        if consecutiveFailures >= 3 then
                            self.Connected = false
                        end

                        return
                    end
                    
                    consecutiveFailures = 0
    
                    --// Handle response \\--
                    if response.Body and response.Body ~= "" then
                        local data = HttpService:JSONDecode(response.Body)
                        local commands = {}
                        if typeof(data) == "table" and data.type == nil and #data > 0 then
                            commands = data
                        elseif typeof(data) == "table" and data.type ~= nil then
                            commands = { data }
                        end

                        for _, command in ipairs(commands) do
                            gotCommands = true
                            self:DispatchMessage(command)
                        end
                    end
                end)
    
                if not success then
                    consecutiveFailures += 1
                    if consecutiveFailures >= 3 then
                        self.Connected = false
                    end
                end
    
                if not gotCommands then
                    task.wait(self.PollInterval)
                end
            end
        end)
    
        return self
    end
    
    function HTTPBridge:WaitForDisconnect()
        while self.Connected do
            task.wait(0.1)
        end
        self:Disconnect()
    end
end

--// Create Bridge \\--
local function CreateBridge()
    if WebSocketAvailable and os.clock() >= websocketRetryAfter then
        local success, bridge = pcall(function()
            return WebSocketBridge.new()
        end)
        
        if success then
            websocketRetryAfter = 0
            return bridge
        end

        -- An API existing does not guarantee it works. Prefer working HTTP
        -- briefly instead of stalling every reconnect, then probe again later.
        websocketRetryAfter = os.clock() + websocketRetryDelay
    end

    return HTTPBridge.new()
end

return {
    CreateBridge = CreateBridge,
}
end
