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

return b end function a.b():typeof(__modImpl())local b=a.cache.b if not b then b={c=__modImpl()}a.cache.b=b end return b.c end end do local function __modImpl()



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

local function ResolveSegment(e,f)
local g=e:FindFirstChild(f)
if g then return g end



local h,i=pcall(function()
return e[f]
end)
if h and typeof(i)=="Instance"then return i end
return nil
end

function b.Resolve(e)
assert(type(e)=="table","Instance target must be an object.")

local f
local g
if e.path~=nil then
assert(e.pathSegments==nil,"Provide path or pathSegments, not both.")
f,g=ParsePath(e.path)
else
assert(type(e.pathSegments)=="table","Provide path or pathSegments.")
f=e.root=="workspace"and workspace or game
g=e.pathSegments
assert(#g>0 and#g<=c,"pathSegments must contain 1-100 names.")
end

local h=f
for i,j in ipairs(g)do
assert(type(j)=="string"and#j<=200,"Invalid path segment at index "..tostring(i)..".")
local k=ResolveSegment(h,j)
assert(k,"Instance path was not found at segment "..tostring(i).." ("..j..").")
h=k
end

return h
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

return b end function a.c():typeof(__modImpl())local b=a.cache.c if not b then b={c=__modImpl()}a.cache.c=b end return b.c end end do local function __modImpl()

local b=a.c()

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

return c end function a.d():typeof(__modImpl())local b=a.cache.d if not b then b={c=__modImpl()}a.cache.d=b end return b.c end end do local function __modImpl()

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
WebSocketAvailable=c.WebSocketAvailable==true,
},b)
end

