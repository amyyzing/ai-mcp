-- Read-only, bounded instance projections shared by Dex inspection and scans.
-- Paths are display metadata; runtime handles preserve identity for duplicate names.
local Inspector = {}
Inspector.__index = Inspector

local VALUE_OPTIONS = {
    maxDepth = 1,
    maxEntries = 10,
    maxStringBytes = 256,
    maxStringBytesPerValue = 256,
    expandTables = true,
}

local PROFILES = {
    { "BasePart", { "Position", "Size", "CFrame", "Anchored", "CanCollide", "CanTouch", "CanQuery", "Transparency", "Color", "Material", "CollisionGroup", "AssemblyLinearVelocity", "AssemblyAngularVelocity", "Massless" } },
    { "Model", { "PrimaryPart", "WorldPivot", "ModelStreamingMode" } },
    { "Humanoid", { "Health", "MaxHealth", "WalkSpeed", "JumpPower", "JumpHeight", "UseJumpPower", "HipHeight", "MoveDirection", "FloorMaterial", "RootPart", "Sit", "PlatformStand", "AutoRotate", "RigType" } },
    { "ValueBase", { "Value" } },
    { "GuiObject", { "Visible", "Position", "Size", "AnchorPoint", "AbsolutePosition", "AbsoluteSize", "AbsoluteRotation", "ZIndex", "LayoutOrder", "ClipsDescendants", "Active", "Selectable", "AutomaticSize", "BackgroundColor3", "BackgroundTransparency", "BorderSizePixel", "Rotation" } },
    { "TextLabel", { "Text", "TextSize", "TextScaled", "TextWrapped", "TextColor3", "TextTransparency", "TextStrokeTransparency", "FontFace", "TextBounds", "RichText", "TextXAlignment", "TextYAlignment" } },
    { "TextButton", { "Text", "TextSize", "TextScaled", "TextWrapped", "TextColor3", "TextTransparency", "TextStrokeTransparency", "FontFace", "TextBounds", "RichText", "TextXAlignment", "TextYAlignment", "AutoButtonColor" } },
    { "TextBox", { "Text", "PlaceholderText", "TextEditable", "ClearTextOnFocus", "MultiLine", "TextSize", "TextScaled", "TextWrapped", "TextColor3", "TextStrokeTransparency", "FontFace", "TextBounds", "RichText" } },
    { "ImageLabel", { "Image", "IsLoaded", "ImageColor3", "ImageTransparency", "ImageRectOffset", "ImageRectSize", "ScaleType" } },
    { "ImageButton", { "Image", "IsLoaded", "ImageColor3", "ImageTransparency", "ImageRectOffset", "ImageRectSize", "ScaleType", "AutoButtonColor" } },
    { "ScrollingFrame", { "CanvasPosition", "CanvasSize", "AbsoluteCanvasSize", "AbsoluteWindowSize", "AutomaticCanvasSize", "ScrollingEnabled", "ScrollingDirection", "ScrollBarThickness" } },
    { "LayerCollector", { "Enabled", "ResetOnSpawn", "ZIndexBehavior" } },
    { "ScreenGui", { "DisplayOrder", "IgnoreGuiInset", "ScreenInsets", "ClipToDeviceSafeArea" } },
    { "BillboardGui", { "Adornee", "AlwaysOnTop", "Size", "StudsOffset", "MaxDistance" } },
    { "SurfaceGui", { "Adornee", "Face", "CanvasSize", "AlwaysOnTop", "PixelsPerStud" } },
    { "UIGridStyleLayout", { "AbsoluteContentSize", "FillDirection", "HorizontalAlignment", "VerticalAlignment", "SortOrder" } },
    { "UIListLayout", { "Padding" } },
    { "UIGridLayout", { "CellSize", "CellPadding", "FillDirectionMaxCells" } },
    { "UIPadding", { "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" } },
    { "UIScale", { "Scale" } },
    { "UISizeConstraint", { "MinSize", "MaxSize" } },
    { "UIAspectRatioConstraint", { "AspectRatio", "AspectType", "DominantAxis" } },
    { "BaseScript", { "Enabled", "RunContext" } },
    { "Sound", { "SoundId", "IsLoaded", "Playing", "TimePosition", "TimeLength", "Volume", "PlaybackSpeed", "Looped", "RollOffMaxDistance", "RollOffMinDistance", "SoundGroup" } },
    { "Animation", { "AnimationId" } },
    { "Decal", { "Texture", "Transparency", "Color3", "Face" } },
    { "Texture", { "StudsPerTileU", "StudsPerTileV", "OffsetStudsU", "OffsetStudsV" } },
    { "MeshPart", { "MeshId", "TextureID", "RenderFidelity", "CollisionFidelity" } },
    { "SpecialMesh", { "MeshId", "TextureId", "MeshType", "Scale", "Offset" } },
    { "Attachment", { "Position", "CFrame", "WorldPosition", "WorldCFrame" } },
    { "Constraint", { "Enabled", "Active", "Attachment0", "Attachment1", "Visible" } },
    { "JointInstance", { "Part0", "Part1", "C0", "C1", "Enabled", "Active" } },
    { "Camera", { "CFrame", "Focus", "CameraSubject", "CameraType", "FieldOfView", "ViewportSize" } },
    { "ProximityPrompt", { "Enabled", "ActionText", "ObjectText", "HoldDuration", "MaxActivationDistance", "RequiresLineOfSight", "KeyboardKeyCode", "GamepadKeyCode" } },
    { "ClickDetector", { "MaxActivationDistance", "CursorIcon" } },
}

