-- Deterministic, dependency-free text encoding for sanitized bridge output.
-- Values reaching this module are already bounded by SanitizeForOutput, but
-- the guards here keep it safe to call independently too.
local function EncodeString(value)
    return string.format("%q", value)
end

local function EncodeNumber(value)
    if value ~= value then return EncodeString("NaN") end
    if value == math.huge then return EncodeString("Infinity") end
    if value == -math.huge then return EncodeString("-Infinity") end
    return tostring(value)
end

local function KeyLess(left, right)
    local leftType = typeof(left)
    local rightType = typeof(right)
    if leftType ~= rightType then
        return leftType == "number"
    end
    if leftType == "number" then
        return left < right
    end
    return tostring(left) < tostring(right)
end

local function Encode(value, seen, depth)
    local valueType = typeof(value)
    if valueType == "nil" then return "nil" end
    if valueType == "boolean" then return value and "true" or "false" end
    if valueType == "number" then return EncodeNumber(value) end
    if valueType == "string" then return EncodeString(value) end
    if valueType ~= "table" then return EncodeString(tostring(value)) end
    if depth >= 12 then return EncodeString("<table: max depth reached>") end
    if seen[value] then return EncodeString("<cyclic table>") end

    seen[value] = true
    local keys = {}
    for key in value do
        table.insert(keys, key)
    end
    table.sort(keys, KeyLess)

    local entries = {}
    for _, key in keys do
        local encodedKey
        if typeof(key) == "string" and string.match(key, "^[A-Za-z_][A-Za-z0-9_]*$") then
            encodedKey = key
        else
            encodedKey = "[" .. Encode(key, seen, depth + 1) .. "]"
        end
        table.insert(entries, encodedKey .. "=" .. Encode(value[key], seen, depth + 1))
    end
    seen[value] = nil
    return "{" .. table.concat(entries, ",") .. "}"
end

return function(value)
    return Encode(value, {}, 0)
end
