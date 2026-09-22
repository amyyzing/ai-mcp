"""Synthetic, non-secret fixtures against the deployed API; never follow source URLs."""
import hashlib
import http.cookiejar
import json
import os
import time
import urllib.parse
import urllib.request

BASE='https://luraph-devirtualiser-production.up.railway.app'
jar=http.cookiejar.CookieJar()
client=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

def request(path, data=None):
    raw=None if data is None else json.dumps(data).encode()
    req=urllib.request.Request(BASE+path,data=raw,headers={'Content-Type':'application/json'})
    with client.open(req,timeout=10) as response:return json.load(response)

deadline=time.monotonic()+240
while True:
    try:
        health=request('/api/health')
        if health.get('ok') and health.get('siteVersion')=='2.0.0':break
    except Exception:pass
    if time.monotonic()>deadline:raise RuntimeError('New healthy deployment did not appear before the deadline')
    time.sleep(5)

fixtures=[
    ('escaped-literal',r'local url="\104\116\116\112\115://example.invalid/owned.lua";return url','strict','literals-decoded'),
    ('modern-full',r'local x:number=3;local text="\104ello";return `{x}:{text}`','sandboxed','literals-decoded'),
    ('unchanged','return 1\n','strict','unchanged'),
]
for name,source,mode,outcome in fixtures:
    job=request('/api/jobs',{'source':source,'name':name+'.luau','mode':mode,'timeout':30})
    end=time.monotonic()+45
    while job['state'] not in ('completed','partial','failed','unsupported','cancelled'):
        if time.monotonic()>end:raise RuntimeError(name+': job timeout')
        time.sleep(.5);job=request('/api/jobs/'+job['id'])
    assert job['state']=='completed', (name,job.get('error'))
    assert job['quality']['outcome']==outcome,(name,job['quality'])
    assert job['quality']['compileChecked'] is True
    assert job['quality']['finalPayloadExecuted'] is False
    assert job['quality']['completeDevirtualization'] is False
    artifact=request('/api/jobs/'+job['id']+'/artifact?name='+urllib.parse.quote(job['primary']))
    if outcome!='unchanged':assert job['primary']!='program.source.luau'
    if name=='escaped-literal':assert 'https://example.invalid/owned.lua' in artifact['text']
    if name=='modern-full':assert 'hello' in artifact['text']
    original=request('/api/jobs/'+job['id']+'/artifact?name=original.input.luau')
    assert original['sha256']==hashlib.sha256(source.encode()).hexdigest()
    print('LIVE PASS:',name,'outcome='+outcome,'selected='+job['primary'])
print('LIVE SUMMARY: 3/3 synthetic public-API cases passed; no referenced URLs fetched.')
