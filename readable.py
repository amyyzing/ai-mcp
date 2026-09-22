"""Lossless-span Luau cleanup and static evidence, independent of VM family.

Literal edits must preserve the native AST. Constant reductions are retained
only when the official compiler produces identical debug-free bytecode at
both O1 and O2. No user function, remote body, or string decoder is executed.
"""
from __future__ import annotations

import hashlib
import json
import math
import re
import shutil
import time
from pathlib import Path
from urllib.parse import urlsplit

from native_tools import (NativeFailure, LUAU_VERSION, ast_digest, bytecode_digest,
                          compile_check, line_starts, nodes, parse_ast, run_tool,
                          span, string_bytes)

UNKNOWN = object()
MAX_EDITS = 20000
MAX_RECORDS = 12000
MAX_CONSTANT_BYTES = 65536
PURE_KINDS = {'AstExprConstantString', 'AstExprConstantNumber', 'AstExprConstantBool', 'AstExprConstantNil', 'AstExprGroup', 'AstExprUnary', 'AstExprBinary', 'AstExprIfElse'}


def truth(value):
    return value is not None and value is not False


def readable_string(value: bytes) -> bytes | None:
    try:
        text = value.decode('utf8')
    except UnicodeDecodeError:
        return None
    if any(not char.isprintable() and char not in '\n\r\t' for char in text):
        return None
    escaped = text.replace('\\', '\\\\').replace('"', '\\"')
    escaped = escaped.replace('\r', '\\r').replace('\n', '\\n').replace('\t', '\\t')
    return ('"' + escaped + '"').encode('utf8')


def literal(value):
    if isinstance(value, bytes):
        return readable_string(value)
    if value is None:
        return b'nil'
    if isinstance(value, bool):
        return b'true' if value else b'false'
    if isinstance(value, (int, float)) and math.isfinite(value):
        if value == 0 and math.copysign(1, value) < 0:
            return b'(-0.0)'
        text = format(float(value), '.17g')
        return ('(' + text + ')' if text.startswith('-') else text).encode('ascii')
    return None


def local_key(value):
    return (value.get('name'), value.get('location'))


def constant_value(node, values, bindings=None):
    kind = node.get('type')
    if kind == 'AstExprConstantString':
        return string_bytes(node)
    if kind == 'AstExprConstantNumber':
        return float(node['value'])
    if kind == 'AstExprConstantBool':
        return node['value']
    if kind == 'AstExprConstantNil':
        return None
    if kind == 'AstExprLocal' and bindings is not None:
        return bindings.get(local_key(node['local']), UNKNOWN)
    get = lambda key: values.get(id(node.get(key)), UNKNOWN)
    if kind == 'AstExprGroup':
        return get('expr')
    if kind == 'AstExprIfElse':
        condition = get('condition')
        return UNKNOWN if condition is UNKNOWN else get('trueExpr' if truth(condition) else 'falseExpr')
    if kind == 'AstExprUnary':
        value, op = get('expr'), node['op']
        if value is UNKNOWN:
            return UNKNOWN
        if op == 'Not':
            return not truth(value)
        if op == 'Minus' and type(value) is float:
            return -value
        if op == 'Len' and isinstance(value, bytes):
            return float(len(value))
        return UNKNOWN
    if kind != 'AstExprBinary':
        return UNKNOWN
    left, right, op = get('left'), get('right'), node['op']
    if left is UNKNOWN:
        return UNKNOWN
    if op == 'And':
        return right if truth(left) else left
    if op == 'Or':
        return left if truth(left) else right
    if right is UNKNOWN:
        return UNKNOWN
    if op in ('CompareEq', 'CompareNe'):
        same = type(left) is type(right) and left == right
        return same if op == 'CompareEq' else not same
    if op == 'Concat' and isinstance(left, bytes) and isinstance(right, bytes):
        return left + right if len(left) + len(right) <= MAX_CONSTANT_BYTES else UNKNOWN
    if op in ('CompareLt', 'CompareLe', 'CompareGt', 'CompareGe'):
        if type(left) is not type(right) or not isinstance(left, (float, bytes)):
            return UNKNOWN
        return {'CompareLt': lambda: left < right, 'CompareLe': lambda: left <= right,
                'CompareGt': lambda: left > right, 'CompareGe': lambda: left >= right}[op]()
    if type(left) is not float or type(right) is not float:
        return UNKNOWN
    if not math.isfinite(left) or not math.isfinite(right):
        return UNKNOWN
    try:
        if op == 'Add': return left + right
        if op == 'Sub': return left - right
        if op == 'Mul': return left * right
        if op == 'Div' and right != 0: return left / right
        if op == 'FloorDiv' and right != 0: return float(math.floor(left / right))
        if op == 'Mod' and right != 0: return left - math.floor(left / right) * right
        if op == 'Pow' and abs(right) <= 128: return math.pow(left, right)
    except (OverflowError, ValueError, ZeroDivisionError):
        pass
    return UNKNOWN


