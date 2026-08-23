local InstancePath = require("../instance-path")

local function ClampInteger(value, fallback, minimum, maximum)
    local parsed = tonumber(value)
    if parsed == nil or parsed ~= parsed then parsed = fallback end
    return math.max(minimum, math.min(maximum, math.floor(parsed)))
end

local function ResolveActor(data, Handles)
    if data.handle then
        local value = Handles:Resolve(data.handle)
        assert(typeof(value) == "Instance" and value:IsA("Actor"), "Actor handle does not reference an Actor Instance.")
        return value
    end
    local value = InstancePath.Resolve(data.target)
    assert(value:IsA("Actor"), "Target Instance is not an Actor.")
    return value
end

return function(context, Bridge)
    local Handles = context.RuntimeHandles
    local Values = context.RuntimeValues

    Bridge:BindToTypeStructured("property-access", function(data)
        local target = InstancePath.Resolve(data.target)
        local property = data.property
        assert(type(property) == "string" and string.match(property, "^[%a_][%w_]*$"), "Invalid property name.")
        local operation = data.operation or "read"

        if operation == "read" then
            local ordinaryOk, ordinary = pcall(function() return target[property] end)
            local hiddenOk = false
            local hiddenValue
            local hiddenFlag
            if not ordinaryOk and type(gethiddenproperty) == "function" then
                hiddenOk, hiddenValue, hiddenFlag = pcall(gethiddenproperty, target, property)
            end
            assert(ordinaryOk or hiddenOk, "Property read failed: " .. tostring(ordinary) .. "; " .. tostring(hiddenValue))
            local value = hiddenOk and hiddenValue or ordinary
            return {
                operation = operation,
                target = InstancePath.Describe(target),
                property = property,
                accessMethod = hiddenOk and "gethiddenproperty" or "ordinary",
                hidden = hiddenOk and hiddenFlag == true or nil,
                value = Values:Encode(value),
            }
        end

        if operation == "write" then
            local replacement = Values:Decode(data.value)
            local previous
            local previousOk, previousValue = pcall(function() return target[property] end)
            if not previousOk and type(gethiddenproperty) == "function" then
                previousOk, previousValue = pcall(gethiddenproperty, target, property)
            end
            if previousOk then previous = previousValue end

            local hiddenOk = false
            local hiddenError
            if data.preferHidden ~= false and type(sethiddenproperty) == "function" then
                hiddenOk, hiddenError = pcall(sethiddenproperty, target, property, replacement)
            end
            if not hiddenOk then
                local ordinaryOk, ordinaryError = pcall(function() target[property] = replacement end)
                assert(ordinaryOk, "Property write failed: " .. tostring(hiddenError) .. "; " .. tostring(ordinaryError))
            end
            return {
                operation = operation,
                target = InstancePath.Describe(target),
                property = property,
                accessMethod = hiddenOk and "sethiddenproperty" or "ordinary",
                previous = Values:Encode(previous),
                value = Values:Encode(replacement),
                written = true,
            }
        end

        if operation == "scriptable-status" then
            assert(type(isscriptable) == "function", "This executor does not expose isscriptable.")
            local ok, scriptable = pcall(isscriptable, target, property)
            assert(ok, "isscriptable failed: " .. tostring(scriptable))
            return {
                operation = operation,
                target = InstancePath.Describe(target),
                property = property,
                scriptable = scriptable == true,
            }
        end

        if operation == "set-scriptable" then
            assert(type(setscriptable) == "function", "This executor does not expose setscriptable.")
            local ok, previous = pcall(setscriptable, target, property, data.scriptable == true)
            assert(ok, "setscriptable failed: " .. tostring(previous))
            return {
                operation = operation,
                target = InstancePath.Describe(target),
                property = property,
                previous = previous,
                scriptable = data.scriptable == true,
            }
        end
        error("Unknown property-access operation: " .. tostring(operation))
    end)

    Bridge:BindToTypeStructured("callback-inspect", function(data)
        local target = InstancePath.Resolve(data.target)
        local property = data.property
        assert(type(property) == "string" and string.match(property, "^[%a_][%w_]*$"), "Invalid callback property name.")
        local operation = data.operation or "inspect"

        local readOk
        local callback
        if type(getcallbackvalue) == "function" then
            readOk, callback = pcall(getcallbackvalue, target, property)
        end
        if not readOk then readOk, callback = pcall(function() return target[property] end) end
        assert(readOk, "Callback property could not be read: " .. tostring(callback))

        if operation == "inspect" then
            return {
                operation = operation,
                target = InstancePath.Describe(target),
                property = property,
                callback = Values:Encode(callback),
                callbackType = typeof(callback),
            }
        end

        if operation == "replace" then
            local replacement = Values:Decode(data.value)
            assert(replacement == nil or type(replacement) == "function", "Callback replacement must be nil or a function handle.")
            local ok, writeError = pcall(function() target[property] = replacement end)
            assert(ok, "Callback replacement failed: " .. tostring(writeError))
            return {
                operation = operation,
                target = InstancePath.Describe(target),
                property = property,
                previous = Values:Encode(callback),
                callback = Values:Encode(replacement),
                replaced = true,
            }
        end
        error("Unknown callback-inspect operation: " .. tostring(operation))
    end)

    Bridge:BindToTypeStructured("runtime-actors", function(data)
        local operation = data.operation or "list"
        if operation == "list" then
            assert(type(getactors) == "function", "This executor does not expose getactors.")
            local ok, actors = pcall(getactors)
            assert(ok and type(actors) == "table", "getactors failed: " .. tostring(actors))
            local cursor = ClampInteger(data.cursor, 0, 0, 1000000000)
            local limit = ClampInteger(data.limit, 50, 1, 200)
            local results = {}
            for index = cursor + 1, math.min(#actors, cursor + limit) do
                local actor = actors[index]
                if typeof(actor) == "Instance" then
                    local description = InstancePath.Describe(actor)
                    description.Handle = Handles:Register(actor, "instance", {
                        className = description.ClassName,
                        path = description.Path,
                        actor = true,
                    })
                    table.insert(results, description)
                end
            end
            local nextCursor = cursor + #results
            return {
                operation = operation,
                total = #actors,
                cursor = cursor,
                nextCursor = nextCursor < #actors and nextCursor or nil,
                actors = results,
            }
        end

        if operation == "threads" then
            assert(type(getactorthreads) == "function", "This executor does not expose getactorthreads.")
            local actor = ResolveActor(data, Handles)
            local ok, threads = pcall(getactorthreads, actor)
            assert(ok and type(threads) == "table", "getactorthreads failed: " .. tostring(threads))
            local results = {}
            for index, thread in threads do
                if index > 500 then break end
                table.insert(results, (Values:Encode(thread)))
            end
            return {
                operation = operation,
                actor = InstancePath.Describe(actor),
                threadCount = #threads,
                threads = results,
                truncated = #threads > #results,
            }
        end
        error("Unknown runtime-actors operation: " .. tostring(operation))
    end)
end
