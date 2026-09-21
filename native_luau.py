"""Native verification using the official pinned Luau compiler and CLI.

The generated harness is trusted; the submitted source is data passed to
loadstring and receives an explicit environment with no host/Roblox APIs.
Lune remains a separate dependency of the unchanged Luraph engine.
"""
from __future__ import annotations
import hashlib
import json
from pathlib import Path
import secrets
import shutil
import subprocess

VERSION = '0.739'
ARCHIVE_SHA256 = '8a9b4b381021722c82d6e6cda0964b5c9e7f354ec1035fcd8b657acc22e49247'
HARNESS = r'''
local hostPrint, compile, bind = print, loadstring, setfenv
local source = __SOURCE__
local seed = __SEED__
local marker = __MARKER__
local env = {}
for _, key in {'assert','error','ipairs','pairs','next','pcall','xpcall','select','tonumber','tostring','type','rawequal','rawget','rawset','getmetatable','setmetatable'} do
    env[key] = getfenv()[key]
end
env.string, env.math, env.table = table.clone(string), table.clone(math), table.clone(table)
env.unpack = table.unpack
env.getfenv = function() return env end
env._G, env._ENV, env._VERSION = env, env, 'Luau'
local function hex(text)
    local result=table.create(#text)
    for i=1,#text do result[i]=string.format('%02x', string.byte(text,i)) end
    return table.concat(result)
end
local function q(text)
    return '"'..string.gsub(text, '[%z\1-\31\\"]', function(c)
        return string.format('\\u%04x', string.byte(c))
    end)..'"'
end
local function scalar(value)
    local kind=type(value)
    if kind=='nil' then return '{"type":"nil"}' end
    if kind=='boolean' then return '{"type":"boolean","value":'..tostring(value)..'}' end
    if kind=='string' then return '{"type":"string","hex":'..q(hex(value))..'}' end
    if kind=='number' then return '{"type":"number","text":'..q(string.format('%.17g',value))..'}' end
    error('Non-scalar output is outside this comparison profile',0)
end
local events={}
local bytes=0
local function record(name,...)
    if #events>=4096 or select('#',...)>128 then error('Trace limit reached',0) end
    local values={}
    for i=1,select('#',...) do
        local value=select(i,...)
        if type(value)=='string' then bytes+=#value end
        if bytes>1048576 then error('Trace byte limit reached',0) end
        values[i]=scalar(value)
    end
    table.insert(events,'{"operation":'..q(name)..',"arguments":['..table.concat(values,',')..']}')
end
env.print=function(...) record('print',...) end
env.warn=function(...) record('warn',...) end
math.randomseed(seed)
local chunk, compileError=compile(source,'@protected')
local ok=false
local err=compileError
local returns={}
if chunk then
    bind(chunk,env)
    local result=table.pack(pcall(chunk))
    ok=result[1]
    if ok then
        for i=2,result.n do
            local encoded,value=pcall(scalar,result[i])
            if encoded then table.insert(returns,value) else ok=false;err='Non-scalar return';break end
        end
    else
        if type(result[2])=='string' then err=string.sub(result[2],1,1000) else err='Non-string error' end
    end
end
hostPrint(marker..'{"ok":'..tostring(ok)..',"error":'..(if err then q(err) else 'null')..',"events":['..table.concat(events,',')..'],"returns":['..table.concat(returns,',')..'],"profile":"official-luau-0.739-closed-v1"}')
'''

def available():
    return bool(shutil.which('luau') and shutil.which('luau-compile'))

def long_string(source: str) -> str:
    equals='='
    while ']'+equals+']' in source:
        equals+='='
    # The first newline after a Lua long-bracket opener is ignored. Adding
    # exactly one keeps the submitted source itself byte-for-byte unchanged.
    return '['+equals+'[\n'+source+']'+equals+']'

def check(path: Path, mode: str, work: Path, seed=1729, timeout=6):
    executable=shutil.which('luau-compile' if mode=='compile' else 'luau')
    if not executable:
        return {'ok':False,'error':'Official Luau runtime/compiler unavailable','unavailable':True,'runtimeVersion':VERSION}
    generated=None
    try:
        if mode=='compile':
            command=[executable,'--null',str(path)]
        else:
            source=path.read_text(encoding='utf8')
            marker='LD_NATIVE_'+secrets.token_hex(16)+':'
            text=HARNESS.replace('__SEED__',str(int(seed))).replace('__MARKER__',json.dumps(marker)).replace('__SOURCE__',long_string(source))
            generated=work/('native-'+secrets.token_hex(12)+'.luau')
            generated.write_text(text,encoding='utf8')
            command=[executable,'-O1','-g1',str(generated)]
        result=subprocess.run(command,cwd=work,capture_output=True,timeout=timeout,check=False)
        if mode=='compile':
            return {'ok':result.returncode==0,'error':None if result.returncode==0 else result.stderr.decode('utf8','replace')[-1600:],'runtimeVersion':VERSION}
        if len(result.stdout)>4*1024**2:return {'ok':False,'error':'Native result exceeded the output budget','runtimeVersion':VERSION}
        lines=[line for line in result.stdout.decode('utf8','replace').splitlines() if line.startswith(marker)]
        if result.returncode!=0 or len(lines)!=1:
            return {'ok':False,'error':'Native verification failed: '+result.stderr.decode('utf8','replace')[-1200:],'runtimeVersion':VERSION}
        report=json.loads(lines[0][len(marker):]);report['runtimeVersion']=VERSION
        return report
    except subprocess.TimeoutExpired:
        return {'ok':False,'error':'Native '+mode+' check timed out','runtimeVersion':VERSION}
    except (OSError,ValueError) as exc:
        return {'ok':False,'error':str(exc)[:600],'runtimeVersion':VERSION}
    finally:
        if generated:generated.unlink(missing_ok=True)
