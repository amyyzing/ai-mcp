local InstancePath = require("../instance-path")

local function ClampInteger(value, fallback, minimum, maximum)
    local parsed = tonumber(value)
    if parsed == nil or parsed ~= parsed then parsed = fallback end
    return math.max(minimum, math.min(maximum, math.floor(parsed)))
end

local function AddEnvironment(results, seen, Handles, name, value, quality)
    if type(value) ~= "table" then return end
    local handle = Handles:Register(value, "table", { environment = name })
    if seen[handle] then return end
    seen[handle] = true
    table.insert(results, { name = name, handle = handle, quality = quality or "exact" })
end

return function(context, Bridge)
    local Handles = context.RuntimeHandles
    local Values = context.RuntimeValues

    Bridge:BindToTypeStructured("runtime-environments", function(data)
        local operation = data.operation or "list"
        if operation == "list" then
            local results = {}
            local seen = {}
            AddEnvironment(results, seen, Handles, "getgenv", getgenv(), "exact")
            if type(getrenv) == "function" then
                local ok, value = pcall(getrenv)
                if ok then AddEnvironment(results, seen, Handles, "getrenv", value, "best-effort") end
            end
            if type(getfenv) == "function" then
                local ok, value = pcall(getfenv, 0)
                if ok then AddEnvironment(results, seen, Handles, "getfenv(0)", value, "best-effort") end
            end
            AddEnvironment(results, seen, Handles, "_G", _G, "roblox-api")
            AddEnvironment(results, seen, Handles, "shared", shared, "roblox-api")
            return { environments = results, count = #results }
        end

        if operation == "script" then
            assert(type(getsenv) == "function", "This executor does not expose getsenv.")
            local scriptInstance = InstancePath.Resolve(data.target)
            local ok, environment = pcall(getsenv, scriptInstance)
            assert(ok and type(environment) == "table", "getsenv failed: " .. tostring(environment))
            local handle = Handles:Register(environment, "table", {
                environment = "script",
                scriptPath = InstancePath.StablePath(scriptInstance),
            })
            return {
                operation = operation,
                script = InstancePath.Describe(scriptInstance),
                environment = { type = "handle", kind = "table", handle = handle },
            }
        end

        if operation == "handle" then
            assert(type(getfenv) == "function", "This executor does not expose getfenv.")
            local value = Handles:Resolve(data.handle)
            local ok, environment = pcall(getfenv, value)
            assert(ok and type(environment) == "table", "getfenv failed: " .. tostring(environment))
            return {
                operation = operation,
                sourceHandle = data.handle,
                environment = Values:Encode(environment),
            }
        end
        error("Unknown runtime-environments operation: " .. tostring(operation))
    end)

    Bridge:BindToTypeStructured("runtime-scripts", function(data)
        local operation = data.operation or "list"
        if operation == "closure" then
            assert(type(getscriptclosure) == "function", "This executor does not expose getscriptclosure.")
            local scriptInstance = InstancePath.Resolve(data.target)
            local ok, closure = pcall(getscriptclosure, scriptInstance)
            assert(ok and type(closure) == "function", "getscriptclosure failed: " .. tostring(closure))
            return {
                operation = operation,
                script = InstancePath.Describe(scriptInstance),
                closure = Values:Encode(closure),
            }
        end

        assert(operation == "list", "Unknown runtime-scripts operation: " .. tostring(operation))
        local collection = data.collection or "scripts"
        local getter
        if collection == "scripts" then getter = getscripts end
        if collection == "running" then getter = getrunningscripts end
        if collection == "loaded-modules" then getter = getloadedmodules end
        if collection == "nil-instances" then getter = getnilinstances end
        if collection == "all-instances" then getter = getinstances end
        assert(type(getter) == "function", "This executor does not expose the requested " .. collection .. " inventory.")

        local ok, values = pcall(getter)
        assert(ok and type(values) == "table", collection .. " inventory failed: " .. tostring(values))
        local cursor = ClampInteger(data.cursor, 0, 0, 1000000000)
        local limit = ClampInteger(data.limit, 50, 1, 200)
        local scanCeiling = cursor + limit + 1
        local results = {}
        local total = 0
        local sourceScanned = 0
        local totalIsLowerBound = false
        for _, value in values do
            sourceScanned += 1
            if sourceScanned % 500 == 0 then task.wait() end
            if typeof(value) ~= "Instance" then continue end
            if total >= cursor and #results < limit then
                local description = InstancePath.Describe(value)
                description.Handle = Handles:Register(value, "instance", {
                    className = description.ClassName,
                    path = description.Path,
                })
                if data.includeHashes == true then
                    if type(getscripthash) == "function" and value:IsA("LuaSourceContainer") then
                        pcall(function() description.ScriptHash = getscripthash(value) end)
                    end
                    if type(getscriptbytecode) == "function" and value:IsA("LuaSourceContainer") then
                        local bytecodeOk, bytecode = pcall(getscriptbytecode, value)
                        if bytecodeOk and type(bytecode) == "string" then description.BytecodeBytes = #bytecode end
                    end
                end
                table.insert(results, description)
            end
            total += 1
            if total >= scanCeiling then
                totalIsLowerBound = true
                break
            end
        end
        local nextCursor = cursor + #results
        return {
            operation = operation,
            collection = collection,
            total = total,
            totalIsLowerBound = totalIsLowerBound,
            sourceReturnedByExecutor = #values,
            sourceScanned = sourceScanned,
            cursor = cursor,
            nextCursor = (totalIsLowerBound or nextCursor < total) and nextCursor or nil,
            results = results,
        }
    end)
end