function b.Probe(c)
local d=type(debug)=="table"and debug or{}
local e={
Descriptor("transport.request",IsFunction(request),"executor-api","exact"),
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

return b end function a.e():typeof(__modImpl())local b=a.cache.e if not b then b={c=__modImpl()}a.cache.e=b end return b.c end end do local function __modImpl()

local b=a.c()

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

return c end function a.f():typeof(__modImpl())local b=a.cache.f if not b then b={c=__modImpl()}a.cache.f=b end return b.c end end do local function __modImpl()

return function(b)
local c=b.HttpService
local d=b.BridgeHTTPURL
local e=b.BridgeWebSocketURL
local f=b.BridgeAuthToken
local g=b.BridgeRequestHeaders
local h=b.WebSocketAvailable
local i=b.WebSocketConnect
local j=b.GetRegistrationInfo
local k=b.SanitizeForOutput
local l=b.LuaEncode
local m=0
local n=30

local function EncodeBridgeResponse(o)
local p,q=pcall(function()
return c:JSONEncode(o)
end)
if p then return q end
return c:JSONEncode{
id=type(o)=="table"and o.id or nil,
success=false,
error="Failed to serialize connector response: "..string.sub(tostring(q),1,300),
}
end


local o={};do
o.__index=o

function o.BindToType(p,q,r)
p.Callbacks[q]=r
end

function o.BindToTypeRaw(p,q,r)
p.Callbacks[q]=r
p.RawCallbacks=p.RawCallbacks or{}
p.RawCallbacks[q]=true
end

function o.BindToTypeStructured(p,q,r)
p.Callbacks[q]=r
p.StructuredCallbacks=p.StructuredCallbacks or{}
p.StructuredCallbacks[q]=true
end

function o.CreateAlias(p,q,r)
for s,t in r do
p.Callbacks[t]=p.Callbacks[q]
if p.RawCallbacks and p.RawCallbacks[q]then
p.RawCallbacks[t]=true
end
if p.StructuredCallbacks and p.StructuredCallbacks[q]then
p.StructuredCallbacks[t]=true
end
end
end

function o.HandleMessage(p,q)
if p.Callbacks[q.type]then
local r,s=pcall(function()
return p.Callbacks[q.type](q)
end)

if r and s==nil then
return nil
end

if not r then
return p:FormatResponse(s,q.id,true)
end

if p.RawCallbacks and p.RawCallbacks[q.type]then
return{
output=tostring(s),
success=true,
id=q.id
}
end

return p:FormatResponse(
s,
q.id,
false,
p.StructuredCallbacks and p.StructuredCallbacks[q.type]==true
)
end
return nil
end

function o.FormatResponse(p,q,r,s,t)
if s then
return{
error=tostring(q),
success=false,
id=r
}
end

local u=k(q)
if typeof(u)~="table"then
u={u}
end

local v={
output=l(u,{
Prettify=false
}),
success=true,
id=r
}
if t then
v.structured=u
end
return v
end

function o.IsAlive(p)
local q,r=pcall(function()
local q
local r=task.spawn(function()
local r,s=pcall(request,{
Url=d,
Method="GET",
Headers=g()
})

if r then
q=s
end
end)

local s=os.clock()
repeat task.wait(0.05)until q~=nil or os.clock()-s>5

if q==nil then
task.cancel(r)
return false
end


if q.StatusCode==426 or q.StatusCode==200 then
return true
end

return false
end)

if not q then
return false
end

return r
end
end


local p=setmetatable({},{__index=o});do
p.__index=p

function p.new()
local q=setmetatable({},p)


local r=0.5
local s=5
local t=10
local u=0

while not q:IsAlive()do
u+=1
if u>=t then
error("Failed to connect to bridge server after "..t.." attempts")
end
task.wait(r)
r=math.min(r*1.5,s)
end


local v
local w=false
local x=task.spawn(function()
local x,y=pcall(function()
local x=e
if f~=""then
x..="?token="..c:UrlEncode(f)
end
return i(x)
end)
if x then
v=y
end
w=true
end)

local y=os.clock()
repeat task.wait(0.05)until v~=nil or w or os.clock()-y>5

if v==nil then
if not w then
task.cancel(x)
end
error(w and"WebSocket connection failed"or"WebSocket connection timed out after 5 seconds")
end

q.WebSocket=v
q.Connected=true
q.Callbacks={}
q.ClientId=nil


q.WebSocket:Send(c:JSONEncode(j()))

q.AliveThread=task.spawn(function()
local z=0
while task.wait(1)do
if not q.Connected then
continue
end

if q:IsAlive()then
z=0
continue
end

z+=1
if z<3 then
continue
end

q.Connected=false
break
end

pcall(function()
q.WebSocket:Close()
end)
end)


q.WebSocket.OnMessage:Connect(function(z)
local A=c:JSONDecode(z)


if A.type=="registered"then
q.ClientId=A.clientId
q.ClientToken=A.clientToken
getgenv().MCP_ClientToken=A.clientToken
return
end

local B=q:HandleMessage(A)
if B then
q.WebSocket:Send(EncodeBridgeResponse(B))
end
end)


q.WebSocket.OnClose:Connect(function()
q.Connected=false
end)

return q
end

function p.WaitForDisconnect(q)
while q.Connected do
task.wait(0.1)
end
end
end


local q=setmetatable({},{__index=o});do
q.__index=q

function q.new()
local r=setmetatable({},q)


local s=0.5
local t=5
local u=10
local v=0

while not r:IsAlive()do
v+=1
if v>=u then
error("Failed to connect to bridge server after "..u.." attempts")
end
task.wait(s)
s=math.min(s*1.5,t)
end

r.Connected=true
r.Callbacks={}
r.PollInterval=0.1
r.ClientId=nil


local w,x=pcall(function()
local w=request{
Url=d.."/register",
Method="POST",
Headers=g{["Content-Type"]="application/json"},
Body=c:JSONEncode(j()),
}
if w.StatusCode==200 and w.Body then
local x=c:JSONDecode(w.Body)
r.ClientId=x.clientId
r.ClientToken=x.clientToken
getgenv().MCP_ClientToken=x.clientToken
end
end)
if not w or type(r.ClientId)~="string"or type(r.ClientToken)~="string"then
r.Connected=false
error("Bridge HTTP registration failed: "..tostring(x or"server rejected registration"))
end


r.PollThread=task.spawn(function()
local y=0

while r.Connected do
local z=false local
A=pcall(function()
local A=d.."/poll"
if r.ClientId then
A=A.."?clientId="..r.ClientId
end
local B=request{
Url=A,
Method="GET",
Headers=g()
}


if B.StatusCode~=204 and B.StatusCode~=200 then
y+=1
if y>=3 then
r.Connected=false
end

return
end

y=0


if B.Body and B.Body~=""then
local C=c:JSONDecode(B.Body)
local D={}
if typeof(C)=="table"and C.type==nil and#C>0 then
D=C
elseif typeof(C)=="table"and C.type~=nil then
D={C}
end

for E,F in ipairs(D)do
z=true
task.spawn(function()
local G=r:HandleMessage(F)
if G==nil then return end
G.clientId=r.ClientId


request{
Url=d.."/respond?clientId="..c:UrlEncode(r.ClientId),
Method="POST",
Headers=g{
["Content-Type"]="application/json"
},
Body=EncodeBridgeResponse(G)
}
end)
end
end
end)

if not A then
y+=1
if y>=3 then
r.Connected=false
end
end

if not z then
task.wait(r.PollInterval)
end
end
end)

return r
end

function q.WaitForDisconnect(r)
while r.Connected do
task.wait(0.1)
end
end
end


local function CreateBridge()
if h and os.clock()>=m then
local r,s=pcall(function()
return p.new()
end)

if r then
m=0
return s
end



m=os.clock()+n
end

return q.new()
end

return{
CreateBridge=CreateBridge,
}
end end function a.g():typeof(__modImpl())local b=a.cache.g if not b then b={c=__modImpl()}a.cache.g=b end return b.c end end do local function __modImpl()

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

return b end function a.h():typeof(__modImpl())local b=a.cache.h if not b then b={c=__modImpl()}a.cache.h=b end return b.c end end do local function __modImpl()

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

return b end function a.i():typeof(__modImpl())local b=a.cache.i if not b then b={c=__modImpl()}a.cache.i=b end return b.c end end do local function __modImpl()

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

return b end function a.j():typeof(__modImpl())local b=a.cache.j if not b then b={c=__modImpl()}a.cache.j=b end return b.c end end do local function __modImpl()

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

return b end function a.k():typeof(__modImpl())local b=a.cache.k if not b then b={c=__modImpl()}a.cache.k=b end return b.c end end do local function __modImpl()

local b=a.k()

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

return c end function a.l():typeof(__modImpl())local b=a.cache.l if not b then b={c=__modImpl()}a.cache.l=b end return b.c end end do local function __modImpl()

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

return b end function a.m():typeof(__modImpl())local b=a.cache.m if not b then b={c=__modImpl()}a.cache.m=b end return b.c end end do local function __modImpl()

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

return b end function a.n():typeof(__modImpl())local b=a.cache.n if not b then b={c=__modImpl()}a.cache.n=b end return b.c end end do local function __modImpl()

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

return b end function a.o():typeof(__modImpl())local b=a.cache.o if not b then b={c=__modImpl()}a.cache.o=b end return b.c end end do local function __modImpl()

return function(b)
local c=b.ScriptMappingPipeline
local d=b.HttpService
local e=b.BridgeHTTPURL
local f=b.BridgeRequestHeaders
local g=b.JobStatus
local h=64
local i=8388608
local j=0.5
local k=5
local l=8

local function IsScriptMappingTransportReady(m)
return(
c.bridge~=nil and
c.bridge.Connected==true and
c.bridge.ClientId~=nil and
c.bridge.ClientId==m
)
end

local function UploadScriptSourceBatch(m,n)
if not m then return false end
if not IsScriptMappingTransportReady(m)then return false end
local o=c.generation
local p=c.session
if not p then return false end

local q={}
local r={}
for s,t in n or{}do
if t.kind=="remove"then
table.insert(r,t.debugId)
else
table.insert(q,{
debugId=t.debugId,
path=t.path,
source=t.source,
scriptHash=t.scriptHash,
})
end
end

local s=#q
local t=math.min(c.total,c.processed+s)
local u=c:IsFinished(t)
local v=p:NextRevision()

local w,x=pcall(request,{
Url=e.."/script-sources",
Method="POST",
Headers=f{
["Content-Type"]="application/json"
},
Body=d:JSONEncode{
clientId=m,
scripts=q,
removedScriptIds=r,
hasFinishedMapping=u,
sourcesToMap=c.total,
processedSources=t,
skippedSources=c.skipped,
mappingSessionId=p.id,
mappingSessionStartedAt=p.startedAt,
mappingRevision=v,
beginMappingSession=not p.started,
}
})

if not w or not x or x.StatusCode~=200 then return false,v end

if(
not c:IsActiveSession(p,o,m)
)then
return false,v,"stale_session"
end

local y=v
if type(x.Body)=="string"and x.Body~=""then
local z,A=pcall(function()
return d:JSONDecode(x.Body)
end)
if z and type(A)=="table"and type(A.acceptedMappingRevision)=="number"then
y=A.acceptedMappingRevision
end
end
if y~=v then return false,v end

p:MarkStarted()
return true,v
end

local function EnqueueScriptSourceUpload(m)
m.queuedBytes=if type(m.source)=="string"then#m.source else 0
c.upload.tail+=1
c.upload.queue[c.upload.tail]=m
c.upload.bytes+=m.queuedBytes
end

local function DequeueScriptSourceUpload()
if c.upload.head>c.upload.tail then return nil end
local m=c.upload.queue[c.upload.head]
c.upload.queue[c.upload.head]=nil
c.upload.head+=1
if m then c.upload.bytes=math.max(0,c.upload.bytes-(m.queuedBytes or 0))end
return m
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
task.wait(j)
continue
end
if c.upload.head>c.upload.tail then
if c.statusDirty then
local m=c.stateVersion
local n=UploadScriptSourceBatch(
c.clientId,
{}
)
if n and c.stateVersion==m then
c.statusDirty=false
end
end
task.wait(j)
continue
end

local m={}
local n=0
while c.upload.head<=c.upload.tail and#m<h do
local o=c.upload.queue[c.upload.head]
local p=if o and type(o.source)=="string"then#o.source else 0
if#m>0 and n+p>i then break end

local q=DequeueScriptSourceUpload()
if not q then continue end
local r=c.jobs[q.debugId]
local s=q.generation==c.generation and r~=nil
local t=s and(
(q.kind=="source"and r.state=="awaiting_upload")or
(q.kind=="remove"and r.state=="removed")
)
if t then
table.insert(m,q)
n+=p
end
end
if#m==0 then continue end

local o=c.stateVersion
local p=UploadScriptSourceBatch(c.clientId,m)
if p then
local q=0
for r,s in m do
if s.kind=="source"and s.generation==c.generation then
if g:MarkMapped(s.debugId,false)then
q+=1
end
end
end
c.statusDirty=
c.stateVersion~=o+q
else
local q=false
for r=#m,1,-1 do
local s=m[r]
if s.generation~=c.generation then
continue
end

s.attempts=(s.attempts or 0)+1
if s.kind=="source"and s.attempts>=k then
q=g:MarkFailed(
s.debugId,
"Source upload failed after "..tostring(s.attempts).." attempts.",
false
)or q
else
EnqueueScriptSourceUpload(s)
end
end
if q then g:Publish()end
local r=m[1]and m[1].attempts or 1
task.wait(math.min(2^math.max(0,r-1),l))
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
end end function a.p():typeof(__modImpl())local b=a.cache.p if not b then b={c=__modImpl()}a.cache.p=b end return b.c end end do local function __modImpl()

return function(b)
local c=b.ScriptMappingPipeline
local d=b.HttpService
local e=b.BridgeHTTPURL
local f=b.BridgeRequestHeaders
local g=b.StripDecompilerBanner
local h=b.base64_encode
local i=b.BuiltInDecompile
local j=b.GetScriptHash
local k=b.DecompilerAttemptState
local l=b.PreparedScript
local m=b.Concurrency
local n=256
local o=1024
local p=33554432
local q=2097152
local r=2
local s=3
local t=8
local u=65
local v={
providerId=nil,
expiresAt=0,
refreshToken=nil,
blockedBuiltinUntil=0,
}
local w={
startedAt=nil,
lastAt=nil,
samples=0,
lastReportAt=0,
revision=0,
}

local function RunWithTimeout(x,y)
local z=false
local A=false
local B

local C=task.spawn(function()
A,B=pcall(y)
z=true
end)

local D=os.clock()+x
while not z and os.clock()<D do
task.wait(0.05)
end

if not z then
pcall(task.cancel,C)
return false,"Timed out after "..tostring(x).."s."
end

if not A then
return false,B
end

return true,B
end

local function RememberScriptSourceForHash(x,y)
if type(x)~="string"or x==""or#x>512 then return false end
if type(y)~="string"or y==""then return false end

local z=c.sourceCacheByHash[x]
if z then
c.sourceCacheBytes=math.max(
0,
c.sourceCacheBytes-#z
)
else
c.sourceCacheEntries+=1
end

if#y>q then
c.sourceCacheByHash[x]=nil
c.sourceCacheSequenceByHash[x]=nil
c.sourceCacheEntries=math.max(
0,
c.sourceCacheEntries-1
)
c.sourceCacheCheckedByHash[x]=true
return false
end

c.sourceCacheSequence+=1
local A=c.sourceCacheSequence
c.sourceCacheByHash[x]=y
c.sourceCacheSequenceByHash[x]=A
c.sourceCacheBytes+=#y
c.sourceCacheOrderTail+=1
c.sourceCacheOrder[c.sourceCacheOrderTail]={
hash=x,
sequence=A,
}
c.sourceCacheCheckedByHash[x]=true

while(
c.sourceCacheEntries>o or
c.sourceCacheBytes>p
)do
local B=c.sourceCacheOrderHead
local C=c.sourceCacheOrder[B]
if not C then break end
c.sourceCacheOrder[B]=nil
c.sourceCacheOrderHead=B+1

if c.sourceCacheSequenceByHash[C.hash]==C.sequence then
local D=c.sourceCacheByHash[C.hash]
c.sourceCacheByHash[C.hash]=nil
c.sourceCacheSequenceByHash[C.hash]=nil
c.sourceCacheEntries=math.max(
0,
c.sourceCacheEntries-1
)
c.sourceCacheBytes=math.max(
0,
c.sourceCacheBytes-(type(D)=="string"and#D or 0)
)
end
end

if(
c.sourceCacheOrderTail-
c.sourceCacheOrderHead+1
)>o*4 then
local B={}
for C,D in c.sourceCacheSequenceByHash do
table.insert(B,{hash=C,sequence=D})
end
table.sort(B,function(C,D)return C.sequence<D.sequence end)
c.sourceCacheOrder=B
c.sourceCacheOrderHead=1
c.sourceCacheOrderTail=#B
end
return true
end

local function ReadScriptHash(x)
if type(j)~="function"then return nil end

local y,z=RunWithTimeout(r,function()
return j(x)
end)

if not y or type(z)~="string"or z==""then
return nil
end

return z
end

local function GetScriptHashForInstance(x)
local y=x:GetDebugId()
if c.scriptHashByDebugId[y]~=nil then
return c.scriptHashByDebugId[y]or nil
end

local z=ReadScriptHash(x)
c.scriptHashByDebugId[y]=z or false
return z
end

local function FetchCachedScriptSourceBatch(x,y)
if#y==0 then return true end

local z,A=pcall(request,{
Url=e.."/script-source-cache",
Method="POST",
Headers=f{
["Content-Type"]="application/json",Accept=
"application/json",
},
Body=d:JSONEncode{
clientId=x,
hashes=y,
},
})

if not z or type(A)~="table"or A.StatusCode~=200 or type(A.Body)~="string"then
return false
end

local B,C=pcall(function()
return d:JSONDecode(A.Body)
end)
if not B or type(C)~="table"or type(C.sources)~="table"then
return false
end

for D,E in ipairs(C.sources)do
if type(E)=="table"then
RememberScriptSourceForHash(E.scriptHash,E.source)
end
end

return true
end

local function FetchCachedScriptSources(x,y)
if type(request)~="function"then return end
if type(x)~="string"or x==""then return end
if type(y)~="table"then return end

local z={}
local A={}
local function flush()
local B=FetchCachedScriptSourceBatch(x,z)
if B then
for C,D in z do
c.sourceCacheCheckedByHash[D]=true
end
end
table.clear(z)
end

for B,C in ipairs(y)do
if(
type(C)=="string"and
C~=""and
not c.sourceCacheByHash[C]and
not c.sourceCacheCheckedByHash[C]and
not A[C]
)then
A[C]=true
table.insert(z,C)
if#z>=n then
flush()
end
end
end

flush()
end

local function ReadScriptBytecode(x)
local y,z=RunWithTimeout(s,function()
return getscriptbytecode(x)
end)
if not y or z==nil then
return false,z or"Failed to read script bytecode."
end
return true,z
end

local function TryBuiltInDecompile(x)
if type(i)~="function"then
return nil,0,"Executor built-in decompile is unavailable.",false
end

local y=os.clock()
local z,A=RunWithTimeout(t,function()
return i(x)
end)
local B=math.floor((os.clock()-y)*1000)
if not z then
local C=tostring(A or"Built-in decompile failed.")
return nil,B,C,string.find(C,"Timed out",1,true)~=nil
end
if type(A)~="string"or A==""then
return nil,B,"Built-in decompile returned no source.",false
end

return g(A),B
end

local function IsActiveMappingContext(x,y)
return(
x==c.generation and
y~=nil and
y==c.clientId
)
end

local function RefreshDecompilerPlan(x,y,z)
y=y or c.generation
z=z or c.clientId
if not IsActiveMappingContext(y,z)then return nil end
local A=os.clock()
if not x and v.expiresAt>A then
return v.providerId
end
if v.refreshToken then
local B=A+2
repeat task.wait()until not v.refreshToken or os.clock()>=B
return v.providerId
end
if type(request)~="function"then return nil end

local B={}
v.refreshToken=B

local C,D=RunWithTimeout(5,function()
return request{
Url=e.."/decompile-plan?clientId="..d:UrlEncode(z),
Method="GET",
Headers=f{Accept=
"application/json",
},
}
end)
if v.refreshToken~=B then return nil end
v.refreshToken=nil
if not IsActiveMappingContext(y,z)then return nil end
if not C or type(D)~="table"or D.StatusCode~=200 or type(D.Body)~="string"then
v.providerId=nil
v.expiresAt=A+0.25
return nil
end

local E,F=pcall(function()
return d:JSONDecode(D.Body)
end)
if not E or type(F)~="table"then
v.providerId=nil
v.expiresAt=A+0.25
return nil
end

v.providerId=if type(F.providerId)=="string"then F.providerId else nil
local G=math.max(0.25,math.min((tonumber(F.ttlMs)or 1000)/1000,5))
v.expiresAt=os.clock()+G
return v.providerId
end

local function ShouldUseDirectBuiltIn(x,y,z)
if x~="builtin"then return false end
if v.blockedBuiltinUntil>os.clock()then return false end
return type(i)=="function"and RefreshDecompilerPlan(false,y,z)=="builtin"
end

local function PostBuiltInObservation(x,y,z)
if not IsActiveMappingContext(y,z)then return end
local A=c.session
if not A then return end
w.revision+=1
x.clientId=z
x.providerId="builtin"
x.observationSessionId=A.id
x.observationSessionStartedAt=A.startedAt
x.observationRevision=w.revision
x.beginObservationSession=true
task.defer(function()
if not IsActiveMappingContext(y,z)then return end
pcall(request,{
Url=e.."/decompiler-observations",
Method="POST",
Headers=f{
["Content-Type"]="application/json",Accept=
"application/json",
},
Body=d:JSONEncode(x),
})
end)
end

local function ReportBuiltInDecompileSuccess(x,y,z)
if not IsActiveMappingContext(y,z)then return end
local A=os.clock()
if w.lastAt==nil or A-w.lastAt>2 then
w.startedAt=A
w.samples=0
end

w.lastAt=A
w.startedAt=w.startedAt or A
w.samples+=1
if A-w.startedAt<0.25 then return end
if A-w.lastReportAt<0.5 then return end
w.lastReportAt=A

local B=math.max(0.001,A-w.startedAt)
PostBuiltInObservation({
latencyMs=x,
successCount=w.samples,
throughputPerSecond=w.samples/B,
throughputWindowMs=B*1000,
throughputSamples=w.samples,
},y,z)
end

local function ReportBuiltInDecompileFailure(x,y,z,A,B)
if not IsActiveMappingContext(A,B)then return end
v.providerId=nil
v.expiresAt=0
v.blockedBuiltinUntil=os.clock()+5
if z==true then m:Reduce()end
PostBuiltInObservation({
latencyMs=y,
errorMessage=tostring(x or"Built-in decompile failed."),
timedOut=z==true,
},A,B)
end

local function RequestServerDecompile(x,y,z,A)
if type(request)~="function"then
return nil,"request function is unavailable"
end

y=if type(y)=="table"then y else{}
local B={
clientId=A,
bytecode=h(x),
builtinAvailable=type(i)=="function",
}
if type(y.builtinSource)=="string"then
B.builtinSource=y.builtinSource
end
if type(y.builtinLatencyMs)=="number"then
B.builtinLatencyMs=y.builtinLatencyMs
end
if type(y.requestedProvider)=="string"then
B.requestedProvider=y.requestedProvider
end
if type(y.disabledProviders)=="table"then
B.disabledProviders=y.disabledProviders
end

local C,D=RunWithTimeout(u,function()
return request{
Url=e.."/decompile",
Method="POST",
Headers=f{
["Content-Type"]="application/json",Accept=
"application/json",
},
Body=d:JSONEncode(B),
}
end)
if not C then
return nil,tostring(D)
end

if type(D)~="table"or type(D.Body)~="string"then
return nil,"Decompile server returned no response body."
end

local E,F=pcall(function()
return d:JSONDecode(D.Body)
end)
if not E or type(F)~="table"then
return nil,"Decompile server returned invalid JSON."
end

local G
if type(F.attemptedProviders)=="table"and type(F.attemptedProviders[1])=="string"then
G=F.attemptedProviders[1]
end

if F.ok==true and type(F.source)=="string"and F.source~=""then
return g(F.source),nil,false,G
end
if F.needsBuiltin==true and F.providerId=="builtin"then
return nil,nil,true,G
end

if type(F.error)=="string"and F.error~=""then
return nil,F.error,false,G
end
if type(F.attempts)=="table"then
return nil,table.concat(F.attempts,"\n\n"),false,G
end

return nil,"Decompile server failed without a detailed error.",false,G
end

local function PrepareScriptForMapping(x,y,z,A,B)
z=z or c.generation
A=A or c.clientId
local C=x:GetDebugId()
local D=GetScriptHashForInstance(x)
if y and D then
FetchCachedScriptSources(A,{D})
end

local E=D and c.sourceCacheByHash[D]or nil
if E then
return{
debugId=C,
scriptHash=D,
source=E,
}
end

local F=RefreshDecompilerPlan(false,z,A)
local G=B or F
local H=B=="builtin"
if H or ShouldUseDirectBuiltIn(G,z,A)then
return{
debugId=C,
scriptHash=D,
retryProviderId=B,
useDirectBuiltin=true,
forceDirectBuiltinRetry=H,
}
end

local I,J=ReadScriptBytecode(x)
if not I then
return nil,J
end

return{
debugId=C,
scriptHash=D,
bytecode=J,
retryProviderId=B,
}
end

local function BuildServerOptions(x,y)
local z={}
if type(x.retryProviderId)=="string"then
z.requestedProvider=x.retryProviderId
end
if type(y)=="table"then
for A,B in y do
z[A]=B
end
end
return if next(z)==nil then nil else z
end

local function TakeRetryServerOptions(x,y)
local z=BuildServerOptions(x,y)
x.retryProviderId=nil
return z
end

local function DecompileScriptSource(x,y,z,A)
z=z or c.generation
A=A or c.clientId
local B
if not y then
y,B=PrepareScriptForMapping(x,true,z,A)
end
if not y then
return nil,B or"Failed to prepare script for decompile.",nil,nil
end

if type(y.source)=="string"and y.source~=""then
return y.source,nil,y.scriptHash,y
end
if y.useDirectBuiltin==true then
local C=y.forceDirectBuiltinRetry==true or
k.CanAttemptBuiltIn(
y,
v.blockedBuiltinUntil,
os.clock()
)
if C then
y.retryProviderId=nil
y.forceDirectBuiltinRetry=nil
y.initialProviderId=y.initialProviderId or"builtin"
k.MarkBuiltInAttempted(y)
local D,E,F,G=TryBuiltInDecompile(x)
if D then
ReportBuiltInDecompileSuccess(E,z,A)
if y.scriptHash then
RememberScriptSourceForHash(y.scriptHash,D)
end
return D,nil,y.scriptHash,y
end

k.DisableBuiltIn(y)
ReportBuiltInDecompileFailure(F,E,G,z,A)
end
local D,E=l.MaterializeServerFallback(y,function()
return ReadScriptBytecode(x)
end)
if not D then
return nil,E,y.scriptHash,y
end
end

if type(y.bytecode)~="string"then
return nil,"Prepared script is missing bytecode.",y.scriptHash,y
end

local C=TakeRetryServerOptions(
y,
if y.builtinDisabled==true then{disabledProviders={"builtin"}}else nil
)
local D,E,F,G=RequestServerDecompile(
y.bytecode,
C,
z,
A
)
if not y.initialProviderId and type(G)=="string"then
y.initialProviderId=G
end
if F then
local H=k.CanAttemptBuiltIn(
y,
v.blockedBuiltinUntil,
os.clock()
)
if H then
k.MarkBuiltInAttempted(y)
local I,J,K,L=TryBuiltInDecompile(x)
if I then
ReportBuiltInDecompileSuccess(J,z,A)
D,E=RequestServerDecompile(y.bytecode,BuildServerOptions(y,{
requestedProvider="builtin",
builtinSource=I,
builtinLatencyMs=J,
}),z,A)
else
k.DisableBuiltIn(y)
ReportBuiltInDecompileFailure(K,J,L,z,A)
D,E=RequestServerDecompile(y.bytecode,BuildServerOptions(y,{
disabledProviders={"builtin"},
}),z,A)
end
else
k.DisableBuiltIn(y)
D,E=RequestServerDecompile(y.bytecode,BuildServerOptions(y,{
disabledProviders={"builtin"},
}),z,A)
end
end
if not D then
return nil,E,y.scriptHash,y
end

if y.scriptHash then
RememberScriptSourceForHash(y.scriptHash,D)
end
return D,nil,y.scriptHash,y
end

local function ResetDecompilerClient()
v.providerId=nil
v.expiresAt=0
v.refreshToken=nil
v.blockedBuiltinUntil=0
w.startedAt=nil
w.lastAt=nil
w.samples=0
w.lastReportAt=0
w.revision=0
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
end end function a.q():typeof(__modImpl())local b=a.cache.q if not b then b={c=__modImpl()}a.cache.q=b end return b.c end end do local function __modImpl()

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
end end function a.r():typeof(__modImpl())local b=a.cache.r if not b then b={c=__modImpl()}a.cache.r=b end return b.c end end do local function __modImpl()

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
end end function a.s():typeof(__modImpl())local b=a.cache.s if not b then b={c=__modImpl()}a.cache.s=b end return b.c end end do local function __modImpl()

local b=a.c()

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
end end function a.t():typeof(__modImpl())local b=a.cache.t if not b then b={c=__modImpl()}a.cache.t=b end return b.c end end do local function __modImpl()

local b=a.c()
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

if n then
local r={}
local s=0
local t=0
local u=false
local v=20000

local function walk(w,x)
if x>j or u then
return
end

for y,z in w:GetChildren()do
if s>=v then
u=true
return
end
s+=1
if not m or z:IsA(l)then
t+=1
r[z.ClassName]=(r[z.ClassName]or 0)+1
end
if x<j then
walk(z,x+1)
if u then return end
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
VisitedDescendants=s,
MatchedDescendants=t,
ClassCounts=r,
TraversalLimited=u,
TraversalLimit=v,
}
end

local function buildTree(r,s)
if s>j then
return nil
end

local t=r:GetChildren()
local u={}
local v=0
local w=#t

for x,y in t do
if v>=k then break end
if p<=0 then
q=true
break
end

if m and not y:IsA(l)then


if s<j then
local z=buildTree(y,s+1)
if z and z.Children and#z.Children>0 then
table.insert(u,z)
v+=1
end
end
continue
end

p-=1

local z={
Name=y.Name,
ClassName=y.ClassName,
ChildCount=#y:GetChildren()
}

if s<j and z.ChildCount>0 then
local A=buildTree(y,s+1)
if A then
z.Children=A.Children
end
end

table.insert(u,z)
v+=1
end

return{
Name=r.Name,
ClassName=r.ClassName,
ChildCount=w,
TruncatedAt=if v<w then v else nil,
Children=u
}
end

local r=buildTree(i,0)
if q and typeof(r)=="table"then
r.Note="Output capped at "..o.." nodes. Narrow with classFilter, lower maxDepth, or summaryOnly=true."
end
return r
end)
end end function a.u():typeof(__modImpl())local b=a.cache.u if not b then b={c=__modImpl()}a.cache.u=b end return b.c end end do local function __modImpl()

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

