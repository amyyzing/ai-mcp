# luraph-devirtualiser

Railway-hosted Lua/Luau recovery workbench with a charcoal/coral glass interface, blurred particles, bounded jobs, cancellation and full artifact downloads.

## Version 2.0: useful output, separate evidence

Every valid input gets official Luau source analysis, independent of whether a VM family is recognized. The default output is the best validated readable source, not an unchanged copy that hides a decoded alternative.

The layers are separate:

- **Literal cleanup:** AST byte spans normalize printable decimal, hexadecimal and Unicode escapes. Binary strings, comments and long-string contents are preserved. Native AST comparison validates the rewritten string values.
- **Constant cleanup:** closed literal-only expressions are reduced. Whole-program debug-free bytecode must match at O1 and O2, or individual literal-only expressions must return identical typed values in native Luau. Application functions and unknown calls are not executed by this pass.
- **Formatting:** pinned StyLua produces a derived view. Official AST or O1/O2 bytecode comparison and compilation are mandatory before selecting it. Debug-source, line-number and timing observations can still differ; the original and unformatted views remain downloadable.
- **Closed constant-array decoding:** recognized prefixes are isolated from the application and evaluated twice in official Luau with a restricted standard-library environment. Native pool recovery avoids the old Python evaluator's instruction ceiling on larger arrays. Prefixes referencing host APIs are not accepted. Accessor inlining is disabled when the array escapes into the suffix or the accessor is reassigned.
- **Specialized VM recovery:** the pinned Luraph engine remains available. Prometheus-style constant-array and closed-model recovery remain explicitly partial. A product banner alone is not proof of support.
- **Inspection:** includes uncalled function bodies, string byte hashes, opaque binary records, possible HTTP/dynamic-compilation dependencies and immutable-local URL chains. No referenced URL is followed. Constant arguments to dynamic compiler references can be exported as embedded source candidates without execution.

This is not a universal all-path decompiler. The official compiler accepting syntax does not imply a custom VM was understood. Unknown VM handlers, external runtimes, encrypted handoff formats and unobserved behavior can remain unresolved.

## Outputs

- `original.input.luau`: exact submitted bytes, including an outer Markdown fence when supplied.
- `program.source.luau`: input with only a complete outer fence removed, if present.
- `program.readable.luau`: validated literal/constant cleanup.
- `program.formatted.luau`: validated formatted derivative.
- `program.analysis.luau` and `recovered.*.luau`: specialized analysis and derived views, with separate recovery qualifications.
- `program.observed.luau`: bounded observed print/warn calls and scalar returns. **Not the full program and never the default source.**
- `program.inspection.json`: source structure, exact string hashes, URL evidence and gaps.
- `program.embedded.*.luau`: literal embedded-source candidates, not remotely fetched applications.
- `static-cleanup.json`, `native-constant-pool.json`, `pipeline.json`, `recovery-report.json`: provenance, individual validation results and transformations.

Outcomes distinguish **unchanged**, **formatted only**, **literals decoded**, **constants decoded**, and **partial VM recovery**. Job completion and compilation are never treated as a proof of whole-program equivalence. Scalar-JSON bugs, failed clipboard behavior and other application bugs are not silently repaired.

## Pinned toolchain

Official Luau 0.739 (`luau`, `luau-compile`, `luau-ast`), Lune 0.10.5 for the existing Luraph engine, StyLua 2.5.2, and `binxgtl/luau-vmp-deobf` commit `5313d53165d64207e44be533358f2334c0657ee8`. Release archives are SHA256-verified. No Lua 5.3 compatibility runtime is used by the native checks. The small Python evaluator remains an optional specialization model, not the source of truth for native language semantics.

The Dockerfile requires Linux x86_64. It runs all native, API and recovery tests in a separate validation stage before producing the runtime image. Test-only HTTP dependencies are not installed in the final image.

```sh
docker build -t luraph-devirtualiser .
docker run --rm -p 8080:8080 luraph-devirtualiser
```

For local tests, install `requirements-dev.txt`, the pinned engine, and put the five native executables on PATH. Then run `python -m unittest discover -s tests -v` and `python smoke.py`. Required native tools are not silently skipped in the new test suite.

## Operational scope

One replica; one active worker and a bounded pending queue. 4 MB UTF-8 input, 30–600 second job deadline, OS memory/CPU/file limits. Cancellation kills the outer worker process group. Complete artifacts are retained subject to 32 MB/job and 96 MB overall limits; omissions are explicitly reported. A small preview never discards retained download bytes. Results expire after 30 minutes or on redeployment.

Submissions stay on the Railway service. No third-party decompiler uploads, browser local storage, executor workspace writes or automatic remote-loader fetches. Full mode may run a supported closed application in a no-host-capability environment; strict mode does not execute the application. Literal-only calculations and isolated decoder prefixes are distinct from application execution.

HTTP: `GET /api/health`, `POST /api/jobs`, `GET /api/jobs/{id}`, `DELETE /api/jobs/{id}`, `GET /api/jobs/{id}/artifact?name=...` (`download=true` for full bytes), and `GET /api/jobs/{id}/download`. Retain the HttpOnly session cookie; results are session-owned.

## Attribution

- Luau: https://github.com/luau-lang/luau (MIT; license included in image).
- Engine: https://github.com/binxgtl/luau-vmp-deobf (upstream license included).
- Lune: https://github.com/lune-org/lune.
- StyLua 2.5.2: https://github.com/JohnnyMorganz/StyLua/tree/v2.5.2 (unmodified binary; MPL-2.0 license and corresponding upstream source available).
