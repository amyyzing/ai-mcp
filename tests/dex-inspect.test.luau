local Inspector = require("../connector-src/dex/inspect")

local function equal(actual, expected, message)
    assert(actual == expected, (message or "values differ") .. ": got " .. tostring(actual) .. ", expected " .. tostring(expected))
end

local INHERITS = {
    Part = { "BasePart" },
    MeshPart = { "BasePart" },
    TextLabel = { "GuiObject" },
    TextButton = { "GuiObject" },
    TextBox = { "GuiObject" },
    Frame = { "GuiObject" },
    ScreenGui = { "LayerCollector" },
    IntValue = { "ValueBase" },
    ObjectValue = { "ValueBase" },
    LocalScript = { "BaseScript", "LuaSourceContainer" },
    ModuleScript = { "LuaSourceContainer" },
}

local instanceMethods = {}
function instanceMethods:IsA(className)
    if className == "Instance" or className == self.ClassName then return true end
    return table.find(INHERITS[self.ClassName] or {}, className) ~= nil
end
function instanceMethods:GetChildren()
    self._childrenReads += 1
    return table.clone(self._children)
end
function instanceMethods:GetAttributes()
    if self._attributeError then error("Attributes unavailable") end
    return self._attributes
end
function instanceMethods:GetTags()
    if self._tagError then error("Tags unavailable") end
    return self._tags
end

local function instance(name, className, parent, properties)
    local value = setmetatable({
        _instance = true,
        _properties = properties or {},
        _parent = parent,
        _children = {},
        _attributes = {},
        _tags = {},
        _attributeError = false,
        _tagError = false,
        _childrenReads = 0,
        _reads = {},
        _hidden = {},
    }, {
        __index = function(self, key)
            if instanceMethods[key] then return instanceMethods[key] end
            self._reads[key] = (self._reads[key] or 0) + 1
            if key == "Parent" then return rawget(self, "_parent") end
            local found = self._properties[key]
            if found ~= nil then return found end
            error("Property unavailable: " .. tostring(key))
        end,
    })
    value._properties.Name = name
    value._properties.ClassName = className
    value._properties.Archivable = true
    if parent then table.insert(parent._children, value) end
    return value
end

local function kind(value)
    if type(value) == "table" and rawget(value, "_instance") == true then return "Instance" end
    if type(value) == "table" and rawget(value, "_datatype") then return value._datatype end
    return typeof(value)
end

local nextHandle = 0
local byHandle, byObject, paths, pins = {}, {}, {}, {}
local Handles = {}
function Handles:Register(value, requestedKind, _metadata, _ttl, pin)
    equal(requestedKind, "instance")
    pins[value] = pin
    if byObject[value] then return byObject[value] end
    nextHandle += 1
    local handle = "rh_test_1_" .. nextHandle
    byHandle[handle] = value
    byObject[value] = handle
    return handle
end
function Handles:Resolve(handle, requestedKind)
    equal(requestedKind, "instance")
    assert(byHandle[handle], "Expired instance handle")
    return byHandle[handle]
end

local Paths = {}
function Paths.Resolve(target)
    local path = target.path
    if target.pathSegments then path = "game." .. table.concat(target.pathSegments, ".") end
    assert(paths[path], "Path not found")
    return paths[path]
end
function Paths.Describe(value)
    local parts, current = {}, value
    for _ = 1, 100 do
        if current == nil then break end
        table.insert(parts, 1, current.Name)
        current = current.Parent
    end
    local path = table.concat(parts, ".")
    return { Name = value.Name, ClassName = value.ClassName, Path = path, FullName = path, DebugId = "debug-" .. value.Name }
end

