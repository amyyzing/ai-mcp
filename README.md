# luraph-devirtualiser

Standalone Railway-hosted interface to the real **luau-vmp-deobf** engine. Raycast-inspired charcoal/coral colours, liquid-glass controls, ambient glowing particles, responsive dual editors, file upload, cancellable jobs, real stage reporting, source previews, artifact downloads, and complete exports.

This branch is an independent website. AI-MCP's main branch is unchanged.

## Deploy

Docker builds Python 3.12, FastAPI, the recovery engine pinned at `5313d53165d64207e44be533358f2334c0657ee8`, and checksum-verified Lune 0.10.5. The engine's MIT notice is included at `/app/ENGINE-LICENSE`.

Deploy this branch in a separate Railway service. The Docker image serves UI and API on `$PORT`; healthcheck `/health`. Use **one replica**, since jobs are held in process memory. No secrets or external worker URL are required.

Local: install the pinned engine and Lune, `pip install -r requirements.txt`, then `python server.py`. Without the engine the UI reports unavailable; it never fabricates results.

## Data and limits

- 4 MiB source; 30–600 seconds per job; one worker; four active/queued jobs.
- One active job per browser session; ten submissions per IP per ten minutes. Lightweight quotas are not abuse-proof identity checks.
- 32 MiB output per job; 96 MiB total retained outputs; 30-minute TTL and capacity eviction.
- Source uses a temporary server work directory removed after the job. Outputs remain in RAM. Restarts/redeploys clear them.
- No browser localStorage/IndexedDB source storage. An opaque HTTP-only session cookie restricts job access.
- No lua.expert uploads. Child processes inherit an allowlisted environment, not deployment secrets. CPU, address-space, file-size, file-descriptor and wall-clock limits apply; cancellation kills the process group.
- The upstream parser/bootstrap sandbox is not a claim of a hardened hostile-code boundary. Use stronger kernel/container isolation before operating a high-volume public service.
- No raw source is logged to the application console. Per-job diagnostics may contain source-derived data and are restricted to the owning session.

## Scope

Supports the pinned engine's supported Luraph v14.x loader families. Not a universal WeAreDevs, arbitrary-VM, or unknown-version deobfuscator. Full recovery permits the bounded bootstrap decoder; strict capture can stop at an intermediate loader. The engine does not invoke the final application. Compilation is not proof of equivalence; original names/comments are not guaranteed.

This version exposes the existing engine. It does **not** implement the proposed advanced SSA/closure-reconstruction pipeline.

## API

`GET /api/health`, `POST /api/jobs` (source, name, mode, timeout), `GET /api/jobs/{id}`, `DELETE /api/jobs/{id}`, `GET /api/jobs/{id}/artifact?name=...`, `GET /api/jobs/{id}/artifact?name=...&download=true`, `GET /api/jobs/{id}/download`.

Establish a browser session with `/` or `/api/health` before submitting JSON. Previews are capped at 160,000 characters; downloads preserve retained bytes. Artifacts include SHA-256 metadata.

## Verification

`pip install -r requirements-dev.txt && python -m unittest discover -s tests -v` runs API tests with an explicitly mocked recovery subprocess. Docker additionally runs `smoke.py`: actual engine instruction lifting and native Lune compilation of an owned fixture, plus actual CLI rejection of unsupported input. Neither test claims complete real-world Luraph corpus compatibility. UI tests cover desktop/mobile layout, settings, error/result rendering and source escaping.
