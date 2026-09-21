"""Owned synthetic shape fixtures, NOT a real-world obfuscator corpus."""
from lua_tokens import quote

def protected_literal(message):
    return '''return(function(...)
local pool={%s,%s}
local function at(i)return pool[i+7]end
for i=1,#pool do pool[i]=string.reverse(pool[i]) end
return(function(env)
local function dispatch(pc)
local f,v
while pc do
if pc<20 then f=env[at(-5)];pc=30
elseif pc<40 then v=at(-6);pc=50
else f(v);pc=nil end
end
end
return dispatch(10)
end)(getfenv())
end)(...)''' % (quote(message[::-1]),quote(b'tnirp'))
