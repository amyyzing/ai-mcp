from __future__ import annotations

import hmac
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


MAX_REQUEST_BYTES = 24 * 1024 * 1024
MAX_SOURCE_BYTES = 4 * 1024 * 1024
MAX_RESULT_CHARS = 1024 * 1024
MAX_LOG_CHARS = 8_000
DEFAULT_TIMEOUT_SECONDS = 180
MAX_TIMEOUT_SECONDS = 600
RUN_SLOT = threading.BoundedSemaphore(1)


def bounded_int(value: Any, fallback: int, minimum: int, maximum: int) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return fallback
    return min(maximum, max(minimum, parsed))


def find_metric(value: Any, key: str) -> Any:
    if isinstance(value, dict):
        if key in value:
            return value[key]
        for child in value.values():
            found = find_metric(child, key)
            if found is not None:
                return found
    elif isinstance(value, list):
        for child in value:
            found = find_metric(child, key)
            if found is not None:
                return found
    return None


def quality_summary(pipeline: Any) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for source_key, result_key in (
        ("compile_checked", "compileChecked"),
        ("fallback_instructions", "fallbackInstructions"),
        ("unresolved_dispatcher_conditionals", "unresolvedDispatcherConditionals"),
        ("bootstrap_executed", "bootstrapExecuted"),
        ("final_payload_executed", "finalPayloadExecuted"),
        ("capture_kind", "captureKind"),
    ):
        found = find_metric(pipeline, source_key)
        if found is not None:
            result[result_key] = found
    return result


def read_text(path: pathlib.Path, limit: int) -> tuple[str, int, bool]:
    text = path.read_text(encoding="utf-8", errors="replace")
    total = len(text)
    if len(text) <= limit:
        return text, total, False
    return text[:limit], total, True


def recovered_output(
    output_dir: pathlib.Path, max_chars: int
) -> tuple[str, str, int, bool]:
    candidates = (
        "embedded_main.luau",
        "program.decompiled.luau",
        "program.pseudo.lua",
    )
    for name in candidates:
        path = output_dir / name
        if path.is_file():
            source, total, truncated = read_text(path, max_chars)
            return name, source, total, truncated
    embedded_dir = output_dir / "embedded_sources"
    if embedded_dir.is_dir():
        for path in sorted(embedded_dir.glob("*.luau")):
            source, total, truncated = read_text(path, max_chars)
            return f"embedded_sources/{path.name}", source, total, truncated
    raise RuntimeError("The devirtualizer did not produce a supported source artifact.")


def subprocess_environment(strict_capture: bool, temp_dir: pathlib.Path) -> dict[str, str]:
    # Pass only the small environment needed by Python/Lune. In particular, the
    # worker authentication token is not inherited by the analysis process.
    allowed = {
        key: os.environ[key]
        for key in ("PATH", "LANG", "LC_ALL", "PYTHONPATH", "PYTHONHOME")
        if key in os.environ
    }
    allowed.update(
        {
            "HOME": str(temp_dir),
            "TMPDIR": str(temp_dir),
            "LUAUVMP_INSTRUCTION_BUDGET": os.environ.get(
                "LUAUVMP_INSTRUCTION_BUDGET", "5000000"
            ),
        }
    )
    if strict_capture:
        allowed["LUAUVMP_STRICT_CAPTURE"] = "1"
    return allowed