return b end function a.v():typeof(__modImpl())local b=a.cache.v if not b then b={c=__modImpl()}a.cache.v=b end return b.c end end do local function __modImpl()

local b=a.v()

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
end end function a.w():typeof(__modImpl())local b=a.cache.w if not b then b={c=__modImpl()}a.cache.w=b end return b.c end end do local function __modImpl()

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
end end function a.x():typeof(__modImpl())local b=a.cache.x if not b then b={c=__modImpl()}a.cache.x=b end return b.c end end do local function __modImpl()

local b=a.c()

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
end end function a.y():typeof(__modImpl())local b=a.cache.y if not b then b={c=__modImpl()}a.cache.y=b end return b.c end end do local function __modImpl()

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
request=type(request)=="function",
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
end end function a.z():typeof(__modImpl())local b=a.cache.z if not b then b={c=__modImpl()}a.cache.z=b end return b.c end end do local function __modImpl()

local b=a.c()

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
end end function a.A():typeof(__modImpl())local b=a.cache.A if not b then b={c=__modImpl()}a.cache.A=b end return b.c end end do local function __modImpl()

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
end end function a.B():typeof(__modImpl())local b=a.cache.B if not b then b={c=__modImpl()}a.cache.B=b end return b.c end end do local function __modImpl()

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
end end function a.C():typeof(__modImpl())local b=a.cache.C if not b then b={c=__modImpl()}a.cache.C=b end return b.c end end do local function __modImpl()

