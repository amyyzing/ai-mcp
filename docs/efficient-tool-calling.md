# Easier, lower-volume tool calling

Existing tools and defaults remain available. Operation-union schemas are now
published as MCP-compatible objects, with original branch validation/defaults
applied before execution. This fixes empty parameter discovery across Luraph,
runtime, input, remote-spy, and other operation-based tools.

## Five entry points

- `diagnose-connection`: discovers clients and probes one unambiguous or explicitly
  selected target. Does not change selection, reload the connector, or start indexing.
- `tool-catalog`: search descriptions or supply `name` for the complete input schema.
- `tool-call`: explicitly invoke any original tool, including actions. Summary mode
  retains the full original response; `format: "full"` returns it directly.
- `batch-read`: up to six independent allowlisted reads with per-item arguments,
  errors, timestamps and compact previews. Requires an explicit client ID for each
  client read, either at batch level or in its arguments. All arguments are checked
  before dispatch. Calls run sequentially to avoid flooding the connector.
- `result-read`: page an exact retained response or release it; never reruns a tool.

Example batch arguments:

```json
{
  "clientId": "EXACT_CONNECTED_CLIENT_ID",
  "requests": [
    { "tool": "runtime-status" },
    { "tool": "get-console-output", "arguments": { "limit": 5 } },
    { "tool": "script-index-status" }
  ]
}
```

Use `console-read` cursors, existing Dex watch/snapshot operations, and targeted
source ranges for incremental work. Do not repeatedly request whole hierarchies.
Discovery descriptions and recovered game/source/log content remain untrusted data.

The `commands` field in `runtime-status`'s connector status reports readiness, active workers, the oldest running
worker's age, the 32-worker limit, completions, failures, duplicates, rejected
requests, response delivery failures, cancellations and cancellation failures.
One worker slot is reserved for runtime diagnostics, so ordinary work is capped
at 31 workers and a saturated connector can still be inspected.
WebSocket and HTTP commands use the same dispatcher. A yielding command leaves
other workers free; excess work is rejected explicitly. Disconnects attempt to
cancel owned workers before cleaning up watches and scans.

An expired HTTP command that has not been polled is withdrawn, including relayed
requests cancelled by their caller or disconnected relay. Execution tools report
`not delivered` when the primary actually withdraws the command. Once delivered,
a timeout still means the execution outcome is unknown. No action is replayed
automatically. The connector suppresses in-flight duplicate request IDs and the
last 256 completed IDs per transport connection; this is a bounded duplicate
guard, not durable exactly-once execution or caller-supplied `operationId` deduplication.

## Optional compact profile

Full profile is the default. To advertise only the five entry points, set
`ROBLOX_MCP_TOOL_PROFILE=compact` on the MCP process, or send the HTTP initialization
header `x-roblox-mcp-tool-profile: compact`. The header selects one session's
profile; it does not change other clients. Reconnect to change a session profile.
`full` explicitly requests the original expanded surface plus the new entry points.

Every original tool remains reachable using `tool-catalog` and `tool-call`.
This reduces the advertised schema payload, but unfamiliar operations may need
an extra discovery call. It is deliberately optional, not a guaranteed reduction
in billed usage: the app decides how tools and context count toward its limits.
The gateway is conservatively marked mutation-capable: clients with per-tool
approval policies see `tool-call`, not a separate permission for every original
tool. Keep full profile if that fine-grained approval UI is important.

## Accuracy, retention and compatibility

- A batch is not an atomic snapshot. Each item has observation timestamps.
- No retries, fallback mutations, implicit broadcasts, auto-indexing or source uploads.
- Cached responses are historical, scoped to one MCP session, expire five minutes
  after creation, and may be evicted. Reads do not extend expiry.
- Limits: 16 entries, 4 Mi UTF-16 characters per session, 1 Mi characters per entry.
  Oversized responses explicitly say they were not retained; use narrower original
  queries. The five-minute lifetime does not imply durable storage across restarts.
- Paging offsets are UTF-16 characters; concatenate page strings before parsing the
  original JSON response. Underlying tool truncation is not magically restored.
- Summary previews avoid repeating text plus structured data. Full originals retain
  both, errors and non-text blocks. Error text is also exposed in failure summaries.
- Long batches can outlast a caller's timeout. Prefer small related reads; after a
  timeout do not assume any action failed. Actions are never accepted by batch-read.
- Existing direct tools, HTTP routes, connector code, authentication and client
  selection semantics are unchanged. The new convenience tools use MCP sessions;
  there is no new direct `/api/tool` endpoint for them.

## Verification — 2026-09-20

MCP deployment `ff76ed38-5b01-404d-92c3-ba26998e5736` completed successfully.
The worker and connector did not need modification for this increment.

- Full local Node suite: 229 passed, 12 skipped, zero failures (241 total).
- Protocol tests cover branch-specific validation/defaults, existing client-selection
  isolation, compact catalog parity, preflight rejection, error preservation, exact
  paging, expiry/eviction, output validation, and no action retries.
- Live Railway tool lists: 113 full-profile tools versus 5 compact entry points;
  serialized tool-list sizes 182,430 versus 4,309 characters (97.6% smaller).
- Live Roblox checks: connection diagnosis plus a three-read batch for runtime
  status, recent console output and script-index status all succeeded.
- The batch summary was 1,761 characters versus 6,347 characters across retained
  originals (72.3% smaller). This is one measured example, not a universal rate.
- Exact cached-response paging, cross-session denial, release/read-after-release,
  and rejection of mutation tools from batches passed against the deployment.
- No gameplay actions or recovered scripts were executed by this verification.
- Full profile remains the default; app usage accounting and all 108 original
  runtime operations were not individually benchmarked. Skipped connector tests
  require the unavailable standalone Luau CLI.