def run_devirtualizer(payload: dict[str, Any]) -> dict[str, Any]:
    source = payload.get("source")
    if not isinstance(source, str) or not source:
        raise ValueError("source must be a non-empty string.")
    if len(source.encode("utf-8")) > MAX_SOURCE_BYTES:
        raise ValueError(f"source exceeds the {MAX_SOURCE_BYTES}-byte limit.")

    capture_mode = payload.get("captureMode", "strict")
    if capture_mode not in ("strict", "sandboxed"):
        raise ValueError("captureMode must be strict or sandboxed.")
    timeout_seconds = bounded_int(
        payload.get("timeoutSeconds"),
        DEFAULT_TIMEOUT_SECONDS,
        30,
        MAX_TIMEOUT_SECONDS,
    )
    max_result_chars = bounded_int(
        payload.get("maxResultChars"),
        MAX_RESULT_CHARS,
        1_000,
        MAX_RESULT_CHARS,
    )
    executable = os.environ.get("LURAPH_CLI", "luauvmp")
    started = time.monotonic()

    with tempfile.TemporaryDirectory(prefix="luraph-job-") as temp_name:
        temp_dir = pathlib.Path(temp_name)
        input_path = temp_dir / "protected.lua"
        output_dir = temp_dir / "recovered"
        input_path.write_text(source, encoding="utf-8")
        command = [
            executable,
            "luraph-full",
            str(input_path),
            "-o",
            str(output_dir),
            "--force",
            "--no-lua-expert",
            "--timeout",
            str(timeout_seconds),
        ]
        try:
            completed = subprocess.run(
                command,
                cwd=temp_dir,
                env=subprocess_environment(capture_mode == "strict", temp_dir),
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=timeout_seconds + 15,
                check=False,
            )
        except FileNotFoundError as error:
            raise RuntimeError(f"Devirtualizer executable was not found: {executable}") from error
        except subprocess.TimeoutExpired as error:
            raise RuntimeError(
                f"Devirtualization exceeded the {timeout_seconds}-second timeout."
            ) from error

        log = (completed.stdout + "\n" + completed.stderr).strip()
        if completed.returncode != 0:
            detail = log[-MAX_LOG_CHARS:] or f"exit code {completed.returncode}"
            raise RuntimeError(f"Devirtualizer failed: {detail}")

        output_file, recovered, recovered_chars, truncated = recovered_output(
            output_dir, max_result_chars
        )
        pipeline: Any = {}
        pipeline_path = output_dir / "pipeline.json"
        if pipeline_path.is_file() and pipeline_path.stat().st_size <= 1024 * 1024:
            try:
                pipeline = json.loads(pipeline_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                pipeline = {}

        return {
            "ok": True,
            "outputFile": output_file,
            "source": recovered,
            "sourceChars": recovered_chars,
            "sourceTruncated": truncated,
            "quality": quality_summary(pipeline),
            "log": log[-MAX_LOG_CHARS:],
            "durationMs": round((time.monotonic() - started) * 1000),
        }


class Handler(BaseHTTPRequestHandler):
    server_version = "RobloxMcpLuraphWorker/1.0"

    def log_message(self, message: str, *args: Any) -> None:
        print(f"[luraph-worker] {self.address_string()} {message % args}", flush=True)

    def send_json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def authorised(self) -> bool:
        expected = os.environ.get("LURAPH_WORKER_TOKEN", "")
        if not expected:
            return False
        supplied = self.headers.get("Authorization", "")
        prefix = "Bearer "
        return supplied.startswith(prefix) and hmac.compare_digest(
            supplied[len(prefix) :], expected
        )

    def do_GET(self) -> None:
        if self.path.rstrip("/") == "/health":
            devirtualizer = shutil.which(os.environ.get("LURAPH_CLI", "luauvmp")) is not None
            lune = shutil.which("lune") is not None
            self.send_json(
                200 if devirtualizer and lune else 503,
                {
                    "ok": devirtualizer and lune,
                    "service": "luraph-worker",
                    "devirtualizer": devirtualizer,
                    "lune": lune,
                },
            )
            return
        self.send_json(404, {"ok": False, "error": "Not found."})

    def do_POST(self) -> None:
        if self.path.rstrip("/") != "/devirtualize":
            self.send_json(404, {"ok": False, "error": "Not found."})
            return
        if not self.authorised():
            self.send_json(401, {"ok": False, "error": "Unauthorized."})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_REQUEST_BYTES:
            self.send_json(413, {"ok": False, "error": "Request body is missing or too large."})
            return
        try:
            payload = json.loads(self.rfile.read(length))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self.send_json(400, {"ok": False, "error": "Request body must be valid JSON."})
            return
        if not isinstance(payload, dict):
            self.send_json(400, {"ok": False, "error": "Request body must be a JSON object."})
            return
        if not RUN_SLOT.acquire(blocking=False):
            self.send_json(429, {"ok": False, "error": "The devirtualizer is already processing a job."})
            return
        try:
            self.send_json(200, run_devirtualizer(payload))
        except ValueError as error:
            self.send_json(400, {"ok": False, "error": str(error)})
        except Exception as error:
            self.send_json(500, {"ok": False, "error": str(error)})
        finally:
            RUN_SLOT.release()


def main() -> None:
    if not os.environ.get("LURAPH_WORKER_TOKEN", "").strip():
        raise SystemExit("LURAPH_WORKER_TOKEN must be configured.")
    port = bounded_int(os.environ.get("PORT"), 8080, 1, 65535)
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"[luraph-worker] listening on 0.0.0.0:{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