return function(b,c)
c:BindToTypeStructured("executor-capabilities",function(d)
return b.RuntimeCapabilities:Probe()
end)
end end function a.D():typeof(__modImpl())local b=a.cache.D if not b then b={c=__modImpl()}a.cache.D=b end return b.c end end do local function __modImpl()

local b=a.c()

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
end end function a.E():typeof(__modImpl())local b=a.cache.E if not b then b={c=__modImpl()}a.cache.E=b end return b.c end end do local function __modImpl()

local b=a.c()

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
end end function a.F():typeof(__modImpl())local b=a.cache.F if not b then b={c=__modImpl()}a.cache.F=b end return b.c end end do local function __modImpl()

local b=a.c()

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
end end function a.G():typeof(__modImpl())local b=a.cache.G if not b then b={c=__modImpl()}a.cache.G=b end return b.c end end do local function __modImpl()

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
end end function a.H():typeof(__modImpl())local b=a.cache.H if not b then b={c=__modImpl()}a.cache.H=b end return b.c end end do local function __modImpl()

local b=a.c()

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
end end function a.I():typeof(__modImpl())local b=a.cache.I if not b then b={c=__modImpl()}a.cache.I=b end return b.c end end do local function __modImpl()

local b=a.c()

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
end end function a.J():typeof(__modImpl())local b=a.cache.J if not b then b={c=__modImpl()}a.cache.J=b end return b.c end end do local function __modImpl()

