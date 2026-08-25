<p align="center">
  <img src="docs/banner-new.svg" alt="Roblox Executor MCP" width="900"/>
</p>

# Roblox Executor MCP Server

An MCP server that allows Agents to interact with a running Roblox game client — execute code, inspect scripts, spy on remotes, and more.

## Contributors

- amyyzing
- Claude Mythos 5
- ChatGPT

## Dashboard

Roblox Executor MCP includes a local web dashboard at:

```text
http://localhost:16384/
```

Use it to see connected Roblox clients, inspect scripts, run tools, view server logs, configure semantic search, and index games for semantic script search.

## Features

- **Code Execution** — Run Lua code and fetch data from the game client.
- **Script Inspection** — Decompile scripts and search across all sources.
- **Controlled Script Indexing** — Start, stop, inspect, or fully resync source mapping on demand; expensive initial indexing is opt-in.
- **Instance Search** — CSS-like selectors and hierarchy trees.
- **Runtime Diagnostics** — Inspect transport latency, executor capabilities, decompiler health, and live mapping state.
- **Runtime Object Debugger** — Keep generation-scoped handles to GC objects, closures, tables, threads, Instances, callbacks, signals, and connections; inspect or manipulate them without flattening everything into text.
- **GC Snapshots and References** — Build reusable GC indexes, query and diff snapshots, compute statistics, and follow table/upvalue/prototype/metatable reference edges.
- **Bounded Runtime Search & Events** — First-match GC searches plus bounded waits; console and non-selector instance journals support resumable cursors.
- **Bundled Remote Spy** — Inspect, block, and filter Remotes/Bindables without executing a separate script. The connector capability-probes executor hooks and never downloads spy code.
- **Railway Luraph Devirtualizer** — Send indexed or directly supplied raw protected source to an optional private Railway worker and return recovered source plus quality metrics without installing Python locally.
- **Unified Input** — Keyboard, text, mouse, scroll, prompt, click-detector, and touch interaction.
- **Screenshot** — Capture Roblox window screenshots (Windows only).
- **Multi-Client** — Connect multiple Roblox clients at once.

## Prerequisites

- **Node.js** ≥ 18
- **Bun** ≥ 1.3 for the interactive OpenTUI harness installer
- **A Roblox executor** that supports `loadstring`, `request`, and (preferably) `WebSocket`

## Quick Start

### 1. Clone the server

```bash
git clone https://github.com/amyyzing/ai-mcp.git
cd ai-mcp
```

### 2. Run the installer

The installer opens a guided browser setup. It builds the server, configures selected AI harnesses, optionally installs the packaged Roblox MCP skill and Roblox connector, and can register the shared server to run in the background with your computer.

On Windows, double-click `setup.cmd`. It checks for Node.js 18+, installs Node.js LTS through WinGet when necessary, and then opens the guided installer.

For manual or non-Windows setup, run:

```bash
npm run install:harnesses
```

The browser opens with a one-time secure installer link. Keep the terminal open until setup finishes. The normal server build consumes the committed `connector.luau` artifact, so installs do not require Darklua. Connector developers can install the pinned tool with `rokit install`, edit `connector-src/`, and regenerate the artifact with `npm run build:connector`.

