local InstancePath = require("../instance-path")
local Inspector = require("../../dex/inspect")
local Scan = require("../../dex/scan")
local Watch = require("../../dex/watch")

return function(context, Bridge)
    local HttpService = game:GetService("HttpService")
    local function measure(value) return #HttpService:JSONEncode(value) end
    local inspector = Inspector.new({
        InstancePath = InstancePath, Handles = context.RuntimeHandles,
        Values = context.RuntimeValues, Measure = measure,
    })
    local scans = Scan.new({
        Inspector = inspector, Measure = measure,
        NewId = function() return HttpService:GenerateGUID(false) end,
    })
    local watches = Watch.new({
        Inspector = inspector, Values = context.RuntimeValues, Measure = measure,
        NewId = function() return HttpService:GenerateGUID(false) end,
    })
    local alive = true
    local api = {
        Version = 1, ClientId = Bridge.ClientId,
        Describe = function(instance)
            assert(alive, "Dex connection closed; reload the MCP connector.")
            return inspector:Describe(instance)
        end,
    }
    getgenv().RobloxMCPDex = api

    local function bind(name, callback)
        Bridge:BindToTypeStructured(name, function(data)
            assert(alive, "Dex connection closed; reconnect and start a fresh query.")
            local result = callback(data)
            result.clientId = Bridge.ClientId
            result.connectorGeneration = context.RuntimeHandles.generation
            result.placeId = game.PlaceId
            result.observedAtUnixMs = DateTime.now().UnixTimestampMillis
            return result
        end)
    end
    bind("dex-inspect", function(data) return inspector:Inspect(data) end)
    bind("dex-query", function(data) return scans:Query(data) end)
    bind("dex-references", function(data) return scans:Query(data, "references") end)
    bind("dex-snapshot", function(data) return scans:Snapshots(data) end)
    bind("dex-watch", function(data)
        if data.operation == "start" then return watches:Start(data) end
        if data.operation == "poll" then return watches:Poll(data) end
        if data.operation == "stop" then return watches:Stop(data) end
        error("Unknown Dex watch operation.")
    end)
    local function dexAdapter()
        local adapter = getgenv().DexMCP
        assert(type(adapter) == "table" and adapter.Version == 1, "Compatible Dex is not loaded. Run the updated Dex loader in this same executor.")
        assert(type(adapter.GetSelection) == "function" and type(adapter.GetStatus) == "function" and type(adapter.Reveal) == "function", "Dex adapter is incomplete; reload the updated Dex loader.")
        assert(adapter.GetStatus().Ready == true, "Dex explorer is closed or still loading.")
        return adapter
    end
    bind("dex-selection", function(data)
        local adapter = dexAdapter()
        local selection = adapter.GetSelection()
        assert(type(selection) == "table", "Dex returned an invalid selection.")
        local status = adapter.GetStatus()
        local total = math.max(#selection, tonumber(status.SelectionCount) or #selection)
        local available = math.min(#selection, 100)
        local offset = math.clamp(math.floor(tonumber(data.offset) or 0), 0, 100)
        local limit = math.clamp(math.floor(tonumber(data.limit) or 25), 1, 50)
        local results, used = {}, 600
        local index = offset
        while index < available and #results < limit do
            local ok, item = pcall(function() return inspector:Describe(selection[index + 1]) end)
            if not ok then item = { unavailable = true, index = index + 1 } end
            local size = measure(item)
            if used + size > (data.maxChars or 20000) then
                if #results > 0 then break end
                item = { Handle = item.Handle, omitted = true, index = index + 1, reason = "output-budget; use dex-inspect with the Handle" }
                size = measure(item)
            end
            table.insert(results, item)
            used += size
            index += 1
        end
        return {
            available = true, adapterVersion = adapter.Version, results = results,
            selectionCount = total, availableSelectionCount = available,
            selectionTruncated = status.SelectionTruncated == true or total > available,
            nextOffset = index < available and index or nil,
            note = "Selection is live; paging is not atomic. Use returned Handles for exact identity.",
        }
    end)
    bind("dex-reveal", function(data)
        local adapter = dexAdapter()
        local instance = inspector:Resolve(data.target)
        local ok, reason = adapter.Reveal(instance)
        assert(ok ~= false, tostring(reason or "Dex could not reveal that instance."))
        return { revealed = true, instance = inspector:Describe(instance) }
    end)

    task.spawn(function()
        while alive and Bridge.Connected do
            task.wait(5)
            if alive then scans:Sweep() watches:Sweep() end
        end
    end)
    return function()
        alive = false
        watches:Destroy()
        scans:Destroy()
        if getgenv().RobloxMCPDex == api then getgenv().RobloxMCPDex = nil end
    end
end
