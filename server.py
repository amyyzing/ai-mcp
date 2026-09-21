"""Ephemeral, bounded web workbench for the pinned luau-vmp-deobf engine."""
from __future__ import annotations

import asyncio
import collections
import hashlib
import io
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import zipfile
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from typing import Any

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles
import uvicorn

ROOT = Path(__file__).resolve().parent
ENGINE_COMMIT = "5313d53165d64207e44be533358f2334c0657ee8"
MAX_SOURCE = 4 * 1024 * 1024
MAX_ARTIFACTS = 32 * 1024 * 1024
TOTAL_RETAINED = 96 * 1024 * 1024
TTL = 30 * 60
MAX_PENDING = 4
PREVIEW = 160_000
LOCK = threading.RLock()
SLOTS = threading.Semaphore(1)
JOBS: dict[str, "Job"] = {}
RATES: dict[str, collections.deque] = {}
STAGES = ["Inspecting source", "Unpacking loader", "Capturing prototypes", "Resolving staged tree", "Recovering instructions", "Extracting source", "Lifting program", "Checking Luau", "Collecting artifacts"]

@dataclass
class Job:
    id: str
    owner: str
    name: str
    source_hash: str
    mode: str
    timeout: int
    state: str = "queued"
    phase: int = 0
    created: float = field(default_factory=time.time)
    started: float | None = None
    finished: float | None = None
    error: str | None = None
    warnings: list[str] = field(default_factory=list)
    events: list[dict] = field(default_factory=list)
    artifacts: dict[str, bytes] = field(default_factory=dict)
    quality: dict[str, Any] = field(default_factory=dict)
    primary: str | None = None
    process: subprocess.Popen | None = field(default=None, repr=False)
    cancelled: threading.Event = field(default_factory=threading.Event, repr=False)

    def event(self, message: str, phase: int | None = None):
        with LOCK:
            if phase is not None:
                self.phase = phase
            if not self.events or self.events[-1]["message"] != message:
                self.events.append({"message": message, "at": round(time.time() - self.created, 2)})
                self.events = self.events[-40:]

    def public(self):
        with LOCK:
            elapsed = ((self.finished or time.time()) - self.started) if self.started else 0
            return {"id": self.id, "name": self.name, "state": self.state, "phase": self.phase,
                    "phaseLabel": STAGES[self.phase], "elapsed": round(elapsed, 2), "mode": self.mode,
                    "sourceHash": self.source_hash, "events": list(self.events), "error": self.error,
                    "warnings": list(self.warnings), "quality": dict(self.quality), "primary": self.primary,
                    "expiresAt": ((self.finished + TTL) if self.finished else None),
                    "artifacts": [{"name": n, "bytes": len(b), "sha256": hashlib.sha256(b).hexdigest(),
                                   "kind": artifact_kind(n)} for n, b in self.artifacts.items()]}


def artifact_kind(name: str) -> str:
    if name == "embedded_main.luau" or name.startswith("embedded_sources/") and name.endswith(".luau"):
        return "Decoded source"
    if name.endswith(".decompiled.luau"):
        return "Structural Luau"
    if name.endswith(".pseudo.lua"):
        return "Instruction view"
    return "Analysis report"


def cleanup():
    now = time.time()
    with LOCK:
        for key, job in list(JOBS.items()):
            if job.finished and now - job.finished > TTL:
                del JOBS[key]
        done = sorted((j for j in JOBS.values() if j.finished), key=lambda j: j.finished or 0)
        total = sum(len(b) for j in JOBS.values() for b in j.artifacts.values())
        while done and (total > TOTAL_RETAINED or len(JOBS) > 32):
            job = done.pop(0)
            total -= sum(map(len, job.artifacts.values()))
            JOBS.pop(job.id, None)
        for ip, records in list(RATES.items()):
            while records and records[0] < now - 600:
                records.popleft()
            if not records:
                RATES.pop(ip, None)


def terminate(job: Job):
    with LOCK:
        process = job.process
    if process is not None and process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def engine_ready() -> bool:
    import importlib.util
    return importlib.util.find_spec("luauvmp") is not None and shutil.which("lune") is not None


