local InstancePath = require("../instance-path")

local function ClampInteger(value, fallback, minimum, maximum)
    local parsed = tonumber(value)
    if parsed == nil or parsed ~= parsed then parsed = fallback end
    return math.max(minimum, math.min(maximum, math.floor(parsed)))
end

local function ReadField(value, field)
    local ok, result = pcall(function() return value[field] end)
    return ok and result or nil
end

local function DescribeConnection(connection, Handles, Values)
    local handle = Handles:Register(connection, "connection")
    return {
        handle = handle,
        enabled = ReadField(connection, "Enabled"),
        connected = ReadField(connection, "Connected"),
        luaConnection = ReadField(connection, "LuaConnection"),
        foreignState = ReadField(connection, "ForeignState"),
        functionValue = Values:Encode(ReadField(connection, "Function")),
        threadValue = Values:Encode(ReadField(connection, "Thread")),
        operations = {
            enable = type(ReadField(connection, "Enable")) == "function",
            disable = type(ReadField(connection, "Disable")) == "function",
            disconnect = type(ReadField(connection, "Disconnect")) == "function",
            fire = type(ReadField(connection, "Fire")) == "function",
            defer = type(ReadField(connection, "Defer")) == "function",
        },
    }
end

local function ResolveSignal(target, signalName)
    local instance = InstancePath.Resolve(target)
    assert(type(signalName) == "string" and string.match(signalName, "^[%a_][%w_]*$"), "Invalid signal name.")
    local ok, signal = pcall(function() return instance[signalName] end)
    assert(ok and typeof(signal) == "RBXScriptSignal", signalName .. " is not an RBXScriptSignal on the target Instance.")
    return instance, signal
end

return function(context, Bridge)
    local Handles = context.RuntimeHandles
    local Values = context.RuntimeValues

    Bridge:BindToTypeStructured("signal-connections", function(data)
        local operation = data.operation or "list"
        if operation == "list" then
            assert(type(getconnections) == "function", "This executor does not expose getconnections.")
            local instance, signal = ResolveSignal(data.target, data.signal)
            local ok, connections = pcall(getconnections, signal)
            assert(ok and type(connections) == "table", "getconnections failed: " .. tostring(connections))
            local cursor = ClampInteger(data.cursor, 0, 0, 1000000000)
            local limit = ClampInteger(data.limit, 50, 1, 200)
            local results = {}
            for index = cursor + 1, math.min(#connections, cursor + limit) do
                table.insert(results, DescribeConnection(connections[index], Handles, Values))
            end
            local nextCursor = cursor + #results
            return {
                operation = operation,
                target = InstancePath.Describe(instance),
                signal = data.signal,
                signalHandle = Handles:Register(signal, "signal", {
                    path = InstancePath.StablePath(instance),
                    signal = data.signal,
                }),
                total = #connections,
                cursor = cursor,
                nextCursor = nextCursor < #connections and nextCursor or nil,
                connections = results,
            }
        end

        if operation == "fire-signal" then
            assert(type(firesignal) == "function", "This executor does not expose firesignal.")
            local instance, signal = ResolveSignal(data.target, data.signal)
            local arguments = {}
            local argumentCount = #(data.arguments or {})
            for index, argument in data.arguments or {} do
                assert(index <= 32, "At most 32 signal arguments are accepted.")
                arguments[index] = Values:Decode(argument)
            end
            local ok, fireError = pcall(firesignal, signal, table.unpack(arguments, 1, argumentCount))
            assert(ok, "firesignal failed: " .. tostring(fireError))
            return { operation = operation, target = InstancePath.Describe(instance), signal = data.signal, fired = true }
        end

        local connection = Handles:Resolve(data.handle, "connection")
        if operation == "inspect" then return DescribeConnection(connection, Handles, Values) end

        local methodName = ({
            enable = "Enable",
            disable = "Disable",
            disconnect = "Disconnect",
            fire = "Fire",
            defer = "Defer",
        })[operation]
        assert(methodName ~= nil, "Unknown signal-connections operation: " .. tostring(operation))
        local method = ReadField(connection, methodName)
        assert(type(method) == "function", "Connection does not support " .. methodName .. ".")
        local arguments = {}
        local argumentCount = #(data.arguments or {})
        for index, argument in data.arguments or {} do
            assert(index <= 32, "At most 32 connection arguments are accepted.")
            arguments[index] = Values:Decode(argument)
        end
        local ok, operationError = pcall(method, connection, table.unpack(arguments, 1, argumentCount))
        assert(ok, methodName .. " failed: " .. tostring(operationError))
        local result = DescribeConnection(connection, Handles, Values)
        result.operation = operation
        result.completed = true
        return result
    end)
end
