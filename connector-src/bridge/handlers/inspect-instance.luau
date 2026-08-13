local InstancePath = require("../instance-path")

return function(_context, Bridge)
    Bridge:BindToTypeStructured("inspect-instance", function(data)
        local target = InstancePath.Resolve(data.target)
        local result = InstancePath.Describe(target)

        if target.Parent then
            result.Parent = InstancePath.Describe(target.Parent)
        end

        local properties = {}
        local propertyErrors = {}
        local requestedProperties = type(data.properties) == "table" and data.properties or {}
        local propertyLimit = math.min(#requestedProperties, 40)
        for index = 1, propertyLimit do
            local propertyName = requestedProperties[index]
            if type(propertyName) ~= "string" or not string.match(propertyName, "^[%a_][%w_]*$") then
                table.insert(propertyErrors, {
                    Property = tostring(propertyName),
                    Error = "Invalid property name.",
                })
                continue
            end

            local ok, value = pcall(function() return target[propertyName] end)
            if ok then
                if typeof(value) == "Instance" then
                    properties[propertyName] = InstancePath.Describe(value)
                else
                    properties[propertyName] = value
                end
            else
                table.insert(propertyErrors, {
                    Property = propertyName,
                    Error = tostring(value),
                })
            end
        end
        if next(properties) ~= nil then result.Properties = properties end
        if #propertyErrors > 0 then result.PropertyErrors = propertyErrors end

        if data.includeAttributes ~= false then
            local ok, attributes = pcall(function() return target:GetAttributes() end)
            if ok then result.Attributes = attributes end
        end

        if data.includeTags ~= false then
            local ok, tags = pcall(function() return target:GetTags() end)
            if ok then result.Tags = tags end
        end

        if data.includeBounds ~= false then
            if target:IsA("BasePart") then
                result.Bounds = {
                    Kind = "BasePart",
                    Position = target.Position,
                    Size = target.Size,
                    CFrame = target.CFrame,
                }
            elseif target:IsA("Model") then
                local ok, boundsCFrame, boundsSize = pcall(function()
                    return target:GetBoundingBox()
                end)
                if ok then
                    result.Bounds = {
                        Kind = "Model",
                        Position = boundsCFrame.Position,
                        Size = boundsSize,
                        CFrame = boundsCFrame,
                    }
                end
            elseif target:IsA("GuiObject") then
                result.Bounds = {
                    Kind = "GuiObject",
                    AbsolutePosition = target.AbsolutePosition,
                    AbsoluteSize = target.AbsoluteSize,
                    Visible = target.Visible,
                    ZIndex = target.ZIndex,
                }
            end
        end

        if data.includeChildren ~= false then
            local children = target:GetChildren()
            local childLimit = math.max(0, math.min(math.floor(tonumber(data.childLimit) or 20), 100))
            local childResults = {}
            for index = 1, math.min(#children, childLimit) do
                local child = children[index]
                local childInfo = InstancePath.Describe(child)
                childInfo.ChildCount = #child:GetChildren()
                table.insert(childResults, childInfo)
            end
            result.ChildCount = #children
            result.Children = childResults
            result.ChildrenLimited = #children > childLimit
        end

        return result
    end)
end
