"""Multi-family recovery router; Luraph uses the original pinned engine.

Closed-model application views are explicitly partial, not an all-path
source decompiler. Complete decoded analysis and evidence are retained.
"""
from __future__ import annotations
import hashlib,json,os,re,sys,time
from pathlib import Path
from lua_tokens import SyntaxFailure
from lua_parse import Parser,walk
from lua_eval import Evaluator,Scope,Table,Closure,Halt,LuaError
from lua_emit import Emitter,constant,MISSING,literal
from native_luau import check as native

ADAPTER_VERSION='closed-luau-1.0.0'
SEEDS=(1729,42,901)

def strip_fence(source):
    s=source.strip()
    if s.startswith('```') and s.endswith('```'):
        first=s.find('\n')
        if first>=0:return s[first+1:-3].strip()
    return source

def outer_function(body):
    if len(body)!=1 or body[0]['k']!='return' or len(body[0]['values'])!=1:return None
    n=body[0]['values'][0]
    if n['k']!='call':return None
    n=n['func']
    while n['k']=='group':n=n['value']
    return n if n['k']=='function' else None

def prefix_information(body):
    fn=outer_function(body)
    if not fn or not fn['body'] or fn['body'][-1]['k']!='return':return None
    prefix=fn['body'][:-1]
    tables=[s for s in prefix if s['k']=='local' and any(v['k']=='table' for v in s['values'])]
    funcs=[s for s in prefix if s['k']=='localfunction' and len(s['value']['body'])==1 and s['value']['body'][0]['k']=='return']
    if len(tables)!=1 or len(funcs)!=1:return None
    e=Evaluator(max_steps=1200000,seconds=8)
    scope=Scope(e.scope);scope.local['...']=[]
    scope=e.block(prefix,scope,new=False)
    if e.calls or e.random_calls:raise Halt('Constant-pool wrapper performed nonconstant operations')
    table=e.lookup(scope,tables[0]['targets'][0]['name'])
    resolver=e.lookup(scope,funcs[0]['target']['name'])
    if not isinstance(table,Table) or not isinstance(resolver,Closure):return None
    if any(not isinstance(k,(int,float)) or not isinstance(v,bytes) for (_,k),v in table.data.items()):return None
    return {'wrapper':fn,'table':table,'resolver':resolver,'scope':scope,'evaluator':e,'declaration':funcs[0], 'name':funcs[0]['target']['name']}

def replacements(body,info):
    if not info:return {}
    out={};mark=object()
    def expression(n,scope):
        if n['k']=='function':
            local=dict(scope)
            for p in n['params']:local[p]=None
            block(n['body'],local);return
        if n['k']=='call':
            f=n['func']
            while f['k']=='group':f=f['value']
            if f['k']=='name' and scope.get(f['name']) is mark:
                args=[constant(x) for x in n['args']]
                if all(v is not MISSING for v in args):
                    try:
                        values=info['evaluator'].call(info['resolver'],args)
                        if len(values)==1 and isinstance(values[0],bytes):out[id(n)]=values[0]
                    except (Halt,LuaError):pass
        for key,value in n.items():
            if isinstance(value,dict) and 'k' in value:expression(value,scope)
            elif isinstance(value,(list,tuple)):
                def seq(v):
                    if isinstance(v,dict) and 'k' in v:expression(v,scope)
                    elif isinstance(v,(list,tuple)):
                        for item in v:seq(item)
                seq(value)
    def block(stmts,scope):
        scope=dict(scope)
        for s in stmts:
            k=s['k']
            if k=='localfunction':
                scope[s['target']['name']]=mark if s is info['declaration'] else None
                expression(s['value'],scope)
            elif k=='local':
                for v in s['values']:expression(v,scope)
                for t in s['targets']:scope[t['name']]=None
            elif k=='if':
                for cond,b in s['branches']:expression(cond,scope);block(b,scope)
                block(s['other'],scope)
            elif k in ('fornum','forin'):
                for v in s['values']:expression(v,scope)
                inner=dict(scope)
                for name in ([s['name']] if k=='fornum' else s['names']):inner[name]=None
                block(s['body'],inner)
            elif k in ('do','while','repeat'):
                if 'condition' in s:expression(s['condition'],scope)
                block(s['body'],scope)
            else:
                expression(s,scope)
                if k=='assign':
                    for t in s['targets']:
                        if t['k']=='name':scope[t['name']]=None
    block(body,{})
    return out

def scalar(value):
    if value is None:return {'type':'nil'}
    if isinstance(value,bool):return {'type':'boolean','value':value}
    if isinstance(value,bytes):return {'type':'string','hex':value.hex()}
    if isinstance(value,(int,float)):return {'type':'number','text':format(value,'.17g')}
    raise Halt('Output includes a nonscalar value; full reconstruction required')

