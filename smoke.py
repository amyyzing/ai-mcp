"""Build-time real-engine smoke tests; not a real-world obfuscator corpus."""
import hashlib
import sys
import tempfile
from pathlib import Path
from luauvmp.luraph_full import Instruction, Program, Proto
from luauvmp.luraph_decompiler import write_decompiled, compile_check
import server
sys.path.insert(0, str(Path(__file__).resolve().parent / 'tests'))
from fixture_shapes import protected_literal

with tempfile.TemporaryDirectory() as folder:
    root = Path(folder)
    program = Program({0: Proto(0, -1, -1, -1, 2, None, None, None, 1, [
        Instruction(0, 1, 'owned recovery smoke fixture', 91, None, 0, None, None, None),
        Instruction(0, 2, None, 99, None, None, None, 0, None),
    ])}, 1)
    semantics = {91: 'c[o[u]]=(E[u]);', 99: 'return c[_[u]];'}
    metrics = write_decompiled(program, semantics, root)
    assert metrics['fallback_instructions'] == 0, metrics
    compile_check(root / 'program.decompiled.luau', root, timeout=30)
    assert 'owned recovery smoke fixture' in (root / 'program.decompiled.luau').read_text()
    print('SMOKE: pinned Luraph engine instruction lifting and Lune compilation passed', flush=True)

def job_for(source, mode='strict'):
    job = server.Job('build-test', 'build-owner', 'fixture.luau', hashlib.sha256(source.encode()).hexdigest(), mode, 30)
    server.execute(job, source)
    assert job.finished is not None, 'Worker cleanup did not complete'
    return job

plain = 'print("plain owned fixture")'
job = job_for(plain)
assert job.state == 'completed', (job.state, job.error)
assert job.primary in ('program.source.luau','program.formatted.luau'), job.quality
assert job.quality['captureKind'] == 'static-source-analysis', job.quality
assert job.quality['compileChecked'] is True, job.quality
assert job.quality['finalPayloadExecuted'] is False, job.quality
assert job.artifacts[job.primary].decode().strip() == plain
print('SMOKE: plain source passed through and compiled without execution', flush=True)

job = job_for(protected_literal(b'owned worker end-to-end fixture'), 'sandboxed')
assert job.state == 'partial', (job.state, job.error, job.warnings)
assert job.primary not in ('program.application.luau','program.observed.luau'), (job.primary, job.warnings)
assert job.quality['nativeComparisons'] == 3, job.quality
assert job.quality['nativeRuntime'] == 'official-luau-0.739', job.quality
assert job.artifacts['program.observed.luau'].decode().strip() == 'print("owned worker end-to-end fixture")'
print('SMOKE: real worker subprocess recovered owned VM-shaped fixture with three native comparisons', flush=True)

job = job_for('local =')
assert job.state == 'unsupported', (job.state, job.error)
assert not job.primary, job.primary
print('SMOKE: malformed source rejected without fabricated output', flush=True)
