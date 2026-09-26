"""Bounded host-surface tracing for VM-shaped Luau wrappers.

The submitted wrapper may execute only inside an explicit environment with no
network, filesystem, process, Roblox, or executor capabilities. HTTP and
loadstring are inert stubs: remote bodies are never fetched or compiled.
"""
from __future__ import annotations
import json
from pathlib import Path
import secrets
import shutil
import subprocess

VERSION = "instrumented-host-trace-1"

HARNESS = r'''
local hostPrint, realCompile, bind = print, loadstring, setfenv
local source = __SOURCE__
local marker = __MARKER__
local profile = __PROFILE__
local env = {}
for _, key in {'assert','error','ipairs','pairs','next','pcall','xpcall','select','tonumber','tostring','type','rawequal','rawget','rawset','getmetatable','setmetatable'} do
    env[key] = getfenv()[key]
end
env.string, env.math, env.table = table.clone(string), table.clone(math), table.clone(table)
env.bit32 = table.clone(bit32)
if utf8 then env.utf8 = table.clone(utf8) end
env.unpack = table.unpack
env._VERSION = 'Luau'

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
    return '{"type":'..q(kind)..'}'
end
local events, bytes = {}, 0
local function record(name,...)
    if #events>=512 or select('#',...)>64 then error('Host trace limit reached',0) end
    local values={}
    for i=1,select('#',...) do
        local value=select(i,...)
        if type(value)=='string' then bytes+=#value end
        if bytes>524288 then error('Host trace byte limit reached',0) end
        values[i]=scalar(value)
    end
    table.insert(events,'{"operation":'..q(name)..',"arguments":['..table.concat(values,',')..']}')
end

local bodyIndex=0
local function nextBody()
    bodyIndex+=1
    return '__LD_HTTP_BODY_'..tostring(bodyIndex)..'__'
end
local gameProxy={}
function gameProxy:HttpGet(...)
    record('game.HttpGet',...)
    return nextBody()
end
env.game=gameProxy

local function requestProxy(options)
    local url, method
    if type(options)=='table' then
        url=options.Url or options.URL or options.url
        method=options.Method or options.method or 'GET'
    else
        url=options
        method='GET'
    end
    record('request',url,method)
    return {StatusCode=200,Status=200,Success=true,Body=nextBody(),Headers={}}
end
env.request=requestProxy
env.http_request=requestProxy
env.httpRequest=requestProxy
env.httprequest=requestProxy
env.http={request=requestProxy}
env.syn={request=requestProxy}

env.loadstring=function(body,chunkname)
    record('loadstring',body,chunkname)
    return function(...)
        record('compiled-call',...)
        return nil
    end
end
env.print=function(...) record('print',...) end
env.warn=function(...) record('warn',...) end
env.getfenv=function() return env end
env.getgenv=function() return env end
env._G, env._ENV = env, env

local chunk, compileError=realCompile(source,'@protected')
local ok, err=false, compileError
if chunk then
    bind(chunk,env)
    local result
    if profile==0 then result=table.pack(pcall(chunk))
    else result=table.pack(pcall(chunk,'__LD_ARG1__')) end
    ok=result[1]
    if not ok then
        err=type(result[2])=='string' and string.sub(result[2],1,1000) or 'Non-string error'
    else
        err=nil
    end
end
hostPrint(marker..'{"ok":'..tostring(ok)..',"error":'..(if err then q(err) else 'null')..',"events":['..table.concat(events,',')..'],"profile":'..tostring(profile)..'}')
'''

def long_string(source: str) -> str:
    equals='='
    while ']'+equals+']' in source:
        equals+='='
    return '['+equals+'[\n'+source+']'+equals+']'