def snapshot(e,ret):
    return {'events':[{'operation':c['function'],'arguments':[scalar(v) for v in c['arguments']]} for c in e.calls], 'returns':[scalar(v) for v in ret]}

def equivalent(expected,actual):
    if not actual.get('ok'):return False
    def clean(x):
        if isinstance(x,dict):
            if not x:return []
            if x.get('type')=='number':
                try:return ('number',float(x['text']))
                except ValueError:return ('number',x['text'])
            return {k:clean(v) for k,v in x.items()}
        if isinstance(x,list):return [clean(v) for v in x]
        return x
    return clean(expected)==clean({k:actual.get(k) for k in ('events','returns')})

def run_local(source_path,output,seconds=180):
    started=time.monotonic();output.mkdir(parents=True,exist_ok=True)
    source=strip_fence(source_path.read_text(encoding='utf8'))
    native_input=output/'original.normalized-input.luau';native_input.write_text(source,encoding='utf8')
    print('[1/7] Parsing Lua/Luau and classifying structure',flush=True)
    body=Parser(source).parse();nodes=list(walk(body));functions=sum(n['k']=='function' for n in nodes)
    wrapped=outer_function(body)
    virtualized=bool(wrapped and any(n['k']=='while' for n in nodes) and functions>=4)
    label='prometheus-style' if virtualized else 'generic-luau'
    info=None;warnings=[];decode_error=None
    try:info=prefix_information(body)
    except (Halt,Exception) as ex:
        decode_error=str(ex);warnings.append('Constant-array analysis stopped: '+str(ex)[:300])
    print('[2/7] Decoding literal constant arrays',flush=True)
    reps=replacements(body,info);emitter=Emitter(reps)
    view='-- Decoded analysis view. Formatting may affect anti-tamper checks.\n'+emitter.block(body)+'\n'
    analysis_path=output/'program.analysis.luau';analysis_path.write_text(view)
    pool=[]
    if info:
        for key in sorted(info['table'].keys()):
            value=info['table'].raw(key)
            pool.append({'index':int(key),'hex':value.hex(),'display':value.decode('utf8','backslashreplace')})
    (output/'decoded-strings.json').write_text(json.dumps(pool,indent=2,ensure_ascii=True))
    expected=None;candidate=None;attempts=[];native_checks=[]
    strict=os.environ.get('LUAUVMP_STRICT_CAPTURE')=='1'
    plain=not virtualized and not wrapped and len(nodes)<2000
    warnings.append('Original names, comments and exact pre-obfuscation layout cannot be assumed recovered.')
    if virtualized:warnings.append('Prometheus-style application output is a bounded, model-specific reconstruction. Retained analysis source still contains dispatcher/anti-tamper logic; no all-path equivalence is claimed.')
    print('[3/7] Evaluating closed computations without host or Roblox capabilities',flush=True)
    assumed=set()
    if not strict and not plain:
        values=set(info['table'].data.values()) if info else set()
        scaffold=b'Tamper Detected!' in values and b':(%d*):' in values and b'pcall' in values
        allowed={v for v in values if isinstance(v,bytes) and re.fullmatch(rb'(?=.*[a-z])(?=.*[A-Z])[A-Za-z0-9]{8,24}',v)} if scaffold else set()
        for seed in SEEDS:
            e=Evaluator(seed=seed,max_steps=2000000,seconds=min(12,max(1,seconds/8)))
            e.allowed_absent=allowed;attempt={'seed':seed}
            try:
                ret=e.run(body);observed=snapshot(e,ret)
                attempt.update(terminated=True,events=len(e.calls),steps=e.steps,randomCalls=e.random_calls,observation=observed)
                assumed.update(e.assumed_absent)
                if expected is None:
                    expected=observed
                    lines=[c['function']+'('+', '.join(literal(v) for v in c['arguments'])+')' for c in e.calls]
                    if ret:lines.append('return '+', '.join(literal(v) for v in ret))
                    candidate='\n'.join(lines)+'\n'
                elif observed!=expected:
                    candidate=None;attempt['error']='Output varies by diagnostic/random seed';attempts.append(attempt);break
            except (Halt,Exception) as ex:
                attempt.update(terminated=False,error=str(ex)[:600],steps=e.steps,unknownGlobals=sorted(e.unknown_reads))
                candidate=None;attempts.append(attempt);break
            attempts.append(attempt)
        if not candidate:
            why=attempts[-1].get('error','No reconstructible scalar operations') if attempts else 'No model'
            warnings.append('Closed-program reconstruction was not completed: '+why+'. The analysis artifact is not a fully devirtualized application.')
    elif strict:warnings.append('Strict mode performs static/constant-array analysis only. Select Full recovery to enable closed-model specialization and isolated native verification.')
    print('[4/7] Preserving full analysis and model evidence',flush=True)
    primary='program.analysis.luau';compile_target=analysis_path
    if plain:
        original=output/'program.source.luau';original.write_text(source+'\n');primary=original.name;compile_target=original
        warnings.append('This input has no supported VM wrapper. Source is returned without claiming devirtualization; it was not executed.')
    print('[5/7] Validating reconstructed candidate against native Luau',flush=True)
    if candidate and candidate.strip():
        path=output/'program.application.luau';path.write_text(candidate);checks=[]
        for seed in SEEDS:
            remaining=seconds-(time.monotonic()-started)
            if remaining<3:checks.append({'seed':seed,'matched':False,'error':'Job deadline approaching'});break
            orig=native(native_input,'trace',output,seed,timeout=min(5,max(1,remaining/3)))
            rebuilt=native(path,'trace',output,seed,timeout=min(5,max(1,remaining/3))) if orig.get('ok') else {'ok':False,'error':'Original native run did not complete'}
            same=equivalent(expected,orig) and equivalent(expected,rebuilt)
            checks.append({'seed':seed,'matched':same,'original':orig,'reconstruction':rebuilt})
            if not same:break
        native_checks=checks
        if len(checks)==len(SEEDS) and all(c['matched'] for c in checks):
            primary=path.name;compile_target=path
            warnings.append('Application view reproduces recorded print/warn calls and scalar returns under three fixed native Luau profiles. It is not an all-path decompiler and omits unobserved global mutations, timing and diagnostic scaffolding.')
        else:
            path.rename(output/'candidate.unverified.luau')
            warnings.append('Native comparison did not confirm the candidate. It is available only as candidate.unverified.luau; the primary view remains the complete analysis source.')
    print('[6/7] Recording coverage, assumptions and unsupported operations',flush=True)
    report={'adapter':ADAPTER_VERSION,'family':label,'classificationEvidence':{'virtualizedWrapper':virtualized,'bannerWeAreDevs':'wearedevs.net/obfuscator' in source[:256],'constantPool':bool(info)},'inputSha256':hashlib.sha256(source.encode()).hexdigest(),'astNodes':len(nodes),'syntacticFunctions':functions,'foldedLiteralExpressions':emitter.folds,'decodedPoolEntries':len(pool),'inlinedAccessorCalls':len(reps),'modelRuns':attempts,'nativeComparisons':native_checks,'assumedAbsentScratchGlobals':[v.decode() for v in sorted(assumed)],'profile':{'globals':'explicit pure-library allowlist; unknown globals stop analysis','debug':None,'newproxy':None,'entryArguments':[],'externalEffects':False,'nativeRuntime':'official-luau-0.739','scope':'observed print/warn calls and scalar returns, not all paths or global-state effects'},'decodeError':decode_error,'warnings':warnings}
    if expected:(output/'observed-calls.json').write_text(json.dumps(expected,indent=2))
    print('[7/7] Compiling the selected Luau artifact without executing it',flush=True)
    compiled=native(compile_target,'compile',output,timeout=min(12,max(2,seconds/4)))
    if not compiled.get('ok'):warnings.append('Native compilation check did not pass: '+compiled.get('error','Unknown failure'))
    report['selectedArtifactCompileCheck']=compiled
    (output/'recovery-report.json').write_text(json.dumps(report,indent=2,ensure_ascii=True))
    complete=plain and compiled.get('ok') is True
    pipeline={'format_version':4,'adapter':ADAPTER_VERSION,'family':label,'primary':primary,'partial':not complete,'warnings':warnings,'final_payload_executed':bool(attempts),'external_effects_allowed':False,'native_original_attempted':bool(native_checks),'execution_context':'closed-luau-sandbox' if native_checks else 'abstract-closed-model' if attempts else 'constant-array-only','prototypes':None,'instructions':None,'capture_kind':'native-verified-application-view' if primary=='program.application.luau' else 'source-pass-through' if plain else 'decoded-analysis','decompiler':{'compile_checked':compiled.get('ok') is True,'fallback_instructions':None},'decoded_pool_entries':len(pool),'inlined_accessor_calls':len(reps),'native_comparisons_passed':sum(c['matched'] for c in native_checks),'native_runtime':'official-luau-0.739','elapsed_seconds':round(time.monotonic()-started,3)}
    (output/'pipeline.json').write_text(json.dumps(pipeline,indent=2))
    native_input.unlink(missing_ok=True)
    return pipeline

def main(source,output,seconds):
    from luauvmp import luraph_loader
    text=Path(source).read_text(encoding='utf8')
    if luraph_loader.detect(text):
        os.execv(sys.executable,[sys.executable,'-m','luauvmp','luraph-full',source,'-o',output,'--force','--no-lua-expert','--timeout',str(seconds)])
    try:run_local(Path(source),Path(output),seconds)
    except (SyntaxFailure,Halt,Exception) as ex:
        print('RECOVERY_UNSUPPORTED: '+str(ex)[:1200],flush=True);sys.exit(3)

if __name__=='__main__':main(sys.argv[1],sys.argv[2],int(sys.argv[3]))
