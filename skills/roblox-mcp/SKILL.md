---
name: roblox-mcp
description: Inspect, search, debug, devirtualize indexed Luraph source, and intentionally modify a connected Roblox client through roblox-executor-mcp or roblox-client-mcp. Use for live instance or script inspection, Luau data probes, garbage-collector searches, remote inspection, client-side execution, Roblox UI interaction, and Roblox window capture.
---

# Roblox MCP

Use the connected MCP server's live tool schemas as the source of truth for names, parameters, defaults, and limits.

## Core decision rules

Apply these defaults unless the task meets an exception in [references/runtime-patterns.md](references/runtime-patterns.md):

1. Prefer a specialized read tool over arbitrary Luau.
2. Use `search-instances` for filtered instance discovery. It runs `QueryDescendants`; do not fetch every descendant and filter it manually.
3. In custom Luau, use `QueryDescendants` for selector-expressible instance filters instead of a `GetDescendants()` scan.
4. Use `search-gc` for one compact first match. Use `gc-snapshot` + `gc-query` when the task needs reusable handles, pages, diffs, statistics, or reference traversal. Use raw `filtergc` only when neither structured query surface can express the predicate.
5. Use `get-data-by-code` when the task needs values returned from Luau. Return compact raw Lua values; do not print data through `execute` or JSON-encode it manually.
6. Use `execute` or `execute-file` only for intentional side effects or code that does not need to return data. Verify the effect with a focused read.

## Operating workflow

1. Select the client. Call `list-clients` when the target is unclear or multiple clients may exist, then call `set-active-client` if needed.
   - If connection, capability, mapping, or decompiler health is uncertain, call `runtime-status`.
2. Narrow with the cheapest specialized tool:
   - One known instance: `inspect-instance`; discovery: `search-instances`, or `get-descendants-tree` with `summaryOnly=true`.
   - Script metadata: `script-index-status`, then `script-index-start` if needed, followed by `list-scripts`.
   - Known text or identifier: `script-grep`.
   - Unknown implementation with known behavior: `semantic-search-scripts`. Confirm remote embedding upload only when the configured endpoint is trusted; local Ollama stays local.
   - Source: `get-script-content` with a focused line range.
   - Luraph-protected indexed source: `devirtualize-luraph` with `operation=run` and `captureMode=strict` first; page with `operation=read`, release when finished, and retry with `sandboxed` only if strict mode stops at an intermediate tree.
   - Arbitrary compact values: `get-data-by-code`.
   - One GC function/table: `search-gc`. Deeper runtime investigation: `executor-capabilities`, then `gc-snapshot`, `gc-query`, and `runtime-inspect`/`runtime-references`.
3. Reduce the root, selector, range, filters, and limit before increasing any output budget.
4. For GC or custom instance probes, follow [references/runtime-patterns.md](references/runtime-patterns.md).
5. Mutate only when the user's request authorizes mutation. Use `execute` or `execute-file`, then verify the resulting state with a specialized read, a targeted `get-data-by-code` probe, or a small console read.
6. For remotes, call `remote-spy` with `operation=list`, a small limit, and `summaryOnly=true` before requesting arguments or changing capture state.
7. Report the observed result. Top-level execution acknowledgement is not proof that the intended in-game state changed; verify that state separately.
8. Use `wait-for-event` cursors for console and non-selector instance journals instead of repeatedly polling snapshots. Selector, attribute, and remote waits observe from call start (or current state with `includeExisting`).

Read [references/functions.md](references/functions.md) when choosing among tools. Read [references/bad-practices.md](references/bad-practices.md) before broad inspection, arbitrary Luau, remote-state changes, or client mutation.
