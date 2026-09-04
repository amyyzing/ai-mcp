local InstancePath = require("../instance-path")
local SearchInstancesRunning = false
local MAX_SELECTOR_MATCHES = 1000

return function(context, Bridge)
local MarketplaceService = context.MarketplaceService

    Bridge:BindToType("search-instances", function(data)
        assert(not SearchInstancesRunning, "Another instance selector search is already running; retry shortly.")
        SearchInstancesRunning = true

        local ok, result = pcall(function()
            local rootInstance = InstancePath.Resolve({ path = data.root })
            local instances = rootInstance:QueryDescendants(data.selector)
            assert(
                #instances <= MAX_SELECTOR_MATCHES,
                "Selector matched over " .. MAX_SELECTOR_MATCHES .. " instances; narrow the selector/root."
            )

            local limit = math.max(1, math.min(tonumber(data.limit) or 20, 100))
            local results = {}

            for i, instance in instances do
                if i > limit then break end

                table.insert(results, InstancePath.Describe(instance))
            end

            return {
                count = #instances,
                limited = #instances > limit,
                results = results
            }
        end)

        SearchInstancesRunning = false
        if not ok then error(result, 0) end
        return result
    end)

    Bridge:BindToType("get-game-info", function(data)
        local info = {
            PlaceId = game.PlaceId,
            GameId = game.GameId,
            PlaceVersion = game.PlaceVersion,
            JobId = game.JobId,
            PlaceName = "Unknown",
            ServerType = "Unknown",
        }
        local warnings = {}

        local productOk, productInfo = pcall(function()
            return MarketplaceService:GetProductInfo(game.PlaceId)
        end)
        if productOk and type(productInfo) == "table" then
            info.PlaceName = productInfo.Name or info.PlaceName
            if type(productInfo.Creator) == "table" then
                info.Creator = productInfo.Creator.Name
                info.CreatorType = tostring(productInfo.Creator.CreatorType)
                info.CreatorId = productInfo.Creator.CreatorTargetId
            end
            if data.includeDescription == true then
                info.PlaceDescription = productInfo.Description
            end
        else
            table.insert(warnings, "Marketplace metadata unavailable: " .. string.sub(tostring(productInfo), 1, 300))
        end

        -- Keep this callback bounded. A game-owned RemoteFunction can yield
        -- forever, so infer the standard server category from local DataModel
        -- properties instead of invoking RobloxReplicatedStorage.GetServerType.
        local privateServerId = tostring(game.PrivateServerId or "")
        local privateServerOwnerId = tonumber(game.PrivateServerOwnerId) or 0
        if privateServerId == "" then
            info.ServerType = "Public"
        elseif privateServerOwnerId > 0 then
            info.ServerType = "Private"
        else
            info.ServerType = "Reserved"
        end
        info.PrivateServerId = privateServerId ~= "" and privateServerId or nil
        info.PrivateServerOwnerId = privateServerOwnerId > 0 and privateServerOwnerId or nil

        if #warnings > 0 then info.Warnings = warnings end

        return info
    end)

    Bridge:BindToType("get-descendants-tree", function(data)
        local rootInstance = InstancePath.Resolve({ path = data.root })
        assert(typeof(rootInstance) == "Instance", "Root path did not resolve to a valid Instance.")

        local maxDepth = math.max(0, math.min(tonumber(data.maxDepth) or 2, 5))
        local maxChildren = math.max(1, math.min(tonumber(data.maxChildren) or 20, 30))
        local classFilter = data.classFilter or ""
        local hasFilter = classFilter ~= ""
        local summaryOnly = data.summaryOnly == true
        local MAX_TREE_NODES = 300
        local nodeBudget = MAX_TREE_NODES
        local budgetHit = false
        local visitedWork = 0
        local workLimited = false
        local deadline = os.clock() + 0.02
        local function visit()
            if visitedWork >= 5000 or os.clock() >= deadline then
                workLimited = true
                return false
            end
            visitedWork += 1
            return true
        end

        if summaryOnly then
            local classCounts = {}
            local visited = 0
            local matched = 0
            local traversalLimited = false
            local MAX_SUMMARY_VISITED = 5000

            local function walk(instance, depth)
                if depth > maxDepth or traversalLimited then
                    return
                end

                for _, child in instance:GetChildren() do
                    if visited >= MAX_SUMMARY_VISITED or not visit() then
                        traversalLimited = true
                        return
                    end
                    visited += 1
                    if not hasFilter or child:IsA(classFilter) then
                        matched += 1
                        classCounts[child.ClassName] = (classCounts[child.ClassName] or 0) + 1
                    end
                    if depth < maxDepth then
                        walk(child, depth + 1)
                        if traversalLimited then return end
                    end
                end
            end

            walk(rootInstance, 1)

            return {
                Root = {
                    Name = rootInstance.Name,
                    ClassName = rootInstance.ClassName,
                    ChildCount = #rootInstance:GetChildren(),
                },
                MaxDepth = maxDepth,
                ClassFilter = if hasFilter then classFilter else nil,
                VisitedDescendants = visited,
                MatchedDescendants = matched,
                ClassCounts = classCounts,
                TraversalLimited = traversalLimited,
                TraversalLimit = MAX_SUMMARY_VISITED,
                ContinuationHint = traversalLimited and "Use dex-query for resumable, budgeted traversal." or nil,
            }
        end

        local function buildTree(instance, depth)
            if depth > maxDepth then
                return nil
            end

            local children = instance:GetChildren()
            local childNodes = {}
            local shown = 0
            local total = #children

            if depth >= maxDepth then
                return { Name = instance.Name, ClassName = instance.ClassName, ChildCount = total, Children = {}, DepthLimited = total > 0 }
            end

            for _, child in children do
                if shown >= maxChildren then break end
                if not visit() then break end
                if nodeBudget <= 0 then
                    budgetHit = true
                    break
                end

                if hasFilter and not child:IsA(classFilter) then
                    -- Even if this child doesn't match, check if any descendant might
                    -- Only skip if we're at max depth anyway
                    if depth < maxDepth then
                        local subtree = buildTree(child, depth + 1)
                        if subtree and subtree.Children and #subtree.Children > 0 then
                            table.insert(childNodes, subtree)
                            shown += 1
                        end
                    end
                    continue
                end

                nodeBudget -= 1

                local node = {
                    Name = child.Name,
                    ClassName = child.ClassName,
                    ChildCount = #child:GetChildren()
                }

                if depth < maxDepth and node.ChildCount > 0 then
                    local subtree = buildTree(child, depth + 1)
                    if subtree then
                        node.Children = subtree.Children
                    end
                end

                table.insert(childNodes, node)
                shown += 1
            end

            return {
                Name = instance.Name,
                ClassName = instance.ClassName,
                ChildCount = total,
                TruncatedAt = if shown < total then shown else nil,
                Children = childNodes
            }
        end

        local tree = buildTree(rootInstance, 0)
        if typeof(tree) == "table" then
            tree.VisitedDescendants = visitedWork
            tree.TraversalLimited = workLimited
        end
        if budgetHit and typeof(tree) == "table" then
            tree.Note = "Output capped at " .. MAX_TREE_NODES .. " nodes. Use dex-query to continue a bounded scan."
        elseif workLimited and typeof(tree) == "table" then
            tree.Note = "Traversal work/time budget reached, including unmatched nodes. Use dex-query for continuation."
        end
        return tree
    end)
end
