local a={cache={}::any}do do local function __modImpl()


local function EncodeString(b)
return string.format("%q",b)
end

local function EncodeNumber(b)
if b~=b then return EncodeString"NaN"end
if b==math.huge then return EncodeString"Infinity"end
if b==-math.huge then return EncodeString"-Infinity"end
return tostring(b)
end

local function KeyLess(b,c)
local d=typeof(b)
local e=typeof(c)
if d~=e then
return d=="number"
end
if d=="number"then
return b<c
end
return tostring(b)<tostring(c)
end

local function Encode(b,c,d)
local e=typeof(b)
if e=="nil"then return"nil"end
if e=="boolean"then return b and"true"or"false"end
if e=="number"then return EncodeNumber(b)end
if e=="string"then return EncodeString(b)end
if e~="table"then return EncodeString(tostring(b))end
if d>=12 then return EncodeString"<table: max depth reached>"end
if c[b]then return EncodeString"<cyclic table>"end

c[b]=true
local f={}
for g in b do
table.insert(f,g)
end
table.sort(f,KeyLess)

local g={}
for h,i in f do
local j
if typeof(i)=="string"and string.match(i,"^[A-Za-z_][A-Za-z0-9_]*$")then
j=i
else
j="["..Encode(i,c,d+1).."]"
end
table.insert(g,j.."="..Encode(b[i],c,d+1))
end
c[b]=nil
return"{"..table.concat(g,",").."}"
end

return function(b)
return Encode(b,{},0)
end end function a.a():typeof(__modImpl())local b=a.cache.a if not b then b={c=__modImpl()}a.cache.a=b end return b.c end end do local function __modImpl()

local b={}

local function AddCandidate(c,d,e)
if type(e)=="function"then
table.insert(c,{
provider=d,
callback=e,
})
end
end

local function NormalizeResponse(c)
assert(type(c)=="table","Executor HTTP API returned a non-table response.")
local d=tonumber(
c.StatusCode or c.Status or c.status_code or c.status
)
assert(d~=nil,"Executor HTTP response did not include a status code.")
return{
StatusCode=d,
Body=c.Body or c.body or c.ResponseBody or"",
Headers=c.Headers or c.headers or{},
}
end

function b.Resolve(c)
c=c or getgenv()
local d={}
AddCandidate(d,"request",c.request)
AddCandidate(d,"http_request",c.http_request)
AddCandidate(d,"httprequest",c.httprequest)

for e,f in{
{name="http.request",owner=c.http},
{name="syn.request",owner=c.syn},
{name="fluxus.request",owner=c.fluxus},
{name="krnl.request",owner=c.krnl},
}do
if typeof(f.owner)=="table"then
AddCandidate(d,f.name,f.owner.request)
end
end

for e,f in d do
local g=f.callback
local function Request(h)
local i={}
for j,k in h do
i[j]=k
end
i.url=i.url or i.Url
i.method=i.method or i.Method
i.headers=i.headers or i.Headers
i.body=i.body or i.Body
local j,k=pcall(g,i)
assert(j,k)
return NormalizeResponse(k)
end
return Request,f.provider
end

return nil,"unavailable"
end

return b end function a.b():typeof(__modImpl())local b=a.cache.b if not b then b={c=__modImpl()}a.cache.b=b end return b.c end end do local function __modImpl()

local b={}
b.__index=b

local function ClampInteger(c,d,e,f)
local g=tonumber(c)
if g==nil or g~=g then g=d end
return math.max(e,math.min(f,math.floor(g)))
end

local function Classify(c)
local d=typeof(c)
if d=="table"or d=="function"or d=="thread"then
return d
end
if d=="Instance"then return"instance"end
if d=="RBXScriptConnection"then return"connection"end
if d=="RBXScriptSignal"then return"signal"end
if d=="userdata"then return"userdata"end
return string.lower(d)
end

function b.new(c)
c=c or{}
local d=tostring(c.RegistryId or"runtime")
d=string.gsub(d,"[^%w]","")
if d==""then d="runtime"end

return setmetatable({
registryId=string.sub(d,1,16),
generation=1,
nextId=0,
entries={},
activeCount=0,
order={},
orderCursor=1,
reverse=setmetatable({},{__mode="k"}),
weakValues=setmetatable({},{__mode="v"}),
strongValues={},
maxHandles=ClampInteger(c.MaxHandles,50000,100,200000),
defaultTtlSeconds=ClampInteger(c.DefaultTtlSeconds,1800,30,7200),
clock=c.Clock or os.clock,
created=0,
released=0,
expired=0,
evicted=0,
collected=0,
lastSweepAt=-math.huge,
sweepIntervalSeconds=1,
},b)
end

function b._now(c)
return c.clock()
end

function b._remove(c,d,e)
local f=c.entries[d]
if f==nil then return false end
c.entries[d]=nil
c.activeCount=math.max(0,c.activeCount-1)
local g=c.strongValues[d]or c.weakValues[d]
c.strongValues[d]=nil
c.weakValues[d]=nil
if g~=nil and c.reverse[g]==d then
c.reverse[g]=nil
end
if e=="released"then c.released+=1 end
if e=="expired"then c.expired+=1 end
if e=="evicted"then c.evicted+=1 end
if e=="collected"then c.collected+=1 end
return true
end

function b.Sweep(c,d)
local e=c:_now()
if d~=true and e-c.lastSweepAt<c.sweepIntervalSeconds then return 0 end
c.lastSweepAt=e
local f=0
for g,h in c.entries do
if c.strongValues[g]==nil and c.weakValues[g]==nil then
if c:_remove(g,"collected")then f+=1 end
elseif h.expiresAt<=e then
if c:_remove(g,"expired")then f+=1 end
end
end
if#c.order>c.maxHandles*2 and#c.order>c.activeCount*2 then
local g={}
for h=c.orderCursor,#c.order do
local i=c.order[h]
if c.entries[i]~=nil then table.insert(g,i)end
end
c.order=g
c.orderCursor=1
end
return f
end

function b._count(c)
return c.activeCount
end

function b._evictOldest(c)
while c.orderCursor<=#c.order do
local d=c.order[c.orderCursor]
c.orderCursor+=1
if c.entries[d]~=nil then
c:_remove(d,"evicted")
return true
end
end
return false
end

function b.Register(c,d,e,f,g,h)
assert(d~=nil,"Cannot create a runtime handle for nil.")
c:Sweep()

local i=c.reverse[d]
local j=i and c.entries[i]or nil
if j then
local k=c:_now()
j.lastAccess=k
j.expiresAt=k+ClampInteger(g,c.defaultTtlSeconds,30,7200)
if f~=nil then j.metadata=f end
if h~=false then
c.strongValues[i]=d
j.pinned=true
end
return i,j
end

while c:_count()>=c.maxHandles do
assert(c:_evictOldest(),"Runtime handle registry is full and could not evict an entry.")
end

c.nextId+=1
local k=string.format("rh_%s_%d_%d",c.registryId,c.generation,c.nextId)
local l=c:_now()
local m={
handle=k,
kind=e or Classify(d),
generation=c.generation,
createdAt=l,
lastAccess=l,
expiresAt=l+ClampInteger(g,c.defaultTtlSeconds,30,7200),
metadata=f,
pinned=h~=false,
}
c.entries[k]=m
c.activeCount+=1
table.insert(c.order,k)
c.weakValues[k]=d
if h~=false then c.strongValues[k]=d end
c.reverse[d]=k
c.created+=1
return k,m
end

function b.Resolve(c,d,e,f)
assert(type(d)=="string"and d~="","A runtime handle is required.")
c:Sweep()
local g=c.entries[d]
assert(g~=nil,"Runtime handle is missing, expired, released, or belongs to another connector generation.")
local h=c.strongValues[d]or c.weakValues[d]
if h==nil then
c:_remove(d,"collected")
error"Runtime object was garbage-collected before this handle was pinned."
end
if e~=nil then
if type(e)=="table"then
local i=false
for j,k in e do
if g.kind==k then i=true break end
end
assert(i,"Runtime handle kind is "..g.kind..", not one of the requested kinds.")
else
assert(g.kind==e,"Runtime handle kind is "..g.kind..", not "..tostring(e)..".")
end
end
local i=c:_now()
g.lastAccess=i
g.expiresAt=i+c.defaultTtlSeconds
if f~=false then
c.strongValues[d]=h
g.pinned=true
end
return h,g
end

function b.Pin(c,d)
local e,f=c:Resolve(d,nil,true)
return e,f
end

function b.Unpin(c,d)
local e=c.entries[d]
if not e then return false end
c.strongValues[d]=nil
e.pinned=false
return true
end

function b.Describe(c,d)local
e, f=c:Resolve(d)
return{
handle=f.handle,
kind=f.kind,
generation=f.generation,
ageSeconds=math.max(0,c:_now()-f.createdAt),
idleSeconds=math.max(0,c:_now()-f.lastAccess),
expiresInSeconds=math.max(0,f.expiresAt-c:_now()),
pinned=f.pinned==true,
metadata=f.metadata,
}
end

function b.Release(c,d)
return c:_remove(d,"released")
end

function b.ReleaseMany(c,d)
local e=0
local f=0
for g,h in d or{}do
if type(h)=="string"and c:Release(h)then
e+=1
else
f+=1
end
end
return e,f
end

function b.List(c,d,e,f)
c:Sweep(true)
d=ClampInteger(d,0,0,1000000000)
e=ClampInteger(e,50,1,200)
local g={}
for h,i in c.entries do
if f==nil or i.kind==f then
table.insert(g,{handle=h,entry=i})
end
end
table.sort(g,function(h,i)return h.handle<i.handle end)

