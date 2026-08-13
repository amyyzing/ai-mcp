return function(context)
local HttpService = context.HttpService
local BridgeHTTPURL = context.BridgeHTTPURL
local BridgeWebSocketURL = context.BridgeWebSocketURL
local BridgeAuthToken = context.BridgeAuthToken
local BridgeRequestHeaders = context.BridgeRequestHeaders
local WebSocketAvailable = context.WebSocketAvailable
local WebSocketConnect = context.WebSocketConnect
local GetRegistrationInfo = context.GetRegistrationInfo
local SanitizeForOutput = context.SanitizeForOutput
local LuaEncode = context.LuaEncode
local websocketRetryAfter = 0
local websocketRetryDelay = 30

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
        return nil
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
                local success, data = pcall(request, {
                    Url = BridgeHTTPURL,
                    Method = "GET",
                    Headers = BridgeRequestHeaders()
                })

                if success then
                    response = data
                end
            end)

            local start = os.clock()
            repeat task.wait(0.05) until response ~= nil or os.clock() - start > 5

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

        --// Send registration \\--
        self.WebSocket:Send(HttpService:JSONEncode(GetRegistrationInfo()))

        self.AliveThread = task.spawn(function()
            local consecutiveFailures = 0
            while task.wait(1) do
                if not self.Connected then
                    continue
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
    
        --// On Message \\--
        self.WebSocket.OnMessage:Connect(function(message)
            local data = HttpService:JSONDecode(message)

            --// Handle registration response \\--
            if data.type == "registered" then
                self.ClientId = data.clientId
                self.ClientToken = data.clientToken
                getgenv().MCP_ClientToken = data.clientToken
                return
            end

            local response = self:HandleMessage(data)
            if response then
                self.WebSocket:Send(EncodeBridgeResponse(response))
            end
        end)
    
        --// On Close \\--
        self.WebSocket.OnClose:Connect(function()
            self.Connected = false
        end)
    
        return self
    end
    
    function WebSocketBridge:WaitForDisconnect()
        while self.Connected do
            task.wait(0.1)
        end
    end
end

--// HTTP Polling Bridge \\--
local HTTPBridge = setmetatable({}, {__index = BaseBridge}); do
    HTTPBridge.__index = HTTPBridge
    
    function HTTPBridge.new()
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
            local regResponse = request({
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
        if not registered or type(self.ClientId) ~= "string" or type(self.ClientToken) ~= "string" then
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
                    local response = request({
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
                            task.spawn(function()
                                local result = self:HandleMessage(command)
                                if result == nil then return end
                                result.clientId = self.ClientId

                                --// Send response back \\--
                                request({
                                    Url = BridgeHTTPURL .. "/respond?clientId=" .. HttpService:UrlEncode(self.ClientId),
                                    Method = "POST",
                                    Headers = BridgeRequestHeaders({
                                        ["Content-Type"] = "application/json"
                                    }),
                                    Body = EncodeBridgeResponse(result)
                                })
                            end)
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
