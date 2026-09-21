"""Official-parser fallback for valid Luau outside the static reducer's grammar.

Acceptance by the compiler is not a deobfuscation claim. Source, AST evidence,
and any bounded execution observations are separate artifacts.
"""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
from native_luau import check, VERSION

MAX_AST_BYTES = 16 * 1024 * 1024
MAX_ENTRIES = 20000

def inspect_source(path: Path, output: Path, timeout: float = 8) -> dict:
    binary = shutil.which('luau-ast')
    report = {'runtimeVersion':VERSION,'executed':False,'functions':[],
              'globalReferences':[],'stringConstants':[], 'complete':False}
    if not binary:
        report['error'] = 'Official AST executable unavailable'
        return report
    ast_path = output / 'parser-output.tmp'
    err_path = output / 'parser-error.tmp'
    try:
        with ast_path.open('wb') as out, err_path.open('wb') as err:
            process = subprocess.Popen([binary,str(path)],stdout=out,stderr=err,stdin=subprocess.DEVNULL,cwd=output)
            try:
                process.wait(timeout=max(.1,timeout))
            except subprocess.TimeoutExpired:
                process.kill();process.wait(timeout=3)
                report['error']='AST collection timed out';return report
        if process.returncode != 0:
            report['error']=err_path.read_bytes()[:1500].decode('utf8','replace') or 'Native AST parser failed'
            return report
        if ast_path.stat().st_size > MAX_AST_BYTES:
            report['error']='AST exceeded collection budget; original source retained'
            return report
        tree = json.loads(ast_path.read_text(encoding='utf8'))
        stack = [tree.get('root',tree)]
        count = 0
        seen_globals = set()
        while stack:
            item = stack.pop()
            if not isinstance(item,dict):
                if isinstance(item,list):stack.extend(reversed(item))
                continue
            count += 1
            if count > 300000:
                report['error']='AST node budget reached';break
            kind=item.get('type')
            location=item.get('location')
            if kind == 'AstExprFunction' and len(report['functions']) < MAX_ENTRIES:
                report['functions'].append({'name':item.get('debugname') or None,
                    'location':location,'parameters':[x.get('name') for x in item.get('args',[])],
                    'vararg':item.get('vararg',False),'depth':item.get('functionDepth'),
                    'executed':None})
            elif kind == 'AstExprGlobal':
                key=(item.get('global'),location)
                if key not in seen_globals and len(report['globalReferences']) < MAX_ENTRIES:
                    seen_globals.add(key)
                    report['globalReferences'].append({'name':key[0],'location':key[1]})
            elif kind == 'AstExprConstantString' and len(report['stringConstants']) < MAX_ENTRIES:
                value=item.get('value','')
                report['stringConstants'].append({'location':location,'value':value[:4096],
                    'truncated':len(value)>4096})
            # AstExprLocal embeds a declaration reference, not a new expression.
            for key,value in item.items():
                if key != 'local' and isinstance(value,(dict,list)):stack.append(value)
        report['nodeCount']=count
        report['complete']=not stack and 'error' not in report
        report['locations']='Zero-based line and byte-column from the official parser'
        report['scope']='Syntactic functions and references, including uncalled bodies; not recovered VM instructions'
        report['entriesCapped']=any(len(report[k]) >= MAX_ENTRIES for k in ('functions','globalReferences','stringConstants'))
        if report['entriesCapped']:report['complete']=False
        return report
    except (ValueError,OSError,RecursionError,UnicodeError) as error:
        report['error']=str(error)[:1500]
        return report
    finally:
        ast_path.unlink(missing_ok=True);err_path.unlink(missing_ok=True)


def run(source_path: Path, output: Path, seconds: int = 180) -> dict:
    from recovery import strip_fence
    output=output.resolve();output.mkdir(parents=True,exist_ok=True)
    started=time.monotonic()
    source=strip_fence(source_path.read_text(encoding='utf8'))
    path=output/'program.source.luau';path.write_text(source,encoding='utf8')
    print('[1/7] Validating with the official Luau compiler',flush=True)
    compiled=check(path,'compile',output,timeout=min(10,max(1,seconds/4)))
    if not compiled.get('ok'):
        (output/'syntax-error.json').write_text(json.dumps(compiled,indent=2))
        raise ValueError('Native Luau compilation failed: '+str(compiled.get('error')))
    print('[2/7] Preserving source outside the reducer grammar',flush=True)
    print('[3/7] Inspecting all syntactic function bodies without execution',flush=True)
    inspection=inspect_source(path,output,timeout=min(8,max(1,seconds/4)))
    (output/'source-inspection.json').write_text(json.dumps(inspection,ensure_ascii=True,indent=2))
    strict=os.getenv('LUAUVMP_STRICT_CAPTURE')=='1'
    observation=None
    warnings=['The official compiler accepts this syntax, but the static deobfuscation reducer does not yet support it. Complete source is retained unchanged; this is not recovered application source.',
              'Syntactic inspection includes uncalled function bodies. It cannot expose encrypted strings or custom VM instructions by itself.']
    print('[4/7] '+('Strict mode: no application execution' if strict else 'Collecting a bounded native observation'),flush=True)
    if not strict:
        observation=check(path,'trace',output,timeout=min(5,max(1,seconds-(time.monotonic()-started)-2)))
        (output/'native-observation.json').write_text(json.dumps(observation,ensure_ascii=True,indent=2))
        warnings.append('The observation covers one closed-environment run, not unexecuted paths or Roblox/executor behavior.')
    print('[5/7] Retaining source and observation as separate artifacts',flush=True)
    print('[6/7] Recording analysis coverage',flush=True)
    report={'format_version':4,'adapter':'official-luau-fallback-1','family':'luau-native-fallback',
        'primary':'program.source.luau','partial':True,'warnings':warnings,
        'final_payload_executed':not strict,'external_effects_allowed':False,
        'native_original_attempted':not strict,'execution_context':'closed-luau-sandbox' if not strict else 'compile-only',
        'capture_kind':'source-pass-through','native_runtime':'official-luau-'+VERSION,
        'input_sha256':hashlib.sha256(source.encode()).hexdigest(),
        'complete_devirtualization':False,'decompiler':{'compile_checked':True,'fallback_instructions':None},
        'syntactic_functions':len(inspection['functions']),'observation_completed':observation.get('ok') if observation else None,
        'elapsed_seconds':round(time.monotonic()-started,3)}
    (output/'pipeline.json').write_text(json.dumps(report,indent=2))
    (output/'recovery-report.json').write_text(json.dumps({'pipeline':report,'nativeCompile':compiled,'inspection':inspection},ensure_ascii=True,indent=2))
    print('[7/7] Official Luau analysis complete; devirtualization coverage remains partial',flush=True)
    return report