local b=a.c()
local c=a.v()

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
end end function a.K():typeof(__modImpl())local b=a.cache.K if not b then b={c=__modImpl()}a.cache.K=b end return b.c end end do local function __modImpl()

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

while true do
local l,m=pcall(c)

if not l then
task.wait(3)
continue
end

local n=d(m)
if n then
e.bridge=m
f()

local o=e.clientId~=n
if o then
h(n)
end

local p=(
getgenv().EnableInitialScriptDecompMapping==true or
getgenv().DisableInitialScriptDecompMapping==false
)and getgenv().DisableInitialScriptDecompMapping~=true

if p or(not o and e.disabled~=true)then
i(n)
j()
k()
g()
else
e.clientId=n
e.disabled=true
e.stateVersion+=1
g()
end
end

local o={a.s()
,a.t()
,a.u()
,a.w()
,a.x()
,a.y()
,a.z()
,a.A()
,a.B()
,a.C()
,a.D()
,a.E()
,a.F()
,a.G()
,a.H()
,a.I()
,a.J()
,a.K()
,
}
for p,q in o do
q(b,m)
end

m:WaitForDisconnect()

if e.bridge==m then
e.bridge=nil
end
task.wait(1)
end
end end function a.L():typeof(__modImpl())local b=a.cache.L if not b then b={c=__modImpl()}a.cache.L=b end return b.c end end end





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



