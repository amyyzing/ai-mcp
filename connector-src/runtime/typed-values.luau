local InstancePath = require("../bridge/instance-path")

local TypedValues = {}
TypedValues.__index = TypedValues

local function ClampInteger(value, fallback, minimum, maximum)
    local parsed = tonumber(value)
    if parsed == nil or parsed ~= parsed then parsed = fallback end
    return math.max(minimum, math.min(maximum, math.floor(parsed)))
end

local function SafeString(value)
    local ok, rendered = pcall(tostring, value)
    return ok and rendered or "<unprintable>"
end

local function Utf8Prefix(value, maxBytes)
    local parts = {}
    local used = 0
    local ok = pcall(function()
        for _, codepoint in utf8.codes(value) do
            local character = utf8.char(codepoint)
            if used + #character > maxBytes then break end
            table.insert(parts, character)
            used += #character
        end
    end)
    if ok then return table.concat(parts), used end
    local sanitized = string.sub(string.gsub(value, "[^%g ]", "?"), 1, maxBytes)
    return sanitized, #sanitized
end

local function FunctionSummary(value)
    local result = {}
    pcall(function() result.name = debug.info(value, "n") end)
    pcall(function() result.source = debug.info(value, "s") end)
    pcall(function() result.line = debug.info(value, "l") end)
    local hashGetter = if type(getfunctionhash) == "function" then getfunctionhash else nil
    if hashGetter then pcall(function() result.hash = hashGetter(value) end) end
    if type(isexecutorclosure) == "function" then
        pcall(function() result.executorClosure = isexecutorclosure(value) == true end)
    end
    return result
end

local function CountTable(value, scanLimit)
    local count = 0
    local exact = true
    local ok = pcall(function()
        for _ in pairs(value) do
            if count >= scanLimit then exact = false break end
            count += 1
        end
    end)
    return count, exact and ok
end

function TypedValues.new(options)
    options = options or {}
    assert(options.Handles ~= nil, "TypedValues requires a runtime handle registry.")
    return setmetatable({
        Handles = options.Handles,
        defaultDepth = ClampInteger(options.DefaultDepth, 3, 0, 8),
        defaultEntries = ClampInteger(options.DefaultEntries, 100, 1, 1000),
        defaultStringBytes = ClampInteger(options.DefaultStringBytes, 4096, 64, 65536),
    }, TypedValues)
end

function TypedValues:_handle(value, kind, summary)
    local handle = self.Handles:Register(value, kind, summary)
    return {
        type = "handle",
        kind = kind,
        handle = handle,
        summary = summary,
    }
end