local function Clamp(value, fallback, minimum, maximum)
    local number = tonumber(value)
    if number == nil or number ~= number then number = fallback end
    return math.max(minimum, math.min(maximum, math.floor(number)))
end

local function Short(value, limit)
    local ok, rendered = pcall(tostring, value)
    if not ok then return "<unprintable>" end
    if #rendered <= limit then return rendered end
    -- Avoid cutting a UTF-8 sequence in half when truncating names and errors.
    local last = limit - 3
    while last > 0 do
        local byte = string.byte(rendered, last + 1)
        if byte == nil or byte < 128 or byte >= 192 then break end
        last -= 1
    end
    return string.sub(rendered, 1, last) .. "..."
end

local function ValidProperty(name)
    return type(name) == "string" and #name <= 100 and string.match(name, "^[%a_][%w_]*$") ~= nil
end

local function Estimate(value, depth, seen)
    depth = depth or 0
    seen = seen or {}
    if type(value) ~= "table" then
        if type(value) == "string" then return #value * 2 + 2, 0 end
        return 24, 0
    end
    if depth > 10 or seen[value] then return 16, 1 end
    seen[value] = true
    local chars, entries = 2, 0
    for key, item in pairs(value) do
        entries += 1
        if entries > 1000 then return 1000000, 1001 end
        local size, nested = Estimate(item, depth + 1, seen)
        chars += #tostring(key) * 2 + size + 5
        entries += nested
    end
    seen[value] = nil
    return chars, entries
end

function Inspector.new(options)
    assert(options and options.InstancePath and options.Handles and options.Values, "Dex inspection requires paths, handles, and typed values.")
    return setmetatable({
        Paths = options.InstancePath,
        Handles = options.Handles,
        Values = options.Values,
        Measure = options.Measure,
        Typeof = options.Typeof or typeof,
        GetHiddenProperty = options.GetHiddenProperty or (type(gethiddenproperty) == "function" and gethiddenproperty or nil),
    }, Inspector)
end

function Inspector:_size(value)
    local estimated, entries = Estimate(value)
    if self.Measure then
        local ok, measured = pcall(self.Measure, value)
        if ok and type(measured) == "number" and measured >= 0 then return measured, entries end
    end
    return estimated, entries
end

function Inspector:_budget(chars, entries)
    return { chars = math.max(0, chars - 300), entries = math.max(0, entries - 20), limited = false }
end

function Inspector:_take(budget, value)
    local chars, entries = self:_size(value)
    if chars + 2 > budget.chars or entries + 1 > budget.entries then
        budget.limited = true
        return false
    end
    budget.chars -= chars + 2
    budget.entries -= entries + 1
    return true
