"""Resource-bounded recovery routing with an official-Luau syntax fallback."""
import os
from pathlib import Path
import resource
import sys

source, output, limit = sys.argv[1:]
seconds = int(limit)
resource.setrlimit(resource.RLIMIT_CPU, (seconds + 5, seconds + 10))
resource.setrlimit(resource.RLIMIT_AS, (1536 * 1024**2, 1536 * 1024**2))
resource.setrlimit(resource.RLIMIT_FSIZE, (64 * 1024**2, 64 * 1024**2))
resource.setrlimit(resource.RLIMIT_NOFILE, (256, 256))
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))

from recovery import main, strip_fence
from lua_tokens import SyntaxFailure
from lua_parse import Parser
from luauvmp import luraph_loader

text = Path(source).read_text(encoding='utf8')
if not luraph_loader.detect(text):
    try:
        Parser(strip_fence(text)).parse()
    except (SyntaxFailure, RecursionError):
        from modern_luau import run
        try:
            run(Path(source), Path(output), seconds)
        except Exception as error:
            print('RECOVERY_UNSUPPORTED: ' + str(error)[:1200], flush=True)
            sys.exit(3)
        sys.exit(0)
main(source, output, seconds)
