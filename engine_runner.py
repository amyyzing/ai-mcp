"""Set operating-system resource limits, then launch the selected recovery adapter."""
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
from recovery import main
main(source, output, seconds)