def run_profile(source: str, work: Path, profile: int, timeout: float):
    executable=shutil.which('luau')
    if not executable:
        return {'ok':False,'error':'Official Luau runtime unavailable','events':[]}
    marker='LD_HOST_'+secrets.token_hex(16)+':'
    generated=work/('host-trace-'+secrets.token_hex(10)+'.tmp.luau')
    try:
        generated.write_text(HARNESS.replace('__SOURCE__',long_string(source))
            .replace('__MARKER__',json.dumps(marker)).replace('__PROFILE__',str(profile)),encoding='utf8')
        result=subprocess.run([executable,'-O1','-g1',str(generated)],cwd=work,
            capture_output=True,timeout=max(.2,timeout),check=False)
        if len(result.stdout)>2*1024*1024:
            return {'ok':False,'error':'Host trace exceeded output budget','events':[]}
        lines=[line for line in result.stdout.decode('utf8','replace').splitlines() if line.startswith(marker)]
        if result.returncode!=0 or len(lines)!=1:
            return {'ok':False,'error':'Host trace runtime failed: '+result.stderr.decode('utf8','replace')[-1000:],'events':[]}
        return json.loads(lines[0][len(marker):])
    except subprocess.TimeoutExpired:
        return {'ok':False,'error':'Host trace timed out','events':[]}
    except (OSError,ValueError,json.JSONDecodeError) as exc:
        return {'ok':False,'error':str(exc)[:700],'events':[]}
    finally:
        generated.unlink(missing_ok=True)

def scalar_value(item):
    if not isinstance(item,dict): return None
    kind=item.get('type')
    if kind=='string':
        try:return bytes.fromhex(item.get('hex','')).decode('utf8')
        except (ValueError,UnicodeDecodeError):return None
    if kind=='boolean': return item.get('value')
    if kind=='number':
        try:return float(item.get('text'))
        except (TypeError,ValueError):return None
    if kind=='nil': return None
    return None

def luau_literal(value):
    if isinstance(value,str):
        return json.dumps(value,ensure_ascii=False)
    if isinstance(value,bool): return 'true' if value else 'false'
    if value is None:return 'nil'
    if isinstance(value,(int,float)):return format(value,'.17g')
    return None

def loader_reconstruction(events):
    if not isinstance(events,list) or len(events)!=3:return None
    first,second,third=events
    if [x.get('operation') for x in events] != ['game.HttpGet','loadstring','compiled-call']:
        return None
    http_args=first.get('arguments',[])
    load_args=second.get('arguments',[])
    call_args=third.get('arguments',[])
    if not http_args or call_args:return None
    url=scalar_value(http_args[0])
    if not isinstance(url,str) or not url.startswith(('https://','http://')):return None
    if not load_args or scalar_value(load_args[0])!='__LD_HTTP_BODY_1__':return None
    extras=[]
    for item in http_args[1:]:
        value=luau_literal(scalar_value(item))
        if value is None:return None
        extras.append(value)
    args=', '.join([json.dumps(url,ensure_ascii=False),*extras])
    return 'loadstring(game:HttpGet('+args+'))()\n'

def observe(path: Path, work: Path, timeout: float = 6):
    source=path.read_text(encoding='utf8')
    each=max(.5,min(3.0,timeout/2))
    runs=[run_profile(source,work,profile,each) for profile in (0,1)]
    report={'adapter':VERSION,'submittedWrapperExecuted':True,'externalEffectsAllowed':False,
            'remoteBodiesFetched':False,'remoteBodiesExecuted':False,'profiles':runs,
            'profilesMatched':runs[0].get('events')==runs[1].get('events'),
            'scope':'Two bounded official-Luau runs with inert HTTP/loadstring stubs; not all-path equivalence.'}
    artifact=None
    if all(r.get('ok') for r in runs) and report['profilesMatched']:
        reconstructed=loader_reconstruction(runs[0].get('events'))
        if reconstructed:
            artifact='program.behavioral.luau'
            (work/artifact).write_text(
                '-- Behavioral reconstruction from two matching no-network Luau profiles.\n'
                '-- Remote content was not fetched or executed; unobserved branches can remain.\n'
                + reconstructed,encoding='utf8')
            report['behavioralArtifact']=artifact
            report['pattern']='httpget-loadstring-call'
    (work/'program.host-trace.json').write_text(json.dumps(report,indent=2),encoding='utf8')
    return report
