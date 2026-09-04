-- Strict instance-path parsing shared by connector tools. This intentionally
-- does not support method calls, operators, globals, or arbitrary expressions.
local InstancePath = {}

local MAX_SEGMENTS = 100
local MAX_PATH_LENGTH = 2000

local function Trim(value)
    return (string.gsub(string.gsub(value, "^%s+", ""), "%s+$", ""))
end

local function IsIdentifier(value)
    return string.match(value, "^[%a_][%w_]*$") ~= nil
end

local function DecodeEscape(character)
    if character == "n" then return "\n" end
    if character == "r" then return "\r" end
    if character == "t" then return "\t" end
    if character == "b" then return "\b" end
    if character == "f" then return "\f" end
    return character
end

local function ParseQuotedSegment(path, position)
    local quote = string.sub(path, position, position)
    assert(quote == '"' or quote == "'", "Bracket segments must use a quoted child name.")
    position += 1

    local output = {}
    local closed = false
    while position <= #path do
        local character = string.sub(path, position, position)
        if character == quote then
            closed = true
            position += 1
            break
        end
        if character == "\\" then
            position += 1
            assert(position <= #path, "Instance path ends inside an escape sequence.")
            character = DecodeEscape(string.sub(path, position, position))
        end
        table.insert(output, character)
        position += 1
    end
    assert(closed, "Unterminated quoted instance-path segment.")
    return table.concat(output), position
end

local function ParsePath(path)
    assert(type(path) == "string", "Instance path must be a string.")
    path = Trim(path)
    assert(path ~= "", "Instance path cannot be empty.")
    assert(#path <= MAX_PATH_LENGTH, "Instance path is too long.")

    local root
    local position
    if string.sub(path, 1, 4) == "game" then
        local boundary = string.sub(path, 5, 5)
        assert(boundary == "" or boundary == "." or boundary == "[", "Path root must be exactly game or workspace.")
        root = game
        position = 5
    elseif string.sub(path, 1, 9) == "workspace" then
        local boundary = string.sub(path, 10, 10)
        assert(boundary == "" or boundary == "." or boundary == "[", "Path root must be exactly game or workspace.")
        root = workspace
        position = 10
    else
        error("Instance path must be rooted at game or workspace.")
    end

    local segments = {}
    while position <= #path do
        assert(#segments < MAX_SEGMENTS, "Instance path has too many segments.")
        local separator = string.sub(path, position, position)
        if separator == "." then
            position += 1
            local remaining = string.sub(path, position)
            local segment = string.match(remaining, "^([%a_][%w_]*)")
            assert(segment ~= nil, "Dot segments must be valid identifiers.")
            table.insert(segments, segment)
            position += #segment
        elseif separator == "[" then
            position += 1
            while string.match(string.sub(path, position, position), "%s") do position += 1 end
            local segment
            segment, position = ParseQuotedSegment(path, position)
            while string.match(string.sub(path, position, position), "%s") do position += 1 end
            assert(string.sub(path, position, position) == "]", "Quoted path segment must end with ].")
            position += 1
            table.insert(segments, segment)
        else
            error("Unsupported instance-path syntax at character " .. tostring(position) .. ".")
        end
    end

    return root, segments
end

local function ResolveSegment(current, segment, uniqueBudget)
    local child = current:FindFirstChild(segment)
    if child then
        if uniqueBudget then
            local matches = 0
            for _, candidate in current:GetChildren() do
                uniqueBudget.remaining -= 1
                assert(uniqueBudget.remaining >= 0 and os.clock() < uniqueBudget.deadline, "Path uniqueness check exceeded its budget. Use a Handle returned by dex-query or dex-selection.")
                if candidate.Name == segment then matches += 1 end
                assert(matches <= 1, "Ambiguous duplicate-name path segment. Use a Handle returned by dex-query or dex-selection.")
            end
        end
        return child
    end

    -- Instance-valued properties (for example Players.LocalPlayer) are safe
    -- to read and preserve useful canonical paths without evaluating code.
    local ok, property = pcall(function()
        return current[segment]
    end)
    if ok and typeof(property) == "Instance" then return property end
    return nil
end

function InstancePath.Resolve(target, requireUnique)
    assert(type(target) == "table", "Instance target must be an object.")

    local root
    local segments
    if target.path ~= nil then
        assert(target.pathSegments == nil, "Provide path or pathSegments, not both.")
        root, segments = ParsePath(target.path)
    else
        assert(type(target.pathSegments) == "table", "Provide path or pathSegments.")
        root = target.root == "workspace" and workspace or game
        segments = target.pathSegments
        assert(#segments > 0 and #segments <= MAX_SEGMENTS, "pathSegments must contain 1-100 names.")
    end

    local current = root
    local uniqueBudget = requireUnique and { remaining = 10000, deadline = os.clock() + 0.02 } or nil
    for index, segment in ipairs(segments) do
        assert(type(segment) == "string" and #segment <= 200, "Invalid path segment at index " .. tostring(index) .. ".")
        local nextInstance = ResolveSegment(current, segment, uniqueBudget)
        assert(nextInstance, "Instance path was not found at segment " .. tostring(index) .. " (" .. segment .. ").")
        current = nextInstance
    end

    return current
end

local function EncodeSegment(name)
    if IsIdentifier(name) then return "." .. name end
    local escaped = string.gsub(name, "\\", "\\\\")
    escaped = string.gsub(escaped, '"', '\\"')
    escaped = string.gsub(escaped, "\n", "\\n")
    escaped = string.gsub(escaped, "\r", "\\r")
    escaped = string.gsub(escaped, "\t", "\\t")
    return '["' .. escaped .. '"]'
end

function InstancePath.StablePath(instance)
    assert(typeof(instance) == "Instance", "StablePath expects an Instance.")
    if instance == game then return "game" end

    local names = {}
    local current = instance
    local reachedGame = false
    while current and current ~= game and #names <= MAX_SEGMENTS do
        table.insert(names, current.Name)
        current = current.Parent
    end
    reachedGame = current == game

    if not reachedGame then
        local ok, fullName = pcall(function() return instance:GetFullName() end)
        return ok and ("<detached>." .. fullName) or ("<detached>." .. instance.Name)
    end

    local output = "game"
    for index = #names, 1, -1 do
        output ..= EncodeSegment(names[index])
    end
    return output
end

function InstancePath.Describe(instance)
    local debugId
    pcall(function() debugId = instance:GetDebugId() end)
    local fullName
    pcall(function() fullName = instance:GetFullName() end)
    return {
        Name = instance.Name,
        ClassName = instance.ClassName,
        Path = InstancePath.StablePath(instance),
        FullName = fullName,
        DebugId = debugId,
    }
end

InstancePath.Parse = ParsePath

return InstancePath
