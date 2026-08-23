local InstancePath = require("../instance-path")

local function ClampInteger(value, fallback, minimum, maximum)
    local parsed = tonumber(value)
    if parsed == nil or parsed ~= parsed then parsed = fallback end
    return math.max(minimum, math.min(maximum, math.floor(parsed)))
end

local function FunctionGetter(primary, fallbackName)
    if type(primary) == "function" then return primary end
    if type(debug) == "table" and type(debug[fallbackName]) == "function" then return debug[fallbackName] end
    return nil
end

local function FirstFunction(...)
    for _, value in { ... } do
        if type(value) == "function" then return value end
    end
    return nil
end

local function SafeFunctionCollection(value, primary, fallbackName)
    local getter = FunctionGetter(primary, fallbackName)
    if not getter then return nil, "Executor does not expose " .. fallbackName .. "." end
    local ok, result = pcall(getter, value)
    if not ok then return nil, tostring(result) end
    if type(result) ~= "table" then return nil, fallbackName .. " returned a non-table value." end
    return result, nil
end

local function FunctionDetails(value)
    local result = {}
    pcall(function() result.name = debug.info(value, "n") end)
    pcall(function() result.source = debug.info(value, "s") end)
    pcall(function() result.line = debug.info(value, "l") end)
    pcall(function() result.parameterCount, result.isVararg = debug.info(value, "a") end)
    if type(getfunctionhash) == "function" then
        pcall(function() result.hash = getfunctionhash(value) end)
    end
    if type(isexecutorclosure) == "function" then
        pcall(function() result.executorClosure = isexecutorclosure(value) == true end)
    end
    if type(islclosure) == "function" then pcall(function() result.luaClosure = islclosure(value) == true end) end
    if type(iscclosure) == "function" then pcall(function() result.cClosure = iscclosure(value) == true end) end
    return result
end

local function PageCollection(collection, cursor, limit, Values)
    cursor = ClampInteger(cursor, 0, 0, 1000000000)
    limit = ClampInteger(limit, 25, 1, 200)
    local results = {}
    local total = 0
    local scanTruncated = false
    local scanCeiling = cursor + limit + 1
    for key, value in pairs(collection or {}) do
        if total >= scanCeiling then scanTruncated = true break end
        if total >= cursor and #results < limit then
            table.insert(results, {
                key = Values:Encode(key),
                value = Values:Encode(value),
            })
        end
        total += 1
    end
    local nextCursor = cursor + #results
    return {
        total = total,
        totalIsLowerBound = scanTruncated,
        cursor = cursor,
        nextCursor = (scanTruncated or nextCursor < total) and nextCursor or nil,
        entries = results,
    }
end

local function ReadConnectionField(connection, name)
    local ok, value = pcall(function() return connection[name] end)
    return ok and value or nil
end

