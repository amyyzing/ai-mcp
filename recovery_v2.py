"""Evidence-scoped recovery orchestration with native static cleanup for every input.

The original, full-program analysis, nested source and execution observations
remain distinct. No network dependency found in submitted code is fetched.
"""
from __future__ import annotations

import hashlib
import json
import os
import signal
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from native_tools import NativeFailure, LUAU_VERSION, compile_check, nodes, parse_ast
from readable import cleanup

VERSION = 'native-recovery-2.0.0'
ROOT = Path(__file__).resolve().parent


def save(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=True), encoding='utf8')


def normalized(source: bytes):
    # Remove only a complete outer Markdown fence, never HTML-unescape code.
    stripped = source.strip()
    if stripped.startswith(b'```') and stripped.endswith(b'```'):
        end = stripped.find(b'\n')
        if end >= 0:
            return stripped[end + 1:-3], True
    return source, False


def stop_descendants(pid):
    # Descendants stay in the outer worker group, so cancellation by the web
    # server remains authoritative. Also reap children on a stage timeout.
    paths = list(Path('/proc').glob('[0-9]*/stat')) if Path('/proc').is_dir() else []
    children = {}
    for path in paths:
        try:
            tail = path.read_text().rsplit(')', 1)[1].split()
            parent = int(tail[1]); child = int(path.parent.name)
            children.setdefault(parent, []).append(child)
        except (OSError, ValueError, IndexError): pass
    pending, descendants = [pid], []
    while pending:
        current = pending.pop()
        for child in children.get(current, []):
            if child not in descendants: descendants.append(child); pending.append(child)
    for child in reversed(descendants):
        try: os.kill(child, signal.SIGKILL)
        except ProcessLookupError: pass