local Values = {}
function Values:Encode(value, options)
    equal(options.maxDepth, 1)
    equal(options.maxEntries, 10)
    equal(options.maxStringBytes, 256)
    if type(value) == "table" and rawget(value, "_encodeError") then error("Unsupported fake type") end
    if kind(value) == "Instance" then
        return { type = "instance", handle = Handles:Register(value, "instance"), ref = { name = value.Name } }
    end
    if type(value) == "string" then
        return { type = "string", value = string.sub(value, 1, options.maxStringBytes), originalBytes = #value > options.maxStringBytes and #value or nil }
    end
    if type(value) == "table" then
        return { type = "vector3", x = value.x or 0, y = value.y or 0, z = value.z or 0 }
    end
    return { type = type(value), value = value }
end

local function measure(value)
    if type(value) == "string" then return #value + 2 end
    if type(value) ~= "table" then return #tostring(value) end
    local size = 2
    for key, found in pairs(value) do size += #tostring(key) + 4 + measure(found) end
    return size
end

local inspector = Inspector.new({ InstancePath = Paths, Handles = Handles, Values = Values, Typeof = kind, Measure = measure })
local game = instance("game", "DataModel", nil)
local workspace = instance("Workspace", "Workspace", game)
local first = instance("Twin", "Part", workspace, { Position = { x = 1, y = 2, z = 3 }, Size = { x = 4, y = 5, z = 6 }, Anchored = false })
local second = instance("Twin", "Part", workspace)
paths["game.Workspace"] = workspace
paths["game.Workspace.Twin"] = first

local firstDescription = inspector:Describe(first)
local secondDescription = inspector:Describe(second)
equal(firstDescription.Path, secondDescription.Path, "duplicate siblings intentionally share display paths")
assert(firstDescription.Handle ~= secondDescription.Handle, "duplicate siblings need distinct canonical handles")
equal(firstDescription.PathDisplayOnly, true)
equal(pins[first], false, "discovery must not pin instance handles")
equal(inspector:Resolve({ handle = secondDescription.Handle }), second)
equal(inspector:Resolve({ path = "game.Workspace.Twin" }), first)
equal(inspector:Resolve({ pathSegments = { "Workspace" } }), workspace)
assert(not pcall(function() inspector:Resolve({ handle = firstDescription.Handle, path = "game.Workspace.Twin" }) end))
assert(not pcall(function() inspector:Resolve({ handle = "rh_expired_1_1" }) end))
byHandle.rh_fake_1_1 = 123
assert(not pcall(function() inspector:Resolve({ handle = "rh_fake_1_1" }) end))

local ok, found, source = inspector:ReadProperty(first, "Anchored", false)
equal(ok, true)
equal(found, false, "false property values survive")
equal(source, "ordinary")
local parentOk, nilParent = inspector:ReadProperty(game, "Parent", false)
equal(parentOk, true)
equal(nilParent, nil)
assert(not inspector:ReadProperty(first, "Destroy()", false))
local unavailable, _, unavailableError = inspector:ReadProperty(first, "Secret", true)
equal(unavailable, false)
assert(string.find(unavailableError, "unavailable", 1, true))

first._hidden.Secret = false
local hiddenInspector = Inspector.new({
    InstancePath = Paths, Handles = Handles, Values = Values, Typeof = kind, Measure = measure,
    GetHiddenProperty = function(value, property)
        if value._hidden[property] == nil then error("No hidden value") end
        return value._hidden[property]
    end,
})
local hiddenOk, hiddenValue, hiddenSource = hiddenInspector:ReadProperty(first, "Secret", true)
equal(hiddenOk, true)
equal(hiddenValue, false, "hidden false values must not fall through")
equal(hiddenSource, "hidden")
assert(not hiddenInspector:ReadProperty(first, "Secret", false), "hidden reads must be opt-in")

first._attributes = { Active = false, Phase = 3 }
first._tags = { "Damageable", "Target" }
local query = inspector:QueryRecord(first, { properties = { "Position", "Anchored", "Parent", "Missing" }, includeAttributes = true, includeTags = true, attributeLimit = 1, tagLimit = 1 })
equal(query.Properties.Position.type, "vector3")
equal(query.Properties.Anchored.value, false)
equal(query.Properties.Parent.type, "instance")
equal(pins[workspace], false, "instance-valued query properties must remain weak handles")
assert(query.PropertyErrors.Missing)
equal(query.AttributesReturned, 1)
equal(query.AttributesLimited, true)
equal(#query.Tags, 1)
equal(query.TagCount, 2)
equal(query.TagsLimited, true)
equal(query.Truncated, true)
equal(query.Properties.Archivable, nil, "query projections do not silently expand auto profiles")
first._tags = { "Zebra", "Alpha" }
local sortedTags = inspector:QueryRecord(first, { includeTags = true }).Tags
equal(sortedTags[1], "Alpha", "tag projections must use stable sorting")
equal(sortedTags[2], "Zebra")
first._tags = { string.rep("t", 150) }
local longTags = inspector:QueryRecord(first, { includeTags = true })
assert(longTags.TagsLimited and longTags.Truncated and #longTags.Tags[1] <= 100)
first._tags = {}

local screen = instance("Screen", "ScreenGui", game, { Enabled = false, DisplayOrder = 5, IgnoreGuiInset = true })
local frame = instance("Frame", "Frame", screen, { Visible = true, ClipsDescendants = true, AbsolutePosition = { x = 0, y = 0 }, AbsoluteSize = { x = 100, y = 100 } })
local text = instance("Title", "TextLabel", frame, { Visible = true, ClipsDescendants = false, Text = "Hello", TextSize = 18, TextScaled = false, TextStrokeTransparency = 0.4, FontFace = { Family = "rbxasset://fonts/families/GothamSSm.json" }, AbsolutePosition = { x = 1, y = 2 }, AbsoluteSize = { x = 30, y = 40 } })
local guiResult = inspector:Inspect({ targets = { { handle = inspector:Describe(text).Handle } }, childLimit = 0, maxChars = 20000 })
local gui = guiResult.results[1]
equal(gui.Properties.Text.value, "Hello")
equal(gui.Properties.TextScaled.value, false)
equal(gui.FontFamily, "rbxasset://fonts/families/GothamSSm.json")
equal(gui.Bounds.Kind, "GuiObject")
equal(gui.Visibility.EffectiveVisible, false, "disabled ScreenGui affects effective ancestry visibility")
equal(gui.Visibility.Limited, false)
equal(#gui.Visibility.ClippingAncestors, 1)
assert(#gui.Ancestors > 0)

local children = inspector:Inspect({ target = { path = "game.Workspace" }, profile = "none", includeAncestors = false, childOffset = 1, childLimit = 1 }).results[1]
equal(children.ChildCount, 2)
equal(children.ChildOffset, 1)
equal(#children.Children, 1)
equal(children.Children[1].Handle, secondDescription.Handle)
equal(children.ChildrenLimited, false)
equal(children.ChildrenPageStable, false)
local firstPage = inspector:Inspect({ target = { path = "game.Workspace" }, profile = "none", childLimit = 1 }).results[1]
equal(firstPage.NextChildOffset, 1)
equal(firstPage.ChildrenLimited, true)
equal(first._childrenReads, 0, "child projections must not recursively enumerate grandchildren")

local script = instance("TestScript", "LocalScript", game, { Enabled = true, RunContext = "Client", Source = "do not read me" })
local scriptRecord = inspector:Inspect({ target = { handle = inspector:Describe(script).Handle }, includeChildren = false }).results[1]
equal(scriptRecord.ScriptMetadata.SourceIncluded, false)
equal(script._reads.Source, nil, "auto profile must not read script source")
equal(scriptRecord.Properties.Enabled.value, true)
local remote = instance("Event", "RemoteEvent", game)
local remoteRecord = inspector:Inspect({ target = { handle = inspector:Describe(remote).Handle } }).results[1]
equal(remoteRecord.RemoteMetadata.Invoked, false)

local batch = inspector:Inspect({ targets = { { handle = "rh_expired_1_1" }, { handle = firstDescription.Handle } }, profile = "none", includeChildren = false })
equal(batch.returnedCount, 2)
assert(batch.results[1].Error)
equal(batch.results[2].Handle, firstDescription.Handle)
equal(batch.results[2].TargetIndex, 2)

first._properties.Huge = string.rep("x", 10000)
first._properties.Unsupported = { _encodeError = true }
local strings = inspector:QueryRecord(first, { properties = { "Huge", "Unsupported" } })
equal(#strings.Properties.Huge.value, 256)
equal(strings.Properties.Huge.originalBytes, 10000)
equal(strings.Properties.Unsupported.type, "unsupported")
equal(strings.Truncated, true, "truncated strings and unsupported values cannot imply complete snapshots")
first._attributeError = true
first._tagError = true
local inaccessible = inspector:QueryRecord(first, { includeAttributes = true, includeTags = true })
assert(inaccessible.AttributeError and inaccessible.TagError)

local targets = {}
for _ = 1, 20 do table.insert(targets, { handle = firstDescription.Handle }) end
local tiny = inspector:Inspect({ targets = targets, maxChars = 1000 })
equal(tiny.limited, true)
assert(tiny.targetsOmitted > 0)
assert(measure(tiny) <= 1000, "small request budgets must cap the complete envelope")
local normal = inspector:Inspect({ targets = targets, properties = { "Huge", "Position", "Anchored" }, maxChars = 20000 })
assert(measure(normal) <= 20000, "batch result must stay within the complete output budget")
assert(normal.returnedCount > 0)
assert(not pcall(function() inspector:Inspect({ targets = {} }) end))
table.insert(targets, targets[1])
assert(not pcall(function() inspector:Inspect({ targets = targets }) end))

local long = instance(string.rep("Name", 400), "Folder", game)
local longDescription = inspector:Describe(long)
assert(#longDescription.Name <= 128 and #longDescription.Path <= 480 and #longDescription.FullName <= 480)
equal(longDescription.DisplayTruncated, true)
equal(inspector:Resolve({ handle = longDescription.Handle }), long)
equal(inspector:QueryRecord(long, {}).Truncated, true, "shortened identity metadata must not imply complete snapshot projections")

local font, fontPartial = inspector:_encode({
    _datatype = "Font", Family = "rbxasset://fonts/families/BuilderSans.json",
    Weight = { Name = "Bold" }, Style = { Name = "Italic" }, Bold = true,
})
equal(font.type, "font")
equal(font.weight, "Bold")
equal(font.style, "Italic")
equal(font.bold, true)
equal(fontPartial, false)
local longFont, longFontPartial = inspector:_encode({
    _datatype = "Font", Family = string.rep("x", 600),
    Weight = { Name = "Regular" }, Style = { Name = "Normal" }, Bold = false,
})
assert(#longFont.family <= 256 and longFontPartial)

print("Dex rich inspection tests passed")
