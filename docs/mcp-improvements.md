# MCP improvements — 2026-10-01

The recurring problems in earlier work were stale identities, expensive discovery,
large reads and confusing action outcomes. Compact tool discovery, read batches,
cached paging, opt-in source indexing and observation cursors already address much
of that. This update fixes gaps in the current command lifecycle and Dex handoff.

## Implemented

- Withdraw timed-out, undelivered HTTP commands instead of leaving them queued for
  a later poll. Relay cancellation, relay disconnect and primary reset also remove
  their queued work. Cancellation remains scoped to the relay that owns the request.
- Report execution as not delivered when the primary withdrew its queued command;
  retain the unknown-outcome warning after delivery. Never automatically replay actions.
- Reject duplicate custom sends before they reach the client. In the connector,
  suppress in-flight duplicate request IDs and the last 256 completed IDs per
  transport connection without retaining large response bodies.
- Run WebSocket and HTTP commands through one dispatcher with at most 32 owned
  workers. A yielding command does not block independent commands. Startup and
  capacity rejection explicitly say that no command ran. Reserve one slot for
  runtime diagnostics so saturated work remains inspectable.
- Attempt to cancel owned workers on disconnect before destroying their Dex scans
  and watches. Track readiness, active work, oldest worker age, failures, duplicate
  requests, rejected work, delivery failures and cancellation failures in runtime status.
- Include the handle registry identity as well as generation in Dex tool responses
  and copied selections. Expose live connector availability and reject a copy if
  connection/registry/generation changes during it. Keep version-1 compatibility.
- Invalidate code-analysis hierarchy observations when either the registry identity
  or generation changes. A reloaded connector starting at generation 1 must not
  retain unseen nodes from another connector's partial hierarchy scan.
- Reuse Instance handles across executor `cloneref` aliases. Use debug IDs only
  to narrow candidates, then confirm identity with Lua equality or the executor's
  protected `compareinstances` call. Debug ID collisions, unavailable debug IDs
  and failed comparisons never establish identity. Release, eviction, expiry and
  generation rotation also remove entries from the native identity index.
- Apply the same native identity comparison to Dex incoming-reference scans.
  Instance-valued properties can refer to the target through a different wrapper.
