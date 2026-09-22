"""Bounded official-Luau tools. Submitted chunks are never executed here."""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

LUAU_VERSION = '0.739'
MAX_AST = 48 * 1024 * 1024
MAX_OUTPUT = 16 * 1024 * 1024


class NativeFailure(RuntimeError):
    pass


def run_tool(tool: str, args: list[str], work: Path, timeout: float = 8,
             limit: int = MAX_OUTPUT) -> bytes:
    binary = shutil.which(tool)
    if not binary:
        raise NativeFailure('Required official tool is unavailable: ' + tool)
    work.mkdir(parents=True, exist_ok=True)
    # Spool output, enforce a live size limit, and always reap the process.
    with tempfile.TemporaryFile(dir=work) as stdout, tempfile.TemporaryFile(dir=work) as stderr:
        process = subprocess.Popen([binary, *args], cwd=work, stdin=subprocess.DEVNULL,
                                   stdout=stdout, stderr=stderr)
        deadline = time.monotonic() + max(0.05, timeout)
        try:
            while process.poll() is None:
                if time.monotonic() > deadline:
                    raise NativeFailure(tool + ' exceeded its deadline')
                if os.fstat(stdout.fileno()).st_size > limit or os.fstat(stderr.fileno()).st_size > 1024 * 1024:
                    raise NativeFailure(tool + ' exceeded its output budget')
                time.sleep(0.01)
            if os.fstat(stdout.fileno()).st_size > limit or os.fstat(stderr.fileno()).st_size > 1024 * 1024:
                raise NativeFailure(tool + ' exceeded its output budget')
            if process.returncode:
                stderr.seek(0)
                detail = stderr.read(1600).decode('utf8', 'replace')
                raise NativeFailure(tool + ' failed: ' + detail)
            stdout.seek(0)
            return stdout.read(limit + 1)
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)


def compile_check(path: Path, work: Path, timeout: float = 8) -> dict:
    try:
        run_tool('luau-compile', ['--null', str(path.resolve())], work, timeout)
        return {'ok': True, 'runtimeVersion': LUAU_VERSION, 'executed': False}
    except NativeFailure as error:
        return {'ok': False, 'runtimeVersion': LUAU_VERSION, 'executed': False,
                'error': str(error)}


def parse_ast(path: Path, work: Path, timeout: float = 8) -> dict:
    raw = run_tool('luau-ast', [str(path.resolve())], work, timeout, MAX_AST)
    # The upstream encoder emits raw bytes >= 0x20, including invalid UTF-8
    # inside binary literals. Latin-1 is a reversible transport, not a guess
    # that the program's strings are Latin-1 text.
    try:
        tree = json.loads(raw.decode('latin1'))
    except (ValueError, RecursionError) as error:
        raise NativeFailure('Official AST could not be decoded: ' + str(error)) from error
    root = tree.get('root', tree)
    if not isinstance(root, dict) or root.get('type') != 'AstStatBlock':
        raise NativeFailure('Unexpected official AST root')
    return root


def nodes(tree: dict, maximum: int = 500000):
    stack = [tree]
    count = 0
    while stack:
        item = stack.pop()
        if isinstance(item, list):
            stack.extend(reversed(item))
        elif isinstance(item, dict):
            count += 1
            if count > maximum:
                raise NativeFailure('AST node budget exceeded')
            yield item
            # A local reference embeds its declaration; don't visit that
            # declaration again for analysis/patch generation.
            for key, value in reversed(list(item.items())):
                if key != 'local' and isinstance(value, (dict, list)):
                    stack.append(value)


def ast_digest(tree: dict) -> str:
    """Structural fingerprint excluding only source-coordinate metadata."""
    digest = hashlib.sha256()
    stack = [tree]
    while stack:
        item = stack.pop()
        if isinstance(item, dict):
            pairs = [(k, v) for k, v in sorted(item.items())
                     if 'location' not in k.lower()]
            digest.update(b'd' + str(len(pairs)).encode() + b':')
            for key, value in reversed(pairs):
                stack.extend([value, key])
        elif isinstance(item, list):
            digest.update(b'l' + str(len(item)).encode() + b':')
            stack.extend(reversed(item))
        else:
            data = json.dumps(item, ensure_ascii=True, allow_nan=True).encode('ascii')
            digest.update(str(len(data)).encode() + b':' + data)
    return digest.hexdigest()


def bytecode_digest(path: Path, work: Path, level: int = 1, timeout: float = 8) -> str:
    data = run_tool('luau-compile', ['--binary', '-O' + str(level), '-g0', '-t0',
                                   str(path.resolve())], work, timeout)
    if not data:
        raise NativeFailure('Compiler returned empty bytecode')
    return hashlib.sha256(data).hexdigest()


def span(location: str, source: bytes, starts: list[int]) -> tuple[int, int]:
    match = re.fullmatch(r'(\d+),(\d+) - (\d+),(\d+)', location or '')
    if not match:
        raise ValueError('Invalid AST source location')
    line1, col1, line2, col2 = map(int, match.groups())
    if line1 >= len(starts) or line2 >= len(starts):
        raise ValueError('AST location outside source')
    begin, end = starts[line1] + col1, starts[line2] + col2
    if not 0 <= begin <= end <= len(source):
        raise ValueError('AST byte span outside source')
    return begin, end


def line_starts(source: bytes) -> list[int]:
    return [0] + [m.end() for m in re.finditer(b'\n', source)]


def string_bytes(node: dict) -> bytes:
    return node['value'].encode('latin1')