function TypedValues:_encode(value, state, depth)
    local valueType = typeof(value)
    if valueType == "nil" then return { type = "nil" } end
    if valueType == "boolean" then return { type = "boolean", value = value } end
    if valueType == "number" then
        if value ~= value then return { type = "number", special = "nan" } end
        if value == math.huge then return { type = "number", special = "positive-infinity" } end
        if value == -math.huge then return { type = "number", special = "negative-infinity" } end
        if value == 0 and 1 / value == -math.huge then return { type = "number", special = "negative-zero" } end
        return { type = "number", value = value }
    end
    if valueType == "string" then
        local allowance = math.max(0, math.min(state.stringBytes, state.maxStringBytesPerValue))
        local prefix, used = Utf8Prefix(value, allowance)
        state.stringBytes -= used
        return {
            type = "string",
            value = prefix,
            originalBytes = #value ~= #prefix and #value or nil,
        }
    end

    if valueType == "Instance" then
        local description = InstancePath.Describe(value)
        local handle = self.Handles:Register(value, "instance", {
            className = description.ClassName,
            path = description.Path,
        })
        return {
            type = "instance",
            handle = handle,
            ref = {
                path = description.Path,
                name = description.Name,
                className = description.ClassName,
                debugId = description.DebugId,
            },
        }
    end

    if valueType == "Vector2" then return { type = "vector2", x = value.X, y = value.Y } end
    if valueType == "Vector3" then return { type = "vector3", x = value.X, y = value.Y, z = value.Z } end
    if valueType == "Color3" then return { type = "color3", r = value.R, g = value.G, b = value.B } end
    if valueType == "BrickColor" then return { type = "brickColor", number = value.Number, name = value.Name } end
    if valueType == "UDim" then return { type = "udim", scale = value.Scale, offset = value.Offset } end
    if valueType == "UDim2" then
        return {
            type = "udim2",
            xScale = value.X.Scale,
            xOffset = value.X.Offset,
            yScale = value.Y.Scale,
            yOffset = value.Y.Offset,
        }
    end
    if valueType == "CFrame" then
        return { type = "cframe", components = { value:GetComponents() } }
    end
    if valueType == "Rect" then
        return {
            type = "rect",
            min = { type = "vector2", x = value.Min.X, y = value.Min.Y },
            max = { type = "vector2", x = value.Max.X, y = value.Max.Y },
        }
    end
    if valueType == "Ray" then
        return {
            type = "ray",
            origin = { type = "vector3", x = value.Origin.X, y = value.Origin.Y, z = value.Origin.Z },
            direction = { type = "vector3", x = value.Direction.X, y = value.Direction.Y, z = value.Direction.Z },
        }
    end
    if valueType == "NumberRange" then return { type = "numberRange", min = value.Min, max = value.Max } end
    if valueType == "EnumItem" then
        return {
            type = "enum",
            enumType = SafeString(value.EnumType),
            name = value.Name,
            value = value.Value,
        }
    end
    if valueType == "DateTime" then return { type = "dateTime", unixTimestampMillis = value.UnixTimestampMillis } end
    if valueType == "PhysicalProperties" then
        return {
            type = "physicalProperties",
            fields = {
                density = value.Density,
                friction = value.Friction,
                elasticity = value.Elasticity,
                frictionWeight = value.FrictionWeight,
                elasticityWeight = value.ElasticityWeight,
            },
        }
    end
    if valueType == "NumberSequence" then
        local keypoints = {}
        for index, point in value.Keypoints do
            if index > state.maxEntries then break end
            table.insert(keypoints, { time = point.Time, value = point.Value, envelope = point.Envelope })
        end
        return { type = "numberSequence", keypoints = keypoints }
    end
    if valueType == "ColorSequence" then
        local keypoints = {}
        for index, point in value.Keypoints do
            if index > state.maxEntries then break end
            table.insert(keypoints, {
                time = point.Time,
                value = { type = "color3", r = point.Value.R, g = point.Value.G, b = point.Value.B },
            })
        end
        return { type = "colorSequence", keypoints = keypoints }
    end

    if valueType == "function" then
        return self:_handle(value, "function", FunctionSummary(value))
    end
    if valueType == "thread" then
        local status
        pcall(function() status = coroutine.status(value) end)
        return self:_handle(value, "thread", { status = status })
    end
    if valueType == "RBXScriptConnection" then
        return self:_handle(value, "connection", nil)
    end
    if valueType == "RBXScriptSignal" then
        return self:_handle(value, "signal", nil)
    end

    if valueType == "table" then
        local count, exact = CountTable(value, math.max(state.maxEntries, 1000))
        local summary = { entryCount = count, entryCountExact = exact }
        local handle = self.Handles:Register(value, "table", summary)
        if state.expandTables ~= true or depth >= state.maxDepth then
            return {
                type = "handle",
                kind = "table",
                handle = handle,
                summary = summary,
                omitted = depth >= state.maxDepth and "depth-limit" or nil,
            }
        end

        local seenId = state.seen[value]
        if seenId then return { type = "reference", tableId = seenId, handle = handle } end
        state.nextTableId += 1
        local tableId = state.nextTableId
        state.seen[value] = tableId
        local entries = {}
        local truncated = false
        for key, foundValue in pairs(value) do
            if state.entries >= state.maxEntries then truncated = true break end
            state.entries += 1
            table.insert(entries, {
                key = self:_encode(key, state, depth + 1),
                value = self:_encode(foundValue, state, depth + 1),
            })
        end
        return {
            type = "table",
            tableId = tableId,
            handle = handle,
            entries = entries,
            truncated = truncated or nil,
            omission = truncated and "entry-limit" or nil,
        }
    end

    if valueType == "userdata" or string.find(valueType, "Connection", 1, true) then
        return self:_handle(value, "userdata", { robloxType = valueType, display = SafeString(value) })
    end

    return {
        type = "unsupported",
        robloxType = valueType,
        display = SafeString(value),
    }
end

function TypedValues:Encode(value, options)
    options = options or {}
    local state = {
        seen = {},
        nextTableId = 0,
        entries = 0,
        maxEntries = ClampInteger(options.maxEntries, self.defaultEntries, 1, 1000),
        stringBytes = ClampInteger(options.maxStringBytes, self.defaultStringBytes, 64, 262144),
        maxStringBytesPerValue = ClampInteger(options.maxStringBytesPerValue, self.defaultStringBytes, 64, 65536),
        maxDepth = ClampInteger(options.maxDepth, self.defaultDepth, 0, 8),
        expandTables = options.expandTables == true,
    }
    local encoded = self:_encode(value, state, 0)
    return encoded, {
        encodedEntries = state.entries,
        remainingStringBytes = state.stringBytes,
        codecVersion = 1,
    }
