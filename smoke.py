"""Build-time native smoke test. This is not a real-world Luraph corpus test."""
import tempfile
from pathlib import Path
from luauvmp.luraph_full import Instruction, Program, Proto
from luauvmp.luraph_decompiler import write_decompiled, compile_check
import server

with tempfile.TemporaryDirectory() as folder:
    root = Path(folder)
    program = Program({0: Proto(0, -1, -1, -1, 2, None, None, None, 1, [
        Instruction(0, 1, 'cats ran over the fence', 91, None, 0, None, None, None),
        Instruction(0, 2, None, 99, None, None, None, 0, None),
    ])}, 1)
    semantics = {91: 'c[o[u]]=(E[u]);', 99: 'return c[_[u]];'}
    metrics = write_decompiled(program, semantics, root)
    assert metrics['fallback_instructions'] == 0, metrics
    compile_check(root / 'program.decompiled.luau', root, timeout=30)
    assert 'cats ran over the fence' in (root / 'program.decompiled.luau').read_text()
    print('SMOKE: actual instruction lifting and native Lune compilation passed', flush=True)
job = server.Job('build-test', 'build-owner', 'plain.luau', 'test', 'strict', 30)
server.execute(job, 'print("plain owned fixture")')
assert job.state == 'unsupported', (job.state, job.error, job.artifacts)
print('SMOKE: actual CLI subprocess correctly rejected unsupported input', flush=True)
