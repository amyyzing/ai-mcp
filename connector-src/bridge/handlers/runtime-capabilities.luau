return function(context, Bridge)
    Bridge:BindToTypeStructured("executor-capabilities", function(_data)
        return context.RuntimeCapabilities:Probe()
    end)
end