def values_for(all_nodes, bindings=None):
    values = {}
    string_budget = 0
    for node in reversed(all_nodes):
        try:
            value = constant_value(node, values, bindings)
        except (OverflowError, ValueError, UnicodeError, KeyError):
            value = UNKNOWN
        if isinstance(value, bytes):
            string_budget += len(value)
            if string_budget > 32 * 1024 * 1024:
                value = UNKNOWN
        if value is not UNKNOWN:
            values[id(node)] = value
    return values


def non_overlapping(edits):
    selected, end = [], -1
    for edit in sorted(edits, key=lambda e: (e['start'], -e['end'])):
        if edit['start'] >= end:
            selected.append(edit)
            end = edit['end']
        if len(selected) >= MAX_EDITS:
            break
    return selected


def apply(source: bytes, edits: list[dict]) -> bytes:
    result, start = [], 0
    for edit in non_overlapping(edits):
        result.extend((source[start:edit['start']], edit['replacement']))
        start = edit['end']
    result.append(source[start:])
    return b''.join(result)


def make_edits(source, tree):
    all_nodes = list(nodes(tree))
    starts = line_starts(source)
    values = values_for(all_nodes)
    pure = {}
    for item in reversed(all_nodes):
        children = [v for v in item.values() if isinstance(v, dict) and str(v.get('type', '')).startswith('AstExpr')]
        pure[id(item)] = item.get('type') in PURE_KINDS and all(pure.get(id(v), False) for v in children)
    strings, folds = [], []
    for node in all_nodes:
        kind = node.get('type', '')
        if kind not in ('AstExprConstantString', 'AstExprBinary', 'AstExprUnary', 'AstExprIfElse'):
            continue
        value = values.get(id(node), UNKNOWN)
        if value is UNKNOWN:
            continue
        replacement = literal(value)
        if replacement is None:
            continue
        try:
            begin, end = span(node.get('location'), source, starts)
        except (ValueError, TypeError):
            continue
        old = source[begin:end]
        # Keep comments, physical line positions, binary strings and synthesized
        # AST record-key nodes intact. Never apply global regex substitutions.
        if not old or b'\n' in old or b'\r' in old:
            continue
        if kind == 'AstExprConstantString':
            if old[:1] not in (b'"', b"'") or not re.search(rb'\\(?:[0-9]|x[0-9a-fA-F]|u\{)', old):
                continue
            if replacement != old:
                strings.append({'start': begin, 'end': end, 'replacement': replacement,
                                'kind': 'string-literal', 'location': node['location']})
        elif pure.get(id(node)) and b'--' not in old and len(replacement) < len(old):
            folds.append({'start': begin, 'end': end, 'replacement': b'(' + replacement + b')',
                          'kind': 'constant-expression', 'location': node['location']})
    return non_overlapping(strings), non_overlapping(folds), all_nodes


def bytecode_match(before, after, work, remaining):
    checks = []
    for level in (1, 2):
        first = bytecode_digest(before, work, level, remaining())
        second = bytecode_digest(after, work, level, remaining())
        checks.append({'optimization': level, 'originalSha256': first,
                       'candidateSha256': second, 'matched': first == second})
    return {'ok': all(check['matched'] for check in checks), 'checks': checks,
            'scope': 'Identical official Luau bytecode without debug/type metadata; no application execution.'}


