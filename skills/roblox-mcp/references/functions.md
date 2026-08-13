# Function guide

Always prefer the live MCP schemas over this summary.

## Read-path priority

Choose the first tool that can answer the question:

1. A specialized inspection tool.
2. `get-data-by-code` for a small custom read that must return values.
3. `execute` or `execute-file` for an intentional side effect.

Do not use `execute` plus `print` as a substitute for returned data.

## Client routing

- `list-clients`: List connected Roblox clients and their IDs.
- `set-active-client`: Route later calls to one client.
- `runtime-status`: Probe routing, latency, executor capabilities, script sync, and decompiler health.

## Inspection and search

- `get-game-info`: Read place and universe metadata.
- `get-descendants-tree`: Summarize or inspect hierarchy below a root.
- `inspect-instance`: Read one known instance's properties, attributes, tags, bounds, stable path, and bounded children.
- `search-instances`: Find instances with `QueryDescendants` selectors. Prefer this over retrieving descendants and filtering them afterward.
- `script-grep`: Search decompiled scripts by exact text or regex.
- `script-index-status`, `script-index-start`, `script-index-stop`, `script-index-resync`: Observe and explicitly control source mapping. Initial full indexing is off by default.
- `list-scripts`: Page through indexed script metadata without source by default.
- `semantic-search-scripts`: Find scripts by behavior when exact identifiers are unknown. OpenAI-compatible providers require explicit confirmation because source-derived text and queries leave the machine and may cost money; indexing also has hard chunk/input budgets.
- `get-script-content`: Read one script or a focused source range.
- `get-console-output`: Read recent developer-console logs.
- `get-data-by-code`: Run a small Luau probe and return serialized raw values. The code must `return` its result.
- `search-gc`: Return the first structured `filtergc` match with bounded summaries and fallback iteration. Executor-native snapshot allocation is outside the tool's control.
- `wait-for-event`: Wait for matching console, instance, attribute, or remote activity. Cursors are resumable only for console and non-selector instance journals.

## Execution and interaction

- `execute`: Run Luau for an intentional side effect and wait for top-level completion/failure acknowledgement; verify the resulting state separately.
- `execute-file`: Run a bounded local `.luau` or `.lua` file and wait for top-level acknowledgement.
- `input`: Send bounded keyboard, text, mouse, scroll, prompt, click-detector, or touch input.
- `click-button`: Fire signals on a Roblox `GuiButton`.
- `type-text-box`: Enter text into a Roblox `TextBox`.

## Remote inspection

- `remote-spy`: Start the bundled spy, then list, inspect, block, unblock, ignore, or unignore captured remotes. Check `operation=status` for executor-specific hook support.

## Windows host tools

- `list-roblox-windows`: List visible Roblox windows and PIDs on Windows.
- `screenshot-window`: Capture a selected Roblox OS window on Windows.

## Selection rules

- Known name, string, remote, or API: use `script-grep`.
- Unknown implementation but known behavior: use `semantic-search-scripts`.
- Known instance criteria: use `search-instances`.
- Unknown hierarchy: start with `get-descendants-tree` summary mode.
- Need a custom read or returned values: use `get-data-by-code`, not `execute`.
- Need an intentional side effect with no returned data: use `execute` or `execute-file`, then verify.
- Need to find GC functions or tables: use `search-gc`; fall back to custom `filtergc` only for unsupported predicates.
- Need a custom selector-expressible instance query: use `QueryDescendants` inside `get-data-by-code`.

See [runtime-patterns.md](runtime-patterns.md) for exact code patterns and fallback conditions.
