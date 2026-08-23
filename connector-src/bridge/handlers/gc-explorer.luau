return function(context, Bridge)
    local explorer = context.GcExplorer

    Bridge:BindToTypeStructured("gc-snapshot", function(data)
        local operation = data.operation or "create"
        if operation == "create" then return explorer:CreateSnapshot(data) end
        if operation == "list" then return explorer:ListSnapshots() end
        if operation == "release" then return explorer:ReleaseSnapshot(data.snapshotId) end
        error("Unknown gc-snapshot operation: " .. tostring(operation))
    end)

    Bridge:BindToTypeStructured("gc-query", function(data)
        return explorer:Query(data)
    end)

    Bridge:BindToTypeStructured("gc-diff", function(data)
        return explorer:Diff(data)
    end)

    Bridge:BindToTypeStructured("gc-statistics", function(data)
        return explorer:Statistics(data)
    end)

    Bridge:BindToTypeStructured("runtime-references", function(data)
        return explorer:References(data)
    end)
end