return function(context, Bridge)
    local Handles = context.RuntimeHandles
    local Values = context.RuntimeValues

    Bridge:BindToTypeStructured("runtime-inspect", function(data)
        local value, entry = Handles:Resolve(data.handle)
        local result = Handles:Describe(data.handle)
        result.robloxType = typeof(value)

        if entry.kind == "table" then
            result.page = PageCollection(value, data.cursor, data.limit, Values)
            result.pageStable = false
            local metatable
            local getMeta = if type(getrawmetatable) == "function" then getrawmetatable else getmetatable
            pcall(function() metatable = getMeta(value) end)
            if metatable ~= nil then result.metatable = Values:Encode(metatable) end
        elseif entry.kind == "function" then
            result.functionInfo = FunctionDetails(value)
            if data.includeConstants ~= false then
                local constants, constantsError = SafeFunctionCollection(value, getconstants, "getconstants")
                result.constants = constants and PageCollection(constants, data.cursor, data.limit, Values) or nil
                result.constantsError = constantsError
            end
            if data.includeUpvalues ~= false then
                local upvalues, upvaluesError = SafeFunctionCollection(value, getupvalues, "getupvalues")
                result.upvalues = upvalues and PageCollection(upvalues, data.cursor, data.limit, Values) or nil
                result.upvaluesError = upvaluesError
            end
            if data.includePrototypes == true then
                local prototypes, prototypesError = SafeFunctionCollection(value, getprotos, "getprotos")
                result.prototypes = prototypes and PageCollection(prototypes, data.cursor, data.limit, Values) or nil
                result.prototypesError = prototypesError
            end
        elseif entry.kind == "instance" then
            result.instance = InstancePath.Describe(value)
            local properties = {}
            local errors = {}
            for index = 1, math.min(#(data.properties or {}), 100) do
                local property = data.properties[index]
                local ok, found = pcall(function() return value[property] end)
                if ok then properties[property] = Values:Encode(found) else errors[property] = tostring(found) end
            end
            if next(properties) then result.properties = properties end
            if next(errors) then result.propertyErrors = errors end
        elseif entry.kind == "thread" then
            pcall(function() result.status = coroutine.status(value) end)
        elseif entry.kind == "connection" then
            result.connection = {
                enabled = ReadConnectionField(value, "Enabled"),
                luaConnection = ReadConnectionField(value, "LuaConnection"),
                foreignState = ReadConnectionField(value, "ForeignState"),
                functionValue = Values:Encode(ReadConnectionField(value, "Function")),
                threadValue = Values:Encode(ReadConnectionField(value, "Thread")),
            }
        else
            result.value = Values:Encode(value)
        end
        return result
    end)

    Bridge:BindToTypeStructured("runtime-read", function(data)
        local value, entry = Handles:Resolve(data.handle)
        local member = data.member
        local found
        if member == "field" then
            assert(entry.kind == "table", "field reads require a table handle.")
            found = rawget(value, Values:Decode(data.key))
        elseif member == "property" then
            assert(entry.kind == "instance", "property reads require an Instance handle.")
            assert(type(data.property) == "string" and string.match(data.property, "^[%a_][%w_]*$"), "Invalid property name.")
            found = value[data.property]
        elseif member == "upvalue" then
            assert(entry.kind == "function", "upvalue reads require a function handle.")
            local upvalues, readError = SafeFunctionCollection(value, getupvalues, "getupvalues")
            assert(upvalues, readError)
            found = upvalues[data.index]
        elseif member == "constant" then
            assert(entry.kind == "function", "constant reads require a function handle.")
            local constants, readError = SafeFunctionCollection(value, getconstants, "getconstants")
            assert(constants, readError)
            found = constants[data.index]
        elseif member == "prototype" then
            assert(entry.kind == "function", "prototype reads require a function handle.")
            local prototypes, readError = SafeFunctionCollection(value, getprotos, "getprotos")
            assert(prototypes, readError)
            found = prototypes[data.index]
        elseif member == "metatable" then
            local getMeta = if type(getrawmetatable) == "function" then getrawmetatable else getmetatable
            found = getMeta(value)
        else
            error("Unknown runtime member: " .. tostring(member))
        end
        return { handle = data.handle, member = member, value = Values:Encode(found) }
    end)

    Bridge:BindToTypeStructured("runtime-write", function(data)
        local value, entry = Handles:Resolve(data.handle)
        local member = data.member
        local replacement = Values:Decode(data.value)
        local previous
        if member == "field" then
            assert(entry.kind == "table", "field writes require a table handle.")
            local key = Values:Decode(data.key)
            previous = rawget(value, key)
            rawset(value, key, replacement)
        elseif member == "property" then
            assert(entry.kind == "instance", "property writes require an Instance handle.")
            assert(type(data.property) == "string" and string.match(data.property, "^[%a_][%w_]*$"), "Invalid property name.")
            previous = value[data.property]
            value[data.property] = replacement
        elseif member == "upvalue" then
            assert(entry.kind == "function", "upvalue writes require a function handle.")
            local upvalues, readError = SafeFunctionCollection(value, getupvalues, "getupvalues")
            assert(upvalues, readError)
            previous = upvalues[data.index]
            local setter = FunctionGetter(setupvalue, "setupvalue")
            assert(setter, "Executor does not expose setupvalue.")
            local ok, setError = pcall(setter, value, data.index, replacement)
            assert(ok, tostring(setError))
        elseif member == "constant" then
            assert(entry.kind == "function", "constant writes require a function handle.")
            local constants, readError = SafeFunctionCollection(value, getconstants, "getconstants")
            assert(constants, readError)
            previous = constants[data.index]
            local setter = FunctionGetter(setconstant, "setconstant")
            assert(setter, "Executor does not expose setconstant.")
            local ok, setError = pcall(setter, value, data.index, replacement)
            assert(ok, tostring(setError))
        else
            error("Unknown writable runtime member: " .. tostring(member))
        end
        return {
            handle = data.handle,
            member = member,
            previous = Values:Encode(previous),
            value = Values:Encode(replacement),
            written = true,
        }
    end)

    Bridge:BindToTypeStructured("runtime-call", function(data)
        local value, entry = Handles:Resolve(data.handle)
        assert(entry.kind == "function" or entry.kind == "table", "runtime-call requires a function or callable table handle.")
        local arguments = {}
        local argumentCount = #(data.arguments or {})
        for index, argument in data.arguments or {} do
            assert(index <= 32, "runtime-call accepts at most 32 arguments.")
            arguments[index] = Values:Decode(argument)
        end

        local identitySetter = FirstFunction(setthreadidentity, setidentity, setthreadcontext)
        local identityGetter = FirstFunction(getthreadidentity, getidentity, getthreadcontext)
        local previousIdentity
        local identityChanged = false
        local identityRestoreAssumed = false
        if data.threadIdentity ~= nil then
            assert(identitySetter ~= nil, "This executor does not expose a thread-identity setter.")
            if identityGetter then pcall(function() previousIdentity = identityGetter() end) end
            if previousIdentity == nil then
                previousIdentity = 8
                identityRestoreAssumed = true
            end
            local identityOk, identityError = pcall(identitySetter, data.threadIdentity)
            assert(identityOk, "Setting thread identity failed: " .. tostring(identityError))
            identityChanged = true
        end
        local packed = table.pack(pcall(value, table.unpack(arguments, 1, argumentCount)))
        if identityChanged then pcall(identitySetter, previousIdentity) end
        if packed[1] ~= true then
            return {
                handle = data.handle,
                success = false,
                error = tostring(packed[2]),
                identityRestoreAssumed = identityRestoreAssumed or nil,
            }
        end
        local results = {}
        for index = 2, math.min(packed.n, 33) do table.insert(results, (Values:Encode(packed[index]))) end
        return {
            handle = data.handle,
            success = true,
            resultCount = packed.n - 1,
            results = results,
            resultsTruncated = packed.n - 1 > #results,
            identityRestoreAssumed = identityRestoreAssumed or nil,
        }
    end)

    Bridge:BindToTypeStructured("runtime-release", function(data)
        local released, missing = Handles:ReleaseMany(data.handles)
        return { released = released, missing = missing, registry = Handles:Stats() }
    end)

    Bridge:BindToTypeStructured("runtime-handles", function(data)
        local result = Handles:List(data.cursor, data.limit, data.kind)
        result.registry = Handles:Stats()
        return result
    end)
end