end

function Inspector:_put(budget, record, key, value)
    if value == nil then return true end
    if not self:_take(budget, { [key] = value }) then return false end
    record[key] = value
    return true
end

function Inspector:_isA(instance, className)
    local ok, result = pcall(function() return instance:IsA(className) end)
    return ok and result == true
end

function Inspector:ReadProperty(instance, name, includeHidden)
    if not ValidProperty(name) then return false, nil, "Invalid property name." end
    local ok, value = pcall(function() return instance[name] end)
    if ok then return true, value, "ordinary" end
    if includeHidden == true then
        if not self.GetHiddenProperty then
            return false, nil, Short(value, 180) .. "; hidden-property access is unavailable."
        end
        local hiddenOk, hiddenValue = pcall(self.GetHiddenProperty, instance, name)
        if hiddenOk then return true, hiddenValue, "hidden" end
        return false, nil, Short(hiddenValue, 240)
    end
    return false, nil, Short(value, 240)
end

function Inspector:Resolve(target)
    assert(type(target) == "table", "An instance target is required.")
    local instance
    if target.handle ~= nil then
        assert(target.path == nil and target.pathSegments == nil, "Provide a handle or path target, not both.")
        instance = self.Handles:Resolve(target.handle, "instance", false)
    else
        instance = self.Paths.Resolve(target, true)
    end
    assert(self.Typeof(instance) == "Instance", "Target does not reference a Roblox Instance.")
    return instance
end

function Inspector:Describe(instance)
    assert(self.Typeof(instance) == "Instance", "Describe expects a Roblox Instance.")
    local ok, description = pcall(self.Paths.Describe, instance)
    if not ok or type(description) ~= "table" then description = {} end
    local record = { PathDisplayOnly = true }
    local limits = { Name = 128, ClassName = 100, Path = 480, FullName = 480, DebugId = 128 }
    for key, limit in pairs(limits) do
        local value = description[key]
        if value == nil and (key == "Name" or key == "ClassName") then
            local found, raw = self:ReadProperty(instance, key, false)
            if found then value = raw end
        end
        if value ~= nil then
            record[key] = Short(value, limit)
            if type(value) == "string" and #value > limit then record.DisplayTruncated = true end
        end
    end
    record.Name = record.Name or "<unavailable>"
    record.ClassName = record.ClassName or "Instance"
    record.Path = record.Path or "<unavailable>"
    record.Handle = self.Handles:Register(instance, "instance", {
        className = record.ClassName,
        path = record.Path,
    }, nil, false)
    return record
end

local function HasOmission(value, depth)
    if type(value) ~= "table" then return false end
    if value.type == "unsupported" or value.originalBytes ~= nil or value.entriesOmitted ~= nil or value.omitted ~= nil or value.omission ~= nil or value.truncated == true then return true end
    if (depth or 0) >= 4 then return false end
    local visited = 0
    for _, child in pairs(value) do
        visited += 1
        if visited > 100 then return true end
        if HasOmission(child, (depth or 0) + 1) then return true end
    end
    return false
end