def native_constants(source, edits, work, remaining):
    """Evaluate only whitelisted literal-expression ASTs in native Luau.

    No submitted function, name lookup, API call, or loader is included.
    A failed batch cannot silently validate any member of that batch.
    """
    from native_luau import check
    accepted, reports = [], []
    for start in range(0, len(edits), 64):
        batch = edits[start:start + 64]
        a, b = work / 'constant-before.tmp.luau', work / 'constant-after.tmp.luau'
        # Parentheses force one scalar result per expression, including nil.
        a.write_bytes(b'return ' + b','.join(b'(' + source[e['start']:e['end']] + b')' for e in batch))
        b.write_bytes(b'return ' + b','.join(b'(' + e['replacement'] + b')' for e in batch))
        try:
            before = check(a, 'trace', work, timeout=remaining())
            after = check(b, 'trace', work, timeout=remaining())
            valid = before.get('ok') and after.get('ok') and not before.get('events') and not after.get('events')
            left, right = before.get('returns', []), after.get('returns', [])
            valid = valid and len(left) == len(batch) and len(right) == len(batch)
            count = 0
            if valid:
                for edit, first, second in zip(batch, left, right):
                    # Preserve exact type, string bytes, arity and number text,
                    # including the sign of zero. No numeric tolerance.
                    if first == second:
                        accepted.append(edit); count += 1
            reports.append({'firstEdit': start, 'count': len(batch), 'matched': count,
                            'nativeCompleted': bool(valid)})
        finally:
            a.unlink(missing_ok=True); b.unlink(missing_ok=True)
    return accepted, {'method': 'native-pure-constant-values', 'batches': reports,
                      'applicationExecuted': False, 'matched': len(accepted),
                      'scope': 'Literal-only expressions; no submitted functions or external effects.'}


def safe_display(value: bytes):
    try:
        text = value.decode('utf8')
        return text if all(c.isprintable() or c in '\n\r\t' for c in text) else None
    except UnicodeDecodeError:
        return None