- Enable anti-AFK automatically with one `Player.Idled` listener per executor
  session. Reconnects reuse the listener; runtime status reports enabled state,
  attempts, successful input calls and errors. Startup teardown removes its own
  listener. `scripts/enable-anti-afk.luau` can enable the same module on an older
  already-running connector without replacing its transport.
  [Player.Idled](https://create.roblox.com/docs/reference/engine/classes/Player#Idled)
  is the trigger; VirtualUser calls are best effort and do not override a game's
  own AFK rules.

## New findings and useful next work

1. **Cancellation needs an end-to-end contract.** Removing an undelivered command
   is safe and definite. Cancelling a running command is best effort: Roblox
   documents states where `task.cancel` can fail. A cancelled top-level worker also
   does not undo completed effects or stop detached tasks created by user code.
   The next useful increment is request-scoped cancellation/progress for explicitly
   cancellable reads, with separate delivered/running/completed outcome reporting.
   [Roblox task cancellation](https://create.roblox.com/docs/reference/engine/libraries/task)
   and [MCP cancellation](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation)
   describe the underlying boundaries. Check the installed SDK and negotiated
   protocol version before adopting newer transport cancellation behavior.
2. **Dex selection paging still reads live state.** Offsets can skip or repeat
   objects if the user changes the selection between calls. A bounded selection
   snapshot with an opaque cursor would make long handoffs stable; retain exact
   handles and explicitly expire it on connector replacement. Current responses
   already say selection paging is not atomic.
3. **Capability presence is not behavior.** Earlier executor probes demonstrated
   that a function can exist or pass a small fixture while failing native identity
   requirements. Add opt-in, harmless semantic probes for the capabilities used by
   a requested workflow, with timestamps and named outcomes rather than a single
   pass percentage. Avoid invasive probing at connector startup.
4. **Shared selections need a direct importer.** Registry metadata now makes a
   stale handoff easier to diagnose. A future bounded `dex-handoff` operation could
   accept copied JSON, check the exact connected client/registry, and inspect those
   handles in one call. It should report stale rows individually and never guess
   a replacement from a display path or switch clients implicitly.

## Validation boundary

Connector regressions use Luau fixtures for both transports, inline replies,
yielding commands, overload, duplicates, delivery failures and disconnect cleanup.
Node regressions cover queued timeouts, relay ownership and reset behavior. Dex
fixtures cover connector availability and identity changes during copy.

- Full Node suite: 238 passed, 8 optional benchmark tests skipped, no failures.
- Final focused checks after hierarchy invalidation and diagnostic reservation:
  26 passed, no skips or failures, including the real native LSP worker.
- Eight standalone Luau suites passed. The generated connector compiled with the
  official Luau CLI; server and connector builds completed successfully.
- Dex adapter: 3 passed with behavioral fixtures and full-script compilation,
  including disconnects and client/registry/generation changes during copy.

These checks initially ran without a connected executor. The live checks below
cover the client modules; the server changes were built locally and not deployed.

Use the rebuilt `connector.luau` with the updated Dex script. The MCP server must
also run the rebuilt `dist` for HTTP queue withdrawal and execution messages.

## Live checks — 2026-10-01

The user connected a Roblox executor after the implementation. Its active hosted
connector lacked the new command diagnostics and Dex status API, so the rebuilt
modules were exercised through a separate temporary HTTP registration in the same
executor. This used the real hosted bridge and real Roblox scheduler, without
replacing the active connector or deploying the local server changes.

- Rebuilt transport/core/Dex handlers responded through the temporary HTTP bridge.
  Runtime status reported readiness, the 32-worker maximum and 31-work limit.
- Real Workspace inspection returned exact handles plus registry/generation
  metadata. Deliberately invalid source returned an explicit compilation failure.
- An isolated dispatcher using the executor's real scheduler suppressed a
  duplicate mutation, rejected work beyond its limit, reserved the diagnostics
  slot, and cancelled 31 waiting workers with zero cancellation failures. No
  waiting-worker effects ran after cancellation. Its response sink was simulated;
  the separate HTTP checks above used the actual hosted server.
- The updated Dex script loaded successfully. Reveal selected Workspace, and
  selection readback returned one matching object with registry/generation
  metadata. This verifies adapter behavior, not independent pixel-level UI QA.

The first inspection and Dex selection produced different Workspace handles with
the same debug ID. A fresh live probe confirmed that cloned references had
different Lua identities and table keys while `compareinstances` returned true.
This led to the native identity fixes above, with collision/error/retirement
regressions rather than merging objects on a debug ID alone.

Hosted HTTP queue withdrawal and server-side hierarchy invalidation remain
locally tested, since the server update has not been deployed. The direct parallel
tool-call experiment did not establish concurrent HTTP dispatch: the caller
serialized those requests. A separate executor-origin HTTP experiment was rejected
with HTTP 403 by the hosted dashboard route; its rejected requests establish no
concurrency result. The scheduler/dispatcher fixture remains the concurrency
evidence, separate from the actual HTTP inspection/readback checks.

The first harness expiry also exposed a cleanup-order error: its temporary Dex
API was retired before the previous API was restored. The helper now restores
ownership first, and a dedicated Luau regression passes. Restoration was then
confirmed in a fresh live executor session, as detailed below.

### Completed follow-up in a fresh live session

- Native Workspace, multiple cloned references and the actual Dex selection all
  reused one handle. Lua equality remained false between the direct and selected
  references while native identity and repeated handle comparisons were true.
- Actual HTTP `dex-inspect`, `dex-reveal` and `dex-selection` returned that same
  Workspace handle. Inspection by the selected handle succeeded afterward.
- An isolated native ObjectValue fixture matched one incoming reference through
  a cloned target whose Lua identity differed from the property value. The fixture
  was destroyed afterward; the registered Dex handler returned success.
- Explicit cleanup, called twice, restored the exact original Dex bridge object,
  removed the temporary marker, disconnected the temporary API and rejected its
  subsequent Describe call. The original bridge's Workspace read succeeded and
  the updated Dex remained ready. This checks adapter ownership and readback,
  not independent pixel-level UI QA.
- The rebuilt connector passed official Luau compilation. All eight standalone
  Luau suites passed after the identity fix; focused transport/Dex Node checks
  passed five tests with no skips. Native identity aliases, same-debug-ID
  collisions, comparator errors, unavailable debug IDs, release and generation
  rotation are covered by the handle regression suite.
- Final targeted Node checks passed 27 tests with no skips, including command
  lifecycle, transport, Dex bridge, response reliability and native LSP. The three
  Dex adapter tests also passed, including compilation of the complete script.
- Anti-AFK was installed on a fresh live client. Its actual idle connection was
  connected and one explicit native keep-alive call succeeded with zero failures.
  Two subsequent natural idle callbacks also succeeded, bringing the count to
  three successful calls with zero failures during release preparation.
  Singleton reuse, idle callback dispatch, input errors, destruction and ownership
  are covered by the connector module regressions. This is not a 20-minute idle
  kick endurance test.

`scripts/verify-connector-live.luau` provides the temporary harness. Bundle it with
Darklua and execute through `get-data-by-code` on an explicitly selected client.
It isolates its credential/global state, exposes explicit cleanup, restores the
previous Dex bridge before destroying its adapter, and expires after ten minutes.
Do not treat this temporary harness as an installed full connector.
