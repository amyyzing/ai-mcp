return function(context)
local CoreGui = context.CoreGui
local TweenService = context.TweenService

local HOST_NAME = "RobloxMCPToastHost"
local DISPLAY_SECONDS = 4

local ToastHost = {
    Generation = 0,
    Gui = nil,
    Toast = nil,
}

local function ResolveParent()
    local environment = getgenv()
    local getHiddenUi = environment.gethui
    if type(getHiddenUi) == "function" then
        local ok, hiddenUi = pcall(getHiddenUi)
        if ok and typeof(hiddenUi) == "Instance" then
            return hiddenUi
        end
    end
    return CoreGui
end

local function ProtectGui(gui)
    local environment = getgenv()
    local protectGui = environment.protect_gui
    if type(protectGui) ~= "function" and typeof(environment.syn) == "table" then
        protectGui = environment.syn.protect_gui
    end
    if type(protectGui) == "function" then
        pcall(protectGui, gui)
    end
end

local function NewLabel(parent, name, text, position, size, font, textSize, color)
    local label = Instance.new("TextLabel")
    label.Name = name
    label.BackgroundTransparency = 1
    label.Position = position
    label.Size = size
    label.Font = font
    label.Text = text
    label.TextColor3 = color
    label.TextSize = textSize
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = parent
    return label
end

function ToastHost:_ensureGui()
    if self.Gui and self.Gui.Parent then return self.Gui end

    local parent = ResolveParent()
    local oldHost = parent:FindFirstChild(HOST_NAME)
    if oldHost then
        oldHost:Destroy()
    end

    local gui = Instance.new("ScreenGui")
    gui.Name = HOST_NAME
    gui.DisplayOrder = 2147483647
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    ProtectGui(gui)
    gui.Parent = parent

    self.Gui = gui
    getgenv().MCP_ToastHost = gui
    return gui
end

function ToastHost:ShowConnected(transport)
    self.Generation += 1
    local generation = self.Generation
    local gui = self:_ensureGui()

    if self.Toast then
        self.Toast:Destroy()
    end

    local toast = Instance.new("Frame")
    toast.Name = "ConnectedToast"
    toast.AnchorPoint = Vector2.new(0.5, 0)
    toast.BackgroundColor3 = Color3.fromRGB(23, 25, 31)
    toast.BackgroundTransparency = 0.05
    toast.BorderSizePixel = 0
    toast.Position = UDim2.new(0.5, 0, 0, -76)
    toast.Size = UDim2.fromOffset(320, 62)
    toast.Parent = gui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 10)
    corner.Parent = toast

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(75, 214, 137)
    stroke.Transparency = 0.35
    stroke.Thickness = 1
    stroke.Parent = toast

    local dot = Instance.new("Frame")
    dot.Name = "StatusDot"
    dot.BackgroundColor3 = Color3.fromRGB(75, 214, 137)
    dot.BorderSizePixel = 0
    dot.Position = UDim2.fromOffset(18, 21)
    dot.Size = UDim2.fromOffset(10, 10)
    dot.Parent = toast

    local dotCorner = Instance.new("UICorner")
    dotCorner.CornerRadius = UDim.new(1, 0)
    dotCorner.Parent = dot

    NewLabel(
        toast,
        "Title",
        "MCP connected",
        UDim2.fromOffset(40, 9),
        UDim2.new(1, -52, 0, 24),
        Enum.Font.GothamSemibold,
        15,
        Color3.fromRGB(245, 247, 250)
    )
    NewLabel(
        toast,
        "Detail",
        transport == "ws" and "Using WebSocket transport" or "Using HTTP transport",
        UDim2.fromOffset(40, 31),
        UDim2.new(1, -52, 0, 20),
        Enum.Font.Gotham,
        12,
        Color3.fromRGB(174, 181, 194)
    )

    self.Toast = toast
    TweenService:Create(
        toast,
        TweenInfo.new(0.25, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
        { Position = UDim2.new(0.5, 0, 0, 18) }
    ):Play()

    task.delay(DISPLAY_SECONDS, function()
        if self.Generation ~= generation or self.Toast ~= toast or not toast.Parent then return end
        local tween = TweenService:Create(
            toast,
            TweenInfo.new(0.2, Enum.EasingStyle.Quart, Enum.EasingDirection.In),
            { Position = UDim2.new(0.5, 0, 0, -76), BackgroundTransparency = 1 }
        )
        tween:Play()
        tween.Completed:Wait()
        if self.Toast == toast then
            self.Toast = nil
        end
        toast:Destroy()
    end)
end

return ToastHost
end