def inspect(tree, source):
    """Syntactic evidence only. URLs and API names are never followed or called."""
    all_nodes = list(nodes(tree))
    strings, functions, globals_, members, calls = [], [], set(), set(), []
    urls = {}
    for node in all_nodes:
        kind = node.get('type')
        if kind == 'AstExprConstantString':
            value = string_bytes(node)
            text = safe_display(value)
            if len(strings) < MAX_RECORDS:
                record = {'location': node.get('location'), 'bytes': len(value),
                          'sha256': hashlib.sha256(value).hexdigest(),
                          'kind': 'text' if text is not None else 'opaque-bytes'}
                if text is not None:
                    record.update(value=text[:4096], truncated=len(text) > 4096)
                else:
                    record.update(previewHex=value[:64].hex(), interpretation='Unresolved binary data, not recovered source')
                strings.append(record)
            if text and len(text) <= 8192 and text.startswith(('https://', 'http://')):
                try:
                    parts = urlsplit(text)
                    if parts.hostname:
                        urls.setdefault(text, {'url': text, 'evidence': 'literal', 'location': node.get('location'), 'fetched': False})
                except ValueError:
                    pass
        elif kind == 'AstExprFunction' and len(functions) < MAX_RECORDS:
            functions.append({'name': node.get('debugname') or None, 'location': node.get('location'),
                              'parameters': [arg.get('name') for arg in node.get('args', [])],
                              'vararg': node.get('vararg', False), 'executed': None})
        elif kind == 'AstExprGlobal':
            globals_.add(node.get('global', ''))
        elif kind == 'AstExprIndexName':
            members.add(node.get('index', ''))
        elif kind == 'AstExprCall' and len(calls) < MAX_RECORDS:
            func = node.get('func', {})
            name = func.get('global') or func.get('index') or func.get('local', {}).get('name')
            if name:
                calls.append({'name': name, 'location': node.get('location'), 'executed': None})
    # Derive immutable-local constant chains for reporting only. Local identity
    # includes its declaration location, so same-name shadowing stays distinct.
    assigned = set()
    declarations = []
    for node in all_nodes:
        if node.get('type') in ('AstStatAssign', 'AstStatCompoundAssign'):
            targets = node.get('vars', []) if node.get('type') == 'AstStatAssign' else [node.get('var', {})]
            for target in targets:
                if target.get('type') == 'AstExprLocal': assigned.add(local_key(target['local']))
        elif node.get('type') == 'AstStatLocal':
            for var, expression in zip(node.get('vars', []), node.get('values', [])):
                declarations.append((var, expression))
    bindings = {}
    for _ in range(8):
        changed = False
        values = values_for(all_nodes, bindings)
        for var, expression in declarations:
            key = local_key(var)
            value = values.get(id(expression), UNKNOWN)
            if key not in assigned and key not in bindings and value is not UNKNOWN:
                bindings[key] = value
                changed = True
                if isinstance(value, bytes):
                    text = safe_display(value)
                    if text and len(text) <= 8192 and text.startswith(('https://', 'http://')):
                        urls.setdefault(text, {'url': text, 'evidence': 'immutable-local-constant-chain',
                                               'name': var.get('name'), 'location': var.get('location'), 'fetched': False})
        if not changed: break
    http_names = {'HttpGet', 'HttpGetAsync', 'GetAsync', 'RequestAsync', 'request',
                  'http_request', 'httpRequest', 'httprequest'}
    # API strings are possible dynamic lookup keys, not proven executed calls.
    text_keys = {entry.get('value') for entry in strings if entry['kind'] == 'text'}
    available_names = globals_ | members | text_keys
    dynamic = bool({'loadstring', 'load'} & available_names)
    http = bool(http_names & available_names)
    return {'formatVersion': 1, 'scope': 'static-syntax-and-constants', 'executed': False,
            'functions': functions, 'calls': calls, 'globalReferences': sorted(globals_),
            'strings': strings, 'urls': list(urls.values())[:256],
            'dependencies': {'possibleExternalLoader': bool(dynamic and http and urls),
                             'dynamicCompilationReferenced': dynamic, 'httpReferenced': http,
                             'externalBodiesRetrieved': 0, 'credentialValueEvaluated': False},
            'coverage': {'syntacticFunctionCount': sum(n.get('type') == 'AstExprFunction' for n in all_nodes),
                         'nodeCount': len(all_nodes), 'recordLimit': MAX_RECORDS,
                         'entriesCapped': any(len(x) >= MAX_RECORDS for x in (strings, functions, calls)),
                         'urlsCapped': len(urls) > 256, 'includesUncalledBodies': True},
            'limitations': ['Syntactic references are not runtime observations.',
                           'Opaque binary literals and external runtime bodies are not decrypted by literal normalization.']}


def extract_embedded(tree, work, prefix, remaining):
    """Recover literal source arguments, not remotely obtained runtime bodies."""
    all_nodes = list(nodes(tree))
    assigned, aliases, declarations = set(), set(), []
    for node in all_nodes:
        if node.get('type') == 'AstStatAssign':
            assigned.update(local_key(v['local']) for v in node.get('vars', []) if v.get('type') == 'AstExprLocal')
        elif node.get('type') == 'AstStatCompoundAssign':
            var = node.get('var', {})
            if var.get('type') == 'AstExprLocal': assigned.add(local_key(var['local']))
        elif node.get('type') == 'AstStatLocal':
            declarations.extend(zip(node.get('vars', []), node.get('values', [])))
    bindings = {}
    for _ in range(8):
        values = values_for(all_nodes, bindings)
        changed = False
        for var, expr in declarations:
            key = local_key(var)
            if key in assigned: continue
            if expr.get('type') == 'AstExprGlobal' and expr.get('global') in ('loadstring', 'load'):
                aliases.add(key)
            elif expr.get('type') == 'AstExprLocal' and local_key(expr['local']) in aliases:
                aliases.add(key)
            value = values.get(id(expr), UNKNOWN)
            if value is not UNKNOWN and key not in bindings:
                bindings[key] = value; changed = True
        if not changed: break
    values = values_for(all_nodes, bindings)
    result, seen, total = [], set(), 0
    for node in all_nodes:
        if node.get('type') != 'AstExprCall' or not node.get('args'): continue
        func = node.get('func', {})
        recognized = func.get('type') == 'AstExprGlobal' and func.get('global') in ('loadstring', 'load')
        recognized = recognized or (func.get('type') == 'AstExprLocal' and local_key(func['local']) in aliases)
        value = values.get(id(node['args'][0]), UNKNOWN)
        if not recognized or not isinstance(value, bytes): continue
        digest = hashlib.sha256(value).hexdigest()
        if digest in seen or len(result) >= 8 or total + len(value) > 2 * 1024 * 1024: continue
        try: value.decode('utf8')
        except UnicodeDecodeError: continue
        seen.add(digest); total += len(value)
        name = prefix + '.embedded.' + str(len(result) + 1).zfill(3) + '.luau'
        path = work / name; path.write_bytes(value)
        checked = compile_check(path, work, remaining())
        result.append({'artifact': name, 'bytes': len(value), 'sha256': digest,
                       'location': node.get('location'), 'compile': checked,
                       'executed': False, 'evidence': 'constant argument to a syntactic dynamic compiler reference',
                       'limitation': 'Call target/runtime execution is not proven; this is an embedded source candidate.'})
    return result