local h={}
local i=math.min(#g,d+e)
for j=d+1,i do
local k=g[j]
table.insert(h,{
handle=k.handle,
kind=k.entry.kind,
generation=k.entry.generation,
ageSeconds=math.max(0,c:_now()-k.entry.createdAt),
expiresInSeconds=math.max(0,k.entry.expiresAt-c:_now()),
pinned=k.entry.pinned==true,
metadata=k.entry.metadata,
})
end
return{
total=#g,
cursor=d,
nextCursor=i<#g and i or nil,
handles=h,
}
end

function b.Stats(c)
c:Sweep(true)
local d={}
local e=0
local f=0
for g,h in c.entries do
e+=1
if h.pinned then f+=1 end
d[h.kind]=(d[h.kind]or 0)+1
end
return{
registryId=c.registryId,
generation=c.generation,
active=e,
pinned=f,
weak=e-f,
maximum=c.maxHandles,
defaultTtlSeconds=c.defaultTtlSeconds,
byKind=d,
lifetime={
created=c.created,
released=c.released,
expired=c.expired,
evicted=c.evicted,
collected=c.collected,
},
}
end

function b.RotateGeneration(c)
for d in c.entries do c:_remove(d,"released")end
c.generation+=1
c.nextId=0
c.order={}
c.orderCursor=1
return c.generation
end

b.Classify=Classify

return b end function a.c():typeof(__modImpl())local b=a.cache.c if not b then b={c=__modImpl()}a.cache.c=b end return b.c end end do local function __modImpl()



local b={}

local c=100
local d=2000

local function Trim(e)
return(string.gsub(string.gsub(e,"^%s+",""),"%s+$",""))
end

local function IsIdentifier(e)
return string.match(e,"^[%a_][%w_]*$")~=nil
end

local function DecodeEscape(e)
if e=="n"then return"\n"end
if e=="r"then return"\r"end
if e=="t"then return"\t"end
if e=="b"then return"\b"end
if e=="f"then return"\f"end
return e
end

local function ParseQuotedSegment(e,f)
local g=string.sub(e,f,f)
assert(g=='"'or g=="'","Bracket segments must use a quoted child name.")
f+=1

local h={}
local i=false
while f<=#e do
local j=string.sub(e,f,f)
if j==g then
i=true
f+=1
break
end
if j=="\\"then
f+=1
assert(f<=#e,"Instance path ends inside an escape sequence.")
j=DecodeEscape(string.sub(e,f,f))
end
table.insert(h,j)
f+=1
end
assert(i,"Unterminated quoted instance-path segment.")
return table.concat(h),f
end

local function ParsePath(e)
assert(type(e)=="string","Instance path must be a string.")
e=Trim(e)
assert(e~="","Instance path cannot be empty.")
assert(#e<=d,"Instance path is too long.")

local f
local g
if string.sub(e,1,4)=="game"then
local h=string.sub(e,5,5)
assert(h==""or h=="."or h=="[","Path root must be exactly game or workspace.")
f=game
g=5
elseif string.sub(e,1,9)=="workspace"then
local h=string.sub(e,10,10)
assert(h==""or h=="."or h=="[","Path root must be exactly game or workspace.")
f=workspace
g=10
else
error"Instance path must be rooted at game or workspace."
end

local h={}
while g<=#e do
assert(#h<c,"Instance path has too many segments.")
local i=string.sub(e,g,g)
if i=="."then
g+=1
local j=string.sub(e,g)
local k=string.match(j,"^([%a_][%w_]*)")
assert(k~=nil,"Dot segments must be valid identifiers.")
table.insert(h,k)
g+=#k
elseif i=="["then
g+=1
while string.match(string.sub(e,g,g),"%s")do g+=1 end
local j
j,g=ParseQuotedSegment(e,g)
while string.match(string.sub(e,g,g),"%s")do g+=1 end
assert(string.sub(e,g,g)=="]","Quoted path segment must end with ].")
g+=1
table.insert(h,j)
else
error("Unsupported instance-path syntax at character "..tostring(g)..".")
end
end

return f,h
end

local function ResolveSegment(e,f,g)
local h=e:FindFirstChild(f)
if h then
if g then
local i=0
for j,k in e:GetChildren()do
g.remaining-=1
assert(g.remaining>=0 and os.clock()<g.deadline,"Path uniqueness check exceeded its budget. Use a Handle returned by dex-query or dex-selection.")
if k.Name==f then i+=1 end
assert(i<=1,"Ambiguous duplicate-name path segment. Use a Handle returned by dex-query or dex-selection.")
end
end
return h
end



local i,j=pcall(function()
return e[f]
end)
if i and typeof(j)=="Instance"then return j end
return nil
end

function b.Resolve(e,f)
assert(type(e)=="table","Instance target must be an object.")

local g
local h
if e.path~=nil then
assert(e.pathSegments==nil,"Provide path or pathSegments, not both.")
g,h=ParsePath(e.path)
else
assert(type(e.pathSegments)=="table","Provide path or pathSegments.")
g=e.root=="workspace"and workspace or game
h=e.pathSegments
assert(#h>0 and#h<=c,"pathSegments must contain 1-100 names.")
end

local i=g
local j=f and{remaining=10000,deadline=os.clock()+0.02}or nil
for k,l in ipairs(h)do
assert(type(l)=="string"and#l<=200,"Invalid path segment at index "..tostring(k)..".")
local m=ResolveSegment(i,l,j)
assert(m,"Instance path was not found at segment "..tostring(k).." ("..l..").")
i=m
end

return i
end

local function EncodeSegment(e)
if IsIdentifier(e)then return"."..e end
local f=string.gsub(e,"\\","\\\\")
f=string.gsub(f,'"','\\"')
f=string.gsub(f,"\n","\\n")
f=string.gsub(f,"\r","\\r")
f=string.gsub(f,"\t","\\t")
return'["'..f..'"]'
end

function b.StablePath(e)
assert(typeof(e)=="Instance","StablePath expects an Instance.")
if e==game then return"game"end

local f={}
local g=e
local h=false
while g and g~=game and#f<=c do
table.insert(f,g.Name)
g=g.Parent
end
h=g==game

if not h then
local i,j=pcall(function()return e:GetFullName()end)
return i and("<detached>."..j)or("<detached>."..e.Name)
end

local i="game"
for j=#f,1,-1 do
i..=EncodeSegment(f[j])
end
return i
end

function b.Describe(e)
local f
pcall(function()f=e:GetDebugId()end)
local g
pcall(function()g=e:GetFullName()end)
return{
Name=e.Name,
ClassName=e.ClassName,
Path=b.StablePath(e),
FullName=g,
DebugId=f,
}
end

b.Parse=ParsePath

return b end function a.d():typeof(__modImpl())local b=a.cache.d if not b then b={c=__modImpl()}a.cache.d=b end return b.c end end do local function __modImpl()

local b=a.d()

local c={}
c.__index=c

local function ClampInteger(d,e,f,g)
local h=tonumber(d)
if h==nil or h~=h then h=e end
return math.max(f,math.min(g,math.floor(h)))
end

local function SafeString(d)
local e,f=pcall(tostring,d)
return e and f or"<unprintable>"
end

local function Utf8Prefix(d,e)
local f={}
local g=0
local h=pcall(function()
for h,i in utf8.codes(d)do
local j=utf8.char(i)
if g+#j>e then break end
table.insert(f,j)
g+=#j
end
end)
if h then return table.concat(f),g end
local i=string.sub(string.gsub(d,"[^%g ]","?"),1,e)
return i,#i
end

local function FunctionSummary(d)
local e={}
pcall(function()e.name=debug.info(d,"n")end)
pcall(function()e.source=debug.info(d,"s")end)
pcall(function()e.line=debug.info(d,"l")end)
local f=if type(getfunctionhash)=="function"then getfunctionhash else nil
if f then pcall(function()e.hash=f(d)end)end
if type(isexecutorclosure)=="function"then
pcall(function()e.executorClosure=isexecutorclosure(d)==true end)
end
return e
end

local function CountTable(d,e)
local f=0
local g=true
local h=pcall(function()
for h in pairs(d)do
if f>=e then g=false break end
f+=1
end
end)
return f,g and h
end

function c.new(d)
d=d or{}
assert(d.Handles~=nil,"TypedValues requires a runtime handle registry.")
return setmetatable({
Handles=d.Handles,
defaultDepth=ClampInteger(d.DefaultDepth,3,0,8),
defaultEntries=ClampInteger(d.DefaultEntries,100,1,1000),
defaultStringBytes=ClampInteger(d.DefaultStringBytes,4096,64,65536),
},c)
end

function c._handle(d,e,f,g)
local h=d.Handles:Register(e,f,g)
return{
type="handle",
kind=f,
handle=h,
summary=g,
}
end

function c._encode(d,e,f,g)
local h=typeof(e)
if h=="nil"then return{type="nil"}end
if h=="boolean"then return{type="boolean",value=e}end
if h=="number"then
if e~=e then return{type="number",special="nan"}end
if e==math.huge then return{type="number",special="positive-infinity"}end
if e==-math.huge then return{type="number",special="negative-infinity"}end
if e==0 and 1/e==-math.huge then return{type="number",special="negative-zero"}end
return{type="number",value=e}
end
if h=="string"then
local i=math.max(0,math.min(f.stringBytes,f.maxStringBytesPerValue))
local j,k=Utf8Prefix(e,i)
f.stringBytes-=k
return{
type="string",
value=j,
originalBytes=#e~=#j and#e or nil,
}
end

if h=="Instance"then
local i=b.Describe(e)
local j=d.Handles:Register(e,"instance",{
className=i.ClassName,
path=i.Path,
})
return{
type="instance",
handle=j,
ref={
path=i.Path,
name=i.Name,
className=i.ClassName,
debugId=i.DebugId,
},
}
end

if h=="Vector2"then return{type="vector2",x=e.X,y=e.Y}end
if h=="Vector3"then return{type="vector3",x=e.X,y=e.Y,z=e.Z}end
if h=="Color3"then return{type="color3",r=e.R,g=e.G,b=e.B}end
if h=="BrickColor"then return{type="brickColor",number=e.Number,name=e.Name}end
if h=="UDim"then return{type="udim",scale=e.Scale,offset=e.Offset}end
if h=="UDim2"then
return{
type="udim2",
xScale=e.X.Scale,
xOffset=e.X.Offset,
yScale=e.Y.Scale,
yOffset=e.Y.Offset,
}
end
if h=="CFrame"then
return{type="cframe",components={e:GetComponents()}}
end
if h=="Rect"then
return{
type="rect",
min={type="vector2",x=e.Min.X,y=e.Min.Y},
max={type="vector2",x=e.Max.X,y=e.Max.Y},
}
end
if h=="Ray"then
return{
type="ray",
origin={type="vector3",x=e.Origin.X,y=e.Origin.Y,z=e.Origin.Z},
direction={type="vector3",x=e.Direction.X,y=e.Direction.Y,z=e.Direction.Z},
}
end
if h=="NumberRange"then return{type="numberRange",min=e.Min,max=e.Max}end
if h=="EnumItem"then
return{
type="enum",
enumType=SafeString(e.EnumType),
name=e.Name,
value=e.Value,
}
end
if h=="DateTime"then return{type="dateTime",unixTimestampMillis=e.UnixTimestampMillis}end
if h=="PhysicalProperties"then
return{
type="physicalProperties",
fields={
density=e.Density,
friction=e.Friction,
elasticity=e.Elasticity,
frictionWeight=e.FrictionWeight,
elasticityWeight=e.ElasticityWeight,
},
}
end
if h=="NumberSequence"then
local i={}
for j,k in e.Keypoints do
if j>f.maxEntries then break end
table.insert(i,{time=k.Time,value=k.Value,envelope=k.Envelope})
end
return{type="numberSequence",keypoints=i}
end
if h=="ColorSequence"then
local i={}
for j,k in e.Keypoints do
if j>f.maxEntries then break end
table.insert(i,{
time=k.Time,
value={type="color3",r=k.Value.R,g=k.Value.G,b=k.Value.B},
})
end
return{type="colorSequence",keypoints=i}
end

if h=="function"then
return d:_handle(e,"function",FunctionSummary(e))
end
if h=="thread"then
local i
pcall(function()i=coroutine.status(e)end)
return d:_handle(e,"thread",{status=i})
end
if h=="RBXScriptConnection"then
return d:_handle(e,"connection",nil)
end
if h=="RBXScriptSignal"then
return d:_handle(e,"signal",nil)
end

if h=="table"then
local i,j=CountTable(e,math.max(f.maxEntries,1000))
local k={entryCount=i,entryCountExact=j}
local l=d.Handles:Register(e,"table",k)
if f.expandTables~=true or g>=f.maxDepth then
return{
type="handle",
kind="table",
handle=l,
summary=k,
omitted=g>=f.maxDepth and"depth-limit"or nil,
}
end

local m=f.seen[e]
if m then return{type="reference",tableId=m,handle=l}end
f.nextTableId+=1
local n=f.nextTableId
f.seen[e]=n
local o={}
local p=false
for q,r in pairs(e)do
if f.entries>=f.maxEntries then p=true break end
f.entries+=1
table.insert(o,{
key=d:_encode(q,f,g+1),
value=d:_encode(r,f,g+1),
})
end
return{
type="table",
tableId=n,
handle=l,
entries=o,
truncated=p or nil,
omission=p and"entry-limit"or nil,
}
end

if h=="userdata"or string.find(h,"Connection",1,true)then
return d:_handle(e,"userdata",{robloxType=h,display=SafeString(e)})
end

return{
type="unsupported",
robloxType=h,
display=SafeString(e),
}
end

function c.Encode(d,e,f)
f=f or{}
local g={
seen={},
nextTableId=0,
entries=0,
maxEntries=ClampInteger(f.maxEntries,d.defaultEntries,1,1000),
stringBytes=ClampInteger(f.maxStringBytes,d.defaultStringBytes,64,262144),
maxStringBytesPerValue=ClampInteger(f.maxStringBytesPerValue,d.defaultStringBytes,64,65536),
maxDepth=ClampInteger(f.maxDepth,d.defaultDepth,0,8),
expandTables=f.expandTables==true,
}
local h=d:_encode(e,g,0)
return h,{
encodedEntries=g.entries,
remainingStringBytes=g.stringBytes,
codecVersion=1,
}
end

local function DecodeEnum(d,e)
local f=string.gsub(tostring(d or""),"^Enum%.","")
local g=Enum[f]
assert(g~=nil,"Unknown Enum type: "..f)
local h=g[tostring(e or"")]
assert(h~=nil,"Unknown Enum item: "..f.."."..tostring(e))
return h
end

function c.Decode(d,e,f)
if type(e)~="table"or e.type==nil then return e end
f=f or{tables={},entries=0}
local g=e.type
if g=="nil"then return nil end
if g=="boolean"or g=="string"then return e.value end
if g=="number"then
if e.special=="nan"then return 0/0 end
if e.special=="positive-infinity"then return math.huge end
if e.special=="negative-infinity"then return-math.huge end
if e.special=="negative-zero"then return-0 end
assert(type(e.value)=="number","Typed number requires a numeric value.")
return e.value
end
if g=="handle"then
local h=d.Handles:Resolve(e.handle)
return h
end
if g=="enum"then return DecodeEnum(e.enumType,e.name)end
if g=="vector2"then return Vector2.new(e.x,e.y)end
if g=="vector3"then return Vector3.new(e.x,e.y,e.z)end
if g=="color3"then return Color3.new(e.r,e.g,e.b)end
if g=="brickColor"then return BrickColor.new(e.number or e.name)end
if g=="udim"then return UDim.new(e.scale,e.offset)end
if g=="udim2"then return UDim2.new(e.xScale,e.xOffset,e.yScale,e.yOffset)end
if g=="cframe"then
assert(type(e.components)=="table"and#e.components==12,"CFrame requires 12 components.")
return CFrame.new(table.unpack(e.components))
end
if g=="rect"then
return Rect.new(d:Decode(e.min,f),d:Decode(e.max,f))
end
if g=="ray"then
return Ray.new(d:Decode(e.origin,f),d:Decode(e.direction,f))
end
if g=="numberRange"then return NumberRange.new(e.min,e.max)end
if g=="dateTime"then return DateTime.fromUnixTimestampMillis(e.unixTimestampMillis)end
if g=="physicalProperties"then
local h=e.fields or{}
return PhysicalProperties.new(
h.density,
h.friction,
h.elasticity,
h.frictionWeight,
h.elasticityWeight
)
end
if g=="numberSequence"then
local h=e.keypoints or{}
f.entries+=#h
assert(f.entries<=1000,"Typed sequence input exceeds 1000 keypoints.")
local i={}
for j,k in h do
table.insert(i,NumberSequenceKeypoint.new(k.time,k.value,k.envelope or 0))
end
return NumberSequence.new(i)
end
if g=="colorSequence"then
local h=e.keypoints or{}
f.entries+=#h
assert(f.entries<=1000,"Typed sequence input exceeds 1000 keypoints.")
local i={}
for j,k in h do
table.insert(i,ColorSequenceKeypoint.new(k.time,d:Decode(k.value,f)))
end
return ColorSequence.new(i)
end
if g=="table"then
f.entries+=#(e.entries or{})
assert(f.entries<=1000,"Typed table input exceeds 1000 entries.")
local h={}
if e.tableId~=nil then f.tables[e.tableId]=h end
for i,j in e.entries or{}do
h[d:Decode(j.key,f)]=d:Decode(j.value,f)
end
return h
end
if g=="reference"then
local h=f.tables[e.tableId]
assert(h~=nil,"Typed table reference points to an unknown tableId.")
return h
end
error("Unsupported typed runtime input: "..tostring(g))
end

c.FunctionSummary=FunctionSummary
c.CountTable=CountTable

return c end function a.e():typeof(__modImpl())local b=a.cache.e if not b then b={c=__modImpl()}a.cache.e=b end return b.c end end do local function __modImpl()

local b={}
b.__index=b

local function TimestampMillis()
local c,d=pcall(function()return DateTime.now().UnixTimestampMillis end)
return c and d or os.time()*1000
end

local function Descriptor(c,d,e,f,g,h)
return{
id=c,
available=d==true,
provider=e,
quality=d and(f or"best-effort")or"degraded",
testedAtUnixMs=TimestampMillis(),
limits=g,
degradedReason=d and nil or(h or"API is not exposed by this executor."),
}
end

local function IsFunction(c)
return type(c)=="function"
end

local function FirstFunction(...)
for c,d in{...}do
if IsFunction(d)then return d end
end
return nil
end

local function ExecutorIdentity()
local c=FirstFunction(identifyexecutor,getexecutorname)
if not c then return nil end
local d,e,f=pcall(c)
if not d then return{error=tostring(e)}end
return{name=tostring(e),version=f~=nil and tostring(f)or nil}
end

function b.new(c)
c=c or{}
return setmetatable({
connectorVersion=tostring(c.ConnectorVersion or"1"),
RequestAvailable=c.RequestAvailable==true,
HttpRequestProvider=tostring(c.HttpRequestProvider or"unavailable"),
WebSocketAvailable=c.WebSocketAvailable==true,
},b)
end

function b.Probe(c)
local d=type(debug)=="table"and debug or{}
local e={
Descriptor("transport.request",c.RequestAvailable,c.HttpRequestProvider,"exact"),
Descriptor("transport.websocket",c.WebSocketAvailable,"executor-api","exact"),
Descriptor("script.loadstring",IsFunction(loadstring),"executor-api","exact"),
Descriptor("script.decompile",IsFunction(decompile),"executor-api","best-effort"),
Descriptor("script.bytecode",IsFunction(getscriptbytecode),"executor-api","best-effort"),
Descriptor("script.hash",IsFunction(getscripthash),"executor-api","best-effort"),
Descriptor("runtime.gc-snapshot",IsFunction(getgc),"executor-api","best-effort"),
Descriptor("runtime.gc-filter",IsFunction(filtergc),"executor-api","best-effort"),
Descriptor("runtime.function-hash",IsFunction(getfunctionhash),"executor-api","best-effort"),
Descriptor("runtime.function-constants",IsFunction(getconstants)or IsFunction(d.getconstants),"executor-api","best-effort"),
Descriptor("runtime.function-set-constant",IsFunction(setconstant)or IsFunction(d.setconstant),"executor-api","best-effort"),
Descriptor("runtime.function-upvalues",IsFunction(getupvalues)or IsFunction(d.getupvalues),"executor-api","best-effort"),
Descriptor("runtime.function-set-upvalue",IsFunction(setupvalue)or IsFunction(d.setupvalue),"executor-api","best-effort"),
Descriptor("runtime.function-prototypes",IsFunction(getprotos)or IsFunction(d.getprotos),"executor-api","best-effort"),
Descriptor("runtime.calling-script",IsFunction(getcallingscript),"executor-api","best-effort"),
Descriptor("runtime.executor-closure",IsFunction(isexecutorclosure),"executor-api","best-effort"),
Descriptor("runtime.environments",IsFunction(getrenv)or IsFunction(getsenv)or IsFunction(getfenv),"executor-api","best-effort"),
Descriptor("runtime.scripts",IsFunction(getscripts),"executor-api","best-effort"),
Descriptor("runtime.running-scripts",IsFunction(getrunningscripts),"executor-api","best-effort"),
Descriptor("runtime.loaded-modules",IsFunction(getloadedmodules),"executor-api","best-effort"),
Descriptor("runtime.nil-instances",IsFunction(getnilinstances),"executor-api","best-effort"),
Descriptor("runtime.all-instances",IsFunction(getinstances),"executor-api","best-effort"),
Descriptor("runtime.script-closure",IsFunction(getscriptclosure),"executor-api","best-effort"),
Descriptor("runtime.thread-identity-read",IsFunction(getthreadidentity)or IsFunction(getidentity)or IsFunction(getthreadcontext),"executor-api","best-effort"),
Descriptor("runtime.thread-identity-write",IsFunction(setthreadidentity)or IsFunction(setidentity)or IsFunction(setthreadcontext),"executor-api","best-effort"),
Descriptor("signal.connections",IsFunction(getconnections),"executor-api","best-effort"),
Descriptor("callback.inspect",IsFunction(getcallbackvalue),"executor-api","best-effort"),
Descriptor("property.hidden-read",IsFunction(gethiddenproperty),"executor-api","best-effort"),
Descriptor("property.hidden-write",IsFunction(sethiddenproperty),"executor-api","best-effort"),
Descriptor("property.scriptable",IsFunction(setscriptable)or IsFunction(isscriptable),"executor-api","best-effort"),
Descriptor("hook.function",IsFunction(hookfunction),"executor-api","best-effort"),
Descriptor("hook.metamethod",IsFunction(hookmetamethod),"executor-api","best-effort"),
Descriptor("hook.namecall-method",IsFunction(getnamecallmethod),"executor-api","best-effort"),
Descriptor("hook.raw-metatable",IsFunction(getrawmetatable),"executor-api","best-effort"),
Descriptor("hook.new-c-closure",IsFunction(newcclosure),"executor-api","best-effort"),
Descriptor("actor.list",IsFunction(getactors),"executor-api","best-effort"),
Descriptor("actor.threads",IsFunction(getactorthreads),"executor-api","best-effort"),
Descriptor("actor.execute",IsFunction(run_on_actor)or IsFunction(runonactor),"executor-api","best-effort"),
Descriptor("input.fire-signal",IsFunction(firesignal),"executor-api","best-effort"),
Descriptor("input.fire-prompt",IsFunction(fireproximityprompt),"executor-api","best-effort"),
Descriptor("input.fire-click-detector",IsFunction(fireclickdetector),"executor-api","best-effort"),
Descriptor("input.fire-touch",IsFunction(firetouchinterest),"executor-api","best-effort"),
}

local f={}
local g=0
for h,i in e do
local j=string.match(i.id,"^([^.]+)")or"other"
f[j]=f[j]or{available=0,unavailable=0}
if i.available then
g+=1
f[j].available+=1
else
f[j].unavailable+=1
end
i.connectorVersion=c.connectorVersion
end

return{
executor=ExecutorIdentity(),
connectorVersion=c.connectorVersion,
testedAtUnixMs=TimestampMillis(),
available=g,
unavailable=#e-g,
byCategory=f,
capabilities=e,
}
end

return b end function a.f():typeof(__modImpl())local b=a.cache.f if not b then b={c=__modImpl()}a.cache.f=b end return b.c end end do local function __modImpl()

local b=a.d()

local c={}
c.__index=c

local function ClampInteger(d,e,f,g)
local h=tonumber(d)
if h==nil or h~=h then h=e end
return math.max(f,math.min(g,math.floor(h)))
end

local function TimestampMillis()
local d,e=pcall(function()return DateTime.now().UnixTimestampMillis end)
return d and e or os.time()*1000
end

local function SafePrimitive(d)
local e=type(d)
return e=="string"or e=="number"or e=="boolean"or d==nil
end

local function IsExecutorClosure(d)
if type(isexecutorclosure)~="function"or type(d)~="function"then return false end
local e,f=pcall(isexecutorclosure,d)
return e and f==true
end

local function GetConstants(d)
local e=if type(getconstants)=="function"then getconstants else nil
if not e and type(debug)=="table"and type(debug.getconstants)=="function"then
e=debug.getconstants
end
if not e then return nil end
local f,g=pcall(e,d)
return f and type(g)=="table"and g or nil
end

local function GetUpvalues(d)
local e=if type(getupvalues)=="function"then getupvalues else nil
if not e and type(debug)=="table"and type(debug.getupvalues)=="function"then
e=debug.getupvalues
end
if not e then return nil end
local f,g=pcall(e,d)
return f and type(g)=="table"and g or nil
end

local function GetPrototypes(d)
local e=if type(getprotos)=="function"then getprotos else nil
if not e and type(debug)=="table"and type(debug.getprotos)=="function"then
e=debug.getprotos
end
if not e then return nil end
local f,g=pcall(e,d)
return f and type(g)=="table"and g or nil
end

local function ContainsPrimitive(d,e,f)
if type(e)~="table"or#e==0 then return true end
if type(d)~="table"then return false end
for g,h in e do
local i=false
local j=0
for k,l in pairs(d)do
if j>=f then break end
j+=1
if SafePrimitive(l)and l==h then i=true break end
end
if not i then return false end
end
return true
end

local function TableSummary(d,e)
local f=0
local g=true
local h={}
local i={}
local j=pcall(function()
for j in pairs(d)do
if f>=e then g=false break end
f+=1
local k=typeof(j)
i[k]=(i[k]or 0)+1
if type(j)=="string"and#h<20 then
table.insert(h,string.sub(j,1,120))
end
end
end)
table.sort(h)
local k={}
for l,m in i do table.insert(k,l..":"..tostring(m))end
table.sort(k)
return{
entryCount=f,
entryCountExact=g and j,
keyNames=h,
keyTypes=i,
signature=table.concat(h,"|").."#"..table.concat(k,","),
}
end

local function FunctionSummary(d,e)
local f=e.FunctionSummary(d)
local g=GetConstants(d)
local h=GetUpvalues(d)
local i=GetPrototypes(d)
f.executorClosure=IsExecutorClosure(d)
f.constantCount=g and#g or nil
f.upvalueCount=h and#h or nil
f.prototypeCount=i and#i or nil
f.signature=table.concat({
tostring(f.hash or""),
tostring(f.source or""),
tostring(f.line or""),
tostring(f.name or""),
tostring(f.constantCount or""),
tostring(f.upvalueCount or""),
},"|")
return f
end

function c.new(d)
d=d or{}
assert(d.Handles~=nil and d.TypedValues~=nil,"GcExplorer requires handles and typed values.")
return setmetatable({
Handles=d.Handles,
TypedValues=d.TypedValues,
snapshots={},
snapshotOrder={},
nextSnapshot=0,
maxSnapshots=ClampInteger(d.MaxSnapshots,8,2,32),
defaultScanLimit=ClampInteger(d.DefaultScanLimit,20000,100,100000),
tableScanLimit=ClampInteger(d.TableScanLimit,250,50,10000),
running=false,
},c)
end

function c._snapshotId(d)
d.nextSnapshot+=1
return string.format("gs_%s_%d",d.Handles.registryId,d.nextSnapshot)
end

function c._objectRecord(d,e)
local f=d.Handles.Classify(e)
local g
if f=="function"then
g=FunctionSummary(e,d.TypedValues)
elseif f=="table"then
g=TableSummary(e,d.tableScanLimit)
elseif f=="thread"then
local h
pcall(function()h=coroutine.status(e)end)
g={status=h,signature="thread:"..tostring(h)}
elseif f=="instance"then
local h=b.Describe(e)
g={
path=h.Path,
name=h.Name,
className=h.ClassName,
debugId=h.DebugId,
}
g.signature=tostring(g.className).."|"..tostring(g.path)
else
g={robloxType=typeof(e),signature=typeof(e)..":"..tostring(e)}
end


local h=d.Handles:Register(e,f,g,3600,false)
return{handle=h,kind=f,summary=g}
end

function c.CreateSnapshot(d,e)
assert(type(getgc)=="function","This executor does not expose getgc; GC snapshots are unavailable.")
assert(not d.running,"Another GC snapshot is already running for this client.")
d.running=true

local f,g=pcall(function()
local f=os.clock()
local g,h=pcall(getgc,e.includeTables~=false)
if not g then g,h=pcall(getgc)end
assert(g and type(h)=="table","getgc failed: "..tostring(h))

local i=ClampInteger(e.scanLimit,d.defaultScanLimit,100,100000)
local j=e.includeExecutor==true
local k={}
for l,m in e.kinds or{}do k[m]=true end
local l=next(k)~=nil
local m={
snapshotId=d:_snapshotId(),
createdAtUnixMs=TimestampMillis(),
scanLimit=i,
totalReturnedByExecutor=#h,
scanned=0,
retained=0,
recordFailures=0,
recordFailureSamples={},
truncated=false,
includeExecutor=j,
objects={},
counts={},
}

for n,o in h do
if m.scanned>=i then m.truncated=true break end
m.scanned+=1
if m.scanned%250==0 then task.wait()end
local p=d.Handles.Classify(o)
if l and not k[p]then continue end
if p=="function"and not j and IsExecutorClosure(o)then continue end
if o==m or o==d.snapshots or o==d.snapshotOrder then continue end
local q,r=pcall(function()return d:_objectRecord(o)end)
if q then
table.insert(m.objects,r)
m.retained+=1
m.counts[r.kind]=(m.counts[r.kind]or 0)+1
else
m.recordFailures+=1
if#m.recordFailureSamples<5 then
table.insert(m.recordFailureSamples,string.sub(tostring(r),1,300))
end
end
end

m.durationMs=math.floor((os.clock()-f)*1000+0.5)
d.snapshots[m.snapshotId]=m
table.insert(d.snapshotOrder,m.snapshotId)
while#d.snapshotOrder>d.maxSnapshots do
local n=table.remove(d.snapshotOrder,1)
d.snapshots[n]=nil
end
return d:DescribeSnapshot(m)
end)
d.running=false
if not f then error(g)end
return g
end

function c.DescribeSnapshot(d,e)
return{
snapshotId=e.snapshotId,
createdAtUnixMs=e.createdAtUnixMs,
durationMs=e.durationMs,
scanLimit=e.scanLimit,
totalReturnedByExecutor=e.totalReturnedByExecutor,
scanned=e.scanned,
retained=e.retained,
recordFailures=e.recordFailures,
recordFailureSamples=e.recordFailureSamples,
truncated=e.truncated,
includeExecutor=e.includeExecutor,
counts=e.counts,
}
end

function c.GetSnapshot(d,e)
local f=d.snapshots[e]
assert(f~=nil,"Unknown or released GC snapshot: "..tostring(e))
return f
end

function c.ListSnapshots(d)
local e={}
for f,g in d.snapshotOrder do
local h=d.snapshots[g]
if h then table.insert(e,d:DescribeSnapshot(h))end
end
return{snapshots=e,maximumSnapshots=d.maxSnapshots,running=d.running}
end

function c.ReleaseSnapshot(d,e)
local f=d.snapshots[e]~=nil
d.snapshots[e]=nil
for g=#d.snapshotOrder,1,-1 do
if d.snapshotOrder[g]==e then table.remove(d.snapshotOrder,g)end
end
return{snapshotId=e,released=f}
end

local function HasTableKeys(d,e)
if type(e)~="table"or#e==0 then return true end
if type(d)~="table"then return false end
for f,g in e do
if rawget(d,g)==nil then return false end
end
return true
end

function c._matches(d,e,f,g)
if g.kind and e.kind~=g.kind then return false end
local h=e.summary or{}
if g.name and h.name~=g.name then return false end
if g.hash and h.hash~=g.hash then return false end
if g.sourceContains then
if type(h.source)~="string"or not string.find(h.source,g.sourceContains,1,true)then return false end
end
if g.signatureContains then
if type(h.signature)~="string"or not string.find(h.signature,g.signatureContains,1,true)then return false end
end
if g.minEntries and(h.entryCount or-1)<g.minEntries then return false end
if g.maxEntries and(h.entryCount or math.huge)>g.maxEntries then return false end
if e.kind=="function"then
if g.ignoreExecutor~=false and h.executorClosure==true then return false end
if not ContainsPrimitive(GetConstants(f),g.constants,d.tableScanLimit)then return false end
if not ContainsPrimitive(GetUpvalues(f),g.upvalues,d.tableScanLimit)then return false end
elseif e.kind=="table"then
if not HasTableKeys(f,g.keys)then return false end
if not ContainsPrimitive(f,g.values,d.tableScanLimit)then return false end
if type(g.keyValuePairs)=="table"then
for i,j in g.keyValuePairs do
if rawget(f,i)~=j then return false end
end
end
end
return true
end

function c.Query(d,e)
local f=d:GetSnapshot(e.snapshotId)
local g=ClampInteger(e.cursor,0,0,1000000000)
local h=ClampInteger(e.limit,25,1,200)
local i={}
local j=0
local k=0
local l=0
for m,n in f.objects do
l+=1
if l%500==0 then task.wait()end
local o,p=pcall(function()return d.Handles:Resolve(n.handle,nil,false)end)
if not o then k+=1 continue end
local q,r=pcall(function()return d:_matches(n,p,e)end)
if not q or not r then continue end
if j>=g and#i<h then
d.Handles:Pin(n.handle)
table.insert(i,n)
end
j+=1
end
local m=g+#i
return{
snapshotId=f.snapshotId,
totalMatched=j,
cursor=g,
nextCursor=m<j and m or nil,
staleHandles=k,
recordsScanned=l,
results=i,
}
end

function c.Diff(d,e)
local f=d:GetSnapshot(e.beforeSnapshotId)
local g=d:GetSnapshot(e.afterSnapshotId)
local h={}
local i={}
local j={}
local k={}
for l,m in f.objects do
h[m.handle]=m
j[m.kind]=(j[m.kind]or 0)+1
end
for l,m in g.objects do
i[m.handle]=m
k[m.kind]=(k[m.kind]or 0)+1
end

local l=ClampInteger(e.sampleLimit,50,0,200)
local m={}
local n={}
local o=0
local p=0
local q=0
for r,s in i do
if h[r]then
q+=1
else
o+=1
if#m<l then table.insert(m,s)end
end
end
for r,s in h do
if not i[r]then
p+=1
if#n<l then table.insert(n,s)end
end
end
return{
beforeSnapshotId=f.snapshotId,
afterSnapshotId=g.snapshotId,
addedCount=o,
removedCount=p,
retainedCount=q,
addedSample=m,
removedSample=n,
countsByKind={before=j,after=k},
}
end

function c.Statistics(d,e)
local f=d:GetSnapshot(e.snapshotId)
local g={}
local h={}
local i={}
for j,k in f.objects do
local l=k.summary or{}
if k.kind=="function"then
local m=tostring(l.source or"<unknown>")
g[m]=(g[m]or 0)+1
elseif k.kind=="table"then
local m=tostring(l.signature or"<unknown>")
h[m]=(h[m]or 0)+1
table.insert(i,k)
end
end
table.sort(i,function(j,k)
return(j.summary.entryCount or 0)>(k.summary.entryCount or 0)
end)
while#i>ClampInteger(e.largestTableLimit,20,0,100)do table.remove(i)end
return{
snapshotId=f.snapshotId,
counts=f.counts,
functionsBySource=g,
tableSignatures=h,
largestTables=i,
handleRegistry=d.Handles:Stats(),
}
end

local function IsReferenceValue(d)
local e=typeof(d)
return e=="table"
or e=="function"
or e=="thread"
or e=="Instance"
or e=="RBXScriptConnection"
or e=="RBXScriptSignal"
or e=="userdata"
end

function c.References(d,e)
local f=d:GetSnapshot(e.snapshotId)
local g=d.Handles:Resolve(e.handle)
local h=e.direction or"both"
local i=ClampInteger(e.limit,100,1,500)
local j=ClampInteger(e.scanLimit,20000,100,100000)
local k=ClampInteger(e.perObjectScanLimit,250,10,10000)
local l={}
local m=0
local n=0
local o=false

local function AddOutgoing(p,q,r)
if#l>=i then o=true return false end
if not IsReferenceValue(q)then return true end
table.insert(l,{
direction="outgoing",
fromHandle=e.handle,
relation=p,
detail=r,
to=d.TypedValues:Encode(q),
})
return true
end

local function AddIncoming(p,q,r)
if#l>=i then o=true return false end
d.Handles:Pin(p.handle)
table.insert(l,{
direction="incoming",
from={
type="handle",
kind=p.kind,
handle=p.handle,
summary=p.summary,
},
relation=q,
detail=r,
toHandle=e.handle,
})
return true
end

if h=="outgoing"or h=="both"then
local p=typeof(g)
if p=="table"then
local q=0
for r,s in next,g do
if q>=k or#l>=i then o=true break end
q+=1
n+=1
AddOutgoing("table-key",r,{key=d.TypedValues:Encode(r)})
if not AddOutgoing("table-value",s,{key=d.TypedValues:Encode(r)})then break end
end
elseif p=="function"then
for q,r in pairs(GetUpvalues(g)or{})do
if#l>=i then o=true break end
AddOutgoing("upvalue",r,{index=d.TypedValues:Encode(q)})
end
for q,r in pairs(GetPrototypes(g)or{})do
if#l>=i then o=true break end
AddOutgoing("prototype",r,{index=d.TypedValues:Encode(q)})
end
end
local q=if type(getrawmetatable)=="function"then getrawmetatable else getmetatable
local r,s=pcall(q,g)
if r and s~=nil then AddOutgoing("metatable",s,nil)end
end

if(h=="incoming"or h=="both")and#l<i then
for p,q in f.objects do
if m>=j or#l>=i then o=true break end
m+=1
if m%250==0 then task.wait()end
if q.handle==e.handle then continue end
local r,s=pcall(function()
return d.Handles:Resolve(q.handle,nil,false)
end)
if not r then continue end
local t=typeof(s)
if t=="table"then
local u=0
local v=pcall(function()
for v,w in next,s do
if u>=k or#l>=i then o=true break end
u+=1
n+=1
if rawequal(v,g)then AddIncoming(q,"table-key",nil)end
if rawequal(w,g)then
AddIncoming(q,"table-value",{key=d.TypedValues:Encode(v)})
end
end
end)
if not v then continue end
elseif t=="function"then
for u,v in pairs(GetUpvalues(s)or{})do
if rawequal(v,g)then
AddIncoming(q,"upvalue",{index=d.TypedValues:Encode(u)})
end
if#l>=i then break end
end
for u,v in pairs(GetPrototypes(s)or{})do
if rawequal(v,g)then
AddIncoming(q,"prototype",{index=d.TypedValues:Encode(u)})
end
if#l>=i then break end
end
end
local u=if type(getrawmetatable)=="function"then getrawmetatable else getmetatable
local v,w=pcall(u,s)
if v and rawequal(w,g)then AddIncoming(q,"metatable",nil)end
end
end

return{
snapshotId=f.snapshotId,
targetHandle=e.handle,
direction=h,
edges=l,
edgeCount=#l,
objectsScanned=m,
entriesScanned=n,
truncated=o,
}
end

return c end function a.g():typeof(__modImpl())local b=a.cache.g if not b then b={c=__modImpl()}a.cache.g=b end return b.c end end do local function __modImpl()

return function(b)
local c=b.CoreGui
local d=b.TweenService

local e="RobloxMCPToastHost"
local f=4

local g={
Generation=0,
Gui=nil,
Toast=nil,
}

local function ResolveParent()
local h=getgenv()
local i=h.gethui
if type(i)=="function"then
local j,k=pcall(i)
if j and typeof(k)=="Instance"then
return k
end
end
return c
end

local function ProtectGui(h)
local i=getgenv()
local j=i.protect_gui
if type(j)~="function"and typeof(i.syn)=="table"then
j=i.syn.protect_gui
end
if type(j)=="function"then
pcall(j,h)
end
end

local function NewLabel(h,i,j,k,l,m,n,o)
local p=Instance.new"TextLabel"
p.Name=i
p.BackgroundTransparency=1
p.Position=k
p.Size=l
p.Font=m
p.Text=j
p.TextColor3=o
p.TextSize=n
p.TextXAlignment=Enum.TextXAlignment.Left
p.Parent=h
return p
end

function g._ensureGui(h)
if h.Gui and h.Gui.Parent then return h.Gui end

local i=ResolveParent()
local j=i:FindFirstChild(e)
if j then
j:Destroy()
end

local k=Instance.new"ScreenGui"
k.Name=e
k.DisplayOrder=2147483647
k.IgnoreGuiInset=true
k.ResetOnSpawn=false
k.ZIndexBehavior=Enum.ZIndexBehavior.Sibling
ProtectGui(k)
k.Parent=i

h.Gui=k
getgenv().MCP_ToastHost=k
return k
end

function g.ShowConnected(h,i)
h.Generation+=1
local j=h.Generation
local k=h:_ensureGui()

if h.Toast then
h.Toast:Destroy()
end

local l=Instance.new"Frame"
l.Name="ConnectedToast"
l.AnchorPoint=Vector2.new(0.5,0)
l.BackgroundColor3=Color3.fromRGB(23,25,31)
l.BackgroundTransparency=0.05
l.BorderSizePixel=0
l.Position=UDim2.new(0.5,0,0,-76)
l.Size=UDim2.new(1,-24,0,62)
l.Parent=k

local m=Instance.new"UISizeConstraint"
m.MaxSize=Vector2.new(320,62)
m.MinSize=Vector2.new(220,62)
m.Parent=l

local n=Instance.new"UICorner"
n.CornerRadius=UDim.new(0,10)
n.Parent=l

local o=Instance.new"UIStroke"
o.Color=Color3.fromRGB(75,214,137)
o.Transparency=0.35
o.Thickness=1
o.Parent=l

local p=Instance.new"Frame"
p.Name="StatusDot"
p.BackgroundColor3=Color3.fromRGB(75,214,137)
p.BorderSizePixel=0
p.Position=UDim2.fromOffset(18,21)
p.Size=UDim2.fromOffset(10,10)
p.Parent=l

local q=Instance.new"UICorner"
q.CornerRadius=UDim.new(1,0)
q.Parent=p

NewLabel(
l,
"Title",
"MCP connected",
UDim2.fromOffset(40,9),
UDim2.new(1,-52,0,24),
Enum.Font.GothamSemibold,
15,
Color3.fromRGB(245,247,250)
)
NewLabel(
l,
"Detail",
i=="ws"and"Using WebSocket transport"or"Using HTTP transport",
UDim2.fromOffset(40,31),
UDim2.new(1,-52,0,20),
Enum.Font.Gotham,
12,
Color3.fromRGB(174,181,194)
)

h.Toast=l
d:Create(
l,
TweenInfo.new(0.25,Enum.EasingStyle.Quart,Enum.EasingDirection.Out),
{Position=UDim2.new(0.5,0,0,18)}
):Play()

task.delay(f,function()
if h.Generation~=j or h.Toast~=l or not l.Parent then return end
local r=d:Create(
l,
TweenInfo.new(0.2,Enum.EasingStyle.Quart,Enum.EasingDirection.In),
{Position=UDim2.new(0.5,0,0,-76),BackgroundTransparency=1}
)
r:Play()
r.Completed:Wait()
if h.Toast==l then
h.Toast=nil
end
l:Destroy()
end)
end

return g
end end function a.h():typeof(__modImpl())local b=a.cache.h if not b then b={c=__modImpl()}a.cache.h=b end return b.c end end do local function __modImpl()

return function(b)
local c=b.HttpService
local d=b.BridgeHTTPURL
local e=b.BridgeWebSocketURL
local f=b.BridgeAuthToken
local g=b.BridgeRequestHeaders
local h=b.Request
local i=b.HttpGet
local j=b.WebSocketAvailable
local k=b.WebSocketConnect
local l=b.GetRegistrationInfo
local m=b.SanitizeForOutput
local n=b.LuaEncode
local o=0
local p=30

local function EncodeBridgeResponse(q)
local r,s=pcall(function()
return c:JSONEncode(q)
end)
if r then return s end
return c:JSONEncode{
id=type(q)=="table"and q.id or nil,
success=false,
error="Failed to serialize connector response: "..string.sub(tostring(s),1,300),
}
end


local q={};do
q.__index=q

function q.BindToType(r,s,t)
r.Callbacks[s]=t
end

function q.BindToTypeRaw(r,s,t)
r.Callbacks[s]=t
r.RawCallbacks=r.RawCallbacks or{}
r.RawCallbacks[s]=true
end

function q.BindToTypeStructured(r,s,t)
r.Callbacks[s]=t
r.StructuredCallbacks=r.StructuredCallbacks or{}
r.StructuredCallbacks[s]=true
end

function q.CreateAlias(r,s,t)
for u,v in t do
r.Callbacks[v]=r.Callbacks[s]
if r.RawCallbacks and r.RawCallbacks[s]then
r.RawCallbacks[v]=true
end
if r.StructuredCallbacks and r.StructuredCallbacks[s]then
r.StructuredCallbacks[v]=true
end
end
end

function q.HandleMessage(r,s)
if r.Callbacks[s.type]then
local t,u=pcall(function()
return r.Callbacks[s.type](s)
end)

if t and u==nil then
return nil
end

if not t then
return r:FormatResponse(u,s.id,true)
end

if r.RawCallbacks and r.RawCallbacks[s.type]then
return{
output=tostring(u),
success=true,
id=s.id
}
end

return r:FormatResponse(
u,
s.id,
false,
r.StructuredCallbacks and r.StructuredCallbacks[s.type]==true
)
end
return nil
end

function q.FormatResponse(r,s,t,u,v)
if u then
return{
error=tostring(s),
success=false,
id=t
}
end

local w=m(s)
if typeof(w)~="table"then
w={w}
end

local x={
output=n(w,{
Prettify=false
}),
success=true,
id=t
}
if v then
x.structured=w
end
return x
end

function q.IsAlive(r)
local s,t=pcall(function()
local s
local t=task.spawn(function()
local t,u
if h then
t,u=pcall(h,{
Url=d,
Method="GET",
Headers=g()
})
else
t,u=pcall(function()
return{StatusCode=200,Body=i(d)}
end)
end

if t then
s=u
end
end)

local u=os.clock()
repeat task.wait(0.05)until s~=nil or os.clock()-u>5

if s==nil then
task.cancel(t)
return false
end


if s.StatusCode==426 or s.StatusCode==200 then
return true
end

return false
end)

if not s then
return false
end

return t
end
end


local r=setmetatable({},{__index=q});do
r.__index=r

function r.new()
local s=setmetatable({},r)


local t=0.5
local u=5
local v=10
local w=0

while not s:IsAlive()do
w+=1
if w>=v then
error("Failed to connect to bridge server after "..v.." attempts")
end
task.wait(t)
t=math.min(t*1.5,u)
end


local x
local y=false
local z=task.spawn(function()
local z,A=pcall(function()
local z=e
if f~=""then
z..="?token="..c:UrlEncode(f)
end
return k(z)
end)
if z then
x=A
end
y=true
end)

local A=os.clock()
repeat task.wait(0.05)until x~=nil or y or os.clock()-A>5

if x==nil then
if not y then
task.cancel(z)
end
error(y and"WebSocket connection failed"or"WebSocket connection timed out after 5 seconds")
end

s.WebSocket=x
s.Connected=true
s.Callbacks={}
s.ClientId=nil


s.WebSocket:Send(c:JSONEncode(l()))

s.AliveThread=task.spawn(function()
local B=0
while task.wait(1)do
if not s.Connected then
continue
end

if s:IsAlive()then
B=0
continue
end

B+=1
if B<3 then
continue
end

s.Connected=false
break
end

pcall(function()
s.WebSocket:Close()
end)
end)


s.WebSocket.OnMessage:Connect(function(B)
local C=c:JSONDecode(B)


if C.type=="registered"then
s.ClientId=C.clientId
s.ClientToken=C.clientToken
getgenv().MCP_ClientToken=C.clientToken
return
end

local D=s:HandleMessage(C)
if D then
s.WebSocket:Send(EncodeBridgeResponse(D))
end
end)


s.WebSocket.OnClose:Connect(function()
s.Connected=false
end)

return s
end

function r.WaitForDisconnect(s)
while s.Connected do
task.wait(0.1)
end
end
end


local s=setmetatable({},{__index=q});do
s.__index=s

function s.new()
assert(h,"This executor exposes neither a working WebSocket nor a supported HTTP request API.")
local t=setmetatable({},s)


local u=0.5
local v=5
local w=10
local x=0

while not t:IsAlive()do
x+=1
if x>=w then
error("Failed to connect to bridge server after "..w.." attempts")
end
task.wait(u)
u=math.min(u*1.5,v)
end

t.Connected=true
t.Callbacks={}
t.PollInterval=0.1
t.ClientId=nil


local y,z=pcall(function()
local y=h{
Url=d.."/register",
Method="POST",
Headers=g{["Content-Type"]="application/json"},
Body=c:JSONEncode(l()),
}
if y.StatusCode==200 and y.Body then
local z=c:JSONDecode(y.Body)
t.ClientId=z.clientId
t.ClientToken=z.clientToken
getgenv().MCP_ClientToken=z.clientToken
end
end)
if not y or type(t.ClientId)~="string"or type(t.ClientToken)~="string"then
t.Connected=false
error("Bridge HTTP registration failed: "..tostring(z or"server rejected registration"))
end


t.PollThread=task.spawn(function()
local A=0

while t.Connected do
local B=false local
C=pcall(function()
local C=d.."/poll"
if t.ClientId then
C=C.."?clientId="..t.ClientId
end
local D=h{
Url=C,
Method="GET",
Headers=g()
}


if D.StatusCode~=204 and D.StatusCode~=200 then
A+=1
if A>=3 then
t.Connected=false
end

return
end

A=0


if D.Body and D.Body~=""then
local E=c:JSONDecode(D.Body)
local F={}
if typeof(E)=="table"and E.type==nil and#E>0 then
F=E
elseif typeof(E)=="table"and E.type~=nil then
F={E}
end

for G,H in ipairs(F)do
B=true
task.spawn(function()
local I=t:HandleMessage(H)
if I==nil then return end
I.clientId=t.ClientId


h{
Url=d.."/respond?clientId="..c:UrlEncode(t.ClientId),
Method="POST",
Headers=g{
["Content-Type"]="application/json"
},
Body=EncodeBridgeResponse(I)
}
end)
end
end
end)

if not C then
A+=1
if A>=3 then
t.Connected=false
end
end

if not B then
task.wait(t.PollInterval)
end
end
end)

return t
end

function s.WaitForDisconnect(t)
while t.Connected do
task.wait(0.1)
end
end
end


local function CreateBridge()
if j and os.clock()>=o then
local t,u=pcall(function()
return r.new()
end)

if t then
o=0
return u
end



o=os.clock()+p
end

return s.new()
end

return{
CreateBridge=CreateBridge,
}
end end function a.i():typeof(__modImpl())local b=a.cache.i if not b then b={c=__modImpl()}a.cache.i=b end return b.c end end do local function __modImpl()

local b={}
b.__index=b

function b.new(c)
local d=setmetatable(c,b)
d.Queue={}
d.QueueHead=1
d.QueueTail=0
d.ActiveWorkers=0
d.ManagerGeneration=0
d.IsDestroyed=false
d.TaskLibrary=c.TaskLibrary or task
d:Reset()
return d
end

function b.QueueOperation(c,...)
if c.IsDestroyed then return end
c.QueueTail+=1
c.Queue[c.QueueTail]=table.pack(...)
c:DrainQueue()
end

function b.DrainQueue(c,d)
if c.IsDestroyed then return end
if d~=nil and c.ManagerGeneration~=d then return end

local e=c.ManagerGeneration
while c.ActiveWorkers<c.MaxConcurrent and c.QueueHead<=c.QueueTail do
local f=c.Queue[c.QueueHead]
c.Queue[c.QueueHead]=nil
c.QueueHead+=1
if not f then continue end

c.ActiveWorkers+=1
c.TaskLibrary.defer(function()
local g=f
while g do
if not c.IsDestroyed and c.ManagerGeneration==e then
local h,i=pcall(
c.MainCallback,
table.unpack(g,1,g.n)
)
if not h then
if c.OnError then
pcall(
c.OnError,
i,
table.unpack(g,1,g.n)
)
end
end
end

if c.IsDestroyed or c.ManagerGeneration~=e or c.ActiveWorkers>c.MaxConcurrent then
break
end

if c.QueueHead<=c.QueueTail then
g=c.Queue[c.QueueHead]
c.Queue[c.QueueHead]=nil
c.QueueHead+=1
else
g=nil
end
end



c.ActiveWorkers=math.max(0,c.ActiveWorkers-1)
c:DrainQueue()
end)
end
end

function b.Reset(c)
if c.IsDestroyed then return end
c.Queue={}
c.QueueHead=1
c.QueueTail=0
c.ManagerGeneration+=1
c:DrainQueue()
end

function b.SetMaxConcurrent(c,d)
c.MaxConcurrent=math.max(1,math.floor(tonumber(d)or 1))
c:DrainQueue()
end

function b.Destroy(c)
if c.IsDestroyed then return end
c.IsDestroyed=true
table.clear(c.Queue)
c.QueueHead=1
c.QueueTail=0
end

b.Stop=b.Destroy

return b end function a.j():typeof(__modImpl())local b=a.cache.j if not b then b={c=__modImpl()}a.cache.j=b end return b.c end end do local function __modImpl()

local b={}
b.__index=b

local c={
mapped=true,
failed=true,
}

local d={
queued={mapping=true,deferred=true,awaiting_upload=true,failed=true,removed=true},
mapping={queued=true,deferred=true,awaiting_upload=true,failed=true,removed=true},
deferred={queued=true,awaiting_upload=true,failed=true,removed=true},
awaiting_upload={mapped=true,failed=true,removed=true},
mapped={removed=true},
failed={queued=true,removed=true},
removed={},
}

function b.new()
return setmetatable({
jobs={},
instances=setmetatable({},{__mode="v"}),
total=0,
processed=0,
skipped=0,
disabled=false,
statusDirty=false,
clientId=nil,
workers=nil,
configuredWorkers=0,
currentWorkers=0,
successesSinceWorkerAdjustment=0,
descendantConnection=nil,
initialScanRunning=false,
initialScanFinished=false,
scanLimit=25000,
scanNodeLimit=250000,
scanTruncated=false,
scanOmitted=0,
sourceBudgetBytes=33554432,
mappedSourceBytes=0,
generation=0,
session=nil,
stateVersion=0,
upload={
queue={},
head=1,
tail=0,
bytes=0,
thread=nil,
},
bridge=nil,
sourceCacheByHash={},
sourceCacheOrder={},
sourceCacheOrderHead=1,
sourceCacheOrderTail=0,
sourceCacheSequence=0,
sourceCacheSequenceByHash={},
sourceCacheEntries=0,
sourceCacheBytes=0,
sourceCacheCheckedByHash={},
scriptHashByDebugId={},
},b)
end

function b.IsActiveSession(e,f,g,h)
return(
e.session==f and
e.generation==g and
e.clientId==h
)
end

function b.IsFinished(e,f)
local g=f==nil and e.processed or f
return e.disabled or(
e.initialScanFinished and
not e.scanTruncated and
g>=e.total
)
end

function b.Reset(e,f,g)
for h,i in e.jobs do
local j=i.destroyingConnection
if j then
pcall(function()j:Disconnect()end)
i.destroyingConnection=nil
end
end

e.generation+=1
e.session=g
e.stateVersion=0
e.currentWorkers=e.configuredWorkers
e.successesSinceWorkerAdjustment=0
e.jobs={}
e.instances=setmetatable({},{__mode="v"})
e.total=0
e.processed=0
e.skipped=0
e.statusDirty=true
e.disabled=false
e.clientId=f
e.scriptHashByDebugId={}
e.sourceCacheCheckedByHash={}
e.initialScanRunning=false
e.initialScanFinished=false
e.scanTruncated=false
e.scanOmitted=0
e.mappedSourceBytes=0
end

function b.MarkScanOmitted(e,f)
e.scanTruncated=true
e.scanOmitted=math.min(1000000000,e.scanOmitted+math.max(1,f or 1))
e.stateVersion+=1
e.statusDirty=true
end

function b.EnsureJob(e,f)
local g=e.jobs[f]
if g then return g,false end

g={debugId=f,generation=e.generation}
e.jobs[f]=g
e.total+=1
e.stateVersion+=1
e.statusDirty=true
return g,true
end

function b.TrackJob(e,f)
local g=e.jobs[f]
if g and g.state~="failed"then return nil end

if not g then
g=e:EnsureJob(f)
else
g.generation=e.generation
end
g.mappingAttempts=0
e:SetJobState(g,"queued")
return g
end

function b.TryStartMapping(e,f)
if e.jobs[f.debugId]~=f or f.generation~=e.generation then return false end
if f.state~="queued"then return false end
e:SetJobState(f,"mapping")
return true
end

function b.CanDeferScanJob(e,f,g)
return(
f~=nil and
f.generation==g and
g==e.generation and
f.state=="queued"
)
end

function b.SetJobState(e,f,g)
local h=f.state
if h==g then return false end
if h~=nil and not d[h][g]then
error("Invalid script mapping transition: "..tostring(h).." -> "..tostring(g))
end

if h=="mapped"then
e.processed=math.max(0,e.processed-1)
elseif h=="failed"then
e.processed=math.max(0,e.processed-1)
e.skipped=math.max(0,e.skipped-1)
end

if g=="mapped"then
e.processed+=1
elseif g=="failed"then
e.processed+=1
e.skipped+=1
elseif g=="removed"then
e.total=math.max(0,e.total-1)
end

f.state=g
if c[h]or c[g]or g=="removed"then
e.stateVersion+=1
e.statusDirty=true
end
return true
end

return b end function a.k():typeof(__modImpl())local b=a.cache.k if not b then b={c=__modImpl()}a.cache.k=b end return b.c end end do local function __modImpl()

local b={}
b.__index=b
local c=0

function b.new(d,e,f)
local g=math.max(0,math.floor(tonumber(e)or 0))
local h=math.max(g,c+1)
c=h
return setmetatable({
id=d,
startedAt=h,
generation=f,
revision=0,
started=false,
},b)
end

function b.NextRevision(d)
d.revision+=1
return d.revision
end

function b.MarkStarted(d)
d.started=true
end

return b end function a.l():typeof(__modImpl())local b=a.cache.l if not b then b={c=__modImpl()}a.cache.l=b end return b.c end end do local function __modImpl()

local b={}

function b.CanAttemptBuiltIn(c,d,e)
return(
c.builtinAttempted~=true and
c.builtinDisabled~=true and
d<=e
)
end

function b.MarkBuiltInAttempted(c)
c.builtinAttempted=true
end

function b.DisableBuiltIn(c)
c.builtinAttempted=true
c.builtinDisabled=true
c.useDirectBuiltin=false
end

return b end function a.m():typeof(__modImpl())local b=a.cache.m if not b then b={c=__modImpl()}a.cache.m=b end return b.c end end do local function __modImpl()

local b=a.m()

local c={}

function c.MaterializeServerFallback(d,e)
b.DisableBuiltIn(d)
if type(d.bytecode)=="string"then
return true
end

local f,g=e()
if not f then
return false,g
end

d.bytecode=g
return true
end

return c end function a.n():typeof(__modImpl())local b=a.cache.n if not b then b={c=__modImpl()}a.cache.n=b end return b.c end end do local function __modImpl()

local b={}
b.__index=b

function b.new(c,d)
c.configuredWorkers=d
c.currentWorkers=d
return setmetatable({pipeline=c},b)
end

function b.Reduce(c)
local d=c.pipeline
local e=math.max(4,math.floor(d.currentWorkers/2))
if e>=d.currentWorkers then return end

d.currentWorkers=e
d.successesSinceWorkerAdjustment=0
if d.workers then
d.workers:SetMaxConcurrent(e)
end
end

function b.RecordSuccess(c)
local d=c.pipeline
if d.currentWorkers>=d.configuredWorkers then return end

d.successesSinceWorkerAdjustment+=1
if d.successesSinceWorkerAdjustment<100 then return end

d.successesSinceWorkerAdjustment=0
d.currentWorkers+=1
if d.workers then
d.workers:SetMaxConcurrent(d.currentWorkers)
end
end

return b end function a.o():typeof(__modImpl())local b=a.cache.o if not b then b={c=__modImpl()}a.cache.o=b end return b.c end end do local function __modImpl()

local b={}
b.__index=b

function b.new(c,d)
d=d or{}
return setmetatable({
pipeline=c,
clock=d.Clock or os.clock,
taskLibrary=d.TaskLibrary or task,
intervalSeconds=d.IntervalSeconds or 30,
maxDelaySeconds=d.MaxDelaySeconds or 300,
batchSize=d.BatchSize or 8,
thread=nil,
},b)
end

function b.Schedule(c,d)
local e=math.max(0,d.resyncRounds or 0)
local f=math.min(
c.intervalSeconds*(2^e),
c.maxDelaySeconds
)
d.nextResyncAt=c.clock()+f
end

function b.Cancel(c,d)
d.nextResyncAt=nil
d.resyncRounds=nil
end

function b.Defer(c,d)
d.nextResyncAt=c.clock()+c.intervalSeconds
end

function b.GetDue(c,d)
d=d or c.clock()
local e={}
for f,g in c.pipeline.jobs do
if(
g.generation==c.pipeline.generation and
g.state=="failed"and
type(g.nextResyncAt)=="number"and
g.nextResyncAt<=d
)then
table.insert(e,g)
end
end

table.sort(e,function(f,g)
if f.nextResyncAt==g.nextResyncAt then
return f.debugId<g.debugId
end
return f.nextResyncAt<g.nextResyncAt
end)
while#e>c.batchSize do
table.remove(e)
end
return e
end

function b.Claim(c,d,e)
e=e or c.clock()
if c.pipeline.jobs[d.debugId]~=d then return false end
if d.generation~=c.pipeline.generation or d.state~="failed"then return false end
if type(d.nextResyncAt)~="number"or d.nextResyncAt>e then return false end

d.resyncRounds=(d.resyncRounds or 0)+1
d.nextResyncAt=nil
d.errorMessage=nil
return c.pipeline:TrackJob(d.debugId)==d
end

function b.Start(c,d)
if c.thread then return end
c.thread=c.taskLibrary.spawn(function()
while true do
c.taskLibrary.wait(c.intervalSeconds)
pcall(d)
end
end)
end

function b.ProcessDue(c,d,e)
for f,g in c:GetDue()do
local h,i=pcall(d,g)
if not h then
if e then
e(g,i)
else
c:Defer(g)
end
end
end
end

return b end function a.p():typeof(__modImpl())local b=a.cache.p if not b then b={c=__modImpl()}a.cache.p=b end return b.c end end do local function __modImpl()

local b={}
b.__index=b


function b.new(c,d)
return setmetatable({
pipeline=c,
failedResync=d,
},b)
end

function b.Publish(c)
c.pipeline.statusDirty=true
end

function b.MarkMapped(c,d,e)
local f=c.pipeline
local g=f.jobs[d]
if g and(g.state=="mapped"or g.state=="failed"or g.state=="removed")then
return false
end

if not g then
g=f:EnsureJob(d)
end

f:SetJobState(g,"mapped")
if c.failedResync then c.failedResync:Cancel(g)end
g.prepared=nil
g.script=nil
if e~=false then c:Publish()end
return true
end

function b.MarkFailed(c,d,e,f)
local g=c.pipeline
local h=g.jobs[d]
if h and(h.state=="mapped"or h.state=="failed"or h.state=="removed")then
return false
end

if not h then
h=g:EnsureJob(d)
end

g:SetJobState(h,"failed")
if c.failedResync then c.failedResync:Schedule(h)end
h.errorMessage=tostring(e or"unknown error")
h.prepared=nil
h.script=nil

if f~=false then c:Publish()end
return true
end

return b end function a.q():typeof(__modImpl())local b=a.cache.q if not b then b={c=__modImpl()}a.cache.q=b end return b.c end end do local function __modImpl()

return function(b)
local c=b.ScriptMappingPipeline
local d=b.HttpService
local e=b.BridgeHTTPURL
local f=b.BridgeRequestHeaders
local g=b.Request
local h=b.JobStatus
local i=64
local j=8388608
local k=0.5
local l=5
local m=8

local function IsScriptMappingTransportReady(n)
return(
c.bridge~=nil and
c.bridge.Connected==true and
c.bridge.ClientId~=nil and
c.bridge.ClientId==n
)
end

local function UploadScriptSourceBatch(n,o)
if not n then return false end
if not IsScriptMappingTransportReady(n)then return false end
local p=c.generation
local q=c.session
if not q then return false end

local r={}
local s={}
for t,u in o or{}do
if u.kind=="remove"then
table.insert(s,u.debugId)
else
table.insert(r,{
debugId=u.debugId,
path=u.path,
source=u.source,
scriptHash=u.scriptHash,
})
end
end

local t=#r
local u=math.min(c.total,c.processed+t)
local v=c:IsFinished(u)
local w=q:NextRevision()

local x,y=pcall(g,{
Url=e.."/script-sources",
Method="POST",
Headers=f{
["Content-Type"]="application/json"
},
Body=d:JSONEncode{
clientId=n,
scripts=r,
removedScriptIds=s,
hasFinishedMapping=v,
sourcesToMap=c.total,
processedSources=u,
skippedSources=c.skipped,
mappingSessionId=q.id,
mappingSessionStartedAt=q.startedAt,
mappingRevision=w,
beginMappingSession=not q.started,
}
})

if not x or not y or y.StatusCode~=200 then return false,w end

if(
not c:IsActiveSession(q,p,n)
)then
return false,w,"stale_session"
end

local z=w
if type(y.Body)=="string"and y.Body~=""then
local A,B=pcall(function()
return d:JSONDecode(y.Body)
end)
if A and type(B)=="table"and type(B.acceptedMappingRevision)=="number"then
z=B.acceptedMappingRevision
end
end
if z~=w then return false,w end

q:MarkStarted()
return true,w
end

local function EnqueueScriptSourceUpload(n)
n.queuedBytes=if type(n.source)=="string"then#n.source else 0
c.upload.tail+=1
c.upload.queue[c.upload.tail]=n
c.upload.bytes+=n.queuedBytes
end

local function DequeueScriptSourceUpload()
if c.upload.head>c.upload.tail then return nil end
local n=c.upload.queue[c.upload.head]
c.upload.queue[c.upload.head]=nil
c.upload.head+=1
if n then c.upload.bytes=math.max(0,c.upload.bytes-(n.queuedBytes or 0))end
return n
end

local function ResetScriptSourceUploadQueue()
c.upload.queue={}
c.upload.head=1
c.upload.tail=0
c.upload.bytes=0
end

local function StartUploadQueue()
if c.upload.thread then return end

c.upload.thread=task.spawn(function()
while true do
if not IsScriptMappingTransportReady(c.clientId)then
task.wait(k)
continue
end
if c.upload.head>c.upload.tail then
if c.statusDirty then
local n=c.stateVersion
local o=UploadScriptSourceBatch(
c.clientId,
{}
)
if o and c.stateVersion==n then
c.statusDirty=false
end
end
task.wait(k)
continue
end

local n={}
local o=0
while c.upload.head<=c.upload.tail and#n<i do
local p=c.upload.queue[c.upload.head]
local q=if p and type(p.source)=="string"then#p.source else 0
if#n>0 and o+q>j then break end

local r=DequeueScriptSourceUpload()
if not r then continue end
local s=c.jobs[r.debugId]
local t=r.generation==c.generation and s~=nil
local u=t and(
(r.kind=="source"and s.state=="awaiting_upload")or
(r.kind=="remove"and s.state=="removed")
)
if u then
table.insert(n,r)
o+=q
end
end
if#n==0 then continue end

local p=c.stateVersion
local q=UploadScriptSourceBatch(c.clientId,n)
if q then
local r=0
for s,t in n do
if t.kind=="source"and t.generation==c.generation then
if h:MarkMapped(t.debugId,false)then
r+=1
end
end
end
c.statusDirty=
c.stateVersion~=p+r
else
local r=false
for s=#n,1,-1 do
local t=n[s]
if t.generation~=c.generation then
continue
end

t.attempts=(t.attempts or 0)+1
if t.kind=="source"and t.attempts>=l then
r=h:MarkFailed(
t.debugId,
"Source upload failed after "..tostring(t.attempts).." attempts.",
false
)or r
else
EnqueueScriptSourceUpload(t)
end
end
if r then h:Publish()end
local s=n[1]and n[1].attempts or 1
task.wait(math.min(2^math.max(0,s-1),m))
end

task.wait()
end
end)
end

return{
EnqueueScriptSourceUpload=EnqueueScriptSourceUpload,
IsScriptMappingTransportReady=IsScriptMappingTransportReady,
ResetScriptSourceUploadQueue=ResetScriptSourceUploadQueue,
StartUploadQueue=StartUploadQueue,
UploadQueueMaxBytes=33554432,
}
end end function a.r():typeof(__modImpl())local b=a.cache.r if not b then b={c=__modImpl()}a.cache.r=b end return b.c end end do local function __modImpl()

return function(b)
local c=b.ScriptMappingPipeline
local d=b.HttpService
local e=b.BridgeHTTPURL
local f=b.BridgeRequestHeaders
local g=b.Request
local h=b.StripDecompilerBanner
local i=b.base64_encode
local j=b.BuiltInDecompile
local k=b.GetScriptHash
local l=b.DecompilerAttemptState
local m=b.PreparedScript
local n=b.Concurrency
local o=256
local p=1024
local q=33554432
local r=2097152
local s=2
local t=3
local u=8
local v=65
local w={
providerId=nil,
expiresAt=0,
refreshToken=nil,
blockedBuiltinUntil=0,
}
local x={
startedAt=nil,
lastAt=nil,
samples=0,
lastReportAt=0,
revision=0,
}

local function RunWithTimeout(y,z)
local A=false
local B=false
local C

local D=task.spawn(function()
B,C=pcall(z)
A=true
end)

local E=os.clock()+y
while not A and os.clock()<E do
task.wait(0.05)
end

if not A then
pcall(task.cancel,D)
return false,"Timed out after "..tostring(y).."s."
end

if not B then
return false,C
end

return true,C
end

local function RememberScriptSourceForHash(y,z)
if type(y)~="string"or y==""or#y>512 then return false end
if type(z)~="string"or z==""then return false end

local A=c.sourceCacheByHash[y]
if A then
c.sourceCacheBytes=math.max(
0,
c.sourceCacheBytes-#A
)
else
c.sourceCacheEntries+=1
end

if#z>r then
c.sourceCacheByHash[y]=nil
c.sourceCacheSequenceByHash[y]=nil
c.sourceCacheEntries=math.max(
0,
c.sourceCacheEntries-1
)
c.sourceCacheCheckedByHash[y]=true
return false
end

c.sourceCacheSequence+=1
local B=c.sourceCacheSequence
c.sourceCacheByHash[y]=z
c.sourceCacheSequenceByHash[y]=B
c.sourceCacheBytes+=#z
c.sourceCacheOrderTail+=1
c.sourceCacheOrder[c.sourceCacheOrderTail]={
hash=y,
sequence=B,
}
c.sourceCacheCheckedByHash[y]=true

while(
c.sourceCacheEntries>p or
c.sourceCacheBytes>q
)do
local C=c.sourceCacheOrderHead
local D=c.sourceCacheOrder[C]
if not D then break end
c.sourceCacheOrder[C]=nil
c.sourceCacheOrderHead=C+1

if c.sourceCacheSequenceByHash[D.hash]==D.sequence then
local E=c.sourceCacheByHash[D.hash]
c.sourceCacheByHash[D.hash]=nil
c.sourceCacheSequenceByHash[D.hash]=nil
c.sourceCacheEntries=math.max(
0,
c.sourceCacheEntries-1
)
c.sourceCacheBytes=math.max(
0,
c.sourceCacheBytes-(type(E)=="string"and#E or 0)
)
end
end

if(
c.sourceCacheOrderTail-
c.sourceCacheOrderHead+1
)>p*4 then
local C={}
for D,E in c.sourceCacheSequenceByHash do
table.insert(C,{hash=D,sequence=E})
end
table.sort(C,function(D,E)return D.sequence<E.sequence end)
c.sourceCacheOrder=C
c.sourceCacheOrderHead=1
c.sourceCacheOrderTail=#C
end
return true
end

local function ReadScriptHash(y)
if type(k)~="function"then return nil end

local z,A=RunWithTimeout(s,function()
return k(y)
end)

if not z or type(A)~="string"or A==""then
return nil
end

return A
end

local function GetScriptHashForInstance(y)
local z=y:GetDebugId()
if c.scriptHashByDebugId[z]~=nil then
return c.scriptHashByDebugId[z]or nil
end

local A=ReadScriptHash(y)
c.scriptHashByDebugId[z]=A or false
return A
end

local function FetchCachedScriptSourceBatch(y,z)
if#z==0 then return true end

local A,B=pcall(g,{
Url=e.."/script-source-cache",
Method="POST",
Headers=f{
["Content-Type"]="application/json",Accept=
"application/json",
},
Body=d:JSONEncode{
clientId=y,
hashes=z,
},
})

if not A or type(B)~="table"or B.StatusCode~=200 or type(B.Body)~="string"then
return false
end

local C,D=pcall(function()
return d:JSONDecode(B.Body)
end)
if not C or type(D)~="table"or type(D.sources)~="table"then
return false
end

for E,F in ipairs(D.sources)do
if type(F)=="table"then
RememberScriptSourceForHash(F.scriptHash,F.source)
end
end

return true
end

local function FetchCachedScriptSources(y,z)
if type(g)~="function"then return end
if type(y)~="string"or y==""then return end
if type(z)~="table"then return end

local A={}
local B={}
local function flush()
local C=FetchCachedScriptSourceBatch(y,A)
if C then
for D,E in A do
c.sourceCacheCheckedByHash[E]=true
end
end
table.clear(A)
end

for C,D in ipairs(z)do
if(
type(D)=="string"and
D~=""and
not c.sourceCacheByHash[D]and
not c.sourceCacheCheckedByHash[D]and
not B[D]
)then
B[D]=true
table.insert(A,D)
if#A>=o then
flush()
end
end
end

flush()
end

local function ReadScriptBytecode(y)
local z,A=RunWithTimeout(t,function()
return getscriptbytecode(y)
end)
if not z or A==nil then
return false,A or"Failed to read script bytecode."
end
return true,A
end

local function TryBuiltInDecompile(y)
if type(j)~="function"then
return nil,0,"Executor built-in decompile is unavailable.",false
end

local z=os.clock()
local A,B=RunWithTimeout(u,function()
return j(y)
end)
local C=math.floor((os.clock()-z)*1000)
if not A then
local D=tostring(B or"Built-in decompile failed.")
return nil,C,D,string.find(D,"Timed out",1,true)~=nil
end
if type(B)~="string"or B==""then
return nil,C,"Built-in decompile returned no source.",false
end

return h(B),C
end

local function IsActiveMappingContext(y,z)
return(
y==c.generation and
z~=nil and
z==c.clientId
)
end

local function RefreshDecompilerPlan(y,z,A)
z=z or c.generation
A=A or c.clientId
if not IsActiveMappingContext(z,A)then return nil end
local B=os.clock()
if not y and w.expiresAt>B then
return w.providerId
end
if w.refreshToken then
local C=B+2
repeat task.wait()until not w.refreshToken or os.clock()>=C
return w.providerId
end
if type(g)~="function"then return nil end

local C={}
w.refreshToken=C

local D,E=RunWithTimeout(5,function()
return g{
Url=e.."/decompile-plan?clientId="..d:UrlEncode(A),
Method="GET",
Headers=f{Accept=
"application/json",
},
}
end)
if w.refreshToken~=C then return nil end
w.refreshToken=nil
if not IsActiveMappingContext(z,A)then return nil end
if not D or type(E)~="table"or E.StatusCode~=200 or type(E.Body)~="string"then
w.providerId=nil
w.expiresAt=B+0.25
return nil
end

local F,G=pcall(function()
return d:JSONDecode(E.Body)
end)
if not F or type(G)~="table"then
w.providerId=nil
w.expiresAt=B+0.25
return nil
end

w.providerId=if type(G.providerId)=="string"then G.providerId else nil
local H=math.max(0.25,math.min((tonumber(G.ttlMs)or 1000)/1000,5))
w.expiresAt=os.clock()+H
return w.providerId
end

local function ShouldUseDirectBuiltIn(y,z,A)
if y~="builtin"then return false end
if w.blockedBuiltinUntil>os.clock()then return false end
return type(j)=="function"and RefreshDecompilerPlan(false,z,A)=="builtin"
end

local function PostBuiltInObservation(y,z,A)
if not IsActiveMappingContext(z,A)then return end
local B=c.session
if not B then return end
x.revision+=1
y.clientId=A
y.providerId="builtin"
y.observationSessionId=B.id
y.observationSessionStartedAt=B.startedAt
y.observationRevision=x.revision
y.beginObservationSession=true
task.defer(function()
if not IsActiveMappingContext(z,A)then return end
pcall(g,{
Url=e.."/decompiler-observations",
Method="POST",
Headers=f{
["Content-Type"]="application/json",Accept=
"application/json",
},
Body=d:JSONEncode(y),
})
end)
end

local function ReportBuiltInDecompileSuccess(y,z,A)
if not IsActiveMappingContext(z,A)then return end
local B=os.clock()
if x.lastAt==nil or B-x.lastAt>2 then
x.startedAt=B
x.samples=0
end

x.lastAt=B
x.startedAt=x.startedAt or B
x.samples+=1
if B-x.startedAt<0.25 then return end
if B-x.lastReportAt<0.5 then return end
x.lastReportAt=B

local C=math.max(0.001,B-x.startedAt)
PostBuiltInObservation({
latencyMs=y,
successCount=x.samples,
throughputPerSecond=x.samples/C,
throughputWindowMs=C*1000,
throughputSamples=x.samples,
},z,A)
end

local function ReportBuiltInDecompileFailure(y,z,A,B,C)
if not IsActiveMappingContext(B,C)then return end
w.providerId=nil
w.expiresAt=0
w.blockedBuiltinUntil=os.clock()+5
if A==true then n:Reduce()end
PostBuiltInObservation({
latencyMs=z,
errorMessage=tostring(y or"Built-in decompile failed."),
timedOut=A==true,
},B,C)
end

local function RequestServerDecompile(y,z,A,B)
if type(g)~="function"then
return nil,"request function is unavailable"
end

z=if type(z)=="table"then z else{}
local C={
clientId=B,
bytecode=i(y),
builtinAvailable=type(j)=="function",
}
if type(z.builtinSource)=="string"then
C.builtinSource=z.builtinSource
end
if type(z.builtinLatencyMs)=="number"then
C.builtinLatencyMs=z.builtinLatencyMs
end
if type(z.requestedProvider)=="string"then
C.requestedProvider=z.requestedProvider
end
if type(z.disabledProviders)=="table"then
C.disabledProviders=z.disabledProviders
end

local D,E=RunWithTimeout(v,function()
return g{
Url=e.."/decompile",
Method="POST",
Headers=f{
["Content-Type"]="application/json",Accept=
"application/json",
},
Body=d:JSONEncode(C),
}
end)
if not D then
return nil,tostring(E)
end

if type(E)~="table"or type(E.Body)~="string"then
return nil,"Decompile server returned no response body."
end

local F,G=pcall(function()
return d:JSONDecode(E.Body)
end)
if not F or type(G)~="table"then
return nil,"Decompile server returned invalid JSON."
end

local H
if type(G.attemptedProviders)=="table"and type(G.attemptedProviders[1])=="string"then
H=G.attemptedProviders[1]
end

if G.ok==true and type(G.source)=="string"and G.source~=""then
return h(G.source),nil,false,H
end
if G.needsBuiltin==true and G.providerId=="builtin"then
return nil,nil,true,H
end

if type(G.error)=="string"and G.error~=""then
return nil,G.error,false,H
end
if type(G.attempts)=="table"then
return nil,table.concat(G.attempts,"\n\n"),false,H
end

return nil,"Decompile server failed without a detailed error.",false,H
end

local function PrepareScriptForMapping(y,z,A,B,C)
A=A or c.generation
B=B or c.clientId
local D=y:GetDebugId()
local E=GetScriptHashForInstance(y)
if z and E then
FetchCachedScriptSources(B,{E})
end

local F=E and c.sourceCacheByHash[E]or nil
if F then
return{
debugId=D,
scriptHash=E,
source=F,
}
end

local G=RefreshDecompilerPlan(false,A,B)
local H=C or G
local I=C=="builtin"
if I or ShouldUseDirectBuiltIn(H,A,B)then
return{
debugId=D,
scriptHash=E,
retryProviderId=C,
useDirectBuiltin=true,
forceDirectBuiltinRetry=I,
}
end

local J,K=ReadScriptBytecode(y)
if not J then
return nil,K
end

return{
debugId=D,
scriptHash=E,
bytecode=K,
retryProviderId=C,
}
end

local function BuildServerOptions(y,z)
local A={}
if type(y.retryProviderId)=="string"then
A.requestedProvider=y.retryProviderId
end
if type(z)=="table"then
for B,C in z do
A[B]=C
end
end
return if next(A)==nil then nil else A
end

local function TakeRetryServerOptions(y,z)
local A=BuildServerOptions(y,z)
y.retryProviderId=nil
return A
end

local function DecompileScriptSource(y,z,A,B)
A=A or c.generation
B=B or c.clientId
local C
if not z then
z,C=PrepareScriptForMapping(y,true,A,B)
end
if not z then
return nil,C or"Failed to prepare script for decompile.",nil,nil
end

if type(z.source)=="string"and z.source~=""then
return z.source,nil,z.scriptHash,z
end
if z.useDirectBuiltin==true then
local D=z.forceDirectBuiltinRetry==true or
l.CanAttemptBuiltIn(
z,
w.blockedBuiltinUntil,
os.clock()
)
if D then
z.retryProviderId=nil
z.forceDirectBuiltinRetry=nil
z.initialProviderId=z.initialProviderId or"builtin"
l.MarkBuiltInAttempted(z)
local E,F,G,H=TryBuiltInDecompile(y)
if E then
ReportBuiltInDecompileSuccess(F,A,B)
if z.scriptHash then
RememberScriptSourceForHash(z.scriptHash,E)
end
return E,nil,z.scriptHash,z
end

l.DisableBuiltIn(z)
ReportBuiltInDecompileFailure(G,F,H,A,B)
end
local E,F=m.MaterializeServerFallback(z,function()
return ReadScriptBytecode(y)
end)
if not E then
return nil,F,z.scriptHash,z
end
end

if type(z.bytecode)~="string"then
return nil,"Prepared script is missing bytecode.",z.scriptHash,z
end

local D=TakeRetryServerOptions(
z,
if z.builtinDisabled==true then{disabledProviders={"builtin"}}else nil
)
local E,F,G,H=RequestServerDecompile(
z.bytecode,
D,
A,
B
)
if not z.initialProviderId and type(H)=="string"then
z.initialProviderId=H
end
if G then
local I=l.CanAttemptBuiltIn(
z,
w.blockedBuiltinUntil,
os.clock()
)
if I then
l.MarkBuiltInAttempted(z)
local J,K,L,M=TryBuiltInDecompile(y)
if J then
ReportBuiltInDecompileSuccess(K,A,B)
E,F=RequestServerDecompile(z.bytecode,BuildServerOptions(z,{
requestedProvider="builtin",
builtinSource=J,
builtinLatencyMs=K,
}),A,B)
else
l.DisableBuiltIn(z)
ReportBuiltInDecompileFailure(L,K,M,A,B)
E,F=RequestServerDecompile(z.bytecode,BuildServerOptions(z,{
disabledProviders={"builtin"},
}),A,B)
end
else
l.DisableBuiltIn(z)
E,F=RequestServerDecompile(z.bytecode,BuildServerOptions(z,{
disabledProviders={"builtin"},
}),A,B)
end
end
if not E then
return nil,F,z.scriptHash,z
end

if z.scriptHash then
RememberScriptSourceForHash(z.scriptHash,E)
end
return E,nil,z.scriptHash,z
end

local function ResetDecompilerClient()
w.providerId=nil
w.expiresAt=0
w.refreshToken=nil
w.blockedBuiltinUntil=0
x.startedAt=nil
x.lastAt=nil
x.samples=0
x.lastReportAt=0
x.revision=0
end

return{
DecompileScriptSource=DecompileScriptSource,
FetchCachedScriptSources=FetchCachedScriptSources,
GetScriptHashForInstance=GetScriptHashForInstance,
PrepareScriptForMapping=PrepareScriptForMapping,
RefreshDecompilerPlan=RefreshDecompilerPlan,
ResetDecompilerClient=ResetDecompilerClient,
TakeRetryServerOptions=TakeRetryServerOptions,
}
end end function a.s():typeof(__modImpl())local b=a.cache.s if not b then b={c=__modImpl()}a.cache.s=b end return b.c end end do local function __modImpl()

return function(b)
local c=b.ScriptMappingPipeline
local d=b.WorkerPool
local e=b.UploadSession
local f=b.GenerateSessionGuid
local g=b.CoreGui
local h=b.CorePackages
local i=b.ScriptContext
local j=b.getnilinstances
local k=b.WorkerCount
local l=b.Concurrency
local m=b.JobStatus
local n=b.FailedResync
local o=b.UploadClient
local p=b.DecompilerClient
local q=o.EnqueueScriptSourceUpload
local r=o.IsScriptMappingTransportReady
local s=o.ResetScriptSourceUploadQueue
local t=p.DecompileScriptSource
local u=p.FetchCachedScriptSources
local v=p.GetScriptHashForInstance
local w=p.PrepareScriptForMapping
local x=p.RefreshDecompilerPlan
local y=p.ResetDecompilerClient
local z=4
local A=8
local B=256
local C=2097152
local D

local function PublishCurrentMappingStatus()
m:Publish()
end

local function RemoveScriptFromMapping(E,F)
local G=c.jobs[E]
if F~=c.generation or not G or G.state=="removed"then return end

c.instances[E]=nil
c:SetJobState(G,"removed")
G.script=nil
G.prepared=nil
q{
kind="remove",
debugId=E,
generation=F,
attempts=0,
}
end

local function AttachScriptToMappingJob(E,F)
E.script=F
c.instances[E.debugId]=F
if E.destroyingConnection then return end
local G=E.generation
E.destroyingConnection=F.Destroying:Once(function()
RemoveScriptFromMapping(E.debugId,G)
end)
end

local function TrackScriptForMapping(E,F)
if(
F and
not c.jobs[E]and
c.total>=c.scanLimit
)then
c:MarkScanOmitted()
return false
end
return c:TrackJob(E)~=nil
end

local function DeferScriptMappingUntilTransport(E,F,G,H)
local I=H or E:GetDebugId()
local J=c.jobs[I]
if G~=c.generation or not J then return end
if J.state=="mapped"or J.state=="failed"or J.state=="removed"then return end

c:SetJobState(J,"deferred")
AttachScriptToMappingJob(J,E)
J.prepared=F
end

local function RetryScriptMapping(E,F,G,H,I)
local J=I or E:GetDebugId()
local K=c.jobs[J]
if G~=c.generation or not K then return end
if K.state=="mapped"or K.state=="failed"or K.state=="removed"then return end
if string.find(tostring(H),"Timed out",1,true)then
l:Reduce()
end

K.mappingAttempts=(K.mappingAttempts or 0)+1
if K.mappingAttempts>=z then
m:MarkFailed(J,H or"Failed to prepare or decompile script source.")
return
end

c:SetJobState(K,"queued")
AttachScriptToMappingJob(K,E)
K.prepared=F
local L=math.min(2^math.max(0,K.mappingAttempts-1),A)
task.delay(L,function()
if G~=c.generation or K.generation~=G then return end
if K.state~="queued"then return end
if not r(c.clientId)then
DeferScriptMappingUntilTransport(E,F,G,J)
return
end

c.workers:QueueOperation(E,F,G,J)
end)
end

local function QueueMappedScriptSource(E,F,G,H,I)
local J=I or E:GetDebugId()
local K=c.jobs[J]
if not K then
TrackScriptForMapping(J)
K=c.jobs[J]
elseif K.state=="failed"then
TrackScriptForMapping(J)
elseif K.state=="mapped"or K.state=="awaiting_upload"or K.state=="removed"then
return false
end

local L=E:GetFullName()
AttachScriptToMappingJob(K,E)

if type(F)~="string"or#F>C then
m:MarkFailed(
J,
"Decompiled source exceeded the 2 MiB connector mapping limit."
)
return false
end
local M=tonumber(K.sourceBytes)or 0
local N=c.mappedSourceBytes-M+#F
if N>c.sourceBudgetBytes then
c:MarkScanOmitted()
m:MarkFailed(
J,
"Connector source budget reached; narrow the index or start a fresh resync."
)
return false
end

while c.upload.bytes+#F>o.UploadQueueMaxBytes do
if H~=c.generation then return false end
if not r(c.clientId)then
RetryScriptMapping(E,nil,H,"Source upload transport became unavailable.",J)
return false
end
task.wait(0.05)
end

c:SetJobState(K,"awaiting_upload")
K.sourceBytes=#F
c.mappedSourceBytes=N
q{
kind="source",
debugId=J,
path=L,
source=F,
scriptHash=G,
attempts=0,
generation=H,
}
return true
end

local function MapScriptSource(E,F,G,H)
if G~=c.generation then return end

local I=H or E:GetDebugId()
local J=c.jobs[I]
if not J or J.state~="queued"then return end
if not r(c.clientId)then
DeferScriptMappingUntilTransport(E,F,G,I)
return
end
if not c:TryStartMapping(J)then return end

if(
c.mappedSourceBytes>=c.sourceBudgetBytes and
not J.sourceBytes
)then
c:MarkScanOmitted()
m:MarkFailed(
I,
"Connector source budget reached; remaining scripts were not decompiled."
)
return
end

while c.upload.bytes>=o.UploadQueueMaxBytes do
if G~=c.generation then return end
if not r(c.clientId)then
DeferScriptMappingUntilTransport(E,F,G,I)
return
end
task.wait(0.05)
end

AttachScriptToMappingJob(J,E)
local K=c.clientId
if not F then
local L
F,L=w(
E,
true,
G,
K,
J.initialProviderId
)
if not F then
RetryScriptMapping(E,nil,G,L,I)
return
end
end
J.prepared=F
local L,M,N,O=t(
E,
F,
G,
K
)
J.prepared=O
if not J.initialProviderId and O then
J.initialProviderId=O.initialProviderId
end
if not L then
RetryScriptMapping(E,O,G,M,I)
return
end
if G~=c.generation then return end
if c.jobs[I]~=J then return end
if J.state=="mapped"or J.state=="failed"or J.state=="removed"then return end
J.mappingAttempts=0
l:RecordSuccess()

QueueMappedScriptSource(E,L,N,G,I)
end

D=function(E,F,G,H,I)
if H~=c.generation or type(I)~="string"then return end
RetryScriptMapping(F,G,H,tostring(E),I)
end

c.workers=d.new{
MaxConcurrent=k,
MainCallback=MapScriptSource,
OnError=D,
}

local function GetScriptByDebugId(E)
local F=c.instances[E]
if F then
return F
end

local G=0
local H={game}
while#H>0 and G<c.scanNodeLimit do
local I=#H
local J=H[I]
H[I]=nil
G+=1

if J:IsA"LuaSourceContainer"then
local K=J.ClassName~="Script"or J.RunContext==Enum.RunContext.Client
local L,M=pcall(function()return J:GetDebugId()end)
if K and L and M==E then
c.instances[E]=J
return J
end
end

local K,L=pcall(function()return J:GetChildren()end)
if K then
local M=c.scanNodeLimit-G-#H
for N=#L,math.max(1,#L-M+1),-1 do
table.insert(H,L[N])
end
end
if G%500==0 then task.wait()end
end

local I,J=pcall(j)
if I then
for K,L in J do
if K>c.scanNodeLimit then break end
if not L:IsA"LuaSourceContainer"then continue end
if L.ClassName=="Script"and L.RunContext~=Enum.RunContext.Client then continue end
local M,N=pcall(function()return L:GetDebugId()end)
if not M or N~=E then continue end

c.instances[E]=L
return L
end
end

return nil
end

local function RetryFailedScripts()
if not r(c.clientId)then return end

n:ProcessDue(function(E)
local F=GetScriptByDebugId(E.debugId)
if not F then
n:Defer(E)
return
end
if not n:Claim(E)then return end

AttachScriptToMappingJob(E,F)
c.workers:QueueOperation(
F,
nil,
E.generation,
E.debugId
)
end,function(E,F)
if E.state=="failed"then
n:Defer(E)
else
m:MarkFailed(
E.debugId,
"Failed to run periodic resync: "..tostring(F)
)
end
end)
end

local function StartFailedScriptResync()
n:Start(RetryFailedScripts)
end

local function IsCandidateScriptForMapping(E)
local F=(
E.ClassName=="Script"and(
E.RunContext==Enum.RunContext.Server or
E.RunContext==Enum.RunContext.Legacy
)
)
if F then return false end

local G=(
E.RobloxLocked or
E:IsDescendantOf(g)or
E:IsDescendantOf(h)or
E:IsDescendantOf(i)
)
if G then return false end

local H=E:GetDebugId()
if c.jobs[H]then return false end

return true
end

local function QueueScriptForMapping(E,F)
local G=E:GetDebugId()
if not TrackScriptForMapping(G,true)then return end
AttachScriptToMappingJob(c.jobs[G],E)

m:Publish()
local H=c.generation
if r(c.clientId)then
c.workers:QueueOperation(E,F,H,G)
else
DeferScriptMappingUntilTransport(E,F,H,G)
end
end

local function ResumeDeferredScriptMappings()
if not r(c.clientId)then return end

for E,F in c.jobs do
if F.generation==c.generation and F.state=="deferred"then
c:SetJobState(F,"queued")
c.workers:QueueOperation(F.script,F.prepared,F.generation,E)
end
end
end

local function StartScriptMapping(E)
if c.disabled or not r(E)then return end

c.clientId=E
local F=c.generation
x(true,F,E)

if not c.descendantConnection then
c.descendantConnection=game.DescendantAdded:Connect(function(G)
if(
F~=c.generation or
c.disabled or
c.clientId~=E
)then
return
end
if not G:IsA"LuaSourceContainer"then
return
end

if not IsCandidateScriptForMapping(G)then return end
QueueScriptForMapping(G)
end)
end

if c.initialScanRunning or c.initialScanFinished then return end
c.initialScanRunning=true


task.spawn(function()
local G={}
local H=false local
I=pcall(function()
local I={}
local J=0

local function considerScript(K)
local L,M=pcall(function()
if not K:IsA"LuaSourceContainer"then return nil end
if not IsCandidateScriptForMapping(K)then return nil end
return K:GetDebugId()
end)
if not L or not M or I[M]then return true end
if c.total>=c.scanLimit then
c:MarkScanOmitted()
return false
end
I[M]=true
if not TrackScriptForMapping(M,true)then return true end
AttachScriptToMappingJob(c.jobs[M],K)
table.insert(G,{script=K,debugId=M})
return true
end




local function scanTree(K)
local L={K}
while#L>0 do
if(
F~=c.generation or
c.disabled
)then
return false
end
J+=1
if J>c.scanNodeLimit then
c:MarkScanOmitted()
return true
end

local M=#L
local N=L[M]
L[M]=nil
if not considerScript(N)then return true end

local O,P=pcall(function()return N:GetChildren()end)
if O then
for Q=#P,1,-1 do
table.insert(L,P[Q])
end
end
if J%500==0 then task.wait()end
end
return true
end

local function scanCategory(K)
for L,M in K do
if(
F~=c.generation or
c.disabled
)then
return false
end
J+=1
if J>c.scanNodeLimit then
c:MarkScanOmitted()
return true
end
if not considerScript(M)then return true end
if J%500==0 then task.wait()end
end
return true
end

if not scanTree(game)then return end
if(
not c.scanTruncated and
c.total<c.scanLimit
)then
if not scanCategory(j())then return end
end

m:Publish()

local K={}
local L={}
local function flushPreparedScripts()
u(E,K)
for M,N in L do
if F~=c.generation then return end
if r(E)then
c.workers:QueueOperation(N.script,nil,F,N.debugId)
else
DeferScriptMappingUntilTransport(N.script,nil,F,N.debugId)
end
end
table.clear(K)
table.clear(L)
end

for M,N in G do
if F~=c.generation then return end
local O=v(N.script)
if O then table.insert(K,O)end
table.insert(L,N)

if#L>=B then
flushPreparedScripts()
end
if M%250==0 then task.wait()end
end
flushPreparedScripts()

H=true
end)

if F~=c.generation then return end
c.initialScanRunning=false
if I and H then
c.initialScanFinished=true
c.stateVersion+=1
PublishCurrentMappingStatus()
return
end

for J,K in G do
local L=c.jobs[K.debugId]
if c:CanDeferScanJob(L,F)then
local M,N=pcall(
DeferScriptMappingUntilTransport,
K.script,
L.prepared,
F,
K.debugId
)
if not M then
local O,P=pcall(
RetryScriptMapping,
K.script,
L.prepared,
F,
tostring(N),
K.debugId
)
if not O then
m:MarkFailed(
K.debugId,
"Scan recovery failed: "..tostring(P),
false
)
end
end
end
end
task.delay(1,function()
if(
F~=c.generation or
c.disabled or
c.clientId~=E
)then
return
end
ResumeDeferredScriptMappings()
StartScriptMapping(E)
end)
end)
end

local function ResetScriptMappingState(E)
local F=c.descendantConnection
local G=c.generation+1
local H=e.new(
f(),
DateTime.now().UnixTimestampMillis,
G
)
c:Reset(E,H)
y()

if F then
F:Disconnect()
c.descendantConnection=nil
end

if c.workers then
c.workers:SetMaxConcurrent(c.currentWorkers)
c.workers:Reset()
end

s()
end

return{
DecompileScriptSource=t,
GetScriptByDebugId=GetScriptByDebugId,
QueueMappedScriptSource=QueueMappedScriptSource,
ResetScriptMappingState=ResetScriptMappingState,
ResumeDeferredScriptMappings=ResumeDeferredScriptMappings,
StartFailedScriptResync=StartFailedScriptResync,
StartScriptMapping=StartScriptMapping,
}
end end function a.t():typeof(__modImpl())local b=a.cache.t if not b then b={c=__modImpl()}a.cache.t=b end return b.c end end do local function __modImpl()

return function(b,c)
local d=b.LogService

c:BindToType("execute",function(e)
setthreadidentity(8)
local f,g=loadstring(e.source)
assert(f,"Failed to compile execution source: "..tostring(g))
f()

return{
status="completed",
operationId=e.operationId or e.id,
message="The top-level Luau chunk completed successfully.",
}
end)

c:BindToTypeRaw("get-console-output",function(e)
local f=math.max(1,math.min(tonumber(e.limit)or 20,200))
local g=e.logsOrder or"NewestFirst"
local h=e.filter
local i=typeof(h)=="string"and h~=""
local j=e.summaryOnly==true

local k=d:GetLogHistory()
local l={}
local m=0
local n={}
local o=0
local p=false
local q=5000

local function matchesFilter(r)
if not i then return true end
return string.find(r.message,h,1,true)~=nil
end

local r=500
local function utf8Prefix(s,t)
local u={}
local v=0
local w=pcall(function()
for w,x in utf8.codes(s)do
local y=utf8.char(x)
if v+#y>t then break end
table.insert(u,y)
v+=#y
end
end)
return w and table.concat(u)or string.sub(string.gsub(s,"[^%g ]","?"),1,t)
end
local function formatLogMessage(s)
local t=tostring(s or"")
if#t>r then
t=utf8Prefix(t,r)
.."…(+"..(#t-r).." chars omitted)"
end
return t
end

if g=="NewestFirst"then
for s=#k,1,-1 do
if o>=q then p=true break end
o+=1
local t=k[s]
if not matchesFilter(t)then continue end

m+=1
local u=t.messageType and t.messageType.Name or"Unknown"
n[u]=(n[u]or 0)+1
if#l<f then
table.insert(l,t)
end
end
else
for s,t in k do
if o>=q then p=true break end
o+=1
if not matchesFilter(t)then continue end

m+=1
local u=t.messageType and t.messageType.Name or"Unknown"
n[u]=(n[u]or 0)+1
if#l<f then
table.insert(l,t)
end
end
end

local s={}
if j then
table.insert(s,string.format("Matched %d logs.",m))
if p then table.insert(s,"Log scan capped at 5000 entries.")end
for t,u in n do
table.insert(s,string.format("%s: %d",t,u))
end
return table.concat(s,"\n")
end

table.insert(s,string.format("Displaying %d/%d logs:",#l,m))
if p then table.insert(s,"Log scan capped at 5000 entries.")end

for t,u in l do
local v=u.messageType and u.messageType.Name or"Unknown"
table.insert(s,string.format(
"[%s t=%s] %s",
v,tostring(u.timestamp),
formatLogMessage(u.message)
))
end

return table.concat(s,"\n")
end)

c:BindToType("get-data-by-code",function(e)
setthreadidentity(8)
local f=table.pack(loadstring(e.source)())

return f
end)
end end function a.u():typeof(__modImpl())local b=a.cache.u if not b then b={c=__modImpl()}a.cache.u=b end return b.c end end do local function __modImpl()

local b=a.d()

return function(c,d)
local e=c.ScriptMappingPipeline
local f=c.GetScriptByDebugId
local g=c.DecompileScriptSource
local h=c.QueueMappedScriptSource

d:BindToTypeRaw("get-script-content",function(i)
local j
local k


if i.debugId then
k=f(i.debugId)
assert(k,"No live script instance found for ScriptProxy with DebugId: "..tostring(i.debugId))
elseif i.target then
k=b.Resolve(i.target)
else
error"Provide a strict instance target or script debugId."
end

assert(typeof(k)=="Instance","Script instance is not an instance.")
assert(k:IsA"LuaSourceContainer","Script instance is not a LuaSourceContainer (Script, LocalScript, or ModuleScript).")
assert(not(
k.ClassName=="Script"and
k.RunContext~=Enum.RunContext.Client
),"Script instance is a server-only Script.")

local l
j,_,l=g(
k,
nil,
e.generation,
e.clientId
)
assert(j,"Failed to decompile script.")
assert(#j<=2097152,"Decompiled source exceeds the 2 MiB read limit.")

local m=k:GetDebugId()
local n=e.jobs[m]
if e.clientId and(not n or n.state~="mapped")then
h(
k,
j,
l,
e.generation,
m
)
end


local o=1
local p=1
while true do
local q=j:find("\n",p,true)
if not q then break end
o+=1
p=q+1
end
local q=math.max(1,math.min(tonumber(i.maxLines)or 200,2000))
local r=i.startLine and math.max(1,math.min(i.startLine,o))or 1
local s=i.endLine and math.max(r,math.min(i.endLine,o))or o
local t=math.min(s,r+q-1)

local u={}
local v=1
local w=1
while v<=t do
local x=j:find("\n",w,true)
local y=x and x-1 or#j
if v>=r then
table.insert(u,j:sub(w,y))
end
if not x then break end
w=x+1
v+=1
end

local x=""
if t<s then
x="\n-- Output truncated to "..q.." lines. Rerun with startLine="..(t+1).." or a tighter range to continue."
end

return"-- Lines "..r.."-"..t.." of "..o.."\n"..table.concat(u,"\n")..x
end)
end end function a.v():typeof(__modImpl())local b=a.cache.v if not b then b={c=__modImpl()}a.cache.v=b end return b.c end end do local function __modImpl()

local b=a.d()
local c=false
local d=1000

return function(e,f)
local g=e.MarketplaceService

f:BindToType("search-instances",function(h)
assert(not c,"Another instance selector search is already running; retry shortly.")
c=true

local i,j=pcall(function()
local i=b.Resolve{path=h.root}
local j=i:QueryDescendants(h.selector)
assert(
#j<=d,
"Selector matched over "..d.." instances; narrow the selector/root."
)

local k=math.max(1,math.min(tonumber(h.limit)or 20,100))
local l={}

for m,n in j do
if m>k then break end

table.insert(l,b.Describe(n))
end

return{
count=#j,
limited=#j>k,
results=l
}
end)

c=false
if not i then error(j,0)end
return j
end)

f:BindToType("get-game-info",function(h)
local i={
PlaceId=game.PlaceId,
GameId=game.GameId,
PlaceVersion=game.PlaceVersion,
JobId=game.JobId,
PlaceName="Unknown",
ServerType="Unknown",
}
local j={}

local k,l=pcall(function()
return g:GetProductInfo(game.PlaceId)
end)
if k and type(l)=="table"then
i.PlaceName=l.Name or i.PlaceName
if type(l.Creator)=="table"then
i.Creator=l.Creator.Name
i.CreatorType=tostring(l.Creator.CreatorType)
i.CreatorId=l.Creator.CreatorTargetId
end
if h.includeDescription==true then
i.PlaceDescription=l.Description
end
else
table.insert(j,"Marketplace metadata unavailable: "..string.sub(tostring(l),1,300))
end




local m=tostring(game.PrivateServerId or"")
local n=tonumber(game.PrivateServerOwnerId)or 0
if m==""then
i.ServerType="Public"
elseif n>0 then
i.ServerType="Private"
else
i.ServerType="Reserved"
end
i.PrivateServerId=m~=""and m or nil
i.PrivateServerOwnerId=n>0 and n or nil

if#j>0 then i.Warnings=j end

return i
end)

f:BindToType("get-descendants-tree",function(h)
local i=b.Resolve{path=h.root}
assert(typeof(i)=="Instance","Root path did not resolve to a valid Instance.")

local j=math.max(0,math.min(tonumber(h.maxDepth)or 2,5))
local k=math.max(1,math.min(tonumber(h.maxChildren)or 20,30))
local l=h.classFilter or""
local m=l~=""
local n=h.summaryOnly==true
local o=300
local p=o
local q=false
local r=0
local s=false
local t=os.clock()+0.02
local function visit()
if r>=5000 or os.clock()>=t then
s=true
return false
end
r+=1
return true
end

if n then
local u={}
local v=0
local w=0
local x=false
local y=5000

local function walk(z,A)
if A>j or x then
return
end

for B,C in z:GetChildren()do
if v>=y or not visit()then
x=true
return
end
v+=1
if not m or C:IsA(l)then
w+=1
u[C.ClassName]=(u[C.ClassName]or 0)+1
end
if A<j then
walk(C,A+1)
if x then return end
end
end
end

walk(i,1)

return{
Root={
Name=i.Name,
ClassName=i.ClassName,
ChildCount=#i:GetChildren(),
},
MaxDepth=j,
ClassFilter=if m then l else nil,
VisitedDescendants=v,
MatchedDescendants=w,
ClassCounts=u,
TraversalLimited=x,
TraversalLimit=y,
ContinuationHint=x and"Use dex-query for resumable, budgeted traversal."or nil,
}
end

local function buildTree(u,v)
if v>j then
return nil
end

local w=u:GetChildren()
local x={}
local y=0
local z=#w

if v>=j then
return{Name=u.Name,ClassName=u.ClassName,ChildCount=z,Children={},DepthLimited=z>0}
end

for A,B in w do
if y>=k then break end
if not visit()then break end
if p<=0 then
q=true
break
end

if m and not B:IsA(l)then


if v<j then
local C=buildTree(B,v+1)
if C and C.Children and#C.Children>0 then
table.insert(x,C)
y+=1
end
end
continue
end

p-=1

local C={
Name=B.Name,
ClassName=B.ClassName,
ChildCount=#B:GetChildren()
}

if v<j and C.ChildCount>0 then
local D=buildTree(B,v+1)
if D then
C.Children=D.Children
end
end

table.insert(x,C)
y+=1
end

return{
Name=u.Name,
ClassName=u.ClassName,
ChildCount=z,
TruncatedAt=if y<z then y else nil,
Children=x
}
end

local u=buildTree(i,0)
if typeof(u)=="table"then
u.VisitedDescendants=r
u.TraversalLimited=s
end
if q and typeof(u)=="table"then
u.Note="Output capped at "..o.." nodes. Use dex-query to continue a bounded scan."
elseif s and typeof(u)=="table"then
u.Note="Traversal work/time budget reached, including unmatched nodes. Use dex-query for continuation."
end
return u
end)
end end function a.w():typeof(__modImpl())local b=a.cache.w if not b then b={c=__modImpl()}a.cache.w=b end return b.c end end do local function __modImpl()

local b={}

local c=128
local d=25
local e=20
local f=100
local g=3
local h=1000
local i=8192
local j=512
local k=20000

local function TruncateUtf8(l,m)
if#l<=m then return l end
if m<=0 then return""end
local n="...(truncated)"
if m<=#n then return string.sub(n,1,m)end
local o=m-#n
local p,q=pcall(utf8.offset,l,0,o+1)
if not p then return string.sub("<invalid UTF-8 string>",1,m)end
return string.sub(l,1,(q or(o+1))-1)..n
end

local function SnapshotValue(l,m,n,o)
if m.entries>=f then return"<snapshot entry limit>"end

local p=typeof(l)
if p=="nil"then return{Type="nil"}end
if p=="string"then
local q=math.max(0,i-m.stringBytes)
if q==0 then return"<snapshot string limit>"end
local r=TruncateUtf8(l,math.min(h,q))
m.stringBytes+=#r
return r
end
if p=="boolean"or p=="number"or p=="Instance"then return l end
if p~="table"then return tostring(l)end
if n>=g then return"<snapshot depth limit>"end
if o[l]then return"<cycle>"end

o[l]=true
local q={}
for r,s in pairs(l)do
if m.entries>=f then break end
m.entries+=1
local t=typeof(r)
local u=r
if t=="string"then
u=SnapshotValue(r,m,n+1,o)
elseif t~="number"then
u=SnapshotValue(tostring(r),m,n+1,o)
end
q[u]=SnapshotValue(s,m,n+1,o)
end
o[l]=nil
return q
end

local function SnapshotArguments(...)
local l=select("#",...)
local m=math.min(l,e)
local n={}
local o={entries=0,stringBytes=0}
local p={}
for q=1,m do
n[q]=SnapshotValue(select(q,...),o,0,p)
end
return n,l,l>m
end

local function CountEntries(l)
local m=0
for n in pairs(l)do m+=1 end
return m
end

local function NewLog(l,m)
local n={
Method=l,
Calls={},
TotalCalls=0,
Ignored=false,
Blocked=false,
SupportsBlock=m,
}

function n.Block(o)
assert(o.SupportsBlock,"Incoming calls cannot be blocked by the bundled passive listener.")
o.Blocked=not o.Blocked
end

function n.Ignore(o)
o.Ignored=not o.Ignored
end

return n
end

function b.Start()
local l=getgenv()
local m=l.Cobalt
if m and m.shared and m.shared.Logs then
return m,false
end

local n={
Logs={
Outgoing=setmetatable({},{__mode="k"}),
Incoming=setmetatable({},{__mode="k"}),
},
connections=setmetatable({},{__mode="k"}),
connectionCount=0,
initialScanRunning=false,
initialScanTruncated=false,
capabilities={
outgoingNamecall=false,
incomingEventSignals=false,
incomingFunctions=false,
incomingBlocking=false,
},
}

local o={
__RobloxMcpInternal=true,
version=1,
shared={},
}

local function ClearLogs()
n.Logs={
Outgoing=setmetatable({},{__mode="k"}),
Incoming=setmetatable({},{__mode="k"}),
}
o.shared.Logs=n.Logs
end

local function GetOrCreateLog(p,q,r,s)
local t=n.Logs[p]
local u=t[q]
if u then return u end
if CountEntries(t)>=c then return nil end
u=NewLog(r,s)
t[q]=u
return u
end

local function Record(p,q,r,s,...)
local t=GetOrCreateLog(p,q,r,s)
if not t or t.Ignored then return t end

local u,v,w=SnapshotArguments(...)
local x=false
if type(checkcaller)=="function"then
local y,z=pcall(checkcaller)
x=y and z==true
end
table.insert(t.Calls,{
Arguments=u,
ArgumentCount=v,
ArgumentsTruncated=w or nil,
IsExecutor=x,
CapturedAt=os.clock(),
})
t.TotalCalls+=1
if#t.Calls>d then table.remove(t.Calls,1)end
return t
end

local function AttachIncoming(p)
if n.connections[p]or n.connectionCount>=j then return end

local q
local r
local s=p.ClassName
if s=="RemoteEvent"or s=="UnreliableRemoteEvent"then
q=p.OnClientEvent
r="OnClientEvent"
elseif s=="BindableEvent"then
q=p.Event
r="Event"
else
return
end

local t,u=pcall(function()
return q:Connect(function(...)
pcall(Record,"Incoming",p,r,false,...)
end)
end)
if t and u then
n.connections[p]=u
n.connectionCount+=1
end
end

local p={
FireServer=true,
InvokeServer=true,
Fire=true,
Invoke=true,
}

if type(hookmetamethod)=="function"and type(getnamecallmethod)=="function"then
local q
local function NamecallHook(r,...)
local s,t=pcall(getnamecallmethod)
if s and typeof(r)=="Instance"and p[t]then
local u,v=pcall(Record,"Outgoing",r,t,true,...)
if u and v and v.Blocked then return nil end
end
return q(r,...)
end
local r=NamecallHook
if type(newcclosure)=="function"then
local s,t=pcall(newcclosure,NamecallHook)
if s and type(t)=="function"then r=t end
end
local s,t=pcall(hookmetamethod,game,"__namecall",r)
if s and type(t)=="function"then
q=t
n.capabilities.outgoingNamecall=true
else
n.capabilities.outgoingError="hookmetamethod failed"
end
else
n.capabilities.outgoingError="executor lacks hookmetamethod/getnamecallmethod"
end

o.shared.Logs=n.Logs
o.shared.ClearLogs=ClearLogs
o.shared.McpInternal={
capabilities=n.capabilities,
limits={
remotesPerDirection=c,
callsPerRemote=d,
argumentsPerCall=e,
snapshotEntriesPerCall=f,
snapshotStringBytesPerCall=i,
incomingConnections=j,
initialScanNodes=k,
},
state=n,
}
l.Cobalt=o

local q,r=pcall(function()
return game.DescendantAdded:Connect(AttachIncoming)
end)
if q and r then
n.descendantConnection=r
n.capabilities.incomingEventSignals=true
else
n.capabilities.incomingError="could not observe new descendants"
end
n.initialScanRunning=true
task.spawn(function()
local s,t=pcall(function()
local s={game}
local t=1
local u=0
while t<=#s and u<k do
local v=s[t]
t+=1
u+=1
AttachIncoming(v)
local w,x=pcall(function()return v:GetChildren()end)
if w then
for y,z in ipairs(x)do
if#s>=k then
n.initialScanTruncated=true
break
end
table.insert(s,z)
end
end
if u%250==0 then task.wait()end
end
n.initialScanTruncated=n.initialScanTruncated or t<=#s
end)
if not s then
n.initialScanError=TruncateUtf8(tostring(t),500)
end
n.initialScanRunning=false
end)

return o,true
end

return b end function a.x():typeof(__modImpl())local b=a.cache.x if not b then b={c=__modImpl()}a.cache.x=b end return b.c end end do local function __modImpl()

local b=a.x()

return function(c,d)
d:BindToType("ensure-remote-spy",function(e)
local f,g=b.Start()
local h=f.__RobloxMcpInternal==true
local i=h and f.shared.McpInternal or nil
return{
status=g and"started"or"already_loaded",
provider=h and"bundled"or"external",
message=g
and"Bundled remote spy started."
or(h and"Bundled remote spy is already running."or"External Cobalt remote spy is already running."),
capabilities=i and i.capabilities or nil,
limits=i and i.limits or nil,
initialScan=i and{
running=i.state.initialScanRunning,
truncated=i.state.initialScanTruncated,
error=i.state.initialScanError,
incomingConnections=i.state.connectionCount,
}or nil,
}
end)

d:BindToType("get-remote-spy-logs",function(e)
local f=getgenv().Cobalt
assert(f and f.shared and f.shared.Logs,"Cobalt remote spy is not loaded. Call ensure-remote-spy first.")

local g=e.direction or"Both"
local h=e.remoteNameFilter or""
local i=math.max(1,math.min(tonumber(e.limit)or 10,100))
local j=math.max(0,math.min(tonumber(e.maxCallsPerRemote)or 2,20))
local k=e.summaryOnly==true
local l=h~=""

local function ProcessLogs(m,n)
local o={}

for p,q in m do
if typeof(p)~="Instance"then continue end
if#o>=i then break end

local r=""
local s=""
local t=""
local u=""
pcall(function()
r=p.Name
s=p.ClassName
t=p:GetFullName()
end)
pcall(function()u=p:GetDebugId()end)


if l and not string.find(string.lower(r),string.lower(h),1,true)then
continue
end


local v={}
local w=#q.Calls
local x=tonumber(q.TotalCalls)or w
local y=math.max(1,w-j+1)

if not k then
for z=y,w do
local A=q.Calls[z]
if not A then continue end

table.insert(v,{
Index=x-w+z,
Arguments=A.Arguments,
Origin=A.Origin,
IsExecutor=A.IsExecutor or false,
IsActor=A.IsActor or false,
Line=A.Line,
})
end
end

table.insert(o,{
RemoteName=r,
RemoteClass=s,
RemotePath=t,
RemoteDebugId=u,
Direction=n,
Method=q.Method,
TotalCalls=x,
RetainedCalls=w,
Ignored=q.Ignored,
Blocked=q.Blocked,
SupportsBlock=q.SupportsBlock~=false,
RecentCalls=if k then nil else v,
})
end

return o
end

local m={}

if g=="Outgoing"or g=="Both"then
local n=ProcessLogs(f.shared.Logs.Outgoing,"Outgoing")
for o,p in n do
table.insert(m,p)
end
end

if g=="Incoming"or g=="Both"then
local n=ProcessLogs(f.shared.Logs.Incoming,"Incoming")
for o,p in n do
table.insert(m,p)
end
end


table.sort(m,function(n,o)
return n.TotalCalls>o.TotalCalls
end)


if#m>i then
local n={}
for o=1,i do
n[o]=m[o]
end
m=n
end

return{
count=#m,
results=m
}
end)
end end function a.y():typeof(__modImpl())local b=a.cache.y if not b then b={c=__modImpl()}a.cache.y=b end return b.c end end do local function __modImpl()

return function(b,c)
local function GetRemoteIdentity(d)
local e={
name="",
path="",
debugId="",
}
pcall(function()
e.name=d.Name
e.path=d:GetFullName()
end)
pcall(function()e.debugId=d:GetDebugId()end)
return e
end

local function FindRemoteLog(d,e)
local f={}
for g,h in d do
if typeof(g)~="Instance"then continue end
local i=GetRemoteIdentity(g)
local j
if type(e.remoteDebugId)=="string"and e.remoteDebugId~=""then
j=i.debugId==e.remoteDebugId
elseif type(e.remotePath)=="string"and e.remotePath~=""then
j=i.path==e.remotePath
else
j=i.name==e.remoteName
end

if j then
table.insert(f,{instance=g,log=h,identity=i})
end
end

if#f==0 then
error("Remote not found in "..tostring(e.direction).." logs. Run remote-spy list again to refresh its identity.")
end
if#f>1 then
error("Remote selector is ambiguous ("..#f.." matches). Use remoteDebugId from remote-spy list.")
end
return f[1].log,f[1].identity
end

c:BindToType("clear-remote-spy-logs",function(d)
local e=getgenv().Cobalt
assert(e and e.shared and e.shared.ClearLogs,"Cobalt remote spy is not loaded. Call ensure-remote-spy first.")

e.shared.ClearLogs()

return{
status="cleared",
message="All remote spy logs have been cleared."
}
end)

c:BindToType("block-remote",function(d)
local e=getgenv().Cobalt
assert(e and e.shared and e.shared.Logs,"Cobalt remote spy is not loaded. Call ensure-remote-spy first.")

local f=d.direction
local g=d.shouldBlock

local h=e.shared.Logs[f]
assert(h,"Invalid direction: "..tostring(f))

local i,j=FindRemoteLog(h,d)
if g and not i.Blocked then
i:Block()
elseif not g and i.Blocked then
i:Block()
end

return{
status="success",
message=(g and"Blocked"or"Unblocked").." remote: "..j.path,
remoteName=j.name,
remotePath=j.path,
remoteDebugId=j.debugId,
blocked=i.Blocked
}
end)

c:BindToType("ignore-remote",function(d)
local e=getgenv().Cobalt
assert(e and e.shared and e.shared.Logs,"Cobalt remote spy is not loaded. Call ensure-remote-spy first.")

local f=d.direction
local g=d.shouldIgnore

local h=e.shared.Logs[f]
assert(h,"Invalid direction: "..tostring(f))

local i,j=FindRemoteLog(h,d)
if g and not i.Ignored then
i:Ignore()
elseif not g and i.Ignored then
i:Ignore()
end

return{
status="success",
message=(g and"Ignoring"or"Unignored").." remote: "..j.path,
remoteName=j.name,
remotePath=j.path,
remoteDebugId=j.debugId,
ignored=i.Ignored
}
end)




c:BindToType("remote-spy",function(d)
local e=d.operation
local f=c.Callbacks["ensure-remote-spy"]{}
if e=="status"then
local g=getgenv().Cobalt
local function CountLogs(h)
local i=0
if typeof(h)~="table"then return i end
for j in h do
i+=1
end
return i
end

return{
status="loaded",
loaded=true,
provider=f.provider,
capabilities=f.capabilities,
limits=f.limits,
initialScan=f.initialScan,
outgoingRemotes=CountLogs(g.shared and g.shared.Logs and g.shared.Logs.Outgoing),
incomingRemotes=CountLogs(g.shared and g.shared.Logs and g.shared.Logs.Incoming),
}
end

if e=="list"then
return c.Callbacks["get-remote-spy-logs"]{
direction=d.direction,
remoteNameFilter=d.nameFilter,
limit=d.limit,
maxCallsPerRemote=d.maxCallsPerRemote,
summaryOnly=d.summaryOnly,
}
elseif e=="clear"then
return c.Callbacks["clear-remote-spy-logs"]{}
elseif e=="block"or e=="unblock"then
return c.Callbacks["block-remote"]{
remoteName=d.remoteName,
remotePath=d.remotePath,
remoteDebugId=d.remoteDebugId,
direction=d.direction,
shouldBlock=e=="block",
}
elseif e=="ignore"or e=="unignore"then
return c.Callbacks["ignore-remote"]{
remoteName=d.remoteName,
remotePath=d.remotePath,
remoteDebugId=d.remoteDebugId,
direction=d.direction,
shouldIgnore=e=="ignore",
}
end

error("Invalid remote-spy operation: "..tostring(e))
end)
end end function a.z():typeof(__modImpl())local b=a.cache.z if not b then b={c=__modImpl()}a.cache.z=b end return b.c end end do local function __modImpl()

local b=a.d()

return function(c,d)
local e=c.VirtualInputManager

d:BindToType("type-text-box",function(f)
local g=f.path
local h=f.string or f.text
local i=f.enter
local j=f.useKeyPress

local k=b.Resolve{path=g}

assert(typeof(k)=="Instance","Path did not resolve to a valid Instance.")
assert(k:IsA"TextBox","Resolved Instance is not a TextBox.")

k:CaptureFocus()
task.wait(0.05)

if j then
local l=pcall(function()
for l=1,#h do
e:SendTextInput(h:sub(l,l),nil,game)
task.wait(0.01)
end
end)

if not l and type(keypress)=="function"then
for m=1,#h do
local n=h:sub(m,m):upper()
local o=n:byte()
if o then
keypress(o)
task.wait(0.01)
if type(keyrelease)=="function"then
keyrelease(o)
end
end
end
end
else
k.Text=h
end

if i then
if j then
if type(keypress)=="function"then
keypress(0x0D)
task.wait(0.01)
if type(keyrelease)=="function"then
keyrelease(0x0D)
end
else
pcall(function()
e:SendKeyEvent(true,Enum.KeyCode.Return,false,game)
task.wait(0.01)
e:SendKeyEvent(false,Enum.KeyCode.Return,false,game)
end)
end
end
k:ReleaseFocus(true)
else
k:ReleaseFocus(false)
end

return{
status="success",
message="Successfully typed into TextBox."
}
end)

d:BindToType("click-button",function(f)
local g=f.path
local h=f.Action or f.action

local i=b.Resolve{path=g}

assert(typeof(i)=="Instance","Path did not resolve to a valid Instance.")
assert(i:IsA"GuiButton","Resolved Instance is not a GuiButton (e.g., TextButton or ImageButton).")
assert(typeof(firesignal)=="function","Your executor does not support 'firesignal', which is required for this command.")

local j={"Activated","MouseButton1Down","MouseButton2Down","MouseButton1Click","MouseButton2Click"}

if h then
assert(table.find(j,h),"Invalid action provided. Valid actions are: "..table.concat(j,", "))
firesignal(i[h])
else
for k,l in pairs(j)do
pcall(function()firesignal(i[l])end)
end
end

return{
status="success",
message="Successfully fired click signals on Button."
}
end)
end end function a.A():typeof(__modImpl())local b=a.cache.A if not b then b={c=__modImpl()}a.cache.A=b end return b.c end end do local function __modImpl()

return function(b,c)
local d=b.ScriptMappingPipeline

local function CountJobStates()
local e={}
for f,g in d.jobs do
local h=g.state or"unknown"
e[h]=(e[h]or 0)+1
end
return e
end

local function PendingUploadCount()
return math.max(0,d.upload.tail-d.upload.head+1)
end

c:BindToTypeStructured("runtime-status",function(e)
local f
if d.workers then
f={
configured=d.configuredWorkers,
currentLimit=d.currentWorkers,
active=d.workers.ActiveWorkers,
queued=math.max(
0,
d.workers.QueueTail-d.workers.QueueHead+1
),
}
end

return{
clientId=c.ClientId,
transport=c.WebSocket and"ws"or"http",
connected=c.Connected==true,
place={
placeId=game.PlaceId,
gameId=game.GameId,
placeVersion=game.PlaceVersion,
jobId=game.JobId,
},
scriptIndex={
enabled=d.disabled~=true,
generation=d.generation,
initialScanRunning=d.initialScanRunning,
initialScanFinished=d.initialScanFinished,
scanLimit=d.scanLimit,
scanNodeLimit=d.scanNodeLimit,
scanTruncated=d.scanTruncated,
scanOmitted=d.scanOmitted,
scanOmittedIsLowerBound=d.scanTruncated,
total=d.total,
processed=d.processed,
skipped=d.skipped,
finished=d:IsFinished(),
jobStates=CountJobStates(),
uploadQueue={
items=PendingUploadCount(),
bytes=d.upload.bytes,
},
workers=f,
sourceCache={
entries=d.sourceCacheEntries,
bytes=d.sourceCacheBytes,
},
sourceBudget={
usedBytes=d.mappedSourceBytes,
limitBytes=d.sourceBudgetBytes,
},
},
capabilities={
request=b.RequestAvailable==true,
requestProvider=b.HttpRequestProvider,
websocket=b.WebSocketAvailable==true,
loadstring=type(loadstring)=="function",
setthreadidentity=type(setthreadidentity)=="function",
decompile=type(decompile)=="function",
getscriptbytecode=type(getscriptbytecode)=="function",
getscripthash=type(getscripthash)=="function",
filtergc=type(filtergc)=="function",
getgc=type(getgc)=="function",
getconstants=type(getconstants)=="function",
getupvalues=type(getupvalues)=="function",
getfunctionhash=type(getfunctionhash)=="function",
firesignal=type(firesignal)=="function",
fireproximityprompt=type(fireproximityprompt)=="function",
fireclickdetector=type(fireclickdetector)=="function",
firetouchinterest=type(firetouchinterest)=="function",
keypress=type(keypress)=="function",
keyrelease=type(keyrelease)=="function",
virtualInputManager=b.VirtualInputManager~=nil,
remoteSpyLoaded=getgenv().Cobalt~=nil,
remoteSpyProvider=getgenv().Cobalt and(
getgenv().Cobalt.__RobloxMcpInternal==true and"bundled"or"external"
)or"not_started",
},
}
end)
end end function a.B():typeof(__modImpl())local b=a.cache.B if not b then b={c=__modImpl()}a.cache.B=b end return b.c end end do local function __modImpl()

local b=a.d()

return function(c,d)
d:BindToTypeStructured("inspect-instance",function(e)
local f=b.Resolve(e.target)
local g=b.Describe(f)

if f.Parent then
g.Parent=b.Describe(f.Parent)
end

local h={}
local i={}
local j=type(e.properties)=="table"and e.properties or{}
local k=math.min(#j,40)
for l=1,k do
local m=j[l]
if type(m)~="string"or not string.match(m,"^[%a_][%w_]*$")then
table.insert(i,{
Property=tostring(m),
Error="Invalid property name.",
})
continue
end

local n,o=pcall(function()return f[m]end)
if n then
if typeof(o)=="Instance"then
h[m]=b.Describe(o)
else
h[m]=o
end
else
table.insert(i,{
Property=m,
Error=tostring(o),
})
end
end
if next(h)~=nil then g.Properties=h end
if#i>0 then g.PropertyErrors=i end

if e.includeAttributes~=false then
local l,m=pcall(function()return f:GetAttributes()end)
if l then g.Attributes=m end
end

if e.includeTags~=false then
local l,m=pcall(function()return f:GetTags()end)
if l then g.Tags=m end
end

if e.includeBounds~=false then
if f:IsA"BasePart"then
g.Bounds={
Kind="BasePart",
Position=f.Position,
Size=f.Size,
CFrame=f.CFrame,
}
elseif f:IsA"Model"then
local l,m,n=pcall(function()
return f:GetBoundingBox()
end)
if l then
g.Bounds={
Kind="Model",
Position=m.Position,
Size=n,
CFrame=m,
}
end
elseif f:IsA"GuiObject"then
g.Bounds={
Kind="GuiObject",
AbsolutePosition=f.AbsolutePosition,
AbsoluteSize=f.AbsoluteSize,
Visible=f.Visible,
ZIndex=f.ZIndex,
}
end
end

if e.includeChildren~=false then
local l=f:GetChildren()
local m=math.max(0,math.min(math.floor(tonumber(e.childLimit)or 20),100))
local n={}
for o=1,math.min(#l,m)do
local p=l[o]
local q=b.Describe(p)
q.ChildCount=#p:GetChildren()
table.insert(n,q)
end
g.ChildCount=#l
g.Children=n
g.ChildrenLimited=#l>m
end

return g
end)
end end function a.C():typeof(__modImpl())local b=a.cache.C if not b then b={c=__modImpl()}a.cache.C=b end return b.c end end do local function __modImpl()



local b={}
b.__index=b

local c={
maxDepth=1,
maxEntries=10,
maxStringBytes=256,
maxStringBytesPerValue=256,
expandTables=true,
}

local d={
{"BasePart",{"Position","Size","CFrame","Anchored","CanCollide","CanTouch","CanQuery","Transparency","Color","Material","CollisionGroup","AssemblyLinearVelocity","AssemblyAngularVelocity","Massless"}},
{"Model",{"PrimaryPart","WorldPivot","ModelStreamingMode"}},
{"Humanoid",{"Health","MaxHealth","WalkSpeed","JumpPower","JumpHeight","UseJumpPower","HipHeight","MoveDirection","FloorMaterial","RootPart","Sit","PlatformStand","AutoRotate","RigType"}},
{"ValueBase",{"Value"}},
{"GuiObject",{"Visible","Position","Size","AnchorPoint","AbsolutePosition","AbsoluteSize","AbsoluteRotation","ZIndex","LayoutOrder","ClipsDescendants","Active","Selectable","AutomaticSize","BackgroundColor3","BackgroundTransparency","BorderSizePixel","Rotation"}},
{"TextLabel",{"Text","TextSize","TextScaled","TextWrapped","TextColor3","TextTransparency","TextStrokeTransparency","FontFace","TextBounds","RichText","TextXAlignment","TextYAlignment"}},
{"TextButton",{"Text","TextSize","TextScaled","TextWrapped","TextColor3","TextTransparency","TextStrokeTransparency","FontFace","TextBounds","RichText","TextXAlignment","TextYAlignment","AutoButtonColor"}},
{"TextBox",{"Text","PlaceholderText","TextEditable","ClearTextOnFocus","MultiLine","TextSize","TextScaled","TextWrapped","TextColor3","TextStrokeTransparency","FontFace","TextBounds","RichText"}},
{"ImageLabel",{"Image","IsLoaded","ImageColor3","ImageTransparency","ImageRectOffset","ImageRectSize","ScaleType"}},
{"ImageButton",{"Image","IsLoaded","ImageColor3","ImageTransparency","ImageRectOffset","ImageRectSize","ScaleType","AutoButtonColor"}},
{"ScrollingFrame",{"CanvasPosition","CanvasSize","AbsoluteCanvasSize","AbsoluteWindowSize","AutomaticCanvasSize","ScrollingEnabled","ScrollingDirection","ScrollBarThickness"}},
{"LayerCollector",{"Enabled","ResetOnSpawn","ZIndexBehavior"}},
{"ScreenGui",{"DisplayOrder","IgnoreGuiInset","ScreenInsets","ClipToDeviceSafeArea"}},
{"BillboardGui",{"Adornee","AlwaysOnTop","Size","StudsOffset","MaxDistance"}},
{"SurfaceGui",{"Adornee","Face","CanvasSize","AlwaysOnTop","PixelsPerStud"}},
{"UIGridStyleLayout",{"AbsoluteContentSize","FillDirection","HorizontalAlignment","VerticalAlignment","SortOrder"}},
{"UIListLayout",{"Padding"}},
{"UIGridLayout",{"CellSize","CellPadding","FillDirectionMaxCells"}},
{"UIPadding",{"PaddingTop","PaddingBottom","PaddingLeft","PaddingRight"}},
{"UIScale",{"Scale"}},
{"UISizeConstraint",{"MinSize","MaxSize"}},
{"UIAspectRatioConstraint",{"AspectRatio","AspectType","DominantAxis"}},
{"BaseScript",{"Enabled","RunContext"}},
{"Sound",{"SoundId","IsLoaded","Playing","TimePosition","TimeLength","Volume","PlaybackSpeed","Looped","RollOffMaxDistance","RollOffMinDistance","SoundGroup"}},
{"Animation",{"AnimationId"}},
{"Decal",{"Texture","Transparency","Color3","Face"}},
{"Texture",{"StudsPerTileU","StudsPerTileV","OffsetStudsU","OffsetStudsV"}},
{"MeshPart",{"MeshId","TextureID","RenderFidelity","CollisionFidelity"}},
{"SpecialMesh",{"MeshId","TextureId","MeshType","Scale","Offset"}},
{"Attachment",{"Position","CFrame","WorldPosition","WorldCFrame"}},
{"Constraint",{"Enabled","Active","Attachment0","Attachment1","Visible"}},
{"JointInstance",{"Part0","Part1","C0","C1","Enabled","Active"}},
{"Camera",{"CFrame","Focus","CameraSubject","CameraType","FieldOfView","ViewportSize"}},
{"ProximityPrompt",{"Enabled","ActionText","ObjectText","HoldDuration","MaxActivationDistance","RequiresLineOfSight","KeyboardKeyCode","GamepadKeyCode"}},
{"ClickDetector",{"MaxActivationDistance","CursorIcon"}},
}

local function Clamp(e,f,g,h)
local i=tonumber(e)
if i==nil or i~=i then i=f end
return math.max(g,math.min(h,math.floor(i)))
end

local function Short(e,f)
local g,h=pcall(tostring,e)
if not g then return"<unprintable>"end
if#h<=f then return h end

local i=f-3
while i>0 do
local j=string.byte(h,i+1)
if j==nil or j<128 or j>=192 then break end
i-=1
end
return string.sub(h,1,i).."..."
end

local function ValidProperty(e)
return type(e)=="string"and#e<=100 and string.match(e,"^[%a_][%w_]*$")~=nil
end

local function Estimate(e,f,g)
f=f or 0
g=g or{}
if type(e)~="table"then
if type(e)=="string"then return#e*2+2,0 end
return 24,0
end
if f>10 or g[e]then return 16,1 end
g[e]=true
local h,i=2,0
for j,k in pairs(e)do
i+=1
if i>1000 then return 1000000,1001 end
local l,m=Estimate(k,f+1,g)
h+=#tostring(j)*2+l+5
i+=m
end
g[e]=nil
return h,i
end

function b.new(e)
assert(e and e.InstancePath and e.Handles and e.Values,"Dex inspection requires paths, handles, and typed values.")
return setmetatable({
Paths=e.InstancePath,
Handles=e.Handles,
Values=e.Values,
Measure=e.Measure,
Typeof=e.Typeof or typeof,
GetHiddenProperty=e.GetHiddenProperty or(type(gethiddenproperty)=="function"and gethiddenproperty or nil),
},b)
end

function b._size(e,f)
local g,h=Estimate(f)
if e.Measure then
local i,j=pcall(e.Measure,f)
if i and type(j)=="number"and j>=0 then return j,h end
end
return g,h
end

function b._budget(e,f,g)
return{chars=math.max(0,f-300),entries=math.max(0,g-20),limited=false}
end

function b._take(e,f,g)
local h,i=e:_size(g)
if h+2>f.chars or i+1>f.entries then
f.limited=true
return false
end
f.chars-=h+2
f.entries-=i+1
return true
end

function b._put(e,f,g,h,i)
if i==nil then return true end
if not e:_take(f,{[h]=i})then return false end
g[h]=i
return true
end

function b._isA(e,f,g)
local h,i=pcall(function()return f:IsA(g)end)
return h and i==true
end

function b.ReadProperty(e,f,g,h)
if not ValidProperty(g)then return false,nil,"Invalid property name."end
local i,j=pcall(function()return f[g]end)
if i then return true,j,"ordinary"end
if h==true then
if not e.GetHiddenProperty then
return false,nil,Short(j,180).."; hidden-property access is unavailable."
end
local k,l=pcall(e.GetHiddenProperty,f,g)
if k then return true,l,"hidden"end
return false,nil,Short(l,240)
end
return false,nil,Short(j,240)
end

function b.Resolve(e,f)
assert(type(f)=="table","An instance target is required.")
local g
if f.handle~=nil then
assert(f.path==nil and f.pathSegments==nil,"Provide a handle or path target, not both.")
g=e.Handles:Resolve(f.handle,"instance",false)
else
g=e.Paths.Resolve(f,true)
end
assert(e.Typeof(g)=="Instance","Target does not reference a Roblox Instance.")
return g
end

function b.Describe(e,f)
assert(e.Typeof(f)=="Instance","Describe expects a Roblox Instance.")
local g,h=pcall(e.Paths.Describe,f)
if not g or type(h)~="table"then h={}end
local i={PathDisplayOnly=true}
local j={Name=128,ClassName=100,Path=480,FullName=480,DebugId=128}
for k,l in pairs(j)do
local m=h[k]
if m==nil and(k=="Name"or k=="ClassName")then
local n,o=e:ReadProperty(f,k,false)
if n then m=o end
end
if m~=nil then
i[k]=Short(m,l)
if type(m)=="string"and#m>l then i.DisplayTruncated=true end
end
end
i.Name=i.Name or"<unavailable>"
i.ClassName=i.ClassName or"Instance"
i.Path=i.Path or"<unavailable>"
i.Handle=e.Handles:Register(f,"instance",{
className=i.ClassName,
path=i.Path,
},nil,false)
return i
end

local function HasOmission(e,f)
if type(e)~="table"then return false end
if e.type=="unsupported"or e.originalBytes~=nil or e.entriesOmitted~=nil or e.omitted~=nil or e.omission~=nil or e.truncated==true then return true end
if(f or 0)>=4 then return false end
local g=0
for h,i in pairs(e)do
g+=1
if g>100 then return true end
if HasOmission(i,(f or 0)+1)then return true end
end
return false
end

function b._encode(e,f)
if e.Typeof(f)=="Instance"then
local g=e:Describe(f)
return{
type="instance",
handle=g.Handle,
ref={
name=g.Name,
className=g.ClassName,
path=g.Path,
debugId=g.DebugId,
pathDisplayOnly=true,
},
},g.DisplayTruncated==true
end
if e.Typeof(f)=="Font"then
local g,h,i=pcall(function()
local g=tostring(f.Family)
return{
type="font",family=Short(g,256),
weight=f.Weight.Name,style=f.Style.Name,bold=f.Bold,
},#g>256
end)
if g then return h,i end
return{type="unsupported",error=Short(h,180)},true
end
local g,h=pcall(function()return e.Values:Encode(f,c)end)
if g then
local i=e.Typeof(f)
if i=="NumberSequence"or i=="ColorSequence"then
local j,k=pcall(function()return#f.Keypoints end)
if j and k>c.maxEntries then h.omitted="keypoint-limit"end
end
return h,HasOmission(h)
end
return{type="unsupported",error=Short(h,180)},true
end

function b._putValue(e,f,g,h,i)
local j,k=e:_encode(i)
if k then f.limited=true end
return e:_put(f,g,h,j)
end

function b._propertyNames(e,f,g,h)
local i,j={},{}
local function add(k)
if#i>=80 or j[k]then return end
j[k]=true
table.insert(i,k)
end
local k=type(g.properties)=="table"and g.properties or{}
for l=1,math.min(#k,80)do
if type(k[l])=="string"then add(k[l])end
end
if h=="auto"then
add"Archivable"
for l,m in d do
if e:_isA(f,m[1])then
for n,o in m[2]do add(o)end
end
end
end
return i
end

function b._projection(e,f,g,h,i)
local j=e:Describe(f)
if g.includeFullName~=true then j.FullName=nil end
if not e:_take(h,j)then
j={Handle=j.Handle,Name=j.Name,ClassName=j.ClassName,PathDisplayOnly=true}
e:_take(h,j)
end
local k=e:_propertyNames(f,g,i)
if#k>0 then
local l,m,n={},{},{}
local o,p=0,0
for q,r in k do
local s,t,u=e:ReadProperty(f,r,g.includeHidden==true)
if s then
if not e:_putValue(h,l,r,t)then o+=1 end
if u=="hidden"and#n<20 then table.insert(n,r)end
else
p+=1
if p<=10 then e:_put(h,m,Short(r,100),u)end
end
if h.chars<150 or h.entries<8 then
o+=#k-q
h.limited=true
break
end
end
if next(l)then j.Properties=l end
if next(m)then j.PropertyErrors=m end
if#n>0 then j.HiddenPropertiesRead=n end
if p>0 then j.PropertyErrorCount=p end
if o>0 then j.PropertiesOmitted=o end
if#(g.properties or{})>80 then j.RequestedPropertiesOmitted=#g.properties-80 end
end

if g.includeAttributes==true then
local l,m=pcall(function()return f:GetAttributes()end)
if l and type(m)=="table"then
local n,o,p={},0,0
local q=Clamp(g.attributeLimit,32,0,64)
for r,s in pairs(m)do
p+=1
if p>q then
j.AttributesLimited=true
break
end
if not e:_putValue(h,n,Short(r,100),s)then
j.AttributesLimited=true
break
end
o+=1
end
j.Attributes=n
j.AttributesReturned=o
else
e:_put(h,j,"AttributeError",Short(m,240))
end
end

if g.includeTags==true then
local l,m=pcall(function()return f:GetTags()end)
if l and type(m)=="table"then
local n,o={},{}
local p=Clamp(g.tagLimit,32,0,64)
for q=1,math.min(#m,p)do
table.insert(o,Short(m[q],100))
if type(m[q])=="string"and#m[q]>100 then j.TagsLimited=true end
end
table.sort(o)
for q,r in o do
if not e:_take(h,r)then break end
table.insert(n,r)
end
j.Tags=n
j.TagCount=#m
if#n<#m then j.TagsLimited=true end
else
e:_put(h,j,"TagError",Short(m,240))
end
end
j.Truncated=j.DisplayTruncated or h.limited or j.AttributesLimited or j.TagsLimited or nil
return j
end

function b.QueryRecord(e,f,g)
g=g or{}
local h=e:_budget(Clamp(g.maxChars,6000,800,20000),Clamp(g.maxEntries,240,30,800))
return e:_projection(f,g,h,"none")
end

function b._bounds(e,f)
if e:_isA(f,"BasePart")then
return{Kind="BasePart",Properties={"Position","Size","CFrame"}}
elseif e:_isA(f,"GuiObject")then
return{Kind="GuiObject",Properties={"AbsolutePosition","AbsoluteSize","Visible","ZIndex"}}
elseif e:_isA(f,"Model")then


return{Kind="Model",Properties={"WorldPivot","PrimaryPart"},Note="Model bounding-box calculation omitted to avoid an unbounded descendant scan."}
end
return nil
end

function b._ancestry(e,f,g,h,i)
local j=e:_isA(f,"GuiObject")or e:_isA(f,"LayerCollector")
local k=g.includeAncestors~=false
if not j and not k then return end
local l=Clamp(g.ancestorLimit,8,0,32)
local m,n={},{}
local o,p,q,r=f,0,false,false
local s=0

for t=1,64 do
p+=1
if j then
if e:_isA(o,"GuiObject")then
local u,v=e:ReadProperty(o,"Visible",false)
if u and v==false then q=true end
local w,x=e:ReadProperty(o,"ClipsDescendants",false)
if o~=f and w and x==true and#n<4 then
local y=e:Describe(o)
local z={Handle=y.Handle,Name=y.Name}
for A,B in{"AbsolutePosition","AbsoluteSize"}do
local C,D=e:ReadProperty(o,B,false)
if C then z[B]=e:_encode(D)end
end
if e:_take(i,z)then table.insert(n,z)end
end
elseif e:_isA(o,"LayerCollector")then
local u,v=e:ReadProperty(o,"Enabled",false)
if u and v==false then q=true end
end
end
local u,v=e:ReadProperty(o,"Parent",false)
if not u then break end
if v==nil then r=true break end
if e.Typeof(v)~="Instance"then break end
s+=1
if k and#m<l then
local w=e:Describe(v)
w.FullName=nil
if e:_take(i,w)then table.insert(m,w)end
end
o=v
if not j and s>=l then break end
end
if k then
h.Ancestors=m
h.AncestorsLimited=not r or s>#m
end
if j then
h.Visibility={
EffectiveVisible=if q then false elseif r then true else nil,
AncestorsChecked=p,
Limited=not r,
Basis="Local Visible/Enabled ancestry only; not occlusion, transparency, viewport intersection, or screenshot visibility.",
}
if#n>0 then h.Visibility.ClippingAncestors=n end
end
end

function b._inspectOne(e,f,g,h,i)
local j=e:_budget(h,i)
local k=table.clone(g)
k.includeAttributes=g.includeAttributes~=false
k.includeTags=g.includeTags~=false
local l=g.profile=="none"and"none"or"auto"
local m=e:_projection(f,k,j,l)
m.Profile=l
if g.includeHidden==true then m.HiddenPropertySupported=e.GetHiddenProperty~=nil end

if g.includeBounds~=false then
local n=e:_bounds(f)
if n then
local o={Kind=n.Kind,Note=n.Note}
for p,q in n.Properties do
local r,s=e:ReadProperty(f,q,false)
if r then o[q]=e:_encode(s)end
end
e:_put(j,m,"Bounds",o)
end
end

if e:_isA(f,"TextLabel")or e:_isA(f,"TextButton")or e:_isA(f,"TextBox")then
local n,o=e:ReadProperty(f,"FontFace",false)
if n and o~=nil then
local p,q=pcall(function()return o.Family end)
if p then e:_put(j,m,"FontFamily",Short(q,256))end
end
end
if e:_isA(f,"LuaSourceContainer")then
e:_put(j,m,"ScriptMetadata",{
SourceIncluded=m.Properties~=nil and m.Properties.Source~=nil,
Note="No require or script execution. An explicitly selected Source property may be truncated.",
})
end
if e:_isA(f,"RemoteEvent")or e:_isA(f,"RemoteFunction")or e:_isA(f,"UnreliableRemoteEvent")then
e:_put(j,m,"RemoteMetadata",{Invoked=false,Note="Instance metadata only; no arguments or server implementation inferred."})
end

e:_ancestry(f,g,m,j)
if g.includeChildren~=false then
local n,o=pcall(function()return f:GetChildren()end)
if n and type(o)=="table"then
local p=Clamp(g.childOffset,0,0,1000000000)
local q=Clamp(g.childLimit,20,0,100)
local r={}
for s=p+1,math.min(#o,p+q)do
local t,u=pcall(function()return e:Describe(o[s])end)
if t then
u.FullName=nil
if not e:_take(j,u)then break end
table.insert(r,u)
else
j.limited=true
break
end
end
m.ChildCount=#o
m.ChildOffset=p
m.Children=r
m.ChildrenLimited=p+#r<#o
m.ChildrenPageStable=false
if m.ChildrenLimited then m.NextChildOffset=p+#r end
else
e:_put(j,m,"ChildError",Short(o,240))
end
end
m.Truncated=m.Truncated or j.limited or nil
return m
end

function b.Inspect(e,f)
f=f or{}
local g=f.targets or(f.target and{f.target})
assert(type(g)=="table"and#g>0 and#g<=20,"Inspect requires 1-20 instance targets.")
local h=Clamp(f.maxChars,20000,1000,60000)
local i,j=h-500,840
local k={}
local l=false
for m,n in ipairs(g)do
local o=#g-m+1
local p=math.floor(i/o)
local q=math.floor(j/o)
if p<500 or q<15 then l=true break end
local r,s=pcall(function()
return e:_inspectOne(e:Resolve(n),f,p,q)
end)
if not r then s={TargetIndex=m,Error=Short(s,240)}end
s.TargetIndex=m
local t,u=e:_size(s)
if t>i or u+1>j then
l=true
break
end
i-=t+1
j-=u+1
table.insert(k,s)
if s.Truncated then l=true end
end
return{
results=k,
requestedCount=#g,
returnedCount=#k,
targetsOmitted=#g-#k,
nextTargetIndex=#k<#g and#k+1 or nil,
limited=l,
maxChars=h,
scope="Client-visible replicated/local instances only.",
}
end

return b end function a.D():typeof(__modImpl())local b=a.cache.D if not b then b={c=__modImpl()}a.cache.D=b end return b.c end end do local function __modImpl()



local b={}
b.__index=b

local function Integer(c,d,e,f)
local g=tonumber(c)
if g==nil or g~=g then g=d end
return math.clamp(math.floor(g),e,f)
end

local function Equal(c,d)
if type(c)~=type(d)then return false end
if type(c)~="table"then return c==d end
for e,f in pairs(c)do if not Equal(f,d[e])then return false end end
for e in pairs(d)do if c[e]==nil then return false end end
return true
end

local function EntryCount(c,d)
if type(c)~="table"then return 0 end
if(d or 0)>=8 then return 1000,"serialization-depth-limit"end
local e,f=0,0
for g,h in pairs(c)do
f+=1
if f>256 then return 1000,"serialization-table-entry-limit"end
local i,j=EntryCount(h,(d or 0)+1)
if j then return 1000,j end
e+=1+i
if e>1000 then break end
end
return e
end

local function Contains(c,d,e)
if type(c)~="string"then return false end
if not e then c,d=string.lower(c),string.lower(d)end
return string.find(c,d,1,true)~=nil
end

function b.new(c)
return setmetatable({
inspector=c.Inspector,
clock=c.Clock or os.clock,
measure=c.Measure or function(d)return EntryCount(d)*80 end,
newId=c.NewId,
serial=0,
sessions={},
ttl=c.TtlSeconds or 300,
maxSessions=c.MaxSessions or 4,
maxSnapshotBytes=c.MaxSnapshotBytes or 2097152,
maxSnapshotRecords=c.MaxSnapshotRecords or 3000,
},b)
end

function b.Sweep(c)
local d=c.clock()
for e,f in pairs(c.sessions)do
if f.expiresAt<=d then c.sessions[e]=nil end
end
end

function b.Destroy(c)
table.clear(c.sessions)
end




function b._fitEnvelope(c,d,e,f)
local g=f-350
if c.measure(d)<=g then return d end
local h=d[e]or{}
for i=#h,1,-1 do
local j=h[i]
local k={
Handle=j.Handle,snapshotId=j.snapshotId,kind=j.kind,
omitted=true,reason="envelope-budget",
}
if c.measure(k)<c.measure(j)then
h[i]=k
d.detailsOmitted=(d.detailsOmitted or 0)+(j.omitted and 0 or 1)
d.detailsComplete=false
end
if c.measure(d)<=g then return d end
end
assert(c.measure(d)<=g,"Dex page metadata exceeds the output budget; increase maxOutputChars.")
return d
end

function b._get(c,d)
c:Sweep()
local e=c.sessions[d]
assert(e,"Dex scan/snapshot expired, was released, was evicted under capacity pressure, or belongs to another connection. Start a new scan.")
return e
end

function b._start(c,d,e)
c:Sweep()
local f=0
for g in pairs(c.sessions)do f+=1 end


while f>=c.maxSessions do
local g
for h,i in pairs(c.sessions)do
if i.done and not i.retain and(not g or i.ordinal<g.ordinal)then
g=i
end
end
if not g then break end
c.sessions[g.id]=nil
f-=1
end
assert(f<c.maxSessions,"Dex scan capacity reached. Release a scan with dex-snapshot operation=release.")
local g=c.inspector:Resolve(d.root or{path="workspace"})
local h=c.inspector:Describe(g)
local i=e=="references"and c.inspector:Resolve(d.target)or nil
c.serial+=1
local j="dx_"..(c.newId and c.newId()or tostring(math.floor(c.clock()*1000000))).."_"..c.serial
local k={
id=j,mode=e,revision=0,ordinal=c.serial,createdAt=c.clock(),expiresAt=c.clock()+c.ttl,
root=h,referenced=i,options=d,
stack={{nodes={g},index=1,depth=0}},
buffered=1,visited=0,matched=0,seen={},counts={},
readErrors=0,projectionErrors=0,depthLimited=false,
limited=false,reasons={},records={},byHandle={},snapshotBytes=0,
retain=e=="query"and d.retainSnapshot==true,done=false,
maxNodes=Integer(d.maxNodes,50000,1,100000),
maxDepth=Integer(d.maxDepth,64,0,100),
}
c.sessions[j]=k
return k
end

function b._limit(c,d,e)
d.limited=true
d.reasons[e]=true
end

function b._matches(c,d,e)
local f=e.options.filters or{}
if f.nameContains and not Contains(d.Name,f.nameContains,f.caseSensitive)then return false end
if f.className and d.ClassName~=f.className then return false end
if f.isA and not d:IsA(f.isA)then return false end
if f.tag and not d:HasTag(f.tag)then return false end
if f.attribute then
local g=d:GetAttribute(f.attribute.name)
if g==nil then return false end
if f.attribute.equals~=nil and g~=f.attribute.equals then return false end
end
if f.textContains then
if not(d:IsA"TextLabel"or d:IsA"TextButton"or d:IsA"TextBox")then return false end
if not Contains(d.Text,f.textContains,f.caseSensitive)then return false end
end
return true
end

function b._record(c,d,e,f)
if e.mode=="references"then
local g={}
for h,i in ipairs(e.options.properties or{})do
if h>20 then break end
local j,k=c.inspector:ReadProperty(d,i,false)
if j and k==e.referenced then table.insert(g,i)end
end
if#g==0 then return nil end
local h=c.inspector:Describe(d)
h.ReferenceProperties=g
h.Depth=f
return h
end
if not c:_matches(d,e)then return nil end
local g=c.inspector:QueryRecord(d,e.options)
g.Depth=f
local h=d.Parent
if h then g.ParentHandle=c.inspector:Describe(h).Handle end
return g
end

function b._prune(c,d)
while#d.stack>0 do
local e=d.stack[#d.stack]
if e.index<=#e.nodes then break end
d.buffered-=#e.nodes
table.remove(d.stack)
end
end

function b._visit(c,d)
c:_prune(d)
if#d.stack==0 then return nil end
if d.visited>=d.maxNodes then
c:_limit(d,"node-limit")
table.clear(d.stack)
return nil
end
local e=d.stack[#d.stack]
local f=e.nodes[e.index]
e.index+=1
d.visited+=1
if d.seen[f]then return nil end
d.seen[f]=true

local g,h=pcall(function()return f:GetChildren()end)
if g then
if#h>0 then
if e.depth>=d.maxDepth then
d.depthLimited=true
elseif d.buffered+#h>100000 then
c:_limit(d,"frontier-limit")
else
table.insert(d.stack,{nodes=h,index=1,depth=e.depth+1})
d.buffered+=#h
end
end
else
d.readErrors+=1
end

local i,j=pcall(function()return c:_record(f,d,e.depth)end)
if not i then d.readErrors+=1 return nil end
if not j then return nil end
d.matched+=1
local k=j.ClassName or"Unknown"
d.counts[k]=(d.counts[k]or 0)+1
if j.PropertyErrorCount or j.AttributeError or j.TagError or j.PropertiesOmitted
or j.AttributesLimited or j.TagsLimited or j.Truncated then
d.projectionErrors+=1
end
if d.retain then
local l=c.measure(j)
if#d.records>=c.maxSnapshotRecords or d.snapshotBytes+l>c.maxSnapshotBytes then
c:_limit(d,"snapshot-retention-limit")
else
table.insert(d.records,j)
d.byHandle[j.Handle]=j
d.snapshotBytes+=l
end
end
return j
end

function b.Query(c,d,e)
e=e or"query"
local f
if d.cursor then
local g,h=string.match(d.cursor,"^(.-):(%d+)$")
assert(g,"Invalid Dex continuation cursor.")
f=c:_get(g)
assert(f.mode==e,"This cursor belongs to another Dex tool.")
h=tonumber(h)
if f.lastInput==h then return f.lastResponse end
assert(h==f.revision and not f.done,"Stale or completed Dex cursor. Use nextCursor from the last response.")
else
f=c:_start(d,e)
end
f.expiresAt=c.clock()+c.ttl
local g=f.revision
local h=Integer(d.limit,25,1,100)
local i=Integer(d.scanBudget,1000,1,10000)
local j=Integer(d.maxChars,20000,2000,60000)
local k=c.clock()+Integer(d.timeBudgetMs,8,1,50)/1000
local l,m,n,o={},1000,100,0
local p=f.visited
repeat
local q=f.pending
f.pending=nil
if not q then q=c:_visit(f)end
if q then

local r=c.measure(q)
local s,t=EntryCount(q,2)
if t or r+m>j or s+n>850 then
if#l>0 then f.pending=q break end
q={
Handle=q.Handle,Name=string.sub(q.Name or"",1,100),
ClassName=q.ClassName,omitted=true,
reason=t or"page-budget",
note="Record details omitted; use dex-inspect with fewer fields.",
}
r,s=c.measure(q),EntryCount(q,2)
o+=1
end
table.insert(l,q)
m+=r
n+=s
end
c:_prune(f)
until#l>=h or#f.stack==0 or f.visited-p>=i or c.clock()>=k
c:_prune(f)
f.done=#f.stack==0 and f.pending==nil
if f.done then
f.finishedAt=c.clock()
table.clear(f.seen)
f.referenced=nil
end
f.revision+=1
local q={}
for r in pairs(f.reasons)do table.insert(q,r)end
table.sort(q)
local r={
scanId=f.id,snapshotId=f.retain and f.id or nil,
results=l,returned=#l,
visitedThisPage=f.visited-p,visited=f.visited,matched=f.matched,
done=f.done,complete=f.done and not f.limited and f.readErrors==0,
nextCursor=not f.done and(f.id..":"..f.revision)or nil,
limited=f.limited,limitReasons=q,depthLimited=f.depthLimited,
readErrors=f.readErrors,projectionErrors=f.projectionErrors,
projectionComplete=f.projectionErrors==0,
retainedRecords=#f.records,capturedAt=f.createdAt,expiresInSeconds=c.ttl,
detailsComplete=o==0,detailsOmitted=o,
replayRetention="Completed non-retained scans may be evicted when new scans need capacity.",
scope="client-visible, non-atomic; streamed-out and server-only descendants are not observable",
enumerationNote="Per-page budgets include non-matches. GetChildren is an atomic engine allocation; very wide parents can exceed a time slice.",
}
if e=="references"then r.coverage="Only supplied readable Instance-valued properties; not arbitrary Lua/GC references."end
r=c:_fitEnvelope(r,"results",j)
f.complete=r.complete
f.lastInput,f.lastResponse=g,r
return r
end

local function PublicSnapshot(c)
return{
snapshotId=c.id,root={Handle=c.root.Handle,Name=c.root.Name},retained=#c.records,
matched=c.matched,visited=c.visited,done=c.done,
complete=c.complete==true,capturedAt=c.createdAt,finishedAt=c.finishedAt,
}
end

function b.Snapshots(c,d)
c:Sweep()
if d.operation=="list"then
local e={}
for f,g in pairs(c.sessions)do
local h=PublicSnapshot(g)
h.snapshotRetained=g.retain
table.insert(e,h)
end
table.sort(e,function(f,g)return f.snapshotId<g.snapshotId end)
return c:_fitEnvelope({
snapshots=e,capacity=c.maxSessions,ttlSeconds=c.ttl,
detailsComplete=true,detailsOmitted=0,
},"snapshots",Integer(d.maxChars,20000,2000,60000))
end
if d.operation=="release"then
local e=c.sessions[d.snapshotId]~=nil
c.sessions[d.snapshotId]=nil
return{released=e,snapshotId=d.snapshotId}
end
local e=Integer(d.cursor,0,0,1000000)
local f=Integer(d.limit,25,1,100)
local g=Integer(d.maxChars,20000,2000,60000)
local h,i,j,k={},1000,100,0
local function add(l)


local m=c.measure(l)
local n,o=EntryCount(l,2)
if o or i+m>g or j+n>850 then
if#h>0 then return false end
l={
Handle=l.Handle,kind=l.kind,fields=l.fields,omitted=true,
reason=o or"page-budget",
note="Page the before/after snapshots or inspect this handle with fewer fields for details.",
}
m,n=c.measure(l),EntryCount(l,2)
k+=1
end
table.insert(h,l)
i+=m
j+=n
return true
end
if d.operation=="page"then
local l=c:_get(d.snapshotId)
assert(l.retain,"This scan did not retain a snapshot. Start dex-query with retainSnapshot=true.")
local m=e
while m<#l.records and#h<f do
if not add(l.records[m+1])then break end
m+=1
end
return c:_fitEnvelope({
snapshot=PublicSnapshot(l),results=h,cursor=e,
nextCursor=m<#l.records and m or nil,
detailsComplete=k==0,detailsOmitted=k,
},"results",g)
end
assert(d.operation=="diff","Unknown Dex snapshot operation.")
local l,m=c:_get(d.beforeId),c:_get(d.afterId)
assert(l.retain and m.retain,"Both scans must retain snapshots.")
assert(l.mode=="query"and m.mode=="query","Only retained Dex queries can be compared.")
assert(l.complete and m.complete,"Diff requires completed, uncapped scans without traversal errors; continue or narrow both scans first.")
assert(l.projectionErrors==0 and m.projectionErrors==0,"Diff requires fully captured projections; use fewer fields or resolve reported property errors.")
assert(l.root.Handle==m.root.Handle,"Snapshots must have the same root instance.")
for n,o in ipairs{"filters","properties","includeAttributes","includeTags","maxDepth"}do
assert(Equal(l.options[o],m.options[o]),"Snapshot projection/scope differs: "..o)
end
local n,o=e,0
local p=#l.records+#m.records
while n<p and#h<f and o<2000 do
local q
if n<#l.records then
local r=l.records[n+1]
local s=m.byHandle[r.Handle]
if not s then
q={kind="removed",Handle=r.Handle,before=r}
elseif not Equal(r,s)then
local t,u={},{}
for v,w in pairs(r)do
if not Equal(w,s[v])then
table.insert(t,v)
u[v]={before=w,after=s[v]}
end
end
for v,w in pairs(s)do
if r[v]==nil then table.insert(t,v)u[v]={after=w}end
end
table.sort(t)
q={
kind=r.ParentHandle~=s.ParentHandle and"moved"or"changed",
Handle=r.Handle,fields=t,changes=u,
}
end
else
local r=m.records[n-#l.records+1]
if not l.byHandle[r.Handle]then q={kind="added",Handle=r.Handle,after=r}end
end
if q and not add(q)then break end
n+=1
o+=1
end
return c:_fitEnvelope({
beforeId=l.id,afterId=m.id,changes=h,
cursor=e,nextCursor=n<p and n or nil,examined=o,
complete=n>=p,atomic=false,
detailsComplete=k==0,detailsOmitted=k,
note="Differences cover captured projections only. Removed means no longer observed in this scope, not proof of destruction.",
},"changes",g)
end

return b end function a.E():typeof(__modImpl())local b=a.cache.E if not b then b={c=__modImpl()}a.cache.E=b end return b.c end end do local function __modImpl()

local b={}
b.__index=b

local c={"Handle","Name","ClassName","Path","DebugId"}
local d=350
local e=0

local function Integer(f,g,h,i)
local j=tonumber(f)
if j==nil or j~=j then j=g end
return math.clamp(math.floor(j),h,i)
end

local function Short(f,g)
local h,i=pcall(tostring,f)
if not h then return"unavailable"end
local j=g or 200
if#i<=j then return i end
while j>0 do
local k=string.byte(i,j+1)
if k==nil or k<128 or k>=192 then break end
j-=1
end
return string.sub(i,1,j)
end

local function List(f,g,h,i)
if f==nil then return{}end
assert(type(f)=="table",g.." must be an array.")
local j,k,l={},{},0
for m,n in pairs(f)do
l+=1
assert(l<=h,g.." exceeds "..h.." entries.")
assert(type(m)=="number"and m>=1 and m%1==0 and m<=h,
g.." must be a dense array.")
if i then
assert(type(n)=="string"and#n>0 and#n<=128,
g.." entries must be nonempty names up to 128 bytes.")
end
end
for m=1,l do
local n=f[m]
assert(n~=nil,g.." must be a dense array.")
if not k[n]then
k[n]=true
table.insert(j,n)
end
end
return j
end



local function Size(f,g)
if type(f)=="string"then
g.bytes+=2
for h=1,#f do
local i=string.byte(f,h)


g.bytes+=if i==34 or i==92 then 2 elseif i<32 or i>=127 then 6 else 1
end
return
end
if type(f)~="table"then
g.bytes+=32
return
end
if g.seen[f]then
g.entries=1000
return
end
g.seen[f]=true
g.bytes+=2
for h,i in pairs(f)do
g.entries+=1
if g.entries>850 then return end
Size(h,g)
Size(i,g)
if g.entries>850 then return end
g.bytes+=2
end
g.seen[f]=nil
end

function b.new(f)
f=f or{}
assert(f.Inspector~=nil and type(f.Inspector._encode)=="function","Dex watch requires an Inspector with bounded value encoding.")
e+=1
local g=f.Clock or os.clock


local h=if f.NewId then f.NewId()else tostring(math.floor(g()*1000000)).."-"..e
assert(type(h)=="string"and#h>0 and#h<=80,"Dex watch registry ID must be 1-80 bytes.")
return setmetatable({
Inspector=f.Inspector,
Clock=g,
registryId=h,
Measure=f.Measure,
maxWatchers=Integer(f.MaxWatchers,8,1,8),
watchers={},
finished={},
finishedOrder={},
serial=0,
destroyed=false,
},b)
end

function b._describe(f,g)
local h,i=pcall(function()return f.Inspector:Describe(g)end)
if not h or type(i)~="table"then return{unavailable=true}end
local j={
PathDisplayOnly=i.PathDisplayOnly~=false,
DisplayTruncated=i.DisplayTruncated,
}
for k,l in ipairs(c)do
if type(i[l])=="string"then

j[l]=i[l]
end
end
return j
end

function b._encode(f,g)

local h,i,j=pcall(function()return f.Inspector:_encode(g)end)
if h and type(i)=="table"then
if j==true then
i=table.clone(i)
i.truncated=true
end
return i
end
return{type="unavailable",error=if h then"Invalid encoded value."else Short(i)}
end

function b._read(f,g,h,i)
if i then
return pcall(function()return g:GetAttribute(h)end)
end
local j,k,l,m=pcall(function()return f.Inspector:ReadProperty(g,h,false)end)
if not j then return false,k end
return k,if k then l else m
end

function b._warning(f,g,h,i,j)
if#g.warnings<20 then
table.insert(g.warnings,{kind=h,name=i,error=Short(j)})
else
g.warningsOmitted+=1
end
end

function b._finish(f,g,h)
if not g.active then return end
g.active=false
for i,j in ipairs(g.connections)do
pcall(function()j:Disconnect()end)
end
g.connections={}
g.events={}
f.watchers[g.id]=nil
f.finished[g.id]={
watcherId=g.id,
active=false,
expired=h=="expired",
reason=h,
nextCursor=g.latestCursor,
latestCursor=g.latestCursor,
droppedEvents=g.droppedEvents,
expiresAt=g.expiresAt,
}
table.insert(f.finishedOrder,g.id)
if#f.finishedOrder>32 then f.finished[table.remove(f.finishedOrder,1)]=nil end
end


function b.Sweep(f)
local g,h=f.Clock(),0
for i,j in pairs(f.watchers)do
if g>=j.expiresAt then
f:_finish(j,"expired")
h+=1
end
end
return h
end

function b._push(f,g,h)
if not g.active then return end
if f.Clock()>=g.expiresAt then
f:_finish(g,"expired")
return
end
g.latestCursor+=1
h.cursor=g.latestCursor
h.observedAt=f.Clock()
local i
if g.count<g.capacity then
i=((g.head+g.count-1)%g.capacity)+1
g.count+=1
else
i=g.head
g.head=(g.head%g.capacity)+1
g.droppedEvents+=1
end
g.events[i]=h
end

function b._connect(f,g,h,i,j,k)
local l,m=pcall(function()
return j():Connect(function(...)
if not g.active then return end
if f.Clock()>=g.expiresAt then
f:_finish(g,"expired")
return
end
local l,m=pcall(k,...)
if not l then
f:_push(g,{kind="observation-error",source=h,name=i,error=Short(m)})
end
end)
end)
if l and m~=nil then
table.insert(g.connections,m)
return true
end
f:_warning(g,h,i,if l then"Signal did not return a connection."else m)
return false
end

function b._watchValue(f,g,h,i,j)
local k=if j then"attribute"else"property"
local l,m=f:_read(h,i,j)
if not l then
f:_warning(g,k,i,m)
return
end
local n=f:_encode(m)
local o=f:_connect(g,k,i,function()
return if j then h:GetAttributeChangedSignal(i)else h:GetPropertyChangedSignal(i)
end,function()
local o,p=f:_read(h,i,j)
local q=if o then f:_encode(p)else{type="unavailable",error=Short(p)}
f:_push(g,{
kind=k,
name=i,
target=f:_describe(h),
oldValue=n,
newValue=q,
})
n=q
end)
if o then
local p=if j then"observedAttributeCount"else"observedPropertyCount"
g[p]+=1
end
end

function b.Start(f,g)
assert(not f.destroyed,"Dex watcher has been destroyed.")
g=g or{}
f:Sweep()
local h=List(g.targets,"targets",10,false)
local i=List(g.properties,"properties",20,true)
local j=List(g.attributes,"attributes",20,true)
assert(#h>0,"At least one watch target is required.")
assert(#i+#j>0 or g.includeChildren==true or g.includeAncestry==true,
"Select properties, attributes, children, or ancestry to watch.")
local k=0
for l in pairs(f.watchers)do k+=1 end
assert(k<f.maxWatchers,"Dex watcher limit reached; stop an existing watcher first.")


local l,m={},{}
for n,o in ipairs(h)do
local p=f.Inspector:Resolve(o)
assert(p~=nil,"Watch target was not found.")
if not m[p]then
m[p]=true
table.insert(l,p)
end
end
f.serial+=1
local n={
id="dex-watch-"..f.registryId.."-"..f.serial,
active=true,
capacity=Integer(g.maxEvents,200,1,500),
expiresAt=f.Clock()+Integer(g.ttlSeconds,300,1,3600),
connections={},events={},head=1,count=0,latestCursor=0,droppedEvents=0,
warnings={},warningsOmitted=0,observedPropertyCount=0,observedAttributeCount=0,
}
f.watchers[n.id]=n
local o={}
local p,q=pcall(function()
for p,q in ipairs(l)do
table.insert(o,f:_describe(q))
for r,s in ipairs(i)do f:_watchValue(n,q,s,false)end
for r,s in ipairs(j)do f:_watchValue(n,q,s,true)end
if g.includeChildren==true then
for r,s in ipairs{"child-added","child-removed"}do
f:_connect(n,s,nil,function()
return if s=="child-added"then q.ChildAdded else q.ChildRemoved
end,function(t)
f:_push(n,{
kind=s,
target=f:_describe(q),
oldValue=f:_encode(if s=="child-removed"then t else nil),
newValue=f:_encode(if s=="child-added"then t else nil),
})
end)
end
end
if g.includeAncestry==true then
local r,s=f:_read(q,"Parent",false)
local t=if r then f:_encode(s)else{type="unavailable"}
local u=f:_describe(q).Path
f:_connect(n,"ancestry",nil,function()return q.AncestryChanged end,
function(v,w)
local x,y=f:_read(q,"Parent",false)
local z=if x then f:_encode(y)else{type="unavailable"}
local A=f:_describe(q)
f:_push(n,{
kind="ancestry",target=A,changedInstance=f:_describe(v),
changedParent=f:_encode(w),
oldValue=t,newValue=z,oldPath=u,newPath=A.Path,
})
t,u=z,A.Path
end)
end
end
assert(#n.connections>0,"No requested watch signals were available.")
end)
if not p then
f:_finish(n,"start-failed")
error(q)
end
local r={
watcherId=n.id,active=true,nextCursor=0,expiresAt=n.expiresAt,
maxEvents=n.capacity,targets=o,connectionCount=#n.connections,
observedPropertyCount=n.observedPropertyCount,observedAttributeCount=n.observedAttributeCount,
warnings=table.clone(n.warnings),warningsOmitted=n.warningsOmitted,
targetDetailsOmitted=0,targetsOmitted=0,
}
local s=Integer(g.maxChars,20000,2000,60000)


for t=#r.targets,1,-1 do
if f:_fits(r,s)then break end
r.targets[t]={Handle=r.targets[t].Handle,omitted=true}
r.targetDetailsOmitted+=1
end
while#r.warnings>0 and not f:_fits(r,s)do
table.remove(r.warnings)
r.warningsOmitted+=1
end
while#r.targets>0 and not f:_fits(r,s)do
table.remove(r.targets)
r.targetsOmitted+=1
end
if not f:_fits(r,s)then
f:_finish(n,"start-failed")
error"Watch startup metadata cannot fit the requested output budget."
end
return r
end

function b._fits(f,g,h)
h=math.max(0,h-d)
local i={entries=0,bytes=0,seen={}}
Size(g,i)
if i.entries>850 then return false end
if f.Measure then
local j,k=pcall(f.Measure,g)
if j and type(k)=="number"and k>=0 and k<math.huge then return k<=h end
end
return i.bytes<=h
end

function b.Poll(f,g)
g=g or{}
f:Sweep()
local h=f.watchers[g.watcherId]
if not h then
local i=f.finished[g.watcherId]
assert(i~=nil,"Unknown Dex watcher; start a new watcher.")
local j=table.clone(i)
j.events,j.hasMore={},false
return j
end
local i=Integer(g.cursor,0,0,9007199254740991)
assert(i<=h.latestCursor,"Watch cursor is newer than the latest event.")
local j=Integer(g.limit,100,1,100)
local k=Integer(g.maxChars,20000,2000,60000)
local l=h.latestCursor-h.count+1
local m=math.max(0,l-1-i)
local n={
watcherId=h.id,active=true,expired=false,expiresAt=h.expiresAt,
events={},nextCursor=math.max(i,l-1),latestCursor=h.latestCursor,
earliestAvailableCursor=l,droppedEvents=h.droppedEvents,
gapEvents=m,cursorExpired=m>0,hasMore=false,
}
for o=1,h.count do
local p=h.events[((h.head+o-2)%h.capacity)+1]
if p.cursor<=i then continue end
if#n.events>=j then break end
local q=n.nextCursor
table.insert(n.events,p)
n.nextCursor=p.cursor
n.hasMore=p.cursor<h.latestCursor
if not f:_fits(n,k)then
table.remove(n.events)
n.nextCursor=q
if#n.events>0 then break end

table.insert(n.events,{cursor=p.cursor,kind=p.kind,omitted=true,reason="output-budget"})
n.nextCursor=p.cursor
end
end
n.hasMore=n.nextCursor<h.latestCursor
return n
end

function b.Stop(f,g)
g=g or{}
f:Sweep()
local h=f.watchers[g.watcherId]
if h then f:_finish(h,"stopped")end
local i=f.finished[g.watcherId]
assert(i~=nil,"Unknown Dex watcher.")
return table.clone(i)
end

function b.Destroy(f)
f.destroyed=true
for g,h in pairs(f.watchers)do f:_finish(h,"destroyed")end
end

return b end function a.F():typeof(__modImpl())local b=a.cache.F if not b then b={c=__modImpl()}a.cache.F=b end return b.c end end do local function __modImpl()

local b=a.d()
local c=a.D()
local d=a.E()
local e=a.F()

return function(f,g)
local h=game:GetService"HttpService"
local function measure(i)return#h:JSONEncode(i)end
local i=c.new{
InstancePath=b,Handles=f.RuntimeHandles,
Values=f.RuntimeValues,Measure=measure,
}
local j=d.new{
Inspector=i,Measure=measure,
NewId=function()return h:GenerateGUID(false)end,
}
local k=e.new{
Inspector=i,Values=f.RuntimeValues,Measure=measure,
NewId=function()return h:GenerateGUID(false)end,
}
local l=true
local m={
Version=1,ClientId=g.ClientId,
Describe=function(m)
assert(l,"Dex connection closed; reload the MCP connector.")
return i:Describe(m)
end,
}
getgenv().RobloxMCPDex=m

local function bind(n,o)
g:BindToTypeStructured(n,function(p)
assert(l,"Dex connection closed; reconnect and start a fresh query.")
local q=o(p)
q.clientId=g.ClientId
q.connectorGeneration=f.RuntimeHandles.generation
q.placeId=game.PlaceId
q.observedAtUnixMs=DateTime.now().UnixTimestampMillis
return q
end)
end
bind("dex-inspect",function(n)return i:Inspect(n)end)
bind("dex-query",function(n)return j:Query(n)end)
bind("dex-references",function(n)return j:Query(n,"references")end)
bind("dex-snapshot",function(n)return j:Snapshots(n)end)
bind("dex-watch",function(n)
if n.operation=="start"then return k:Start(n)end
if n.operation=="poll"then return k:Poll(n)end
if n.operation=="stop"then return k:Stop(n)end
error"Unknown Dex watch operation."
end)
local function dexAdapter()
local n=getgenv().DexMCP
assert(type(n)=="table"and n.Version==1,"Compatible Dex is not loaded. Run the updated Dex loader in this same executor.")
assert(type(n.GetSelection)=="function"and type(n.GetStatus)=="function"and type(n.Reveal)=="function","Dex adapter is incomplete; reload the updated Dex loader.")
assert(n.GetStatus().Ready==true,"Dex explorer is closed or still loading.")
return n
end
bind("dex-selection",function(n)
local o=dexAdapter()
local p=o.GetSelection()
assert(type(p)=="table","Dex returned an invalid selection.")
local q=o.GetStatus()
local r=math.max(#p,tonumber(q.SelectionCount)or#p)
local s=math.min(#p,100)
local t=math.clamp(math.floor(tonumber(n.offset)or 0),0,100)
local u=math.clamp(math.floor(tonumber(n.limit)or 25),1,50)
local v,w={},600
local x=t
while x<s and#v<u do
local y,z=pcall(function()return i:Describe(p[x+1])end)
if not y then z={unavailable=true,index=x+1}end
local A=measure(z)
if w+A>(n.maxChars or 20000)then
if#v>0 then break end
z={Handle=z.Handle,omitted=true,index=x+1,reason="output-budget; use dex-inspect with the Handle"}
A=measure(z)
end
table.insert(v,z)
w+=A
x+=1
end
return{
available=true,adapterVersion=o.Version,results=v,
selectionCount=r,availableSelectionCount=s,
selectionTruncated=q.SelectionTruncated==true or r>s,
nextOffset=x<s and x or nil,
note="Selection is live; paging is not atomic. Use returned Handles for exact identity.",
}
end)
bind("dex-reveal",function(n)
local o=dexAdapter()
local p=i:Resolve(n.target)
local q,r=o.Reveal(p)
assert(q~=false,tostring(r or"Dex could not reveal that instance."))
return{revealed=true,instance=i:Describe(p)}
end)

task.spawn(function()
while l and g.Connected do
task.wait(5)
if l then j:Sweep()k:Sweep()end
end
end)
return function()
l=false
k:Destroy()
j:Destroy()
if getgenv().RobloxMCPDex==m then getgenv().RobloxMCPDex=nil end
end
end end function a.G():typeof(__modImpl())local b=a.cache.G if not b then b={c=__modImpl()}a.cache.G=b end return b.c end end do local function __modImpl()

return function(b,c)
local d=b.ScriptMappingPipeline
local e=b.PublishScriptMappingStatus
local f=b.ResetScriptMappingState
local g=b.StartScriptMapping
local h=b.StartFailedScriptResync
local i=b.ResumeDeferredScriptMappings

local function CountJobStates()
local j={}
for k,l in d.jobs do
local m=l.state or"unknown"
j[m]=(j[m]or 0)+1
end
return j
end

local function Status(j)
local k=d.workers
return{
action=j,
enabled=d.disabled~=true,
generation=d.generation,
sessionId=d.session and d.session.id or nil,
mappingRevision=d.session and d.session.revision or nil,
initialScanRunning=d.initialScanRunning,
initialScanFinished=d.initialScanFinished,
scanLimit=d.scanLimit,
scanNodeLimit=d.scanNodeLimit,
scanTruncated=d.scanTruncated,
scanOmitted=d.scanOmitted,
scanOmittedIsLowerBound=d.scanTruncated,
finished=d:IsFinished(),
total=d.total,
processed=d.processed,
skipped=d.skipped,
jobStates=CountJobStates(),
workers=k and{
configured=d.configuredWorkers,
currentLimit=d.currentWorkers,
active=k.ActiveWorkers,
queued=math.max(0,k.QueueTail-k.QueueHead+1),
}or nil,
uploadQueue={
items=math.max(
0,
d.upload.tail-d.upload.head+1
),
bytes=d.upload.bytes,
},
sourceCache={
entries=d.sourceCacheEntries,
bytes=d.sourceCacheBytes,
},
sourceBudget={
usedBytes=d.mappedSourceBytes,
limitBytes=d.sourceBudgetBytes,
},
}
end

local function ClientId()
local j=c.ClientId or d.clientId
assert(type(j)=="string"and j~="","Bridge client registration is not ready.")
return j
end

local function StartFresh(j)
local k=ClientId()
f(k)
g(k)
h()
i()
e()
return Status(j)
end

c:BindToTypeStructured("script-index-status",function(j)
return Status"status"
end)

c:BindToTypeStructured("script-index-start",function(j)
if d.disabled then
return StartFresh"started"
end

if not d.initialScanRunning and not d.initialScanFinished then
local k=ClientId()
g(k)
h()
i()
e()
return Status"started"
end

return Status"already_active"
end)

c:BindToTypeStructured("script-index-stop",function(j)
if d.disabled then
return Status"already_stopped"
end

local k=ClientId()



f(k)
d.disabled=true
d.stateVersion+=1
e()
return Status"stopped"
end)

c:BindToTypeStructured("script-index-resync",function(j)
return StartFresh"resync_started"
end)
end end function a.H():typeof(__modImpl())local b=a.cache.H if not b then b={c=__modImpl()}a.cache.H=b end return b.c end end do local function __modImpl()

return function(b,c)
local d=500
local e=false

local function AnyEqual(f,g)
if type(g)~="table"or#g==0 then return true end
if type(f)~="table"then return false end
for h,i in ipairs(g)do
local j=0
for k,l in pairs(f)do
if j>=d then break end
j+=1
if l==i then return true end
end
end
return false
end

local function IsExecutorClosure(f)
if type(isexecutorclosure)~="function"then return false end
local g,h=pcall(isexecutorclosure,f)
return g and h==true
end

local function FunctionName(f)
local g,h=pcall(function()return debug.info(f,"n")end)
return g and h or nil
end

local function FunctionHash(f)
local g=if type(getfunctionhash)=="function"then getfunctionhash else nil
if not g then return nil end
local h,i=pcall(g,f)
return h and i or nil
end

local function FunctionConstants(f)
local g=if type(getconstants)=="function"then getconstants else nil
if not g and debug and type(debug.getconstants)=="function"then g=debug.getconstants end
if not g then return nil end
local h,i=pcall(g,f)
return h and i or nil
end

local function FunctionUpvalues(f)
local g=if type(getupvalues)=="function"then getupvalues else nil
if not g and debug and type(debug.getupvalues)=="function"then g=debug.getupvalues end
if not g then return nil end
local h,i=pcall(g,f)
return h and i or nil
end

local function MatchesFunction(f,g)
if type(f)~="function"then return false end
if g.ignoreExecutor~=false and IsExecutorClosure(f)then return false end
if g.name~=nil and FunctionName(f)~=g.name then return false end
if g.hash~=nil and FunctionHash(f)~=g.hash then return false end
if not AnyEqual(FunctionConstants(f),g.constants)then return false end
if not AnyEqual(FunctionUpvalues(f),g.upvalues)then return false end
return true
end

local function MatchesTable(f,g)
if type(f)~="table"then return false end

if type(g.keys)=="table"and#g.keys>0 then
local h=false
for i,j in ipairs(g.keys)do
if rawget(f,j)~=nil then
h=true
break
end
end
if not h then return false end
end

if type(g.values)=="table"and#g.values>0 then
local h=false
for i,j in ipairs(g.values)do
local k=0
for l,m in pairs(f)do
if k>=d then break end
k+=1
if m==j then
h=true
break
end
end
if h then break end
end
if not h then return false end
end

if type(g.keyValuePairs)=="table"then
for h,i in pairs(g.keyValuePairs)do
if rawget(f,h)~=i then return false end
end
end
return true
end

local function SummarizeFunction(f)
local g
local h
pcall(function()g=debug.info(f,"s")end)
pcall(function()h=debug.info(f,"l")end)
local i=FunctionConstants(f)
local j=FunctionUpvalues(f)
return{
Name=FunctionName(f),
Source=g,
Line=h,
Hash=FunctionHash(f),
IsExecutorClosure=IsExecutorClosure(f),
ConstantCount=type(i)=="table"and#i or nil,
UpvalueCount=type(j)=="table"and#j or nil,
}
end

local function SafePreview(f)
local g=typeof(f)
if g=="string"then
if#f>200 then return string.sub(f,1,200).."...(truncated)"end
return f
end
if g=="number"or g=="boolean"or g=="nil"then return f end
if g=="Instance"then
local h,i=pcall(function()return f:GetFullName()end)
return h and i or tostring(f)
end
return"<"..g..">"
end

local function SummarizeTable(f,g)
local h={
EntryCount=0,
EntryCountExact=true,
Keys={},
}
for i in pairs(f)do
if h.EntryCount>=d then
h.EntryCountExact=false
break
end
h.EntryCount+=1
if#h.Keys<20 then table.insert(h.Keys,SafePreview(i))end
end
h.EntryCountLowerBound=h.EntryCount
h.EntryScanLimit=d

if type(g.previewKeys)=="table"and#g.previewKeys>0 then
local i={}
for j=1,math.min(#g.previewKeys,30)do
local k=g.previewKeys[j]
local l=rawget(f,k)
i[tostring(k)]=if g.includeValues==true
then SafePreview(l)
else l~=nil
end
h.Preview=i
elseif g.includeValues==true then
local i={}
local j=0
for k,l in pairs(f)do
if j>=10 then break end
i[tostring(SafePreview(k))]=SafePreview(l)
j+=1
end
h.Preview=i
end
return h
end

local function StructuredFilter(f)
local g={}
if f.kind=="function"then
g.Name=f.name
g.Hash=f.hash
g.Constants=f.constants
g.Upvalues=f.upvalues
g.IgnoreExecutor=f.ignoreExecutor~=false
else
g.Keys=f.keys
g.Values=f.values
g.KeyValuePairs=f.keyValuePairs
end




local h,i=pcall(filtergc,f.kind,g,true)
if not h then return nil,tostring(i)end
if f.kind=="function"then
return type(i)=="function"and{i}or{},nil
end
if type(i)~="table"or next(i)==nil then return{},nil end
return{i},nil
end

local function CompatibilityFilter(f)
assert(type(getgc)=="function","Executor supports neither filtergc nor getgc.")
local g,h=pcall(getgc,true)
assert(g and type(h)=="table","getgc compatibility fallback failed: "..tostring(h))

local i=math.max(100,math.min(math.floor(tonumber(f.scanLimit)or 10000),50000))
local j={}
local k=0
local l=0
for m,n in ipairs(h)do
if l>=i then break end
l+=1
local o=if f.kind=="function"
then MatchesFunction(n,f)
else MatchesTable(n,f)
if o then
k+=1
if#j<1 then table.insert(j,n)end
end
end
return j,l,#h>i,k
end

c:BindToTypeStructured("search-gc",function(f)
assert(f.kind=="function"or f.kind=="table","kind must be function or table.")
local g=if f.kind=="function"
then f.name~=nil or f.hash~=nil or(type(f.constants)=="table"and#f.constants>0)or(type(f.upvalues)=="table"and#f.upvalues>0)
else(type(f.keys)=="table"and#f.keys>0)or(type(f.values)=="table"and#f.values>0)or(type(f.keyValuePairs)=="table"and next(f.keyValuePairs)~=nil)
assert(g,"At least one GC search criterion is required.")
assert(not e,"Another search-gc request is already running for this client.")
e=true

local h,i=pcall(function()
local h
local i=false
local j
local k
local l=false
local m
if type(filtergc)=="function"then
h,j=StructuredFilter(f)
end
if not h then
i=true
h,k,l,m=CompatibilityFilter(f)
end

local n={}
for o,p in h do
local q=if f.kind=="function"
then SummarizeFunction(p)
else SummarizeTable(p,f)
table.insert(n,q)
end

local o=m or#h
local p=if i then not l else#h==0
return{
kind=f.kind,
count=o,
countIsLowerBound=not p,
limited=if i then l or o>1 else#h>0,
results=n,
fallbackUsed=i,
filtergcError=j,
scanned=k,
scanTruncated=l,
tableEntryScanLimit=d,
nativeAllocationNote=if i
then"getgc creates an executor-owned full GC snapshot before the bounded scan."
else"filtergc runs executor-native traversal in first-result mode; internal traversal allocation is executor-defined.",
}
end)
e=false
if not h then error(i)end
return i
end)
end end function a.I():typeof(__modImpl())local b=a.cache.I if not b then b={c=__modImpl()}a.cache.I=b end return b.c end end do local function __modImpl()

return function(b,c)
c:BindToTypeStructured("executor-capabilities",function(d)
return b.RuntimeCapabilities:Probe()
end)
end end function a.J():typeof(__modImpl())local b=a.cache.J if not b then b={c=__modImpl()}a.cache.J=b end return b.c end end do local function __modImpl()

local b=a.d()

local function ClampInteger(c,d,e,f)
local g=tonumber(c)
if g==nil or g~=g then g=d end
return math.max(e,math.min(f,math.floor(g)))
end

local function FunctionGetter(c,d)
if type(c)=="function"then return c end
if type(debug)=="table"and type(debug[d])=="function"then return debug[d]end
return nil
end

local function FirstFunction(...)
for c,d in{...}do
if type(d)=="function"then return d end
end
return nil
end

local function SafeFunctionCollection(c,d,e)
local f=FunctionGetter(d,e)
if not f then return nil,"Executor does not expose "..e.."."end
local g,h=pcall(f,c)
if not g then return nil,tostring(h)end
if type(h)~="table"then return nil,e.." returned a non-table value."end
return h,nil
end

local function FunctionDetails(c)
local d={}
pcall(function()d.name=debug.info(c,"n")end)
pcall(function()d.source=debug.info(c,"s")end)
pcall(function()d.line=debug.info(c,"l")end)
pcall(function()d.parameterCount,d.isVararg=debug.info(c,"a")end)
if type(getfunctionhash)=="function"then
pcall(function()d.hash=getfunctionhash(c)end)
end
if type(isexecutorclosure)=="function"then
pcall(function()d.executorClosure=isexecutorclosure(c)==true end)
end
if type(islclosure)=="function"then pcall(function()d.luaClosure=islclosure(c)==true end)end
if type(iscclosure)=="function"then pcall(function()d.cClosure=iscclosure(c)==true end)end
return d
end

local function PageCollection(c,d,e,f)
d=ClampInteger(d,0,0,1000000000)
e=ClampInteger(e,25,1,200)
local g={}
local h=0
local i=false
local j=d+e+1
for k,l in pairs(c or{})do
if h>=j then i=true break end
if h>=d and#g<e then
table.insert(g,{
key=f:Encode(k),
value=f:Encode(l),
})
end
h+=1
end
local k=d+#g
return{
total=h,
totalIsLowerBound=i,
cursor=d,
nextCursor=(i or k<h)and k or nil,
entries=g,
}
end

local function ReadConnectionField(c,d)
local e,f=pcall(function()return c[d]end)
return e and f or nil
end

return function(c,d)
local e=c.RuntimeHandles
local f=c.RuntimeValues

d:BindToTypeStructured("runtime-inspect",function(g)
local h,i=e:Resolve(g.handle)
local j=e:Describe(g.handle)
j.robloxType=typeof(h)

if i.kind=="table"then
j.page=PageCollection(h,g.cursor,g.limit,f)
j.pageStable=false
local k
local l=if type(getrawmetatable)=="function"then getrawmetatable else getmetatable
pcall(function()k=l(h)end)
if k~=nil then j.metatable=f:Encode(k)end
elseif i.kind=="function"then
j.functionInfo=FunctionDetails(h)
if g.includeConstants~=false then
local k,l=SafeFunctionCollection(h,getconstants,"getconstants")
j.constants=k and PageCollection(k,g.cursor,g.limit,f)or nil
j.constantsError=l
end
if g.includeUpvalues~=false then
local k,l=SafeFunctionCollection(h,getupvalues,"getupvalues")
j.upvalues=k and PageCollection(k,g.cursor,g.limit,f)or nil
j.upvaluesError=l
end
if g.includePrototypes==true then
local k,l=SafeFunctionCollection(h,getprotos,"getprotos")
j.prototypes=k and PageCollection(k,g.cursor,g.limit,f)or nil
j.prototypesError=l
end
elseif i.kind=="instance"then
j.instance=b.Describe(h)
local k={}
local l={}
for m=1,math.min(#(g.properties or{}),100)do
local n=g.properties[m]
local o,p=pcall(function()return h[n]end)
if o then k[n]=f:Encode(p)else l[n]=tostring(p)end
end
if next(k)then j.properties=k end
if next(l)then j.propertyErrors=l end
elseif i.kind=="thread"then
pcall(function()j.status=coroutine.status(h)end)
elseif i.kind=="connection"then
j.connection={
enabled=ReadConnectionField(h,"Enabled"),
luaConnection=ReadConnectionField(h,"LuaConnection"),
foreignState=ReadConnectionField(h,"ForeignState"),
functionValue=f:Encode(ReadConnectionField(h,"Function")),
threadValue=f:Encode(ReadConnectionField(h,"Thread")),
}
else
j.value=f:Encode(h)
end
return j
end)

d:BindToTypeStructured("runtime-read",function(g)
local h,i=e:Resolve(g.handle)
local j=g.member
local k
if j=="field"then
assert(i.kind=="table","field reads require a table handle.")
k=rawget(h,f:Decode(g.key))
elseif j=="property"then
assert(i.kind=="instance","property reads require an Instance handle.")
assert(type(g.property)=="string"and string.match(g.property,"^[%a_][%w_]*$"),"Invalid property name.")
k=h[g.property]
elseif j=="upvalue"then
assert(i.kind=="function","upvalue reads require a function handle.")
local l,m=SafeFunctionCollection(h,getupvalues,"getupvalues")
assert(l,m)
k=l[g.index]
elseif j=="constant"then
assert(i.kind=="function","constant reads require a function handle.")
local l,m=SafeFunctionCollection(h,getconstants,"getconstants")
assert(l,m)
k=l[g.index]
elseif j=="prototype"then
assert(i.kind=="function","prototype reads require a function handle.")
local l,m=SafeFunctionCollection(h,getprotos,"getprotos")
assert(l,m)
k=l[g.index]
elseif j=="metatable"then
local l=if type(getrawmetatable)=="function"then getrawmetatable else getmetatable
k=l(h)
else
error("Unknown runtime member: "..tostring(j))
end
return{handle=g.handle,member=j,value=f:Encode(k)}
end)

d:BindToTypeStructured("runtime-write",function(g)
local h,i=e:Resolve(g.handle)
local j=g.member
local k=f:Decode(g.value)
local l
if j=="field"then
assert(i.kind=="table","field writes require a table handle.")
local m=f:Decode(g.key)
l=rawget(h,m)
rawset(h,m,k)
elseif j=="property"then
assert(i.kind=="instance","property writes require an Instance handle.")
assert(type(g.property)=="string"and string.match(g.property,"^[%a_][%w_]*$"),"Invalid property name.")
l=h[g.property]
h[g.property]=k
elseif j=="upvalue"then
assert(i.kind=="function","upvalue writes require a function handle.")
local m,n=SafeFunctionCollection(h,getupvalues,"getupvalues")
assert(m,n)
l=m[g.index]
local o=FunctionGetter(setupvalue,"setupvalue")
assert(o,"Executor does not expose setupvalue.")
local p,q=pcall(o,h,g.index,k)
assert(p,tostring(q))
elseif j=="constant"then
assert(i.kind=="function","constant writes require a function handle.")
local m,n=SafeFunctionCollection(h,getconstants,"getconstants")
assert(m,n)
l=m[g.index]
local o=FunctionGetter(setconstant,"setconstant")
assert(o,"Executor does not expose setconstant.")
local p,q=pcall(o,h,g.index,k)
assert(p,tostring(q))
else
error("Unknown writable runtime member: "..tostring(j))
end
return{
handle=g.handle,
member=j,
previous=f:Encode(l),
value=f:Encode(k),
written=true,
}
end)

d:BindToTypeStructured("runtime-call",function(g)
local h,i=e:Resolve(g.handle)
assert(i.kind=="function"or i.kind=="table","runtime-call requires a function or callable table handle.")
local j={}
local k=#(g.arguments or{})
for l,m in g.arguments or{}do
assert(l<=32,"runtime-call accepts at most 32 arguments.")
j[l]=f:Decode(m)
end

local l=FirstFunction(setthreadidentity,setidentity,setthreadcontext)
local m=FirstFunction(getthreadidentity,getidentity,getthreadcontext)
local n
local o=false
local p=false
if g.threadIdentity~=nil then
assert(l~=nil,"This executor does not expose a thread-identity setter.")
if m then pcall(function()n=m()end)end
if n==nil then
n=8
p=true
end
local q,r=pcall(l,g.threadIdentity)
assert(q,"Setting thread identity failed: "..tostring(r))
o=true
end
local q=table.pack(pcall(h,table.unpack(j,1,k)))
if o then pcall(l,n)end
if q[1]~=true then
return{
handle=g.handle,
success=false,
error=tostring(q[2]),
identityRestoreAssumed=p or nil,
}
end
local r={}
for s=2,math.min(q.n,33)do table.insert(r,(f:Encode(q[s])))end
return{
handle=g.handle,
success=true,
resultCount=q.n-1,
results=r,
resultsTruncated=q.n-1>#r,
identityRestoreAssumed=p or nil,
}
end)

d:BindToTypeStructured("runtime-release",function(g)
local h,i=e:ReleaseMany(g.handles)
return{released=h,missing=i,registry=e:Stats()}
end)

d:BindToTypeStructured("runtime-handles",function(g)
local h=e:List(g.cursor,g.limit,g.kind)
h.registry=e:Stats()
return h
end)
end end function a.K():typeof(__modImpl())local b=a.cache.K if not b then b={c=__modImpl()}a.cache.K=b end return b.c end end do local function __modImpl()

local b=a.d()

local function ClampInteger(c,d,e,f)
local g=tonumber(c)
if g==nil or g~=g then g=d end
return math.max(e,math.min(f,math.floor(g)))
end

local function AddEnvironment(c,d,e,f,g,h)
if type(g)~="table"then return end
local i=e:Register(g,"table",{environment=f})
if d[i]then return end
d[i]=true
table.insert(c,{name=f,handle=i,quality=h or"exact"})
end

return function(c,d)
local e=c.RuntimeHandles
local f=c.RuntimeValues

d:BindToTypeStructured("runtime-environments",function(g)
local h=g.operation or"list"
if h=="list"then
local i={}
local j={}
AddEnvironment(i,j,e,"getgenv",getgenv(),"exact")
if type(getrenv)=="function"then
local k,l=pcall(getrenv)
if k then AddEnvironment(i,j,e,"getrenv",l,"best-effort")end
end
if type(getfenv)=="function"then
local k,l=pcall(getfenv,0)
if k then AddEnvironment(i,j,e,"getfenv(0)",l,"best-effort")end
end
AddEnvironment(i,j,e,"_G",_G,"roblox-api")
AddEnvironment(i,j,e,"shared",shared,"roblox-api")
return{environments=i,count=#i}
end

if h=="script"then
assert(type(getsenv)=="function","This executor does not expose getsenv.")
local i=b.Resolve(g.target)
local j,k=pcall(getsenv,i)
assert(j and type(k)=="table","getsenv failed: "..tostring(k))
local l=e:Register(k,"table",{
environment="script",
scriptPath=b.StablePath(i),
})
return{
operation=h,
script=b.Describe(i),
environment={type="handle",kind="table",handle=l},
}
end

if h=="handle"then
assert(type(getfenv)=="function","This executor does not expose getfenv.")
local i=e:Resolve(g.handle)
local j,k=pcall(getfenv,i)
assert(j and type(k)=="table","getfenv failed: "..tostring(k))
return{
operation=h,
sourceHandle=g.handle,
environment=f:Encode(k),
}
end
error("Unknown runtime-environments operation: "..tostring(h))
end)

d:BindToTypeStructured("runtime-scripts",function(g)
local h=g.operation or"list"
if h=="closure"then
assert(type(getscriptclosure)=="function","This executor does not expose getscriptclosure.")
local i=b.Resolve(g.target)
local j,k=pcall(getscriptclosure,i)
assert(j and type(k)=="function","getscriptclosure failed: "..tostring(k))
return{
operation=h,
script=b.Describe(i),
closure=f:Encode(k),
}
end

assert(h=="list","Unknown runtime-scripts operation: "..tostring(h))
local i=g.collection or"scripts"
local j
if i=="scripts"then j=getscripts end
if i=="running"then j=getrunningscripts end
if i=="loaded-modules"then j=getloadedmodules end
if i=="nil-instances"then j=getnilinstances end
if i=="all-instances"then j=getinstances end
assert(type(j)=="function","This executor does not expose the requested "..i.." inventory.")

local k,l=pcall(j)
assert(k and type(l)=="table",i.." inventory failed: "..tostring(l))
local m=ClampInteger(g.cursor,0,0,1000000000)
local n=ClampInteger(g.limit,50,1,200)
local o=m+n+1
local p={}
local q=0
local r=0
local s=false
for t,u in l do
r+=1
if r%500==0 then task.wait()end
if typeof(u)~="Instance"then continue end
if q>=m and#p<n then
local v=b.Describe(u)
v.Handle=e:Register(u,"instance",{
className=v.ClassName,
path=v.Path,
})
if g.includeHashes==true then
if type(getscripthash)=="function"and u:IsA"LuaSourceContainer"then
pcall(function()v.ScriptHash=getscripthash(u)end)
end
if type(getscriptbytecode)=="function"and u:IsA"LuaSourceContainer"then
local w,x=pcall(getscriptbytecode,u)
if w and type(x)=="string"then v.BytecodeBytes=#x end
end
end
table.insert(p,v)
end
q+=1
if q>=o then
s=true
break
end
end
local t=m+#p
return{
operation=h,
collection=i,
total=q,
totalIsLowerBound=s,
sourceReturnedByExecutor=#l,
sourceScanned=r,
cursor=m,
nextCursor=(s or t<q)and t or nil,
results=p,
}
end)
end end function a.L():typeof(__modImpl())local b=a.cache.L if not b then b={c=__modImpl()}a.cache.L=b end return b.c end end do local function __modImpl()

local b=a.d()

local function ClampInteger(c,d,e,f)
local g=tonumber(c)
if g==nil or g~=g then g=d end
return math.max(e,math.min(f,math.floor(g)))
end

local function ResolveActor(c,d)
if c.handle then
local e=d:Resolve(c.handle)
assert(typeof(e)=="Instance"and e:IsA"Actor","Actor handle does not reference an Actor Instance.")
return e
end
local e=b.Resolve(c.target)
assert(e:IsA"Actor","Target Instance is not an Actor.")
return e
end

return function(c,d)
local e=c.RuntimeHandles
local f=c.RuntimeValues

d:BindToTypeStructured("property-access",function(g)
local h=b.Resolve(g.target)
local i=g.property
assert(type(i)=="string"and string.match(i,"^[%a_][%w_]*$"),"Invalid property name.")
local j=g.operation or"read"

if j=="read"then
local k,l=pcall(function()return h[i]end)
local m=false
local n
local o
if not k and type(gethiddenproperty)=="function"then
m,n,o=pcall(gethiddenproperty,h,i)
end
assert(k or m,"Property read failed: "..tostring(l).."; "..tostring(n))
local p=m and n or l
return{
operation=j,
target=b.Describe(h),
property=i,
accessMethod=m and"gethiddenproperty"or"ordinary",
hidden=m and o==true or nil,
value=f:Encode(p),
}
end

if j=="write"then
local k=f:Decode(g.value)
local l
local m,n=pcall(function()return h[i]end)
if not m and type(gethiddenproperty)=="function"then
m,n=pcall(gethiddenproperty,h,i)
end
if m then l=n end

local o=false
local p
if g.preferHidden~=false and type(sethiddenproperty)=="function"then
o,p=pcall(sethiddenproperty,h,i,k)
end
if not o then
local q,r=pcall(function()h[i]=k end)
assert(q,"Property write failed: "..tostring(p).."; "..tostring(r))
end
return{
operation=j,
target=b.Describe(h),
property=i,
accessMethod=o and"sethiddenproperty"or"ordinary",
previous=f:Encode(l),
value=f:Encode(k),
written=true,
}
end

if j=="scriptable-status"then
assert(type(isscriptable)=="function","This executor does not expose isscriptable.")
local k,l=pcall(isscriptable,h,i)
assert(k,"isscriptable failed: "..tostring(l))
return{
operation=j,
target=b.Describe(h),
property=i,
scriptable=l==true,
}
end

if j=="set-scriptable"then
assert(type(setscriptable)=="function","This executor does not expose setscriptable.")
local k,l=pcall(setscriptable,h,i,g.scriptable==true)
assert(k,"setscriptable failed: "..tostring(l))
return{
operation=j,
target=b.Describe(h),
property=i,
previous=l,
scriptable=g.scriptable==true,
}
end
error("Unknown property-access operation: "..tostring(j))
end)

d:BindToTypeStructured("callback-inspect",function(g)
local h=b.Resolve(g.target)
local i=g.property
assert(type(i)=="string"and string.match(i,"^[%a_][%w_]*$"),"Invalid callback property name.")
local j=g.operation or"inspect"

local k
local l
if type(getcallbackvalue)=="function"then
k,l=pcall(getcallbackvalue,h,i)
end
if not k then k,l=pcall(function()return h[i]end)end
assert(k,"Callback property could not be read: "..tostring(l))

if j=="inspect"then
return{
operation=j,
target=b.Describe(h),
property=i,
callback=f:Encode(l),
callbackType=typeof(l),
}
end

if j=="replace"then
local m=f:Decode(g.value)
assert(m==nil or type(m)=="function","Callback replacement must be nil or a function handle.")
local n,o=pcall(function()h[i]=m end)
assert(n,"Callback replacement failed: "..tostring(o))
return{
operation=j,
target=b.Describe(h),
property=i,
previous=f:Encode(l),
callback=f:Encode(m),
replaced=true,
}
end
error("Unknown callback-inspect operation: "..tostring(j))
end)

d:BindToTypeStructured("runtime-actors",function(g)
local h=g.operation or"list"
if h=="list"then
assert(type(getactors)=="function","This executor does not expose getactors.")
local i,j=pcall(getactors)
assert(i and type(j)=="table","getactors failed: "..tostring(j))
local k=ClampInteger(g.cursor,0,0,1000000000)
local l=ClampInteger(g.limit,50,1,200)
local m={}
for n=k+1,math.min(#j,k+l)do
local o=j[n]
if typeof(o)=="Instance"then
local p=b.Describe(o)
p.Handle=e:Register(o,"instance",{
className=p.ClassName,
path=p.Path,
actor=true,
})
table.insert(m,p)
end
end
local n=k+#m
return{
operation=h,
total=#j,
cursor=k,
nextCursor=n<#j and n or nil,
actors=m,
}
end

if h=="threads"then
assert(type(getactorthreads)=="function","This executor does not expose getactorthreads.")
local i=ResolveActor(g,e)
local j,k=pcall(getactorthreads,i)
assert(j and type(k)=="table","getactorthreads failed: "..tostring(k))
local l={}
for m,n in k do
if m>500 then break end
table.insert(l,(f:Encode(n)))
end
return{
operation=h,
actor=b.Describe(i),
threadCount=#k,
threads=l,
truncated=#k>#l,
}
end
error("Unknown runtime-actors operation: "..tostring(h))
end)
end end function a.M():typeof(__modImpl())local b=a.cache.M if not b then b={c=__modImpl()}a.cache.M=b end return b.c end end do local function __modImpl()

return function(b,c)
local d=b.GcExplorer

c:BindToTypeStructured("gc-snapshot",function(e)
local f=e.operation or"create"
if f=="create"then return d:CreateSnapshot(e)end
if f=="list"then return d:ListSnapshots()end
if f=="release"then return d:ReleaseSnapshot(e.snapshotId)end
error("Unknown gc-snapshot operation: "..tostring(f))
end)

c:BindToTypeStructured("gc-query",function(e)
return d:Query(e)
end)

c:BindToTypeStructured("gc-diff",function(e)
return d:Diff(e)
end)

c:BindToTypeStructured("gc-statistics",function(e)
return d:Statistics(e)
end)

c:BindToTypeStructured("runtime-references",function(e)
return d:References(e)
end)
end end function a.N():typeof(__modImpl())local b=a.cache.N if not b then b={c=__modImpl()}a.cache.N=b end return b.c end end do local function __modImpl()

local b=a.d()

local function ClampInteger(c,d,e,f)
local g=tonumber(c)
if g==nil or g~=g then g=d end
return math.max(e,math.min(f,math.floor(g)))
end

local function ReadField(c,d)
local e,f=pcall(function()return c[d]end)
return e and f or nil
end

local function DescribeConnection(c,d,e)
local f=d:Register(c,"connection")
return{
handle=f,
enabled=ReadField(c,"Enabled"),
connected=ReadField(c,"Connected"),
luaConnection=ReadField(c,"LuaConnection"),
foreignState=ReadField(c,"ForeignState"),
functionValue=e:Encode(ReadField(c,"Function")),
threadValue=e:Encode(ReadField(c,"Thread")),
operations={
enable=type(ReadField(c,"Enable"))=="function",
disable=type(ReadField(c,"Disable"))=="function",
disconnect=type(ReadField(c,"Disconnect"))=="function",
fire=type(ReadField(c,"Fire"))=="function",
defer=type(ReadField(c,"Defer"))=="function",
},
}
end

local function ResolveSignal(c,d)
local e=b.Resolve(c)
assert(type(d)=="string"and string.match(d,"^[%a_][%w_]*$"),"Invalid signal name.")
local f,g=pcall(function()return e[d]end)
assert(f and typeof(g)=="RBXScriptSignal",d.." is not an RBXScriptSignal on the target Instance.")
return e,g
end

return function(c,d)
local e=c.RuntimeHandles
local f=c.RuntimeValues

d:BindToTypeStructured("signal-connections",function(g)
local h=g.operation or"list"
if h=="list"then
assert(type(getconnections)=="function","This executor does not expose getconnections.")
local i,j=ResolveSignal(g.target,g.signal)
local k,l=pcall(getconnections,j)
assert(k and type(l)=="table","getconnections failed: "..tostring(l))
local m=ClampInteger(g.cursor,0,0,1000000000)
local n=ClampInteger(g.limit,50,1,200)
local o={}
for p=m+1,math.min(#l,m+n)do
table.insert(o,DescribeConnection(l[p],e,f))
end
local p=m+#o
return{
operation=h,
target=b.Describe(i),
signal=g.signal,
signalHandle=e:Register(j,"signal",{
path=b.StablePath(i),
signal=g.signal,
}),
total=#l,
cursor=m,
nextCursor=p<#l and p or nil,
connections=o,
}
end

if h=="fire-signal"then
assert(type(firesignal)=="function","This executor does not expose firesignal.")
local i,j=ResolveSignal(g.target,g.signal)
local k={}
local l=#(g.arguments or{})
for m,n in g.arguments or{}do
assert(m<=32,"At most 32 signal arguments are accepted.")
k[m]=f:Decode(n)
end
local m,n=pcall(firesignal,j,table.unpack(k,1,l))
assert(m,"firesignal failed: "..tostring(n))
return{operation=h,target=b.Describe(i),signal=g.signal,fired=true}
end

local i=e:Resolve(g.handle,"connection")
if h=="inspect"then return DescribeConnection(i,e,f)end

local j=({
enable="Enable",
disable="Disable",
disconnect="Disconnect",
fire="Fire",
defer="Defer",
})[h]
assert(j~=nil,"Unknown signal-connections operation: "..tostring(h))
local k=ReadField(i,j)
assert(type(k)=="function","Connection does not support "..j..".")
local l={}
local m=#(g.arguments or{})
for n,o in g.arguments or{}do
assert(n<=32,"At most 32 connection arguments are accepted.")
l[n]=f:Decode(o)
end
local n,o=pcall(k,i,table.unpack(l,1,m))
assert(n,j.." failed: "..tostring(o))
local p=DescribeConnection(i,e,f)
p.operation=h
p.completed=true
return p
end)
end end function a.O():typeof(__modImpl())local b=a.cache.O if not b then b={c=__modImpl()}a.cache.O=b end return b.c end end do local function __modImpl()

local b=a.d()

return function(c,d)
local e=c.VirtualInputManager
local f=c.Players
local g=game:GetService"UserInputService"

local function MousePosition(h)
if h.x~=nil or h.y~=nil then
assert(type(h.x)=="number"and type(h.y)=="number","Provide both x and y, or omit both.")
return math.floor(h.x),math.floor(h.y)
end
local i=g:GetMouseLocation()
return math.floor(i.X),math.floor(i.Y)
end

local function KeyCodeForExecutor(h)
local i=h.Name
if#i==1 then return string.byte(string.upper(i))end
local j={
Backspace=0x08,
Tab=0x09,
Return=0x0D,
LeftShift=0x10,
RightShift=0x10,
LeftControl=0x11,
RightControl=0x11,
LeftAlt=0x12,
RightAlt=0x12,
Escape=0x1B,
Space=0x20,
PageUp=0x21,
PageDown=0x22,
End=0x23,
Home=0x24,
Left=0x25,
Up=0x26,
Right=0x27,
Down=0x28,
Insert=0x2D,
Delete=0x2E,
}
if j[i]then return j[i]end
local k=string.match(i,"^F(%d+)$")
if k then
local l=tonumber(k)
if l and l>=1 and l<=12 then return 0x6F+l end
end
return h.Value
end

local function SendKey(h)
local i=Enum.KeyCode[h.key]
assert(i~=nil,"Unknown Enum.KeyCode: "..tostring(h.key))
local j=h.state or"press"
local k=math.max(1,math.min(math.floor(tonumber(h.repeatCount)or 1),20))
local l=math.max(0,math.min((tonumber(h.durationMs)or 40)/1000,2))
l=math.min(l,10/k)
local m=false

local function Send(n)
local o=pcall(function()
e:SendKeyEvent(n,i,false,game)
end)
if o then return end

m=true
local p=KeyCodeForExecutor(i)
if n then
assert(type(keypress)=="function","VirtualInputManager and keypress both failed/unavailable.")
keypress(p)
else
assert(type(keyrelease)=="function","VirtualInputManager and keyrelease both failed/unavailable.")
keyrelease(p)
end
end

for n=1,k do
if j=="down"then
Send(true)
elseif j=="up"then
Send(false)
else
Send(true)
if l>0 then task.wait(l)end
Send(false)
end
end
return{status="sent",action="key",key=i.Name,state=j,fallbackUsed=m}
end

local function SendText(h)
local i=tostring(h.text or"")
assert(#i<=2000,"Text input is limited to 2000 characters.")
local j
if h.target then
j=b.Resolve(h.target)
assert(j:IsA"TextBox","Text target must resolve to a TextBox.")
j:CaptureFocus()
task.wait()
end

local k=false
local l=pcall(function()
for l=1,#i do
e:SendTextInput(string.sub(i,l,l),nil,game)
if l%100==0 then task.wait()end
end
end)
if not l then
assert(j,"VirtualInputManager text input failed and no TextBox fallback target was supplied.")
j.Text=i
k=true
end

if h.submit==true then
pcall(function()
e:SendKeyEvent(true,Enum.KeyCode.Return,false,game)
e:SendKeyEvent(false,Enum.KeyCode.Return,false,game)
end)
end
if j then j:ReleaseFocus(h.submit==true)end
return{status="sent",action="text",characters=#i,submitted=h.submit==true,fallbackUsed=k}
end

local function SendMouse(h)
local i,j=MousePosition(h)
local k=h.event
local l=h.button or"left"
local m=({left=0,right=1,middle=2})[l]
assert(m~=nil,"Unsupported mouse button.")
local n=false

if k=="move"then
local o=pcall(function()e:SendMouseMoveEvent(i,j,game)end)
if not o then
assert(type(mousemoveabs)=="function","Mouse movement is unsupported by this executor.")
mousemoveabs(i,j)
n=true
end
else
local function SendButton(o)
local p=pcall(function()
e:SendMouseButtonEvent(i,j,m,o,game,0)
end)
if p then return end
n=true
local q={
left={down=mouse1press,up=mouse1release},
right={down=mouse2press,up=mouse2release},
}
local r=q[l]
local s=r and r[o and"down"or"up"]
assert(type(s)=="function","Mouse button input is unsupported by this executor.")
s()
end

if k=="down"then
SendButton(true)
elseif k=="up"then
SendButton(false)
elseif k=="click"then
SendButton(true)
task.wait(0.04)
SendButton(false)
else
error("Unsupported mouse event: "..tostring(k))
end
end

return{status="sent",action="mouse",event=k,button=l,x=i,y=j,fallbackUsed=n}
end

local function SendScroll(h)
local i,j=MousePosition(h)
local k=math.max(1,math.min(math.floor(tonumber(h.clicks)or 1),50))
local l=h.direction=="up"
local m=false
for n=1,k do
local o=pcall(function()
e:SendMouseWheelEvent(i,j,l,game)
end)
if not o then
assert(type(mousescroll)=="function","Mouse wheel input is unsupported by this executor.")
mousescroll(l and 1 or-1)
m=true
end
end
return{status="sent",action="scroll",direction=h.direction,clicks=k,fallbackUsed=m}
end

local function FirePrompt(h)
local i=b.Resolve(h.target)
assert(i:IsA"ProximityPrompt","Target must be a ProximityPrompt.")
local j=math.max(0,math.min(tonumber(h.holdDuration)or i.HoldDuration,10))
if type(fireproximityprompt)=="function"then
fireproximityprompt(i,j)
return{status="fired",action="proximity-prompt",target=b.Describe(i),fallbackUsed=false}
end

local k=pcall(function()i:InputHoldBegin()end)
assert(k,"Executor does not support fireproximityprompt or ProximityPrompt input methods.")
if j>0 then task.wait(j)end
i:InputHoldEnd()
return{status="fired",action="proximity-prompt",target=b.Describe(i),fallbackUsed=true}
end

local function FireDetector(h)
local i=b.Resolve(h.target)
assert(i:IsA"ClickDetector","Target must be a ClickDetector.")
local j=math.max(0,math.min(tonumber(h.distance)or 0,10000))
if type(fireclickdetector)=="function"then
fireclickdetector(i,j)
return{status="fired",action="click-detector",target=b.Describe(i),fallbackUsed=false}
end

assert(type(firesignal)=="function","Executor supports neither fireclickdetector nor firesignal.")
firesignal(i.MouseClick,f.LocalPlayer)
return{status="fired",action="click-detector",target=b.Describe(i),fallbackUsed=true}
end

local function FireTouch(h)
assert(type(firetouchinterest)=="function","Executor does not support firetouchinterest.")
local i=b.Resolve(h.first)
local j=b.Resolve(h.second)
assert(i:IsA"BasePart"and j:IsA"BasePart","Both touch targets must be BaseParts.")
local k=h.state or"tap"
if k=="begin"or k=="tap"then firetouchinterest(i,j,0)end
if k=="tap"then task.wait()end
if k=="end"or k=="tap"then firetouchinterest(i,j,1)end
return{
status="fired",
action="touch",
state=k,
first=b.Describe(i),
second=b.Describe(j),
}
end

d:BindToTypeStructured("input",function(h)
if h.action=="key"then return SendKey(h)end
if h.action=="text"then return SendText(h)end
if h.action=="mouse"then return SendMouse(h)end
if h.action=="scroll"then return SendScroll(h)end
if h.action=="proximity-prompt"then return FirePrompt(h)end
if h.action=="click-detector"then return FireDetector(h)end
if h.action=="touch"then return FireTouch(h)end
error("Unsupported input action: "..tostring(h.action))
end)
end end function a.P():typeof(__modImpl())local b=a.cache.P if not b then b={c=__modImpl()}a.cache.P=b end return b.c end end do local function __modImpl()

local b=a.d()
local c=a.x()

local d="__ROBLOX_MCP_EVENT_JOURNAL_V2"
local e="__ROBLOX_MCP_EVENT_JOURNAL_V1"
local f=500
local g=5000
local h=2000
local i=1000
local j=5
local k=1
local l=2000
local m=5000
local n=2

return function(o,p)
local q=o.LogService
local r=0
local s=0

local t=getgenv()
local u=t[d]
if type(u)~="table"or u.version~=2 then
if type(u)=="table"and type(u.connections)=="table"then
for v,w in u.connections do pcall(function()w:Disconnect()end)end
end
u={
version=2,
nextCursor=0,
events={},
head=1,
count=0,
connections={},
}
t[d]=u
end
local v=t[e]
if type(v)=="table"and type(v.connections)=="table"then
for w,x in v.connections do
pcall(function()x:Disconnect()end)
end
end
t[e]=nil

local function Push(w,x)
u.nextCursor+=1
x.kind=w
x.cursor=u.nextCursor
x.observedAt=os.clock()
local y
if u.count<f then
y=((u.head+u.count-1)%f)+1
u.count+=1
else
y=u.head
u.head=(u.head%f)+1
end
u.events[y]=x
return x
end

local function JournalEventAt(w)
if w<1 or w>u.count then return nil end
local x=((u.head+w-2)%f)+1
return u.events[x]
end

local function EarliestEvent()
return JournalEventAt(1)
end

local function EnsureConsoleJournal()
if u.connections.console then return end
local w,x=pcall(function()
return q.MessageOut:Connect(function(w,x)
w=tostring(w)
if#w>h then
w=string.sub(w,1,h).."...(truncated)"
end
Push("console",{
message=w,
level=x and x.Name or tostring(x or"Unknown"),
})
end)
end)
if w then u.connections.console=x end
end

local function MinimalInstanceDescription(w)
local x,y=pcall(b.Describe,w)
if not x then return nil end
return{
Name=y.Name,
ClassName=y.ClassName,
Path=y.Path,
DebugId=y.DebugId,
}
end

local function EnsureInstanceJournal()
if u.connections.instance then return end
u.connections.instance=game.DescendantAdded:Connect(function(w)
local x=MinimalInstanceDescription(w)
if not x then return end
Push("instance",x)
end)
end

local function Contains(w,x,y)
if type(x)~="string"or x==""then return true end
w=tostring(w or"")
if not y then
w=string.lower(w)
x=string.lower(x)
end
return string.find(w,x,1,true)~=nil
end

local function MatchesConsole(w,x)
if w.kind~="console"then return false end
if x.level and string.lower(tostring(w.level))~=string.lower(x.level)then return false end
return Contains(w.message,x.contains,x.caseSensitive==true)
end

local function MatchesInstance(w,x,y)
if w.kind~="instance"then return false end
if x.name and w.Name~=x.name then return false end
if x.className and w.ClassName~=x.className then return false end
if not Contains(w.Path,x.pathContains,false)then return false end
if y then
local z=w.Path or""
if z~=y then
if string.sub(z,1,#y)~=y then return false end
local A=string.sub(z,#y+1,#y+1)
if A~="."and A~="["then return false end
end
end
return true
end

local function CursorExpired(w)
local x=EarliestEvent()
return x~=nil and w<x.cursor-1
end

local function WaitForJournal(w,x)
local y=math.max(0.1,math.min((tonumber(w.timeoutMs)or 5000)/1000,30))
local z=tonumber(w.cursor)
if z==nil then z=u.nextCursor end
z=math.max(0,math.floor(z))
local A=CursorExpired(z)
local B=os.clock()+y

repeat
for C=1,u.count do
local D=JournalEventAt(C)
if D.cursor>z and x(D)then
return{
matched=true,
cursor=D.cursor,
event=D,
cursorExpired=A,
}
end
end
task.wait(0.05)
until os.clock()>=B

return{
matched=false,
timedOut=true,
cursor=u.nextCursor,
cursorExpired=A,
earliestAvailableCursor=EarliestEvent()and EarliestEvent().cursor or u.nextCursor,
}
end

local function ExistingConsole(w)
local x,y=pcall(function()return q:GetLogHistory()end)
if not x then return nil end
local z=math.max(1,#y-f+1)
for A=#y,z,-1 do
local B=y[A]
local C={
kind="console",
cursor=u.nextCursor,
message=string.sub(tostring(B.message or""),1,h),
level=B.messageType and B.messageType.Name or"Unknown",
timestamp=B.timestamp,
existing=true,
}
if MatchesConsole(C,w)then return C end
end
return nil
end

local function DescriptionMatches(w,x)
return MatchesInstance({
kind="instance",
Name=w.Name,
ClassName=w.ClassName,
Path=w.Path,
},x)
end

local function QuerySelector(w,x)
local y=w:QueryDescendants(x)
assert(
#y<=i,
"Selector matched over "..tostring(i).." instances; narrow the selector/root."
)
return y
end

local function ExistingInstance(w,x)
if w.selector then
local y=QuerySelector(x,w.selector)
for z,A in ipairs(y)do
local B=b.Describe(A)
if DescriptionMatches(B,w)then return B end
end
return nil
end

local y={x}
local z=1
local A=0
while z<=#y and A<g do
local B=y[z]
z+=1
A+=1
local C=b.Describe(B)
if DescriptionMatches(C,w)then return C end
for D,E in ipairs(B:GetChildren())do
if#y>=g then break end
table.insert(y,E)
end
end
return nil
end

local function WaitForSelector(w,x)
assert(r<k,"Too many selector waits are already active.")
r+=1
local y
local z,A=pcall(function()
local z={}
local A=0
local B=false
local C=false
y=x.DescendantAdded:Connect(function(D)
if z[D]then return end
if A>=l then
B=true
return
end
z[D]=true
A+=1
C=true
end)

if w.includeExisting==true then
for D,E in ipairs(QuerySelector(x,w.selector))do
local F=b.Describe(E)
if DescriptionMatches(F,w)then
F.kind="instance"
F.existing=true
return{matched=true,cursor=u.nextCursor,event=F}
end
end
end

local D=math.max(0.1,math.min((tonumber(w.timeoutMs)or 5000)/1000,30))
local E=os.clock()+D
local F=0
repeat
if C and F<j then
assert(not B,"Too many descendants were added while waiting; narrow the selector/root.")
C=false
F+=1
local G=z
z={}
A=0
for H,I in ipairs(QuerySelector(x,w.selector))do
if G[I]then
local J=b.Describe(I)
if DescriptionMatches(J,w)then
local K=Push("instance",J)
return{
matched=true,
cursor=K.cursor,
event=K,
selectorScans=F,
}
end
end
end
end
task.wait(0.05)
until os.clock()>=E
return{
matched=false,
timedOut=true,
cursor=u.nextCursor,
selectorScans=F,
selectorScanLimitReached=F>=j,
}
end)
if y then y:Disconnect()end
r-=1
if not z then error(A)end
return A
end

local function AttributeMatches(w,x,y)
if w=="exists"then return x~=nil end
if w=="equals"then return x==y end
return true
end

local function WaitForAttribute(w)
local x=b.Resolve(w.target)
local y=w.attribute
local z=w.condition or"changed"
if z=="equals"then assert(w.equals~=nil,"equals value is required.")end
local A=x:GetAttribute(y)
if w.includeExisting==true and z~="changed"and AttributeMatches(z,A,w.equals)then
return{
matched=true,
cursor=u.nextCursor,
event={
kind="attribute",
target=b.Describe(x),
attribute=y,
value=A,
existing=true,
},
}
end

local B
local C=x:GetAttributeChangedSignal(y):Connect(function()
local C=x:GetAttribute(y)
if not AttributeMatches(z,C,w.equals)then return end
B=Push("attribute",{
target=b.Describe(x),
attribute=y,
value=C,
})
end)
local D=math.max(0.1,math.min((tonumber(w.timeoutMs)or 5000)/1000,30))
local E=os.clock()+D
repeat task.wait(0.05)until B or os.clock()>=E
C:Disconnect()

if B then
return{matched=true,cursor=B.cursor,event=B}
end
return{matched=false,timedOut=true,cursor=u.nextCursor}
end

local function RemoteDirections(w)
if w=="Incoming"then return{"Incoming"}end
if w=="Outgoing"then return{"Outgoing"}end
return{"Outgoing","Incoming"}
end

local function RemoteEvent(w,x,y,z)
return{
kind="remote",
direction=y,
remote=b.Describe(w),
method=x.Method,
totalCalls=tonumber(x.TotalCalls)or(type(x.Calls)=="table"and#x.Calls or 0),
existing=z or nil,
}
end

local function WaitForRemote(w)
assert(s<n,"Too many remote waits are already active.")
s+=1
local x,y=pcall(function()
local x=c.Start()
assert(x and x.shared and x.shared.Logs,"Bundled remote spy could not be started.")
local y={Incoming={},Outgoing={}}
local z=RemoteDirections(w.direction)
local A=0

for B,C in ipairs(z)do
local D=x.shared.Logs[C]
if type(D)=="table"then
for E,F in pairs(D)do
A+=1
assert(A<=m,"Remote spy has too many captured remotes; narrow nameContains/direction or clear logs.")
if typeof(E)~="Instance"then continue end
if not Contains(E.Name,w.nameContains,false)then continue end
local G=tonumber(F.TotalCalls)or(type(F.Calls)=="table"and#F.Calls or 0)
y[C][E]=G
if w.includeExisting==true and G>0 then
local H=RemoteEvent(E,F,C,true)
H.cursor=u.nextCursor
return{matched=true,cursor=H.cursor,event=H}
end
end
end
end

local B=math.max(0.1,math.min((tonumber(w.timeoutMs)or 5000)/1000,30))
local C=os.clock()+B
repeat
local D=0
for E,F in ipairs(z)do
local G=x.shared.Logs[F]
if type(G)~="table"then continue end
for H,I in pairs(G)do
D+=1
assert(D<=m,"Remote spy has too many captured remotes; narrow nameContains/direction or clear logs.")
if typeof(H)~="Instance"then continue end
if not Contains(H.Name,w.nameContains,false)then continue end
local J=tonumber(I.TotalCalls)or(type(I.Calls)=="table"and#I.Calls or 0)
if J>(y[F][H]or 0)then
local K=Push("remote",RemoteEvent(H,I,F,false))
return{matched=true,cursor=K.cursor,event=K}
end
y[F][H]=J
end
end
task.wait(0.1)
until os.clock()>=C
return{matched=false,timedOut=true,cursor=u.nextCursor}
end)
s-=1
if not x then error(y)end
return y
end

p:BindToTypeStructured("wait-for-event",function(w)
if w.mode=="console"then
EnsureConsoleJournal()
if w.includeExisting==true then
local x=ExistingConsole(w)
if x then return{matched=true,cursor=x.cursor,event=x}end
end
return WaitForJournal(w,function(x)return MatchesConsole(x,w)end)
elseif w.mode=="instance"then
local x=w.root and b.Resolve(w.root)or game
if w.selector then return WaitForSelector(w,x)end
EnsureInstanceJournal()
if w.includeExisting==true then
local y=ExistingInstance(w,x)
if y then
y.kind="instance"
y.existing=true
return{matched=true,cursor=u.nextCursor,event=y}
end
end
local y=x==game and nil or b.StablePath(x)
return WaitForJournal(w,function(z)return MatchesInstance(z,w,y)end)
elseif w.mode=="attribute"then
return WaitForAttribute(w)
elseif w.mode=="remote"then
return WaitForRemote(w)
end
error("Unsupported wait mode: "..tostring(w.mode))
end)
end end function a.Q():typeof(__modImpl())local b=a.cache.Q if not b then b={c=__modImpl()}a.cache.Q=b end return b.c end end do local function __modImpl()

return function(b)
local c=b.CreateBridge
local d=b.WaitForBridgeClientId
local e=b.ScriptMappingPipeline
local f=b.StartUploadQueue
local g=b.PublishScriptMappingStatus
local h=b.ResetScriptMappingState
local i=b.StartScriptMapping
local j=b.StartFailedScriptResync
local k=b.ResumeDeferredScriptMappings
local l=b.ToastHost

while true do
local m,n=pcall(c)

if not m then
task.wait(3)
continue
end

local o=d(n)
if o then
pcall(function()
l:ShowConnected(n.WebSocket and"ws"or"http")
end)
e.bridge=n
f()

local p=e.clientId~=o
if p then
h(o)
end

local q=(
getgenv().EnableInitialScriptDecompMapping==true or
getgenv().DisableInitialScriptDecompMapping==false
)and getgenv().DisableInitialScriptDecompMapping~=true

if q or(not p and e.disabled~=true)then
i(o)
j()
k()
g()
else
e.clientId=o
e.disabled=true
e.stateVersion+=1
g()
end
end

local p={a.u()
,a.v()
,a.w()
,a.y()
,a.z()
,a.A()
,a.B()
,a.C()
,a.G()
,a.H()
,a.I()
,a.J()
,a.K()
,a.L()
,a.M()
,a.N()
,a.O()
,a.P()
,a.Q()
,
}
local q={}
local r,s=pcall(function()
for r,s in p do
local t=s(b,n)
if type(t)=="function"then table.insert(q,t)end
end
n:WaitForDisconnect()
end)
for t=#q,1,-1 do pcall(q[t])end

if e.bridge==n then
e.bridge=nil
end
if not r then
n.Connected=false
for t,u in{n.AliveThread,n.PollThread}do
pcall(task.cancel,u)
end
pcall(function()if n.WebSocket then n.WebSocket:Close()end end)
error(s,0)
end
task.wait(1)
end
end end function a.R():typeof(__modImpl())local b=a.cache.R if not b then b={c=__modImpl()}a.cache.R=b end return b.c end end end





if not game:IsLoaded()then
game.Loaded:Wait()
end


if getgenv().MCP_Loaded==true or getgenv().MCP_Loading==true then
return
end

getgenv().MCP_Loading=true
task.delay(30,function()
if getgenv().MCP_Loaded~=true then
getgenv().MCP_Loading=nil
end
end)

local b=getgenv().BridgeURL or getgenv().bridgeurl or...or"localhost:16384"
b=tostring(b):gsub("/+$","")
local c
local d
if string.match(b,"^https://")then
c=b
d="wss://"..string.sub(b,9)
elseif string.match(b,"^http://")then
c=b
d="ws://"..string.sub(b,8)
elseif string.match(b,"^wss://")then
d=b
c="https://"..string.sub(b,7)
elseif string.match(b,"^ws://")then
d=b
c="http://"..string.sub(b,6)
else
c="http://"..b
d="ws://"..b
end
getgenv().BridgeURL=b
getgenv().bridgeurl=b
local e=getgenv().MCPAuthToken or getgenv().BridgeAuthToken
if type(e)~="string"then e=""end

local function BridgeRequestHeaders(f)
local g={}
for h,i in f or{}do
g[h]=i
end
if e~=""then
g["X-Roblox-MCP-Token"]=e
end
local h=getgenv().MCP_ClientToken
if type(h)=="string"and h~=""then
g["X-Roblox-MCP-Client-Token"]=h
end
return g
end


local f=cloneref or function(f)return f end

local g:VirtualInputManager=f(Instance.new"VirtualInputManager")
local h:MarketplaceService=f(game:GetService"MarketplaceService")
local i:CoreGui=f(game:GetService"CoreGui")
local j:CorePackages=f(game:GetService"CorePackages")
local k:ScriptContext=f(game:GetService"ScriptContext")
local l:HttpService=f(game:GetService"HttpService")
local m:LogService=f(game:GetService"LogService")
local n:Players=f(game:GetService"Players")
local o:TweenService=f(game:GetService"TweenService")



local p
do




local q='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'


p=base64encode or function(r)
return((r:gsub('.',function(s)
local t,u='',s:byte()
for v=8,1,-1 do t=t..(u%2^v-u%2^(v-1)>0 and'1'or'0')end
return t
end)..'0000'):gsub('%d%d%d?%d?%d?%d?',function(s)
if(#s<6)then return''end
local t=0
for u=1,6 do t=t+(s:sub(u,u)=='1'and 2^(6-u)or 0)end
return q:sub(t+1,t+1)
end)..({'','==','='})[#r%3+1])
end
end



local q=type(getscripthash)=="function"and getscripthash or nil
local r=type(decompile)=="function"and decompile or nil

local s=a.a()




local t=8
local u=256
local v=2000
local w=500
local x=131072

local function SanitizeString(y,z)
y=tostring(y)
local A=math.max(0,math.min(w,z.stringBytes))
if A==0 then return"<string omitted: output budget reached>"end

local B={}
local C=0
local D=pcall(function()
for D,E in utf8.codes(y)do
local F=utf8.char(E)
if C+#F>A then break end
table.insert(B,F)
C+=#F
end
end)
local E
if D then
E=table.concat(B)
else
E=string.sub(string.gsub(y,"[^%g ]","?"),1,A)
C=#E
end

z.stringBytes=math.max(0,z.stringBytes-C)
return#E<#y and(E.."...(truncated)")or E
end

local function SanitizeForOutput(y,z,A,B)
z=z or 0
B=B or{
entries=v,
stringBytes=x,
}
local C=typeof(y)

if C=="Instance"then
local D,E=pcall(function()return y:GetFullName()end)
return SanitizeString(D and E or y,B)
elseif C=="string"then
return SanitizeString(y,B)
elseif C=="number"then
if y~=y then return"<nan>"end
if y==math.huge then return"<infinity>"end
if y==-math.huge then return"<-infinity>"end
return y
elseif C=="boolean"or C=="nil"then
return y
elseif C~="table"then

local D,E=pcall(tostring,y)
return SanitizeString(D and E or"<unprintable value>",B)
end

if z>=t then
return"<table: max depth reached>"
end

A=A or{}
if A[y]then
return"<cyclic table>"
end
A[y]=true

local D={}
local E=#y
local F=E>0
if F then
local G=0
for H in pairs(y)do
G+=1
if type(H)~="number"or H%1~=0 or H<1 or H>E then
F=false
break
end
if G>=u+1 then break end
end
end

if F then
local G=math.min(E,u)
local H=0
for I=1,G do
if B.entries<=0 then break end
B.entries-=1
H+=1
D[I]=SanitizeForOutput(y[I],z+1,A,B)
end
if E>H then
D[H+1]={
__omitted=tostring(E-H).." additional array entries omitted",
}
end
A[y]=nil
return D
end

local G=0
local H=false
for I,J in pairs(y)do
if G>=u or B.entries<=0 then
H=true
break
end
G+=1
B.entries-=1


local K=SanitizeString(typeof(I)=="string"and I or tostring(I),B)
D[K]=SanitizeForOutput(J,z+1,A,B)
end
if H then
D.__omitted="additional entries omitted"
end

A[y]=nil
return D
end



local function StripDecompilerBanner(y)
if typeof(y)~="string"then return y end
return(string.gsub(y,"^%s*%-%-[^\n]*[Dd]ecompiled[^\n]*\n","",1))
end

local y=getnilinstances or function()return{}end


local z,A=a.b().Resolve(getgenv())



local function ResolveWebSocketConnect()
if typeof(WebSocket)=="table"then
if type(WebSocket.connect)=="function"then return WebSocket.connect end
if type(WebSocket.Connect)=="function"then return WebSocket.Connect end
end
if typeof(websocket)=="table"then
if type(websocket.connect)=="function"then return websocket.connect end
if type(websocket.Connect)=="function"then return websocket.Connect end
end
if typeof(syn)=="table"and typeof(syn.websocket)=="table"then
if type(syn.websocket.connect)=="function"then return syn.websocket.connect end
if type(syn.websocket.Connect)=="function"then return syn.websocket.Connect end
end
return nil
end

local B=ResolveWebSocketConnect()
local C=B~=nil and getgenv().DisableWebSocket~=true


local function GenerateSessionGuid()
local D,E=pcall(function()
return l:GenerateGUID(false)
end)
if D and type(E)=="string"and E~=""then
return E
end
return tostring(os.clock()).."-"..tostring(math.random(1,1000000000))
end

local function GetClientIdentityKey()
local D=n.LocalPlayer
return table.concat({
tostring(game.PlaceId or 0),
tostring(game.JobId or""),
tostring(D and D.UserId or 0),
},":")
end

local function GetStableClientSessionId()
local D=GetClientIdentityKey()
if type(getgenv().MCP_ClientSessionId)~="string"or getgenv().MCP_ClientIdentityKey~=D then
getgenv().MCP_ClientSessionId=GenerateSessionGuid()
getgenv().MCP_ClientIdentityKey=D
end
return getgenv().MCP_ClientSessionId
end

local function GetRegistrationInfo()
local D=n.LocalPlayer
local E="Unknown"
pcall(function()
local F=h:GetProductInfo(game.PlaceId)
E=F.Name
end)
return{
type="register",
username=D and D.Name or"Unknown",
userId=D and D.UserId or 0,
placeId=game.PlaceId,
jobId=game.JobId,
placeName=E,
sessionId=GetStableClientSessionId(),
clientToken=getgenv().MCP_ClientToken,
}
end



local D=a.c().new{
RegistryId=GenerateSessionGuid(),
MaxHandles=getgenv().MCP_RuntimeMaxHandles,
DefaultTtlSeconds=getgenv().MCP_RuntimeHandleTtlSeconds,
}
local E=a.e().new{
Handles=D,
DefaultDepth=getgenv().MCP_RuntimeValueDepth,
DefaultEntries=getgenv().MCP_RuntimeValueEntries,
DefaultStringBytes=getgenv().MCP_RuntimeValueStringBytes,
}
local F=a.f().new{
ConnectorVersion="3",
RequestAvailable=z~=nil,
HttpRequestProvider=A,
WebSocketAvailable=C,
}
local G=a.g().new{
Handles=D,
TypedValues=E,
MaxSnapshots=getgenv().MCP_GcMaxSnapshots,
DefaultScanLimit=getgenv().MCP_GcDefaultScanLimit,
TableScanLimit=getgenv().MCP_GcTableScanLimit,
}
local H=a.h(){
CoreGui=i,
TweenService=o,
}


local I=a.i(){
HttpService=l,
BridgeHTTPURL=c,
BridgeWebSocketURL=d,
BridgeAuthToken=e,
BridgeRequestHeaders=BridgeRequestHeaders,
Request=z,
HttpGet=function(I)return game:HttpGet(I)end,
WebSocketAvailable=C,
WebSocketConnect=B,
GetRegistrationInfo=GetRegistrationInfo,
SanitizeForOutput=SanitizeForOutput,
LuaEncode=s,
}
local J=I.CreateBridge


local K=a.j()
local L=a.k()
local M=a.l()
local N=a.m()
local O=a.n()
local P=L.new()
local Q=math.max(
1,
math.min(math.floor(tonumber(getgenv().MCP_ScriptMappingWorkers)or 24),64)
)
local R=a.o().new(
P,
Q
)
local S=math.max(
5,
math.min(tonumber(getgenv().MCP_FailedScriptResyncInterval)or 30,600)
)
local T=a.p().new(P,{
IntervalSeconds=S,
MaxDelaySeconds=math.max(S,300),
BatchSize=math.max(
1,
math.min(math.floor(tonumber(getgenv().MCP_FailedScriptResyncBatchSize)or 8),32)
),
})
local U=a.q().new(
P,
T
)
local V=a.r(){
ScriptMappingPipeline=P,
HttpService=l,
BridgeHTTPURL=c,
BridgeRequestHeaders=BridgeRequestHeaders,
Request=z,
JobStatus=U,
}
local W=a.s(){
ScriptMappingPipeline=P,
HttpService=l,
BridgeHTTPURL=c,
BridgeRequestHeaders=BridgeRequestHeaders,
Request=z,
StripDecompilerBanner=StripDecompilerBanner,
base64_encode=p,
BuiltInDecompile=r,
GetScriptHash=q,
DecompilerAttemptState=N,
PreparedScript=O,
Concurrency=R,
}
local X=a.t(){
ScriptMappingPipeline=P,
WorkerPool=K,
UploadSession=M,
GenerateSessionGuid=GenerateSessionGuid,
CoreGui=i,
CorePackages=j,
ScriptContext=k,
getnilinstances=y,
WorkerCount=Q,
Concurrency=R,
JobStatus=U,
FailedResync=T,
UploadClient=V,
DecompilerClient=W,
}
local Y=V.StartUploadQueue
local function PublishScriptMappingStatus()
U:Publish()
end
local Z=X.StartScriptMapping
local aa=X.StartFailedScriptResync
local ab=X.ResetScriptMappingState
local ac=X.ResumeDeferredScriptMappings
local ad=X.GetScriptByDebugId
local ae=X.QueueMappedScriptSource
local af=X.DecompileScriptSource

local function WaitForBridgeClientId(ag)
local ah=os.clock()+5
repeat
if ag.ClientId then
return ag.ClientId
end
if not ag.Connected then
return nil
end
task.wait(0.05)
until os.clock()>ah

return nil
end

getgenv().MCP_Loaded=true
getgenv().MCP_Loading=nil
local ag,ah=pcall(function()a.R()
{
CreateBridge=J,
WaitForBridgeClientId=WaitForBridgeClientId,
ScriptMappingPipeline=P,
StartUploadQueue=Y,
PublishScriptMappingStatus=PublishScriptMappingStatus,
ResetScriptMappingState=ab,
StartScriptMapping=Z,
StartFailedScriptResync=aa,
ResumeDeferredScriptMappings=ac,
GetScriptByDebugId=ad,
DecompileScriptSource=af,
QueueMappedScriptSource=ae,
LogService=m,
MarketplaceService=h,
VirtualInputManager=g,
Players=n,
LuaEncode=s,
WebSocketAvailable=C,
RequestAvailable=z~=nil,
HttpRequestProvider=A,
RuntimeHandles=D,
RuntimeValues=E,
RuntimeCapabilities=F,
GcExplorer=G,
ToastHost=H,
}
end)
if not ag then
getgenv().MCP_Loaded=nil
getgenv().MCP_Loading=nil
error(ah)
end