For a terminal-only setup, use the explicit CLI installer. The CLI picker is built with [OpenTUI](https://opentui.com/) and runs through Bun:

```bash
npm run install:harnesses:cli
```

If the interactive terminal picker is unavailable, add `-- --plain`. Press `s` in the picker or pass `-- --show-all-harnesses` to reveal every supported config target. After writing configs, both installers can automatically restart supported GUI harnesses that are currently running. CLI-only harness sessions still receive a restart instruction when they cannot be relaunched safely.

To explore the browser flow without changing configs, installing packages, registering a service, or restarting harnesses, run:

```bash
npm run install:harnesses:preview
```

Pass `-- --no-open` to either browser command to start it without opening a browser. Pass `-- --host 0.0.0.0` to access it from another device over your LAN or Tailscale; use the complete tokenized URL printed by the installer.

The installer can also place the Roblox loader into a detected executor autoexec folder, such as MacSploit on macOS or supported Windows executor autoexec folders. Use the prompt, or run:

```bash
npm run getscript -- --autoexec
```

It can also help with:

- cross-machine setup on the same LAN
- copying the Roblox loader to your clipboard
- optional Ollama `embeddinggemma` setup for semantic indexing
- pulling latest repo changes before install/build

To update an existing install later, run:

```bash
npm run update
```

You can also open **Dashboard → Settings → Server updates** and select **Update now**.

### Manual setup

If you prefer to configure a client yourself, use the setup guide for your client:

| Client         | Guide                                       |
| -------------- | ------------------------------------------- |
| Cursor         | [Setup Guide](docs/setup-cursor.md)         |
| Claude Desktop | [Setup Guide](docs/setup-claude-desktop.md) |
| Claude Code    | [Setup Guide](docs/setup-claude-code.md)    |
| Codex CLI      | [Setup Guide](docs/setup-codex.md)          |
| Windsurf       | [Setup Guide](docs/setup-windsurf.md)       |
| Antigravity    | [Setup Guide](docs/setup-antigravity.md)    |
| BLACKBOX AI    | [Setup Guide](docs/setup-blackbox.md)       |
| ZCode          | [Setup Guide](docs/setup-zcode.md)          |

### 3. Connect from Roblox

The installer prints this for you. Put it in your executor or Auto Execute:

```lua
local HttpService = game:GetService("HttpService")
local attempts = 0

while not getgenv().MCP_Loaded do
    local bridgeUrl = tostring(getgenv().BridgeURL or "localhost:16384"):gsub("/+$", "")
    local bridgeBase
    if string.match(bridgeUrl, "^https?://") then
        bridgeBase = bridgeUrl
    elseif string.match(bridgeUrl, "^wss://") then
        bridgeBase = "https://" .. string.sub(bridgeUrl, 7)
    elseif string.match(bridgeUrl, "^ws://") then
        bridgeBase = "http://" .. string.sub(bridgeUrl, 6)
    else
        bridgeBase = "http://" .. bridgeUrl
    end

    local scriptUrl = bridgeBase .. "/script.luau"
    local token = getgenv().MCPAuthToken or getgenv().BridgeAuthToken
    if type(token) == "string" and token ~= "" then
        scriptUrl ..= "?token=" .. HttpService:UrlEncode(token)
    end

    attempts += 1
    local success, loadError = pcall(function()
        local source = game:HttpGet(scriptUrl)
        local chunk, compileError = loadstring(source)
        assert(chunk, compileError or "The bridge returned an invalid connector script.")
        chunk()
    end)

    if not success and (attempts == 1 or attempts % 20 == 0) then
        warn("[Roblox MCP] Connector attempt " .. attempts .. " failed for " .. bridgeBase .. ": " .. tostring(loadError))
    end

    task.wait(attempts < 10 and 0.15 or 1)
end
```

**Optional settings** (set before the `loadstring`):

```lua
getgenv().BridgeURL = "10.0.0.4:16384"                  -- host:port, or https://bridge.example
getgenv().MCPAuthToken = "replace-with-your-pairing-token" -- required for remote bridges
getgenv().DisableWebSocket = true                        -- optional: force HTTP polling
getgenv().EnableInitialScriptDecompMapping = true        -- opt into full indexing on connect
getgenv().MCP_FailedScriptResyncInterval = 30            -- retry failed script syncs periodically
getgenv().MCP_FailedScriptResyncBatchSize = 8            -- bound each periodic retry batch
```

Full-game script indexing is off by default to keep large experiences responsive. Use the `script-index-start` MCP tool when needed, or set `EnableInitialScriptDecompMapping = true` before loading the connector.

Transport selection is automatic. The connector detects common executor WebSocket APIs, attempts a real connection, and falls back to HTTP polling if WebSocket is missing or broken. `DisableWebSocket` is only a troubleshooting override; normal users do not need to set it.

`BridgeURL` must point to this Roblox MCP server and its `/script.luau` route. Do not set it to an executor application's agent-facing MCP endpoint: for example, Potassium's local MCP port exposes `list_clients`, `execute_script`, and `read_console`, but it does not host this connector. Potassium can execute the loader, while the loader still connects separately to this server on `16384` or to an authenticated HTTPS deployment.

When `MCPAuthToken` is set, the loader automatically authenticates the initial connector download as well as its later WebSocket or HTTP requests. A failed download or compile attempt is reported through `warn` instead of being silently swallowed.

After the MCP server starts and Roblox connects, open the dashboard:

```text
http://localhost:16384/
```

### Bundled remote spy

The `remote-spy` MCP tool starts its internal spy on first use; users do not need to execute Cobalt separately. Run `operation=status` to see the executor capabilities that were detected. Outgoing namecall capture and blocking require `hookmetamethod` plus `getnamecallmethod`. Incoming `RemoteEvent`, `UnreliableRemoteEvent`, and `BindableEvent` calls are observed passively, so incoming calls can be ignored but not blocked; incoming function callbacks are not intercepted. If a compatible external Cobalt instance is already running, the MCP uses it instead of installing a second hook.

### Executor runtime debugger

The runtime tools capability-probe each executor rather than assuming one API set. A practical deep-inspection flow is:

1. `executor-capabilities`
2. `gc-snapshot` with `operation=create`
3. `gc-query` with narrow criteria
4. `runtime-inspect`, `runtime-read`, or `runtime-references` on returned handles
5. `runtime-release` when retained objects are no longer needed

Additional tools expose runtime environments and loaded/running script inventories, Actor threads, callback properties, hidden/non-scriptable properties, and `getconnections` metadata/control. Tagged values preserve Roblox datatypes, cycles, shared table references, non-finite numbers, and non-serializable objects through handles. GC snapshot handles are weak until returned by a query, so creating a snapshot does not itself keep every discovered object alive or corrupt later diffs.

### Railway Luraph devirtualizer

The optional `devirtualize-luraph` tool processes an indexed script or directly supplied raw Lua/Luau source on a separate Railway worker, so users do not install Python, Lune, or the devirtualizer on their PC. Raw submissions do not require a connected Roblox client or script index. Deploy a second Railway service from this repository with **Dockerfile Path** set to `/services/luraph-worker/Dockerfile`, name it `luraph-worker`, and leave it private. Configure a `/health` healthcheck and set the same random `LURAPH_WORKER_TOKEN` on both services. On the main MCP service, also set:

```text
LURAPH_WORKER_URL=http://luraph-worker.railway.internal:8080
LURAPH_WORKER_TOKEN=<shared random token>
```

For indexed game source, call `script-index-start` if needed, use `list-scripts` to obtain the exact path, then call `devirtualize-luraph` with `operation=run`. For source already in hand, call it with `operation=run-source`, `source=<raw Lua/Luau>`, and an optional `sourceName`; this works with no Roblox client connected. Raw source is limited to 4 MiB. Page either cached result with `operation=read` and its returned `nextStartLine`, then use `operation=release`. Results expire after 10 minutes. `captureMode=strict` is the default and may stop at an intermediate tree. `captureMode=sandboxed` permits the devirtualizer's bounded bootstrap decoder but does not invoke the final protected payload. The worker pins its devirtualizer and Lune versions, disables the optional lua.expert upload, handles one job at a time, and deletes ephemeral artifacts after every request. See [the worker deployment guide](services/luraph-worker/README.md).

## Community

Have a suggestion or need help? Join the [Discord server](https://discord.gg/FJcJMuze7S).

## Security

> **This server allows arbitrary code execution.** Only use with AI clients you trust. The bridge binds to loopback by default. Remote mode requires an explicit bind host and pairing token; even with authentication, **never expose it directly to the internet.** Plain `http://`/`ws://` LAN traffic is not encrypted, so its token, game data, source, and commands are visible and modifiable by anyone able to intercept that network. Prefer a VPN/SSH tunnel or an `https://` TLS-terminating bridge. See [Advanced](docs/advanced.md) for details.

## License

[MIT](LICENSE)