def cleanup(path: Path, work: Path, seconds: float = 20, prefix='program') -> dict:
    started = time.monotonic()
    work.mkdir(parents=True, exist_ok=True)
    source = path.read_bytes()
    report = {'formatVersion': 2, 'runtimeVersion': LUAU_VERSION, 'executed': False,
              'inputSha256': hashlib.sha256(source).hexdigest(), 'primary': path.name,
              'escapedLiteralsDecoded': 0, 'constantExpressionsFolded': 0,
              'changed': False, 'validation': {}, 'warnings': [], 'edits': []}
    def remaining():
        left = seconds - (time.monotonic() - started)
        if left <= 0: raise NativeFailure('Static analysis deadline reached')
        return min(8.0, left)
    try:
        checked = compile_check(path, work, remaining())
        report['validation']['inputCompile'] = checked
        if not checked['ok']: return report
        tree = parse_ast(path, work, remaining())
        strings, folds, _ = make_edits(source, tree)
        evidence = inspect(tree, source)
        (work / (prefix + '.inspection.json')).write_text(json.dumps(evidence, indent=2, ensure_ascii=True))
        report['inspectionArtifact'] = prefix + '.inspection.json'
        report['embeddedSources'] = extract_embedded(tree, work, prefix, remaining)
        if report['embeddedSources']:
            (work / (prefix + '.embedded.json')).write_text(json.dumps(report['embeddedSources'], indent=2))
        report['possibleExternalLoader'] = evidence['dependencies']['possibleExternalLoader']
        report['urlCount'] = len(evidence['urls'])
        report['syntacticFunctions'] = evidence['coverage']['syntacticFunctionCount']
        report['coverageCapped'] = evidence['coverage']['entriesCapped'] or evidence['coverage']['urlsCapped']
        report['globalReferences'] = evidence['globalReferences']
        report['opaqueBinaryLiterals'] = sum(x['kind'] == 'opaque-bytes' for x in evidence['strings'])
        selected, selected_tree, accepted = source, tree, []
        candidate = work / (prefix + '.readable.luau')
        if strings:
            candidate.write_bytes(apply(source, strings))
            candidate_tree = parse_ast(candidate, work, remaining())
            valid = ast_digest(tree) == ast_digest(candidate_tree)
            compiled = compile_check(candidate, work, remaining())
            report['validation']['literalEdits'] = {'astEqual': valid, 'compile': compiled}
            if valid and compiled['ok']:
                selected, selected_tree, accepted = candidate.read_bytes(), candidate_tree, strings
                report['escapedLiteralsDecoded'] = len(strings)
            else:
                report['warnings'].append('Literal rewrite validation failed; the original was retained.')
        # Propose reductions against original spans, including literal edits.
        if folds:
            proposed = non_overlapping(folds + strings)
            candidate.write_bytes(apply(source, proposed))
            try:
                proof = bytecode_match(path, candidate, work, remaining)
            except NativeFailure as error:
                proof = {'ok': False, 'error': str(error)}
            report['validation']['constantEdits'] = proof
            if proof['ok']:
                selected = candidate.read_bytes()
                selected_tree = parse_ast(candidate, work, remaining())
                accepted = proposed
                report['constantExpressionsFolded'] = sum(e['kind'] == 'constant-expression' for e in accepted)
                # Count string-node edits retained directly or contained within
                # a validated constant replacement, not pool decoder entries.
                report['escapedLiteralsDecoded'] = sum(any(e['start'] <= s['start'] and e['end'] >= s['end'] for e in accepted) for s in strings)
            else:
                verified, values_proof = native_constants(source, folds, work, remaining)
                report['validation']['constantValues'] = values_proof
                if verified:
                    proposed = non_overlapping(verified + strings)
                    candidate.write_bytes(apply(source, proposed))
                    check = compile_check(candidate, work, remaining())
                    if check['ok']:
                        selected, selected_tree, accepted = candidate.read_bytes(), parse_ast(candidate, work, remaining()), proposed
                        report['constantExpressionsFolded'] = len(verified)
                        report['escapedLiteralsDecoded'] = sum(any(e['start'] <= t['start'] and e['end'] >= t['end'] for e in accepted) for t in strings)
                if len(verified) < len(folds):
                    report['warnings'].append('Unconfirmed constant reductions were discarded; other verified changes remain.')
        candidate.write_bytes(selected)
        final_check = compile_check(candidate, work, remaining())
        report['validation']['selectedCompile'] = final_check
        if not final_check['ok']:
            candidate.unlink(missing_ok=True)
            report['warnings'].append('Transformed source did not compile; no transformed artifact was promoted.')
            report['escapedLiteralsDecoded'] = report['constantExpressionsFolded'] = 0
            return report
        report['changed'] = selected != source
        if report['changed']:
            report['primary'] = candidate.name
            report['outputSha256'] = hashlib.sha256(selected).hexdigest()
            for edit in accepted:
                old = source[edit['start']:edit['end']]
                report['edits'].append({'kind': edit['kind'], 'location': edit['location'],
                    'startByte': edit['start'], 'endByte': edit['end'],
                    'before': old[:240].decode('utf8', 'replace'),
                    'after': edit['replacement'][:240].decode('utf8', 'replace'),
                    'previewTruncated': len(old) > 240 or len(edit['replacement']) > 240})
        else:
            candidate.unlink(missing_ok=True)
        # Optional formatter: mandatory official AST/bytecode validation below.
        # StyLua's own --verify can report false differences on numeric VM
        # scaffolds, so native validation is the acceptance gate.
        if shutil.which('stylua'):
            formatted = work / (prefix + '.formatted.luau')
            formatted.write_bytes(selected)
            try:
                run_tool('stylua', ['--syntax', 'Luau', '--indent-type', 'Spaces',
                         '--indent-width', '4', '--column-width', '100', str(formatted.resolve())], work, remaining())
                formatted_tree = parse_ast(formatted, work, remaining())
                same = ast_digest(selected_tree) == ast_digest(formatted_tree)
                proof = None
                if not same:
                    comparison = work / (prefix + '.format-base.tmp.luau')
                    comparison.write_bytes(selected)
                    try:
                        proof = bytecode_match(comparison, formatted, work, remaining)
                        same = proof['ok']
                    finally:
                        comparison.unlink(missing_ok=True)
                fmt_check = compile_check(formatted, work, remaining())
                report['validation']['formatting'] = {'equivalent': same, 'bytecode': proof, 'compile': fmt_check}
                if same and fmt_check['ok'] and formatted.read_bytes() != selected:
                    report['formattedArtifact'] = formatted.name
                    report['warnings'].append('Formatting passed native structural or bytecode validation, but line-number/debug-source/timing observations can differ. The unformatted source remains available.')
                else:
                    formatted.unlink(missing_ok=True)
            except NativeFailure as error:
                formatted.unlink(missing_ok=True)
                report['warnings'].append('Optional formatting stopped: ' + str(error)[:400])
    except (NativeFailure, ValueError, RecursionError, MemoryError) as error:
        report['warnings'].append('Static analysis was bounded or unavailable: ' + str(error)[:500])
        # If analysis was interrupted, never leave an unchecked candidate in the
        # primary slot. The caller can still expose the original input.
        report['primary'] = path.name
        report['changed'] = False
        report['escapedLiteralsDecoded'] = report['constantExpressionsFolded'] = 0
        (work / (prefix + '.readable.luau')).unlink(missing_ok=True)
    finally:
        report['elapsedSeconds'] = round(time.monotonic() - started, 4)
    return report
