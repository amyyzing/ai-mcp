-- One idle listener for the whole executor session, including bridge reconnects.
return function(options)
    local globals = options.Environment or getgenv()
    local previous = globals.RobloxMCPAntiAFK
    if type(previous) == "table" and previous.Version == 1
        and previous.Connection and previous.Connection.Connected then return previous end

    local api = {Version = 1, Enabled = false, Attempts = 0, Succeeded = 0, Failed = 0}
    function api.Pulse()
        if not api.Enabled then return false end
        api.Attempts += 1
        local ok, problem = pcall(options.KeepAlive)
        if ok then
            api.Succeeded += 1
            api.LastError = nil
        else
            api.Failed += 1
            api.LastError = string.sub(tostring(problem), 1, 240)
        end
        return ok
    end
    function api.GetStatus()
        return {enabled = api.Enabled and api.Connection ~= nil and api.Connection.Connected,
            backend = "virtual-user", attempts = api.Attempts, succeeded = api.Succeeded,
            failed = api.Failed, lastError = api.LastError}
    end
    function api.Destroy()
        api.Enabled = false
        if api.Connection then api.Connection:Disconnect() api.Connection = nil end
        if globals.RobloxMCPAntiAFK == api then globals.RobloxMCPAntiAFK = nil end
    end
    local ok, connection = pcall(function() return options.Player.Idled:Connect(api.Pulse) end)
    if ok then
        api.Connection = connection
        api.Enabled = true
    else
        api.LastError = string.sub(tostring(connection), 1, 240)
    end
    globals.RobloxMCPAntiAFK = api
    return api
end
