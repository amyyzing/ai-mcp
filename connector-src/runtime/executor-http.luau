local ExecutorHttp = {}

local function AddCandidate(candidates, provider, callback)
    if type(callback) == "function" then
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
    assert(statusCode ~= nil, "Executor HTTP response did not include a status code.")
    return {
        StatusCode = statusCode,
        Body = response.Body or response.body or response.ResponseBody or "",
        Headers = response.Headers or response.headers or {},
    }
end

function ExecutorHttp.Resolve(environment)
    environment = environment or getgenv()
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

    for _, candidate in candidates do
        local callback = candidate.callback
        local function Request(options)
            local normalizedOptions = {}
            for key, value in options do
                normalizedOptions[key] = value
            end
            normalizedOptions.url = normalizedOptions.url or normalizedOptions.Url
            normalizedOptions.method = normalizedOptions.method or normalizedOptions.Method
            normalizedOptions.headers = normalizedOptions.headers or normalizedOptions.Headers
            normalizedOptions.body = normalizedOptions.body or normalizedOptions.Body
            local ok, response = pcall(callback, normalizedOptions)
            assert(ok, response)
            return NormalizeResponse(response)
        end
        return Request, candidate.provider
    end

    return nil, "unavailable"
end

return ExecutorHttp