def legacy_run(source, output, seconds):
    """Quarantine specialized output until its child has completed."""
    specialized = output / '_specialized'
    specialized.mkdir(exist_ok=True)
    with tempfile.TemporaryFile(dir=output) as log:
        process = subprocess.Popen([sys.executable, str(ROOT / 'recovery.py'),
                                    str(source), str(specialized), str(max(1, int(seconds)))],
                                   cwd=specialized, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        try:
            process.wait(timeout=max(1, seconds))
        except subprocess.TimeoutExpired:
            stop_descendants(process.pid); process.kill(); process.wait(timeout=5)
            return None, 'Specialized recovery exceeded its stage budget; native static analysis was retained.'
        finally:
            if process.poll() is None:
                stop_descendants(process.pid); process.kill(); process.wait(timeout=5)
        log.seek(0, 2); size = log.tell(); log.seek(max(0, size - 16000))
        diagnostic = log.read(16000).decode('utf8', 'replace')
        pipeline = specialized / 'pipeline.json'
        if process.returncode == 0 and pipeline.is_file():
            result = json.loads(pipeline.read_text())
            save(output / 'specialized-pipeline.json', result)
            for path in specialized.iterdir():
                if path.is_file() and not path.is_symlink() and path.suffix in ('.json','.lua','.luau'):
                    if path.name == 'pipeline.json': continue
                    name = 'specialized-recovery-report.json' if path.name == 'recovery-report.json' else path.name
                    # The normalized original is owned by the orchestrator.
                    if name != 'program.source.luau': shutil.copyfile(path, output / name)
                elif path.name == 'embedded_sources' and path.is_dir() and not path.is_symlink():
                    destination=output/'embedded_sources'; destination.mkdir(exist_ok=True)
                    for entry in path.iterdir():
                        if entry.is_file() and not entry.is_symlink() and entry.suffix in ('.json','.lua','.luau'):
                            shutil.copyfile(entry,destination/entry.name)
            return result, None
        save(output / 'specialized-failure.json', {'returnCode': process.returncode, 'diagnostic': diagnostic})
        return None, 'The specialized adapter did not finish; full static source and available evidence remain accessible.'


def wrapper_candidate(path, output, timeout):
    """Structural routing hint only; neither a banner nor size proves a VM."""
    try:
        tree = parse_ast(path, output, timeout)
        from native_pool import shape
        if shape(tree): return True
        statements = tree.get('body', [])
        all_nodes = list(nodes(tree))
        return (len(statements) == 1 and statements[0].get('type') == 'AstStatReturn'
                and sum(n.get('type') == 'AstExprFunction' for n in all_nodes) >= 4
                and any(n.get('type') in ('AstStatWhile', 'AstStatRepeat') for n in all_nodes))
    except NativeFailure:
        return False


def run(source_path: Path, output: Path, seconds: int = 180):
    started = time.monotonic()
    output = output.resolve(); output.mkdir(parents=True, exist_ok=True)
    source = source_path.read_bytes()
    original = output / 'original.input.luau'; original.write_bytes(source)
    text, unfenced = normalized(source)
    path = output / 'program.source.luau'; path.write_bytes(text)
    warnings = []
    if unfenced: warnings.append('A complete outer Markdown fence was removed. original.input.luau retains the exact submitted bytes.')
    def left(cap=20):
        available = seconds - (time.monotonic() - started) - 1
        if available <= 0: raise NativeFailure('Recovery deadline reached')
        return min(cap, available)

    print('[1/7] Checking the original with official Luau', flush=True)
    compiled = compile_check(path, output, left(8))
    if not compiled['ok']:
        save(output / 'syntax-error.json', compiled)
        raise ValueError(compiled.get('error', 'Invalid Luau source'))
    print('[2/7] Decoding literals and reducing verified constant expressions', flush=True)
    static = cleanup(path, output, left(min(24, seconds * .35)), prefix='program')
    save(output / 'static-cleanup.json', static)
    best = static.get('formattedArtifact') or static['primary']
    base = 'program.source.luau'
    outcome = ('constants-decoded' if static.get('constantExpressionsFolded') else
               'literals-decoded' if static.get('escapedLiteralsDecoded') else
               'formatted-only' if static.get('formattedArtifact') else 'unchanged')
    capture = 'static-source-analysis'
    family = 'external-loader' if static.get('possibleExternalLoader') else 'luau-source'
    partial = bool(static.get('coverageCapped'))
    changed = bool(static.get('changed'))
    legacy = None
    print('[3/7] Selecting a specialized VM adapter only when structure matches', flush=True)
    from luauvmp import luraph_loader
    luraph = luraph_loader.detect(text.decode('utf8'))
    candidate = not luraph and wrapper_candidate(path, output, left(5))
    if luraph or candidate:
        # Work in the existing output root so legacy artifacts keep their names.
        legacy, error = legacy_run(path, output, left(max(3, int(seconds * .45))))
        if error: warnings.append(error)
        partial = True
        family = 'luraph' if luraph else 'vm-shaped-luau'
        if legacy:
            if luraph and legacy.get('final_payload_executed') is not False:
                raise RuntimeError('The Luraph adapter did not confirm its final-payload non-execution boundary.')
            if not luraph and legacy.get('external_effects_allowed') is not False:
                raise RuntimeError('The specialized adapter did not confirm its no-external-effects boundary.')
            declared = legacy.get('primary')
            choices = ([declared] if declared and declared != 'program.application.luau' else [])
            useful_analysis = bool(legacy.get('decoded_pool_entries') or legacy.get('inlined_accessor_calls'))
            choices += ['embedded_main.luau', 'program.decompiled.luau']
            if useful_analysis: choices += ['program.analysis.luau']
            choices += ['program.pseudo.lua']
            if not useful_analysis: choices = [name for name in choices if name != 'program.analysis.luau']
            base = next((name for name in choices if name and (output / name).is_file()), base)
            if base != 'program.source.luau':
                capture = legacy.get('capture_kind', 'partial-vm-recovery')
                if capture == 'native-verified-application-view': capture = 'decoded-analysis'
                outcome = 'partial-vm-recovery'
                changed = True
                # An advisory analysis remains partial even if subsequent native
                # cleanup preserves its AST: this does not validate its origin.
                refined = cleanup(output / base, output, left(24), prefix='recovered')
                save(output / 'recovered-cleanup.json', refined)
                best = refined.get('formattedArtifact') or refined['primary']
                if not (output / best).is_file(): best = base
                warnings.extend(refined.get('warnings', []))
            else:
                outcome = 'partial-analysis'
        else:
            outcome = 'partial-analysis'
        warnings.append('VM-family routing is structural and version-specific. Static cleanup and successful compilation do not establish complete devirtualization.')
    print('[4/7] Keeping full source separate from observed application calls', flush=True)
    # Legacy code may rewrite program.source; restore the exact normalized input.
    path.write_bytes(text)
    observation = output / 'program.application.luau'
    observation_name = None
    if observation.is_file():
        observation_name = 'program.observed.luau'
        observation.replace(output / observation_name)
        warnings.append('program.observed.luau contains only calls/returns observed under bounded test profiles; it is not the full program and is not selected by default.')
    warnings.extend(static.get('warnings', []))
    if static.get('possibleExternalLoader'):
        warnings.append('External loader references were found. Downloaded runtime bodies were not supplied or fetched; binary handoff data remains opaque.')
        partial = True
    if legacy:
        warnings.extend(legacy.get('warnings', []))
        if legacy.get('finalization_error'): warnings.append(str(legacy['finalization_error'])[:1000])
    print('[5/7] Validating the actual selected output, not just the input', flush=True)
    if not (output / best).is_file(): best = static['primary']
    selected_check = compile_check(output / best, output, left(8))
    if not selected_check['ok']:
        warnings.append('Selected transformed source did not compile; the original source is selected instead.')
        best = path.name; selected_check = compiled; outcome = 'unchanged'; changed = False; partial = True
    selected_hash = hashlib.sha256((output / best).read_bytes()).hexdigest()
    print('[6/7] Reporting transformations, dependency gaps and artifact provenance', flush=True)
    warnings = list(dict.fromkeys(warnings))
    report = {
        'format_version': 5, 'adapter': VERSION, 'family': family,
        'primary': best, 'base_artifact': base, 'outcome': outcome,
        'changed': changed, 'formatting_changed': best.endswith('.formatted.luau'),
        'input_sha256': hashlib.sha256(source).hexdigest(), 'output_sha256': selected_hash,
        'partial': partial, 'complete_devirtualization': False,
        'warnings': warnings, 'external_effects_allowed': False,
        'final_payload_executed': bool(legacy and legacy.get('final_payload_executed')),
        'native_original_attempted': bool(legacy and legacy.get('native_original_attempted')),
        'execution_context': legacy.get('execution_context', 'capture-only') if legacy else 'static-no-execution',
        'capture_kind': capture, 'native_runtime': 'official-luau-' + LUAU_VERSION,
        'escaped_literals_decoded': static.get('escapedLiteralsDecoded', 0),
        'constant_expressions_folded': static.get('constantExpressionsFolded', 0),
        'decoded_pool_entries': legacy.get('decoded_pool_entries') if legacy else None,
        'inlined_accessor_calls': legacy.get('inlined_accessor_calls') if legacy else None,
        'native_comparisons_passed': legacy.get('native_comparisons_passed') if legacy else None,
        'observed_artifact': observation_name,
        'artifact_aliases': {'program.application.luau': observation_name} if observation_name else {},
        'native_constant_prefix': (output / 'native-constant-pool.json').is_file(),
        'syntactic_functions': static.get('syntacticFunctions'),
        'external_urls': static.get('urlCount', 0),
        'opaque_binary_literals': static.get('opaqueBinaryLiterals', 0),
        'embedded_sources': len(static.get('embeddedSources', [])),
        'decompiler': {'compile_checked': selected_check['ok'],
                       'fallback_instructions': (legacy or {}).get('decompiler', {}).get('fallback_instructions')},
        'analysis_validation': static.get('validation', {}),
        'elapsed_seconds': round(time.monotonic() - started, 4),
    }
    if legacy:
        for key in ('bootstrap_executed', 'bootstrap_completed', 'finalization_error', 'prototypes', 'instructions', 'unresolved_dispatcher_conditionals'):
            if key in legacy: report[key] = legacy[key]
    save(output / 'pipeline.json', report)
    save(output / 'recovery-report.json', {'pipeline': report, 'staticCleanup': static,
         'selectedArtifactCompileCheck': selected_check,
         'equivalenceScope': 'Literal edits preserve native AST values. Constant folds require matching debug-free O1/O2 bytecode or exact native evaluation of strictly literal-only expressions. Specialized VM recovery and trace observations have separate, narrower evidence.'})
    print('[7/7] Analysis finished: ' + outcome, flush=True)
    return report


if __name__ == '__main__':
    try:
        run(Path(sys.argv[1]), Path(sys.argv[2]), int(sys.argv[3]))
    except Exception as error:
        print('RECOVERY_UNSUPPORTED: ' + str(error)[:1500], flush=True)
        sys.exit(3)
