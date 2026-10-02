local ExecutorHttp = {}

local function AddCandidate(candidates, provider, callback)
    if type(callback) == "function" then
        for _, candidate in ipairs(candidates) do
            if candidate.callback == callback then return end
        end
        table.insert(candidates, {
            provider = provider,
            callback = callback,
        })
    end
end

local function NormalizeResponse(response)
    assert(type(response) == "table", "Executor HTTP API returned a non-table response.")
    local statusCode = tonumber(
        response.StatusCode or response.Status or response.status_code or response.status
    )
    assert(statusCode ~= nil and statusCode >= 100 and statusCode <= 599 and statusCode % 1 == 0,
        "Executor HTTP response did not include a valid status code.")
    local body = response.Body or response.body or response.ResponseBody or ""
    assert(type(body) == "string", "Executor HTTP response body was not a string.")
    return {
        StatusCode = statusCode,
        Body = body,
        Headers = response.Headers or response.headers or {},
    }
end

local function NormalizeOptions(options)
    local normalized = table.clone(options)
    for _, names in ipairs({ { "Url", "url" }, { "Method", "method" }, { "Headers", "headers" }, { "Body", "body" } }) do
        local value = options[names[1]] or options[names[2]]
        if names[1] == "Headers" and type(value) == "table" then value = table.clone(value) end
        normalized[names[1]], normalized[names[2]] = value, value
    end
    return normalized
end

function ExecutorHttp.Resolve(environment, options)
    environment = environment or getgenv()
    options = options or {}
    local candidates = {}
    AddCandidate(candidates, "request", environment.request)
    AddCandidate(candidates, "http_request", environment.http_request)
    AddCandidate(candidates, "httprequest", environment.httprequest)

    for _, entry in {
        { name = "http.request", owner = environment.http },
        { name = "syn.request", owner = environment.syn },
        { name = "fluxus.request", owner = environment.fluxus },
        { name = "krnl.request", owner = environment.krnl },
    } do
        if typeof(entry.owner) == "table" then
            AddCandidate(candidates, entry.name, entry.owner.request)
        end
    end

    local selected, validated, failures = 1, false, 0
    local function GetStatus()
        return {
            provider = candidates[selected] and candidates[selected].provider or "unavailable",
            candidates = #candidates,
            responseValidated = validated,
            failedRequests = failures,
        }
    end
    if #candidates == 0 then return nil, "unavailable", GetStatus end

    local function Request(requestOptions)
        assert(type(requestOptions) == "table", "Executor HTTP options must be a table.")
        local url = requestOptions.Url or requestOptions.url
        local method = string.upper(tostring(requestOptions.Method or requestOptions.method or "GET"))
        -- Only the configured, read-only reachability probe can try another API.
        -- Polling drains a command queue; POSTs can have effects before failing.
        local probe = options.ProbeUrl ~= nil and url == options.ProbeUrl and method == "GET"
        local first = selected
        for offset = 0, (if probe then #candidates - 1 else 0) do
            local index = ((first + offset - 1) % #candidates) + 1
            local candidate = candidates[index]
            local ok, response = pcall(function()
                return NormalizeResponse(candidate.callback(NormalizeOptions(requestOptions)))
            end)
            if ok then
                selected, validated = index, true
                -- A valid 4xx/5xx is a server response, not a broken executor API.
                return response
            end
            validated = false
            failures += 1
        end
        -- Native error strings can contain URLs/headers; do not echo credentials.
        error(if probe then "No executor HTTP API passed the bridge reachability probe."
            else "Executor HTTP provider " .. candidates[selected].provider .. " failed or returned an invalid response; request was not replayed.")
    end
    return Request, candidates[selected].provider, GetStatus
end

return ExecutorHttp
