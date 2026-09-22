"""Apply OS resource limits and run the recovery orchestrator."""
import resource
import sys
from pathlib import Path

source, output, limit = sys.argv[1:]
seconds = int(limit)
resource.setrlimit(resource.RLIMIT_CPU, (seconds + 5, seconds + 10))
resource.setrlimit(resource.RLIMIT_AS, (1536 * 1024**2, 1536 * 1024**2))
resource.setrlimit(resource.RLIMIT_FSIZE, (64 * 1024**2, 64 * 1024**2))
resource.setrlimit(resource.RLIMIT_NOFILE, (256, 256))
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
from recovery_v2 import run
try:
    run(Path(source), Path(output), seconds)
except Exception as error:
    print('RECOVERY_UNSUPPORTED: ' + str(error)[:1500], flush=True)
    sys.exit(3)
