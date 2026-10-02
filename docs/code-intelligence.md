# Headless code intelligence (first milestone)

AI-MCP exposes five optional host-side analysis tools: `code-check`,
`code-definition`, `code-references`, `code-type-at`, and `code-symbols`.
They use the existing source store and Dex hierarchy observations. They do not
execute source, run a second decompiler, attach a memory reader, or require VS Code.

## Install on the MCP host

```powershell
npm run install:lsp
npm run build
```

Restart the MCP core after updating its code. No connector changes are required
if the connected connector already supports structured `dex-query`.

The explicit installer supports upstream Windows x64, Linux x64 and macOS ARM64
archives. It pins Live LSP **v1.69.3**, source revision
`0f360106d50ee7ec46e4fc304c8e69df5f2505d1`, validates archive and definition
SHA-256 checksums, and retains upstream license information. Installation is
not an automatic side effect of an analysis call. Platform availability is not
proof of runtime compatibility; run the native tests on each deployment host.

By default the runtime lives in `.build-tools/live-lsp`. Set
`ROBLOX_MCP_LSP_DIR` for a persistent absolute runtime directory (both installer
and core must use the same location). On Railway, install the **Linux** runtime
in the build image with `npm run install:lsp`, preserve its directory in the
runtime image, and run the native tests there. Do not upload a Windows executable
to Railway. The repository's `railway.json` builds the server, installs the pinned
runtime, and requires the native regression suite to pass before deployment.
No deployment or credential change is performed by the installer itself.

## Use

1. Select the client and use `list-scripts` to find its exact `debugId`.
2. Pass that ID as `scriptId`. The position tools take zero-based `line` and
   UTF-16 `character` offsets; definition/reference locations include a `scriptId`
   when they resolve to an indexed document. Returned file URIs identify in-memory
   documents, not persistent source files.
3. Optionally supply `sourceIds` to restrict analysis to the target and relevant
   dependencies. Source acquisition remains with existing indexing tools.
4. Read `freshness`, `coverage`, and `truncated`, not just `result`.

`refreshHierarchy` defaults to true. It reuses Dex's bounded, client-visible scan
(up to 1000 visited instances, 12 pages, 15 seconds). False uses the prior
timestamped observation. Each client has an isolated native worker; two workers
may be active, and idle workers expire after five minutes. Each analysis scope
is bounded to 2000 documents / 8 MiB of source. Output is bounded separately.

## Correctness and limitations

- One authoritative source store; the LSP owns only derived parse/type caches.
  Store changes invalidate outstanding requests. Mapping resets and client
  replacement discard workers and their documents.
- Source provenance can be original, decompiled, normalized, stub, or unknown.
  Legacy records remain **unknown** rather than being relabeled as original.
- Existing `$/executor/full` overlays link observed instances to managed source
  documents. Source-only edits use `didChange`; structural changes rebuild the
  overlay. The adapter does not invent unsupported native rename messages.
- Partial scans retain omitted instances. Only complete observations establish
  removal. Duplicate sibling names are excluded from name-based resolution;
  unresolved or truncated identifiers are not guessed. Unlinked sources and
  modules without source are reported. This is not a complete game snapshot.
- `analysisInputRevision` identifies desired inputs accepted by the adapter;
  `submittedInputRevision` identifies inputs sent to this worker. Confirmation
  is per queried document against those inputs, supported by pinned native
  ordering and real-server fixtures—not by a sleep, notification write, or
  unrelated diagnostic. It never claims all workspace analysis is current.
- A changed dependency can supersede a result even when the queried document
  version is unchanged. Superseded results are rejected by default. Exploratory
  requests with `requireFresh=false` receive the explicit stale state.
- Push diagnostics are not cached or used as acknowledgments; `code-check`
  requests pull diagnostics. Late/unknown responses cannot satisfy later requests.
- Strict DataModel diagnostics and hover are explicitly enabled. Source Luau
  pragmas still apply: a nonstrict dependency can be permissive despite detailed
  hover types. `nocheck` is not type validation. Executor API support is not
  runtime-validated. A clean diagnostic result is not proof code will work.
- Upstream reference lookup has incomplete support for returned primitive values.
  References are limited to supplied sources. No heuristic string search is
  presented as a language-server reference result.
- Remote-type fetching, automatic definition/flag downloads, external process
  attachment, and independent source/decompiler acquisition are not enabled.
  Definitions and effective configuration hashes accompany results.
- MemoryAPI, memory-provider identity, recording integration, and broader
  provider abstractions are deliberately outside this milestone.

## Verification

```powershell
$env:REQUIRE_LSP_TESTS = "1"
npm run test:lsp
```

Without an installed runtime, native tests explicitly skip; with
`REQUIRE_LSP_TESTS=1`, a missing or mismatched runtime fails the run. Native
fixtures launch the real pinned server. They cover all five tools, inter-module
definitions/references, dependency changes, stub replacement, source removal,
rename/reparent, partial observations, duplicate names, UTF-16 positions,
superseded results and worker isolation. Transport tests separately cover
timeouts, shutdown and malformed frames. Live bridge checks and deployment
validation must be reported separately from deterministic fixtures.