end

local function DecodeEnum(enumType, name)
    local normalized = string.gsub(tostring(enumType or ""), "^Enum%.", "")
    local enum = Enum[normalized]
    assert(enum ~= nil, "Unknown Enum type: " .. normalized)
    local item = enum[tostring(name or "")]
    assert(item ~= nil, "Unknown Enum item: " .. normalized .. "." .. tostring(name))
    return item
end

function TypedValues:Decode(value, state)
    if type(value) ~= "table" or value.type == nil then return value end
    state = state or { tables = {}, entries = 0 }
    local valueType = value.type
    if valueType == "nil" then return nil end
    if valueType == "boolean" or valueType == "string" then return value.value end
    if valueType == "number" then
        if value.special == "nan" then return 0 / 0 end
        if value.special == "positive-infinity" then return math.huge end
        if value.special == "negative-infinity" then return -math.huge end
        if value.special == "negative-zero" then return -0.0 end
        assert(type(value.value) == "number", "Typed number requires a numeric value.")
        return value.value
    end
    if valueType == "handle" then
        local resolved = self.Handles:Resolve(value.handle)
        return resolved
    end
    if valueType == "enum" then return DecodeEnum(value.enumType, value.name) end
    if valueType == "vector2" then return Vector2.new(value.x, value.y) end
    if valueType == "vector3" then return Vector3.new(value.x, value.y, value.z) end
    if valueType == "color3" then return Color3.new(value.r, value.g, value.b) end
    if valueType == "brickColor" then return BrickColor.new(value.number or value.name) end
    if valueType == "udim" then return UDim.new(value.scale, value.offset) end
    if valueType == "udim2" then return UDim2.new(value.xScale, value.xOffset, value.yScale, value.yOffset) end
    if valueType == "cframe" then
        assert(type(value.components) == "table" and #value.components == 12, "CFrame requires 12 components.")
        return CFrame.new(table.unpack(value.components))
    end
    if valueType == "rect" then
        return Rect.new(self:Decode(value.min, state), self:Decode(value.max, state))
    end
    if valueType == "ray" then
        return Ray.new(self:Decode(value.origin, state), self:Decode(value.direction, state))
    end
    if valueType == "numberRange" then return NumberRange.new(value.min, value.max) end
    if valueType == "dateTime" then return DateTime.fromUnixTimestampMillis(value.unixTimestampMillis) end
    if valueType == "physicalProperties" then
        local fields = value.fields or {}
        return PhysicalProperties.new(
            fields.density,
            fields.friction,
            fields.elasticity,
            fields.frictionWeight,
            fields.elasticityWeight
        )
    end
    if valueType == "numberSequence" then
        local encoded = value.keypoints or {}
        state.entries += #encoded
        assert(state.entries <= 1000, "Typed sequence input exceeds 1000 keypoints.")
        local keypoints = {}
        for _, point in encoded do
            table.insert(keypoints, NumberSequenceKeypoint.new(point.time, point.value, point.envelope or 0))
        end
        return NumberSequence.new(keypoints)
    end
    if valueType == "colorSequence" then
        local encoded = value.keypoints or {}
        state.entries += #encoded
        assert(state.entries <= 1000, "Typed sequence input exceeds 1000 keypoints.")
        local keypoints = {}
        for _, point in encoded do
            table.insert(keypoints, ColorSequenceKeypoint.new(point.time, self:Decode(point.value, state)))
        end
        return ColorSequence.new(keypoints)
    end
    if valueType == "table" then
        state.entries += #(value.entries or {})
        assert(state.entries <= 1000, "Typed table input exceeds 1000 entries.")
        local result = {}
        if value.tableId ~= nil then state.tables[value.tableId] = result end
        for _, entry in value.entries or {} do
            result[self:Decode(entry.key, state)] = self:Decode(entry.value, state)
        end
        return result
    end
    if valueType == "reference" then
        local result = state.tables[value.tableId]
        assert(result ~= nil, "Typed table reference points to an unknown tableId.")
        return result
    end
    error("Unsupported typed runtime input: " .. tostring(valueType))
end

TypedValues.FunctionSummary = FunctionSummary
TypedValues.CountTable = CountTable

return TypedValues
