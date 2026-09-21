# luraph-devirtualiser

A Railway-hosted, ephemeral Lua/Luau recovery workbench. Raycast-inspired charcoal/coral colours, translucent glass panels, animated blurred particles, responsive editors, real progress, cancellation and complete artifact downloads.

## Recovery providers

- **Luraph:** pinned `luau-vmp-deobf` 0.5.2, commit `5313d53165d64207e44be533358f2334c0657ee8`. The upstream capture/finalisation pipeline stays intact and third-party decompiler uploads stay disabled.
- **Local analysis adapter:** parses its supported Lua/Luau syntax, evaluates closed constant-array decoders, folds literal arithmetic, and emits the complete analysis source. Supports structures encountered in Prometheus-style/WeAreDevs wrappers; the banner is evidence, not proof of compatibility.
- **Closed-model specialization:** in Full recovery, a bounded Python evaluator can derive scalar print/warn operations and return values. A candidate is promoted only after the original and candidate match under three native Luau runs. This is **model-specific partial reconstruction, NOT a universal all-path decompiler**. Global mutations, entry arguments, timings, diagnostic behaviour, unexecuted branches and Roblox interactions are not proved equivalent. Missing or unsupported APIs stop specialization. A disclosed scratch-global absence profile may be used for recognized diagnostic scaffolding.
- **Official native validation:** Luau **0.739** `luau` and `luau-compile`, downloaded from the official release and SHA256-verified. Lune 0.10.5 remains installed because the Luraph engine requires it; the new adapter uses the official CLI instead of Lune or a Lua 5.x approximation.

Official archive SHA256: `8a9b4b381021722c82d6e6cda0964b5c9e7f354ec1035fcd8b657acc22e49247`.

## What the outputs mean

`program.application.luau` is a native-verified **observed application view**. It is partial and accompanied by scope/assumptions. `program.analysis.luau` preserves the full parsed program with decoded constants and literal arithmetic; VM dispatch remains, and formatting can affect anti-tamper checks. `candidate.unverified.luau` is never silently promoted. `program.source.luau` is non-VM source passed through and compile-checked, not devirtualized or executed. Existing Luraph embedded/structural/instruction artifacts retain their distinct labels. A clean compile is not a semantic-equivalence proof.

Reports include input hashes, decoded constants, original-versus-candidate traces, runtime version, seeds, unresolved globals and native validation failures. The adapter has no parameter for a desired/expected output.

## Running

Build and run with Docker on Linux x86_64:

```sh
docker build -t luraph-devirtualiser .
docker run --rm -p 8080:8080 luraph-devirtualiser
```

The official Ubuntu release bundled here is x86_64. Other architectures require a separately verified Luau build; this image fails explicitly rather than installing an incompatible binary.

Railway uses `railway.json`, the root Dockerfile, `$PORT`, and `/api/health`. Keep one replica: the queue and artifact store are process-local.

For local tests, install `requirements-dev.txt` and put official `luau`, `luau-compile`, plus Lune on PATH. Install the pinned recovery engine for end-to-end Luraph tests. Run:

```sh
python -m unittest discover -s tests -v
python smoke.py
```

Native tests must not be reported as passed when skipped. Synthetic tests are owned fixtures, not a claim of coverage for all obfuscator releases. User submissions are not checked into the repository.

## Limits and storage

4 MB UTF-8 input; one active worker with four pending jobs; 30–600 second job timeout; per-process memory/CPU/file limits; 32 MB retained artifacts per job; 96 MB global retention; 30-minute maximum result retention. Cancellation terminates the process group. Results are scoped to an HttpOnly browser-session cookie. Jobs use temporary server files; retained results live in server memory and are evicted on capacity, expiry or restart. No browser local storage and no executor workspace writes.

The native verification harness gives submissions an explicit pure-library environment. No require, filesystem, network, OS commands, clipboard or Roblox services are exposed. Original code is executed only within the disclosed closed-model verification path; Luraph continues using its separate disabled-final-payload capture policy. Static/strict mode skips application specialization. Unsupported syntax and unknown custom VMs can still fail or produce partial analysis; universal recovery is not claimed.

## HTTP interface

- `GET /api/health` — exact runtime/adapter status.
- `POST /api/jobs` — source/name/mode/timeout; mode is `sandboxed` or `strict`.
- `GET /api/jobs/{id}` — progress, quality, warnings and artifact manifest.
- `DELETE /api/jobs/{id}` — cancel.
- `GET /api/jobs/{id}/artifact?name=...` — bounded preview.
- Add `download=true` for the entire artifact; preview truncation never discards retained bytes.
- `GET /api/jobs/{id}/download` — full retained artifact archive.

Maintain the same cookie across requests. A different browser session cannot retrieve another session's job.

## Attribution

Luau: https://github.com/luau-lang/luau — MIT License (included in image as LUAU-LICENSE).
Luraph engine: https://github.com/binxgtl/luau-vmp-deobf — upstream license included as ENGINE-LICENSE.
Lune: https://github.com/lune-org/lune.
