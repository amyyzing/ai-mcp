"""Native recovery of a supported closed constant-array prefix.

The application suffix is never executed. Only a syntactically isolated,
standard-library-only prefix is evaluated, twice with different seeds.
"""
from __future__ import annotations
import hashlib
import json
from pathlib import Path
import secrets
from native_tools import NativeFailure, line_starts, nodes, parse_ast, span
from native_luau import check
from lua_eval import Evaluator, Scope, Table, Closure

PURE_GLOBALS = {'string','table','math','type','ipairs','pairs','next','select','tonumber','tostring','assert','error','unpack'}


def shape(tree):
    body = tree.get('body', [])
    if len(body) != 1 or body[0].get('type') != 'AstStatReturn': return None
    result = body[0].get('list', [])
    if len(result) != 1 or result[0].get('type') != 'AstExprCall': return None
    fn = result[0].get('func', {})
    while fn.get('type') == 'AstExprGroup': fn = fn['expr']
    if fn.get('type') != 'AstExprFunction' or fn.get('args'): return None
    statements = fn['body'].get('body', [])
    if len(statements) < 3 or statements[-1].get('type') != 'AstStatReturn': return None
    prefix = statements[:-1]
    tables = [s for s in prefix if s.get('type') == 'AstStatLocal' and len(s.get('vars', [])) == 1 and len(s.get('values', [])) == 1 and s['values'][0].get('type') == 'AstExprTable']
    functions = [s for s in prefix if s.get('type') == 'AstStatLocalFunction' and len(s['func']['body'].get('body', [])) == 1 and s['func']['body']['body'][0].get('type') == 'AstStatReturn']
    if len(tables) != 1 or len(functions) != 1: return None
    return fn, prefix, tables[0]['vars'][0], functions[0]


def recover(source: str, legacy_body: list, work: Path, timeout=5):
    from recovery import outer_function
    source_path = work / 'constant-prefix-input.tmp.luau'; source_path.write_text(source, encoding='utf8')
    harness = work / ('constant-prefix-' + secrets.token_hex(8) + '.tmp.luau')
    try:
        tree = parse_ast(source_path, work, timeout)
        info = shape(tree)
        if not info: return None
        fn, prefix, declaration, accessor = info
        for n in nodes({'body': prefix}):
            if n.get('type') == 'AstExprGlobal' and n.get('global') not in PURE_GLOBALS: return None
            if n.get('type') == 'AstExprVarargs': return None
        legacy_fn = outer_function(legacy_body)
        if not legacy_fn: return None
        legacy_accessors = [s for s in legacy_fn['body'][:-1] if s['k'] == 'localfunction' and s['target']['name'] == accessor['name']['name']]
        if len(legacy_accessors) != 1: return None
        legacy_accessor = legacy_accessors[0]
        table_name = declaration['name']
        # Accessor may reference only its argument and the captured array.
        from lua_parse import walk
        allowed_names = set(legacy_accessor['value']['params']) | {table_name}
        if any(n['k'] == 'name' and n['name'] not in allowed_names for n in walk(legacy_accessor['value']['body'])): return None
        raw = source.encode('utf8'); starts = line_starts(raw)
        begin, _ = span(prefix[0]['location'], raw, starts)
        _, end = span(prefix[-1]['location'], raw, starts)
        prefix_source = raw[begin:end].decode('utf8')
        token = '__ld_' + secrets.token_hex(12)
        # Capture validation helpers before the prefix can shadow local names.
        header = f'local {token}t,{token}p,{token}u,{token}e=type,pairs,unpack,error\nreturn(function(...)\n'
        footer = f'''\nlocal {token}n=0
for {token}k,{token}v in {token}p({table_name}) do
 if {token}t({token}k)~="number" or {token}k%1~=0 or {token}k<1 or {token}k>20000 or {token}t({token}v)~="string" then {token}e("Invalid closed constant pool",0) end
 if {token}k>{token}n then {token}n={token}k end
end
for {token}k=1,{token}n do if {token}t({table_name}[{token}k])~="string" then {token}e("Sparse constant pool",0) end end
return {token}u({table_name},1,{token}n)
end)()
'''
        harness.write_text(header + prefix_source + footer, encoding='utf8')
        results = []
        for seed in (1729, 42):
            result = check(harness, 'trace', work, seed=seed, timeout=timeout)
            if not result.get('ok') or result.get('events') or any(v.get('type') != 'string' for v in result.get('returns', [])): return None
            results.append(result['returns'])
        if not results[0] or results[0] != results[1]: return None
        table = Table()
        for i, value in enumerate(results[0], 1): table.put(i, bytes.fromhex(value['hex']))
        # Refuse inlining if the array escapes into the application or if the
        # accessor is reassigned. Decoded constants can still be inspected.
        array_key = (declaration['name'], declaration['location'])
        function_key = (accessor['name']['name'], accessor['name']['location'])
        inline = True
        for n in nodes(fn['body']['body'][-1]):
            if n.get('type') == 'AstExprLocal':
                local = n['local']
                if (local['name'], local['location']) == array_key: inline = False
            if n.get('type') == 'AstStatAssign':
                for target in n.get('vars', []):
                    local = target.get('local', {})
                    if (local.get('name'), local.get('location')) == function_key: inline = False
        evaluator = Evaluator(seconds=10, max_steps=2000000)
        scope = Scope(evaluator.scope); scope.local[table_name] = table
        resolver = Closure(legacy_accessor['value'], scope)
        scope.local[legacy_accessor['target']['name']] = resolver
        report = {'adapter':'native-closed-constant-prefix-1','entries':len(results[0]),
                  'prefixSha256':hashlib.sha256(prefix_source.encode()).hexdigest(),
                  'nativeRunsMatched':2,'applicationExecuted':False,'allowInlining':inline,
                  'scope':'Closed standard-library prefix; application suffix excluded.'}
        (work/'native-constant-pool.json').write_text(json.dumps(report,indent=2))
        return {'wrapper':legacy_fn,'table':table,'resolver':resolver,'scope':scope,
                'evaluator':evaluator,'declaration':legacy_accessor,
                'name':legacy_accessor['target']['name'],'allow_inline':inline,'native':report}
    finally:
        source_path.unlink(missing_ok=True);harness.unlink(missing_ok=True)
