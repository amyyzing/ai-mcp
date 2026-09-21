"""Set operating-system resource limits, then launch the real pinned engine."""
import os
import resource
import sys

source, output, limit = sys.argv[1:]
seconds = int(limit)
resource.setrlimit(resource.RLIMIT_CPU, (seconds + 5, seconds + 10))
resource.setrlimit(resource.RLIMIT_AS, (1536 * 1024**2, 1536 * 1024**2))
resource.setrlimit(resource.RLIMIT_FSIZE, (64 * 1024**2, 64 * 1024**2))
resource.setrlimit(resource.RLIMIT_NOFILE, (256, 256))
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
os.execv(sys.executable, [sys.executable, "-m", "luauvmp", "luraph-full", source,
                         "-o", output, "--force", "--no-lua-expert", "--timeout", str(seconds)])