local o
do




local p='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'


o=base64encode or function(q)
return((q:gsub('.',function(r)
local s,t='',r:byte()
for u=8,1,-1 do s=s..(t%2^u-t%2^(u-1)>0 and'1'or'0')end
return s
end)..'0000'):gsub('%d%d%d?%d?%d?%d?',function(r)
if(#r<6)then return''end
local s=0
for t=1,6 do s=s+(r:sub(t,t)=='1'and 2^(6-t)or 0)end
return p:sub(s+1,s+1)
end)..({'','==','='})[#q%3+1])
end
end



local p=type(getscripthash)=="function"and getscripthash or nil
local q=type(decompile)=="function"and decompile or nil

local r=a.a()




local s=8
local t=256
local u=2000
local v=500
local w=131072

local function SanitizeString(x,y)
x=tostring(x)
local z=math.max(0,math.min(v,y.stringBytes))
if z==0 then return"<string omitted: output budget reached>"end

local A={}
local B=0
local C=pcall(function()
for C,D in utf8.codes(x)do
local E=utf8.char(D)
if B+#E>z then break end
table.insert(A,E)
B+=#E
end
end)
local D
if C then
D=table.concat(A)
else
D=string.sub(string.gsub(x,"[^%g ]","?"),1,z)
B=#D
end

y.stringBytes=math.max(0,y.stringBytes-B)
return#D<#x and(D.."...(truncated)")or D
end

local function SanitizeForOutput(x,y,z,A)
y=y or 0
A=A or{
entries=u,
stringBytes=w,
}
local B=typeof(x)

if B=="Instance"then
local C,D=pcall(function()return x:GetFullName()end)
return SanitizeString(C and D or x,A)
elseif B=="string"then
return SanitizeString(x,A)
elseif B=="number"then
if x~=x then return"<nan>"end
if x==math.huge then return"<infinity>"end
if x==-math.huge then return"<-infinity>"end
return x
elseif B=="boolean"or B=="nil"then
return x
elseif B~="table"then

local C,D=pcall(tostring,x)
return SanitizeString(C and D or"<unprintable value>",A)
end

if y>=s then
return"<table: max depth reached>"
end

z=z or{}
if z[x]then
return"<cyclic table>"
end
z[x]=true

local C={}
local D=#x
local E=D>0
if E then
local F=0
for G in pairs(x)do
F+=1
if type(G)~="number"or G%1~=0 or G<1 or G>D then
E=false
break
end
if F>=t+1 then break end
end
end

if E then
local F=math.min(D,t)
local G=0
for H=1,F do
if A.entries<=0 then break end
A.entries-=1
G+=1
C[H]=SanitizeForOutput(x[H],y+1,z,A)
end
if D>G then
C[G+1]={
__omitted=tostring(D-G).." additional array entries omitted",
}
end
z[x]=nil
return C
end

local F=0
local G=false
for H,I in pairs(x)do
if F>=t or A.entries<=0 then
G=true
break
end
F+=1
A.entries-=1


local J=SanitizeString(typeof(H)=="string"and H or tostring(H),A)
C[J]=SanitizeForOutput(I,y+1,z,A)
end
if G then
C.__omitted="additional entries omitted"
end

z[x]=nil
return C
end



local function StripDecompilerBanner(x)
if typeof(x)~="string"then return x end
return(string.gsub(x,"^%s*%-%-[^\n]*[Dd]ecompiled[^\n]*\n","",1))
end

local x=getnilinstances or function()return{}end




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

local y=ResolveWebSocketConnect()
local z=y~=nil and getgenv().DisableWebSocket~=true


local function GenerateSessionGuid()
local A,B=pcall(function()
return l:GenerateGUID(false)
end)
if A and type(B)=="string"and B~=""then
return B
end
return tostring(os.clock()).."-"..tostring(math.random(1,1000000000))
end

local function GetClientIdentityKey()
local A=n.LocalPlayer
return table.concat({
tostring(game.PlaceId or 0),
tostring(game.JobId or""),
tostring(A and A.UserId or 0),
},":")
end

local function GetStableClientSessionId()
local A=GetClientIdentityKey()
if type(getgenv().MCP_ClientSessionId)~="string"or getgenv().MCP_ClientIdentityKey~=A then
getgenv().MCP_ClientSessionId=GenerateSessionGuid()
getgenv().MCP_ClientIdentityKey=A
end
return getgenv().MCP_ClientSessionId
end

local function GetRegistrationInfo()
local A=n.LocalPlayer
local B="Unknown"
pcall(function()
local C=h:GetProductInfo(game.PlaceId)
B=C.Name
end)
return{
type="register",
username=A and A.Name or"Unknown",
userId=A and A.UserId or 0,
placeId=game.PlaceId,
jobId=game.JobId,
placeName=B,
sessionId=GetStableClientSessionId(),
clientToken=getgenv().MCP_ClientToken,
}
end



local A=a.b().new{
RegistryId=GenerateSessionGuid(),
MaxHandles=getgenv().MCP_RuntimeMaxHandles,
DefaultTtlSeconds=getgenv().MCP_RuntimeHandleTtlSeconds,
}
local B=a.d().new{
Handles=A,
DefaultDepth=getgenv().MCP_RuntimeValueDepth,
DefaultEntries=getgenv().MCP_RuntimeValueEntries,
DefaultStringBytes=getgenv().MCP_RuntimeValueStringBytes,
}
local C=a.e().new{
ConnectorVersion="2",
WebSocketAvailable=z,
}
local D=a.f().new{
Handles=A,
TypedValues=B,
MaxSnapshots=getgenv().MCP_GcMaxSnapshots,
DefaultScanLimit=getgenv().MCP_GcDefaultScanLimit,
TableScanLimit=getgenv().MCP_GcTableScanLimit,
}


local E=a.g(){
HttpService=l,
BridgeHTTPURL=c,
BridgeWebSocketURL=d,
BridgeAuthToken=e,
BridgeRequestHeaders=BridgeRequestHeaders,
WebSocketAvailable=z,
WebSocketConnect=y,
GetRegistrationInfo=GetRegistrationInfo,
SanitizeForOutput=SanitizeForOutput,
LuaEncode=r,
}
local F=E.CreateBridge


local G=a.h()
local H=a.i()
local I=a.j()
local J=a.k()
local K=a.l()
local L=H.new()
local M=math.max(
1,
math.min(math.floor(tonumber(getgenv().MCP_ScriptMappingWorkers)or 24),64)
)
local N=a.m().new(
L,
M
)
local O=math.max(
5,
math.min(tonumber(getgenv().MCP_FailedScriptResyncInterval)or 30,600)
)
local P=a.n().new(L,{
IntervalSeconds=O,
MaxDelaySeconds=math.max(O,300),
BatchSize=math.max(
1,
math.min(math.floor(tonumber(getgenv().MCP_FailedScriptResyncBatchSize)or 8),32)
),
})
local Q=a.o().new(
L,
P
)
local R=a.p(){
ScriptMappingPipeline=L,
HttpService=l,
BridgeHTTPURL=c,
BridgeRequestHeaders=BridgeRequestHeaders,
JobStatus=Q,
}
local S=a.q(){
ScriptMappingPipeline=L,
HttpService=l,
BridgeHTTPURL=c,
BridgeRequestHeaders=BridgeRequestHeaders,
StripDecompilerBanner=StripDecompilerBanner,
base64_encode=o,
BuiltInDecompile=q,
GetScriptHash=p,
DecompilerAttemptState=J,
PreparedScript=K,
Concurrency=N,
}
local T=a.r(){
ScriptMappingPipeline=L,
WorkerPool=G,
UploadSession=I,
GenerateSessionGuid=GenerateSessionGuid,
CoreGui=i,
CorePackages=j,
ScriptContext=k,
getnilinstances=x,
WorkerCount=M,
Concurrency=N,
JobStatus=Q,
FailedResync=P,
UploadClient=R,
DecompilerClient=S,
}
local U=R.StartUploadQueue
local function PublishScriptMappingStatus()
Q:Publish()
end
local V=T.StartScriptMapping
local W=T.StartFailedScriptResync
local X=T.ResetScriptMappingState
local Y=T.ResumeDeferredScriptMappings
local Z=T.GetScriptByDebugId
local aa=T.QueueMappedScriptSource
local ab=T.DecompileScriptSource

local function WaitForBridgeClientId(ac)
local ad=os.clock()+5
repeat
if ac.ClientId then
return ac.ClientId
end
if not ac.Connected then
return nil
end
task.wait(0.05)
until os.clock()>ad

return nil
end

getgenv().MCP_Loaded=true
getgenv().MCP_Loading=nil
local ac,ad=pcall(function()a.L()
{
CreateBridge=F,
WaitForBridgeClientId=WaitForBridgeClientId,
ScriptMappingPipeline=L,
StartUploadQueue=U,
PublishScriptMappingStatus=PublishScriptMappingStatus,
ResetScriptMappingState=X,
StartScriptMapping=V,
StartFailedScriptResync=W,
ResumeDeferredScriptMappings=Y,
GetScriptByDebugId=Z,
DecompileScriptSource=ab,
QueueMappedScriptSource=aa,
LogService=m,
MarketplaceService=h,
VirtualInputManager=g,
Players=n,
LuaEncode=r,
WebSocketAvailable=z,
RuntimeHandles=A,
RuntimeValues=B,
RuntimeCapabilities=C,
GcExplorer=D,
}
end)
if not ac then
getgenv().MCP_Loaded=nil
getgenv().MCP_Loading=nil
error(ad)
end