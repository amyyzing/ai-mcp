# Dex inspection and explorer integration

The connector includes seven Dex tools. Inspection, scans, references, snapshots and watches work without opening the Dex GUI. Only selection/reveal require the compatible Dex explorer in the **same executor**. Both transport fallbacks (WebSocket and HTTP) use the same handlers.

| Tool | Use |
| --- | --- |
| `dex-selection` | Read the current Dex selection as exact instance handles; includes total/available counts and truncation. |
| `dex-reveal` | Select, show and scroll to an instance in Dex. Changes explorer UI, not the game object. |
| `dex-inspect` | Batch up to 20 targets with class-aware properties, attributes, tags, bounds, ancestry, GUI visibility metadata and paged children. |
| `dex-query` | Resume a name/class/tag/attribute/text-filtered hierarchy scan, with selected property projections. |
| `dex-snapshot` | List, page, compare or release retained query snapshots. |
| `dex-references` | Find ordinary instance-valued properties pointing at a target, such as ObjectValue.Value, joints, attachments or Adornee. |
| `dex-watch` | Start, poll and stop property/attribute/child/ancestry observers, with bounded event history and expiry. |

## A practical workflow

1. Select a Roblox client with `list-clients` / `set-active-client`. If Dex is open, use `dex-selection` or its **Copy MCP selection** context-menu action. Otherwise start a narrow `dex-query`.
2. Pass the returned `Handle` as `{ "handle": "<returned handle>" }` to inspection, reveal, reference or watch tools. Names and paths are display metadata; handles distinguish identical sibling names and survive renames while valid.
3. Request relevant fields, rather than all descendants and script sources. The automatic inspection profiles include GUI geometry/layout, text/font/image loading, parts/models, humanoids, scripts' metadata, sounds, animations, meshes, joints and prompts. [Font metadata](https://create.roblox.com/docs/reference/engine/datatypes/Font) includes family, weight, style and boldness.
4. For scans, keep following `nextCursor` **even if a page returns zero matches**. Continuations accept only the cursor and page/time/output budgets; the initial request captures root, filters and projection fields.
5. To compare states, start two queries with `retainSnapshot: true` and identical root/filter/projection/depth settings. Finish both scans before requesting a diff. Release snapshots when done.
6. For a small set of changing objects, start a watch, retain its `watcherId`, and poll using the last `nextCursor`. Stop it after observing the interaction. Reconnects invalidate watch IDs, cursors and snapshots.

Example GUI query arguments:

```json
{
  "root": { "path": "game.Players.LocalPlayer.PlayerGui" },
  "filters": { "isA": "ImageLabel" },
  "properties": ["Image", "IsLoaded", "ImageTransparency", "AbsolutePosition", "AbsoluteSize"],
  "limit": 20
}
```

Example continuation:

```json
{ "cursor": "<nextCursor from the response>", "limit": 20 }
```

Use separate narrow class queries for asset references (`Image`, `SoundId`, `AnimationId`, `MeshId`, `TextureID`) and group repeated IDs on the agent side. Property errors are retained instead of silently interpreting unsupported fields as empty values. Inspect script metadata first; use existing targeted script-content tools when source is actually needed. No scan automatically requires modules or invokes remotes.

## Completeness and limits

- Results cover client-visible replicated/local objects, not server-only objects or streamed-out state. Scans and child pages are observations over time, not atomic snapshots. A removed diff record means it was no longer observed, not proof it was destroyed on the server.
- Default scan pages examine up to 1,000 candidates for about 8 ms, including nonmatches; limits are adjustable. `GetChildren()` itself is an atomic engine call, so a very wide parent can exceed the time slice. Use a narrow root when possible.
- Scans default to 50,000 visited candidates and depth 64, with hard limits of 100,000 candidates/depth 100. Depth completeness is relative to that requested scope. Flags distinguish traversal, projection and retained-data completeness.
- Four active/retained scan sessions fit per connector; retained snapshots are bounded to 3,000 records / 2 MiB each and expire after five idle minutes. Completed non-retained scans can be evicted under pressure; stale cursors return an explicit restart error.
- Snapshot comparisons require compatible, complete retained projections. Oversized/deep difference details are explicitly omitted; read the corresponding snapshot pages or inspect the instance with fewer fields. Do not infer equality from missing data.
- Up to eight watches, ten targets each, are supported. The default event ring is 200 records (maximum 500), with a five-minute lifetime (configurable up to one hour). Polls report dropped history and cursor gaps. Stops, expiry and disconnects release signal connections.
- Requested output budgets range from 2,000 to 32,000 characters. Inspect at most 20 targets per call; child pages contain at most 100 objects. Follow continuation/omission fields and reduce fields or batch size when needed. Watch startup and polling both apply the character budget, reserving space for bridge metadata. Startup first compacts target descriptions to handles (`omitted: true`), then omits warnings or target rows if necessary. `targetDetailsOmitted` counts all compacted or omitted target descriptions; `targetsOmitted` counts missing target rows, and `warningsOmitted` counts missing warnings. These omissions affect only the response: all established subscriptions remain active, and the watcher ID and observation counts are preserved.
- GUI `EffectiveVisible` checks only the local `Visible`/`Enabled` ancestry. It does not establish pixel visibility, occlusion, transparency or viewport intersection. OS screenshots run on the **primary MCP host**, not automatically on the Roblox device; a Railway Linux host cannot capture that device's Windows window.

## Loading and testing

Reload the rebuilt MCP connector and updated Dex script to use the new handlers and adapter. Either load order works. Existing auth tokens and loader transport settings are unchanged. The adapter adds no HTTP endpoint and does not copy credentials.

`npm test` rebuilds the connector/server and runs Node and Luau regressions. Luau tests use simulated instances/signals for repeatable pagination, budgets, identity, comparisons and cleanup checks. They do not replace a live Roblox executor/UI test.