function Inspector:_encode(value)
    if self.Typeof(value) == "Instance" then
        local description = self:Describe(value)
        return {
            type = "instance",
            handle = description.Handle,
            ref = {
                name = description.Name,
                className = description.ClassName,
                path = description.Path,
                debugId = description.DebugId,
                pathDisplayOnly = true,
            },
        }, description.DisplayTruncated == true
    end
    if self.Typeof(value) == "Font" then
        local ok, encoded, partial = pcall(function()
            local family = tostring(value.Family)
            return {
                type = "font", family = Short(family, 256),
                weight = value.Weight.Name, style = value.Style.Name, bold = value.Bold,
            }, #family > 256
        end)
        if ok then return encoded, partial end
        return { type = "unsupported", error = Short(encoded, 180) }, true
    end
    local ok, encoded = pcall(function() return self.Values:Encode(value, VALUE_OPTIONS) end)
    if ok then
        local valueType = self.Typeof(value)
        if valueType == "NumberSequence" or valueType == "ColorSequence" then
            local countOk, count = pcall(function() return #value.Keypoints end)
            if countOk and count > VALUE_OPTIONS.maxEntries then encoded.omitted = "keypoint-limit" end
        end
        return encoded, HasOmission(encoded)
    end
    return { type = "unsupported", error = Short(encoded, 180) }, true
end

function Inspector:_putValue(budget, record, key, value)
    local encoded, partial = self:_encode(value)
    if partial then budget.limited = true end
    return self:_put(budget, record, key, encoded)
end

function Inspector:_propertyNames(instance, data, profile)
    local names, seen = {}, {}
    local function add(name)
        if #names >= 80 or seen[name] then return end
        seen[name] = true
        table.insert(names, name)
    end
    local requested = type(data.properties) == "table" and data.properties or {}
    for index = 1, math.min(#requested, 80) do
        if type(requested[index]) == "string" then add(requested[index]) end
    end
    if profile == "auto" then
        add("Archivable")
        for _, group in PROFILES do
            if self:_isA(instance, group[1]) then
                for _, name in group[2] do add(name) end
            end
        end
    end
    return names
end

function Inspector:_projection(instance, data, budget, profile)
    local record = self:Describe(instance)
    if data.includeFullName ~= true then record.FullName = nil end
    if not self:_take(budget, record) then
        record = { Handle = record.Handle, Name = record.Name, ClassName = record.ClassName, PathDisplayOnly = true }
        self:_take(budget, record)
    end
    local names = self:_propertyNames(instance, data, profile)
    if #names > 0 then
        local properties, errors, hidden = {}, {}, {}
        local omitted, errorCount = 0, 0
        for propertyIndex, name in names do
            local ok, value, source = self:ReadProperty(instance, name, data.includeHidden == true)
            if ok then
                if not self:_putValue(budget, properties, name, value) then omitted += 1 end
                if source == "hidden" and #hidden < 20 then table.insert(hidden, name) end
            else
                errorCount += 1
                if errorCount <= 10 then self:_put(budget, errors, Short(name, 100), source) end
            end
            if budget.chars < 150 or budget.entries < 8 then
                omitted += #names - propertyIndex
                budget.limited = true
                break
            end
        end
        if next(properties) then record.Properties = properties end
        if next(errors) then record.PropertyErrors = errors end
        if #hidden > 0 then record.HiddenPropertiesRead = hidden end
        if errorCount > 0 then record.PropertyErrorCount = errorCount end
        if omitted > 0 then record.PropertiesOmitted = omitted end
        if #(data.properties or {}) > 80 then record.RequestedPropertiesOmitted = #data.properties - 80 end
    end

    if data.includeAttributes == true then
        local ok, attributes = pcall(function() return instance:GetAttributes() end)
        if ok and type(attributes) == "table" then
            local projected, count, visited = {}, 0, 0
            local attributeLimit = Clamp(data.attributeLimit, 32, 0, 64)
            for key, value in pairs(attributes) do
                visited += 1
                if visited > attributeLimit then
                    record.AttributesLimited = true
                    break
                end
                if not self:_putValue(budget, projected, Short(key, 100), value) then
                    record.AttributesLimited = true
                    break
                end
                count += 1
            end
            record.Attributes = projected
            record.AttributesReturned = count
        else
            self:_put(budget, record, "AttributeError", Short(attributes, 240))
        end
    end

    if data.includeTags == true then
        local ok, tags = pcall(function() return instance:GetTags() end)
        if ok and type(tags) == "table" then
            local projected, sorted = {}, {}
            local limit = Clamp(data.tagLimit, 32, 0, 64)
            for index = 1, math.min(#tags, limit) do
                table.insert(sorted, Short(tags[index], 100))
                if type(tags[index]) == "string" and #tags[index] > 100 then record.TagsLimited = true end
            end
            table.sort(sorted)
            for _, value in sorted do
                if not self:_take(budget, value) then break end
                table.insert(projected, value)
            end
            record.Tags = projected
            record.TagCount = #tags
            if #projected < #tags then record.TagsLimited = true end
        else
            self:_put(budget, record, "TagError", Short(tags, 240))
        end
    end
    record.Truncated = record.DisplayTruncated or budget.limited or record.AttributesLimited or record.TagsLimited or nil
    return record
end

function Inspector:QueryRecord(instance, options)
    options = options or {}
    local budget = self:_budget(Clamp(options.maxChars, 6000, 800, 20000), Clamp(options.maxEntries, 240, 30, 800))
    return self:_projection(instance, options, budget, "none")
end

function Inspector:_bounds(instance)
    if self:_isA(instance, "BasePart") then
        return { Kind = "BasePart", Properties = { "Position", "Size", "CFrame" } }
    elseif self:_isA(instance, "GuiObject") then
        return { Kind = "GuiObject", Properties = { "AbsolutePosition", "AbsoluteSize", "Visible", "ZIndex" } }
    elseif self:_isA(instance, "Model") then
        -- GetBoundingBox internally walks all model parts. Keep rich Dex reads
        -- non-recursive: WorldPivot/PrimaryPart are cheap metadata alternatives.
        return { Kind = "Model", Properties = { "WorldPivot", "PrimaryPart" }, Note = "Model bounding-box calculation omitted to avoid an unbounded descendant scan." }
    end
    return nil
end

function Inspector:_ancestry(instance, data, record, budget)
    local gui = self:_isA(instance, "GuiObject") or self:_isA(instance, "LayerCollector")
    local wantAncestors = data.includeAncestors ~= false
    if not gui and not wantAncestors then return end
    local limit = Clamp(data.ancestorLimit, 8, 0, 32)
    local ancestors, clipping = {}, {}
    local current, checked, hidden, complete = instance, 0, false, false
    local ancestorCount = 0
    -- Visibility needs more ancestry than the optional displayed breadcrumb.
    for _ = 1, 64 do
        checked += 1
        if gui then
            if self:_isA(current, "GuiObject") then
                local ok, visible = self:ReadProperty(current, "Visible", false)
                if ok and visible == false then hidden = true end
                local clipOk, clips = self:ReadProperty(current, "ClipsDescendants", false)
                if current ~= instance and clipOk and clips == true and #clipping < 4 then
                    local description = self:Describe(current)
                    local clip = { Handle = description.Handle, Name = description.Name }
                    for _, property in { "AbsolutePosition", "AbsoluteSize" } do
                        local found, value = self:ReadProperty(current, property, false)
                        if found then clip[property] = self:_encode(value) end
                    end
                    if self:_take(budget, clip) then table.insert(clipping, clip) end
                end
            elseif self:_isA(current, "LayerCollector") then
                local ok, enabled = self:ReadProperty(current, "Enabled", false)
                if ok and enabled == false then hidden = true end
            end
        end
        local parentOk, parent = self:ReadProperty(current, "Parent", false)
        if not parentOk then break end
        if parent == nil then complete = true break end
        if self.Typeof(parent) ~= "Instance" then break end
        ancestorCount += 1
        if wantAncestors and #ancestors < limit then
            local ancestor = self:Describe(parent)
            ancestor.FullName = nil
            if self:_take(budget, ancestor) then table.insert(ancestors, ancestor) end
        end
        current = parent
        if not gui and ancestorCount >= limit then break end
    end
    if wantAncestors then
        record.Ancestors = ancestors
        record.AncestorsLimited = not complete or ancestorCount > #ancestors
    end
    if gui then
        record.Visibility = {
            EffectiveVisible = if hidden then false elseif complete then true else nil,
            AncestorsChecked = checked,
            Limited = not complete,
            Basis = "Local Visible/Enabled ancestry only; not occlusion, transparency, viewport intersection, or screenshot visibility.",
        }
        if #clipping > 0 then record.Visibility.ClippingAncestors = clipping end
    end
end

function Inspector:_inspectOne(instance, data, chars, entries)
    local budget = self:_budget(chars, entries)
    local options = table.clone(data)
    options.includeAttributes = data.includeAttributes ~= false
    options.includeTags = data.includeTags ~= false
    local profile = data.profile == "none" and "none" or "auto"
    local record = self:_projection(instance, options, budget, profile)
    record.Profile = profile
    if data.includeHidden == true then record.HiddenPropertySupported = self.GetHiddenProperty ~= nil end

    if data.includeBounds ~= false then
        local bounds = self:_bounds(instance)
        if bounds then
            local result = { Kind = bounds.Kind, Note = bounds.Note }
            for _, name in bounds.Properties do
                local ok, value = self:ReadProperty(instance, name, false)
                if ok then result[name] = self:_encode(value) end
            end
            self:_put(budget, record, "Bounds", result)
        end
    end

    if self:_isA(instance, "TextLabel") or self:_isA(instance, "TextButton") or self:_isA(instance, "TextBox") then
        local fontOk, font = self:ReadProperty(instance, "FontFace", false)
        if fontOk and font ~= nil then
            local familyOk, family = pcall(function() return font.Family end)
            if familyOk then self:_put(budget, record, "FontFamily", Short(family, 256)) end
        end
    end
    if self:_isA(instance, "LuaSourceContainer") then
        self:_put(budget, record, "ScriptMetadata", {
            SourceIncluded = record.Properties ~= nil and record.Properties.Source ~= nil,
            Note = "No require or script execution. An explicitly selected Source property may be truncated.",
        })
    end
    if self:_isA(instance, "RemoteEvent") or self:_isA(instance, "RemoteFunction") or self:_isA(instance, "UnreliableRemoteEvent") then
        self:_put(budget, record, "RemoteMetadata", { Invoked = false, Note = "Instance metadata only; no arguments or server implementation inferred." })
    end

    self:_ancestry(instance, data, record, budget)
    if data.includeChildren ~= false then
        local ok, children = pcall(function() return instance:GetChildren() end)
        if ok and type(children) == "table" then
            local offset = Clamp(data.childOffset, 0, 0, 1000000000)
            local limit = Clamp(data.childLimit, 20, 0, 100)
            local projected = {}
            for index = offset + 1, math.min(#children, offset + limit) do
                local childOk, child = pcall(function() return self:Describe(children[index]) end)
                if childOk then
                    child.FullName = nil
                    if not self:_take(budget, child) then break end
                    table.insert(projected, child)
                else
                    budget.limited = true
                    break
                end
            end
            record.ChildCount = #children
            record.ChildOffset = offset
            record.Children = projected
            record.ChildrenLimited = offset + #projected < #children
            record.ChildrenPageStable = false
            if record.ChildrenLimited then record.NextChildOffset = offset + #projected end
        else
            self:_put(budget, record, "ChildError", Short(children, 240))
        end
    end
    record.Truncated = record.Truncated or budget.limited or nil
    return record
end

function Inspector:Inspect(data)
    data = data or {}
    local targets = data.targets or (data.target and { data.target })
    assert(type(targets) == "table" and #targets > 0 and #targets <= 20, "Inspect requires 1-20 instance targets.")
    local maxChars = Clamp(data.maxChars, 20000, 1000, 60000)
    local remainingChars, remainingEntries = maxChars - 500, 840
    local results = {}
    local limited = false
    for index, target in ipairs(targets) do
        local remaining = #targets - index + 1
        local chars = math.floor(remainingChars / remaining)
        local entries = math.floor(remainingEntries / remaining)
        if chars < 500 or entries < 15 then limited = true break end
        local ok, record = pcall(function()
            return self:_inspectOne(self:Resolve(target), data, chars, entries)
        end)
        if not ok then record = { TargetIndex = index, Error = Short(record, 240) } end
        record.TargetIndex = index
        local usedChars, usedEntries = self:_size(record)
        if usedChars > remainingChars or usedEntries + 1 > remainingEntries then
            limited = true
            break
        end
        remainingChars -= usedChars + 1
        remainingEntries -= usedEntries + 1
        table.insert(results, record)
        if record.Truncated then limited = true end
    end
    return {
        results = results,
        requestedCount = #targets,
        returnedCount = #results,
        targetsOmitted = #targets - #results,
        nextTargetIndex = #results < #targets and #results + 1 or nil,
        limited = limited,
        maxChars = maxChars,
        scope = "Client-visible replicated/local instances only.",
    }
end

return Inspector
