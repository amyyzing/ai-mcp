local register = require("../connector-src/bridge/handlers/core")
local calls = {}
setfenv(register, setmetatable({setthreadidentity=function() end}, {__index=getfenv(register)}))
local bridge = {}
function bridge:BindToType(name, handler) calls[name]=handler end
function bridge:BindToTypeRaw(name, handler) calls[name]=handler end
register({}, bridge)
local ok, problem = pcall(calls["get-data-by-code"], {source="local ="})
assert(not ok and tostring(problem):find("Failed to compile data source",1,true), tostring(problem))
assert(not tostring(problem):find("attempt to call a nil value",1,true))
local values = calls["get-data-by-code"]({source="return nil, 17, false"})
assert(values.n==3 and values[1]==nil and values[2]==17 and values[3]==false)
local result = calls.execute({source="return", operationId="probe"})
assert(result.status=="completed" and result.operationId=="probe")
print("core compilation error and nil-return contracts passed")