def execute(job: Job, source: str):
    acquired = False
    try:
        while not acquired:
            if job.cancelled.is_set():
                return
            acquired = SLOTS.acquire(timeout=0.5)
        if job.cancelled.is_set():
            return
        with LOCK:
            job.state, job.started = "running", time.time()
        job.event("Inspecting submitted source", 0)
        with tempfile.TemporaryDirectory(prefix="devirtualise-") as folder:
            work = Path(folder)
            input_file, output = work / "input.luau", work / "output"
            input_file.write_text(source, encoding="utf-8")
            source = ""  # Do not retain raw submission after writing the ephemeral input.
            env = {key: os.environ[key] for key in ("PATH", "LANG", "LC_ALL") if key in os.environ}
            env.update(HOME=folder, TMPDIR=folder, PYTHONUNBUFFERED="1", PYTHONDONTWRITEBYTECODE="1",
                       LUAUVMP_INSTRUCTION_BUDGET="5000000")
            if job.mode == "strict":
                env["LUAUVMP_STRICT_CAPTURE"] = "1"
            command = [sys.executable, str(ROOT / "engine_runner.py"), str(input_file), str(output), str(job.timeout)]
            process = subprocess.Popen(command, cwd=work, env=env, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            with LOCK:
                job.process = process
            tail = bytearray()
            def drain():
                pending = bytearray()
                assert process.stdout is not None
                while True:
                    block = process.stdout.read1(4096)
                    if not block:
                        break
                    tail.extend(block)
                    if len(tail) > 65536:
                        del tail[:-65536]
                    pending.extend(block)
                    while b"\n" in pending:
                        line, _, remainder = pending.partition(b"\n")
                        pending = bytearray(remainder)
                        match = re.search(rb"\[([1-7])/7\]", line)
                        if match:
                            stage = int(match[1])
                            job.event(STAGES[stage], stage)
                    if len(pending) > 8192:
                        pending.clear()
            reader = threading.Thread(target=drain, daemon=True)
            reader.start()
            deadline = time.monotonic() + job.timeout
            while process.poll() is None:
                if job.cancelled.is_set():
                    terminate(job)
                    break
                if time.monotonic() > deadline:
                    terminate(job)
                    job.error = f"Recovery reached the {job.timeout}-second time limit. Try a longer limit or strict capture."
                    break
                time.sleep(0.15)
            process.wait(timeout=10)
            reader.join(timeout=3)
            if job.cancelled.is_set():
                return
            if job.error:
                raise RuntimeError(job.error)
            log = tail.decode("utf-8", errors="replace")
            if process.returncode != 0:
                if "not a supported Luraph" in log:
                    raise ValueError("This input is not recognised as a supported Luraph v14.x loader. Plain Luau, WeAreDevs and other obfuscators are not automatically supported. No replacement source was fabricated.")
                clean = re.sub(r"\x1b\[[0-9;]*m", "", log).replace(folder, "<job>")
                # Only the job owner can retrieve diagnostic output; never log source on the server.
                with LOCK:
                    job.artifacts["diagnostic.txt"] = clean[-16000:].encode()
                raise RuntimeError("The engine could not recover this input. Open diagnostic.txt for the exact failure; the file may use an unsupported layout or require another capture mode.")
            job.event("Collecting complete artifacts", 8)
            pipeline_path = output / "pipeline.json"
            if not pipeline_path.is_file():
                raise RuntimeError("The engine returned without a pipeline report.")
            pipeline = json.loads(pipeline_path.read_text())
            d = pipeline.get("decompiler", {})
            job.quality = {"compileChecked": d.get("compile_checked"),
                           "fallbackInstructions": d.get("fallback_instructions"),
                           "unresolvedConditionals": d.get("unresolved_dispatcher_conditionals", pipeline.get("unresolved_dispatcher_conditionals")),
                           "prototypes": pipeline.get("prototypes"), "instructions": pipeline.get("instructions"),
                           "captureKind": pipeline.get("capture_kind"),
                           "bootstrapExecuted": pipeline.get("bootstrap_executed"),
                           "bootstrapCompleted": pipeline.get("bootstrap_completed"),
                           "finalPayloadExecuted": pipeline.get("final_payload_executed")}
            if job.quality["finalPayloadExecuted"] is not False:
                raise RuntimeError("The pipeline did not confirm the final-payload non-execution boundary.")
            partial = False
            if pipeline.get("finalization_error"):
                partial = True
                job.warnings.append("Staged finalisation did not finish; these artifacts describe the strict-capture fallback, not necessarily the final application.")
            if job.mode == "strict":
                job.warnings.append("Strict capture can stop at an intermediate loader. A compiling result is not proof that the final application was recovered.")
            if d.get("fallback_instructions", 0) or job.quality["unresolvedConditionals"]:
                partial = True
                job.warnings.append("Some operations remain unresolved. Treat structural output as partial recovery.")
            if d.get("compile_checked") is not True:
                partial = True
                job.warnings.append("A successful compilation check was not confirmed.")
            candidates = []
            for pattern in ("*.luau", "*.lua", "*.json", "embedded_sources/*.luau", "embedded_sources/*.json"):
                candidates.extend(output.glob(pattern))
            total = 0
            for path in sorted(set(candidates)):
                if not path.is_file() or path.is_symlink():
                    continue
                size = path.stat().st_size
                if total + size > MAX_ARTIFACTS:
                    partial = True
                    job.warnings.append(f"Artifact omitted because the {MAX_ARTIFACTS // 1048576} MB retention limit was reached: {path.name}")
                    continue
                content = path.read_bytes()
                with LOCK:
                    job.artifacts[path.relative_to(output).as_posix()] = content
                total += size
            choices = ["embedded_main.luau", "program.decompiled.luau", "program.pseudo.lua"]
            job.primary = next((n for n in choices if n in job.artifacts), None)
            if job.primary is None:
                job.primary = next((n for n in job.artifacts if n.endswith(".luau")), None)
            if job.primary is None:
                raise RuntimeError("The engine produced no readable source artifact.")
            job.state = "partial" if partial else "completed"
            job.event("Recovery finished · inspect the quality report")
    except ValueError as exc:
        job.state, job.error = "unsupported", str(exc)
        job.event("Input format not supported")
    except Exception as exc:
        job.state, job.error = "failed", str(exc)
        job.event("Recovery stopped")
    finally:
        terminate(job)
        with LOCK:
            if job.cancelled.is_set():
                job.state, job.error = "cancelled", None
                job.event("Job cancelled")
            job.finished, job.process = time.time(), None
        if acquired:
            SLOTS.release()
        cleanup()


@asynccontextmanager
async def lifespan(app):
    async def reap():
        while True:
            await asyncio.sleep(60)
            cleanup()
    task = asyncio.create_task(reap())
    yield
    task.cancel()
    for job in list(JOBS.values()):
        if not job.finished:
            job.cancelled.set()
            terminate(job)

app = FastAPI(title="luraph-devirtualiser", docs_url=None, redoc_url=None, lifespan=lifespan)

@app.middleware("http")
async def policy(request: Request, call_next):
    session = request.cookies.get("ld_session", "")
    if not re.fullmatch(r"[A-Za-z0-9_-]{43}", session):
        session = secrets.token_urlsafe(32)
    request.state.owner = hashlib.sha256(session.encode()).hexdigest()
    if request.method in ("POST", "DELETE"):
        if request.headers.get("sec-fetch-site") == "cross-site":
            return JSONResponse({"detail": "Cross-site submission is not allowed."}, status_code=403)
        origin = request.headers.get("origin")
        if origin and origin.split("://", 1)[-1] != request.headers.get("host"):
            return JSONResponse({"detail": "Origin does not match this service."}, status_code=403)
    response = await call_next(request)
    if request.cookies.get("ld_session") != session:
        response.set_cookie("ld_session", session, httponly=True, samesite="strict",
                            secure=request.headers.get("x-forwarded-proto", request.url.scheme) == "https", max_age=3600)
    response.headers["Cache-Control"] = "no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
    return response

@app.get("/health")
@app.get("/api/health")
def health():
    ready = engine_ready()
    with LOCK:
        active = sum(not j.finished for j in JOBS.values())
    return JSONResponse({"ok": ready, "engine": "luau-vmp-deobf", "commit": ENGINE_COMMIT,
                         "version": "0.5.2", "activeJobs": active, "maxSourceBytes": MAX_SOURCE,
                         "retentionSeconds": TTL, "thirdPartyUploads": False}, status_code=200 if ready else 503)

@app.post("/api/jobs", status_code=202)
async def create_job(request: Request):
    if not engine_ready():
        raise HTTPException(503, "The recovery engine is not available. No simulated results are returned.")
    raw = bytearray()
    async for chunk in request.stream():
        raw.extend(chunk)
        if len(raw) > MAX_SOURCE * 6 + 4096:
            raise HTTPException(413, "Request is too large.")
    try:
        data = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        raise HTTPException(400, "Invalid JSON body.")
    if not isinstance(data, dict) or not isinstance(data.get("source"), str):
        raise HTTPException(400, "A source string is required.")
    source = data["source"]
    if not source.strip():
        raise HTTPException(400, "Paste or upload some source first.")
    encoded = source.encode("utf-8")
    if len(encoded) > MAX_SOURCE:
        raise HTTPException(413, "Source is limited to 4 MB.")
    mode = data.get("mode", "sandboxed")
    if mode not in ("strict", "sandboxed"):
        raise HTTPException(400, "Unknown capture mode.")
    timeout = data.get("timeout", 180)
    if isinstance(timeout, bool) or not isinstance(timeout, int) or not 30 <= timeout <= 600:
        raise HTTPException(400, "Timeout must be between 30 and 600 seconds.")
    name = str(data.get("name", "protected.luau")).replace("\\", "/").split("/")[-1]
    name = re.sub(r"[^\w. -]", "_", name)[:100] or "protected.luau"
    cleanup()
    ip = request.headers.get("x-real-ip", request.client.host if request.client else "unknown")
    ip_key = hashlib.sha256(ip.encode()).hexdigest()
    with LOCK:
        if sum(not j.finished for j in JOBS.values()) >= MAX_PENDING:
            raise HTTPException(429, "The worker queue is full. Try again after an active job finishes.")
        if any(j.owner == request.state.owner and not j.finished for j in JOBS.values()):
            raise HTTPException(409, "You already have an active job.")
        history = RATES.setdefault(ip_key, collections.deque())
        if len(history) >= 10:
            raise HTTPException(429, "Submission limit reached: 10 jobs per 10 minutes.")
        history.append(time.time())
        job = Job(secrets.token_urlsafe(24), request.state.owner, name, hashlib.sha256(encoded).hexdigest(), mode, timeout)
        JOBS[job.id] = job
        job.event("Queued for the recovery engine")
    threading.Thread(target=execute, args=(job, source), daemon=True).start()
    return job.public()


def owned(job_id: str, request: Request) -> Job:
    cleanup()
    with LOCK:
        job = JOBS.get(job_id)
        if not job or not secrets.compare_digest(job.owner, request.state.owner):
            raise HTTPException(404, "Job not found or expired. Results are temporary and belong to this browser session.")
        return job

@app.get("/api/jobs/{job_id}")
def job_status(job_id: str, request: Request):
    return owned(job_id, request).public()

@app.delete("/api/jobs/{job_id}")
def cancel(job_id: str, request: Request):
    job = owned(job_id, request)
    if not job.finished:
        job.cancelled.set()
        terminate(job)
    return {"ok": True, "state": job.state}

@app.get("/api/jobs/{job_id}/artifact")
def artifact(job_id: str, request: Request, name: str, download: bool = False):
    job = owned(job_id, request)
    with LOCK:
        content = job.artifacts.get(name)
    if content is None:
        raise HTTPException(404, "Artifact not found.")
    if download:
        safe_name = re.sub(r"[^\w.-]", "_", name.split("/")[-1])
        return Response(content, media_type="application/octet-stream", headers={"Content-Disposition": f'attachment; filename="{safe_name}"'})
    text = content.decode("utf-8", errors="replace")
    return {"name": name, "text": text[:PREVIEW], "previewTruncated": len(text) > PREVIEW,
            "bytes": len(content), "sha256": hashlib.sha256(content).hexdigest()}

@app.get("/api/jobs/{job_id}/download")
def download_all(job_id: str, request: Request):
    job = owned(job_id, request)
    with LOCK:
        files = dict(job.artifacts)
    if not files:
        raise HTTPException(404, "No artifacts are available.")
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, content in files.items():
            archive.writestr(name, content)
        archive.writestr("web-report.json", json.dumps(job.public(), indent=2))
    return Response(buffer.getvalue(), media_type="application/zip", headers={"Content-Disposition": 'attachment; filename="luraph-recovery.zip"'})

@app.get("/")
def home():
    return FileResponse(ROOT / "static" / "index.html")

app.mount("/static", StaticFiles(directory=ROOT / "static"), name="static")

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8080")), access_log=False)
