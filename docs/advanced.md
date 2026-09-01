# Advanced Configuration

## Shared Core and Remote Mode

By default, each AI harness starts a small stdio adapter. The first adapter starts one persistent background core on port `16384`; every other adapter connects to that same core. The core owns the Roblox bridge, dashboard, decompiler processes, and MCP tool sessions.

### Remote primary (`--baseurl`)

If your AI client runs on macOS/Linux but Roblox is on a Windows machine, its stdio adapter can connect directly to the Windows background core:

```json
{
  "mcpServers": {
    "roblox-executor-mcp": {
      "command": "node",
      "args": [
        "/path/to/roblox-executor-mcp/dist/index.js",
        "--baseurl",
        "http://<windows-ip>:16384"
      ]
    }
  }
}
```

**Fallback behavior:**

| Scenario | Result |
|---|---|
| Remote reachable | Adapter connects to the remote background core |
| Remote unreachable | Adapter falls back to the local background core |
| Local core already running | Adapter reuses the existing local core |

Because tools execute in the selected background core, `screenshot-window` and `list-roblox-windows` run on the remote Windows host when `--baseurl` is connected.

The core listens on `127.0.0.1` by default. For a LAN or VPN bridge, set these variables on the Windows core and on every remote stdio adapter:

```text
ROBLOX_MCP_HOST=0.0.0.0
ROBLOX_MCP_AUTH_TOKEN=<a-long-random-pairing-token>
ROBLOX_MCP_CONNECTOR_TOKEN=<a-different-long-random-connector-token>
```

Use `ROBLOX_MCP_CONNECTOR_TOKEN` as the long-lived Roblox connector credential. Keep
`ROBLOX_MCP_AUTH_TOKEN` for MCP adapters and agents only. If the connector token
is omitted, Roblox falls back to the agent token for backward compatibility. If
a non-loopback host is enabled without an explicit token, the core generates a
token for that run and prints it to stderr; explicit tokens are more reliable
across restarts.

Plain `http://` and `ws://` provide authentication but no confidentiality or transport integrity. On an ordinary LAN, the pairing token, game data, script source, and executed commands can be observed or modified by a network attacker. Use a trusted isolated network only as a last resort; prefer Tailscale/a VPN, an SSH tunnel, or an HTTPS reverse proxy. The connector accepts `https://...` in `BridgeURL` and automatically uses `wss://` for WebSocket transport.

Wildcard binds accept direct IP Host headers. If clients use a DNS name, list it explicitly with `ROBLOX_MCP_ALLOWED_HOSTS=roblox-pc.example.internal` (comma-separate multiple names). This prevents DNS-rebinding pages from disguising a public hostname as the local bridge.

## Connector Options

Set these in Roblox **before** running the connector:

| Variable | Default | Description |
|---|---|---|
| `getgenv().BridgeURL` | `localhost:16384` | Server address, or an `https://` base URL for TLS termination |
| `getgenv().MCPAuthToken` | empty | Pairing token required by a remote or explicitly protected bridge |
| `getgenv().DisableWebSocket` | `false` | Optional troubleshooting override that forces HTTP polling |
| `getgenv().EnableInitialScriptDecompMapping` | `false` | Opt into a full script decompilation/index scan immediately on connect |
| `getgenv().DisableInitialScriptDecompMapping` | unset | Legacy compatibility: explicit `false` opts in; `true` disables initial mapping |
| `getgenv().MCP_FailedScriptResyncInterval` | `30` | Seconds before the first failed-script resync; repeated failures back off to five minutes |
| `getgenv().MCP_FailedScriptResyncBatchSize` | `8` | Maximum failed scripts queued by one periodic resync tick |
| `getgenv().MCP_RuntimeMaxHandles` | `50000` | Maximum active runtime handles (100-200000); old handles are evicted in creation order when full |
| `getgenv().MCP_RuntimeHandleTtlSeconds` | `1800` | Idle lifetime for pinned runtime handles (30-7200 seconds) |
| `getgenv().MCP_RuntimeValueDepth` | `3` | Maximum inline tagged-table depth (0-8); deeper objects become handles |
| `getgenv().MCP_RuntimeValueEntries` | `100` | Default tagged-value entry budget (1-1000) |
| `getgenv().MCP_RuntimeValueStringBytes` | `4096` | Default UTF-8 string budget per runtime value |
| `getgenv().MCP_GcMaxSnapshots` | `8` | Retained GC snapshot manifests (2-32) |
| `getgenv().MCP_GcDefaultScanLimit` | `20000` | Default number of executor GC objects considered by a snapshot |
| `getgenv().MCP_GcTableScanLimit` | `250` | Default number of table entries sampled for signatures and predicates |

For a hosted bridge, run `loadstring(game:HttpGet("https://your-host/loader.luau"))()`.
The server injects `ROBLOX_MCP_CONNECTOR_TOKEN` into the downloaded bootstrap, and
the connector authenticates its script download, WebSocket, and HTTP fallback
requests automatically. The token remains available to the running executor even
though it is omitted from the pasted command.

Failed script mappings are retried automatically in bounded batches. A resync prioritizes the provider that the original attempt actually reached, then uses the configured provider order as fallback.

Initial full-game script indexing is opt-in because it can be expensive in large experiences. Start it on demand with the `script-index-start` tool, rebuild it with `script-index-resync`, or set `getgenv().EnableInitialScriptDecompMapping = true` before loading the connector.

Runtime handles are scoped to one connector generation and never silently reused. GC snapshot indexing initially stores weak object references; a handle becomes pinned when a query returns it or another tool explicitly uses it. Every snapshot/query page reports scan counts, cursors, stale handles, and truncation state so executor visibility limits remain distinguishable from an empty result.

The connector supports two transport modes:
- **WebSocket** (preferred) — persistent connection, lower latency
- **HTTP Polling** — fallback for executors that don't support WebSocket

Transport selection is automatic. The connector recognizes common executor WebSocket API names, attempts a real connection, and falls back to HTTP polling if the API is absent, broken, or unable to connect. A failed WebSocket probe is temporarily cooled down so reconnects remain responsive.

## Archive Updates

Git checkouts update from their configured tracking remote. Packaged installs
do not trust a baked-in download location; configure an archive you control:

```text
ROBLOX_MCP_UPDATE_ARCHIVE_URL=https://downloads.example/roblox-mcp.tar.gz
ROBLOX_MCP_UPDATE_ARCHIVE_SHA256=<optional-64-character-sha256>
```

The updater requires HTTPS (except loopback tests), bounds the download,
rejects unsafe archive paths and links, and verifies the digest when supplied.

## Dashboard

A live status dashboard is available at `http://localhost:16384/` when the server is running. It shows connected clients, server role, and uptime.

Under **Settings → Decompiler fallbacks**, choose **Add provider → Custom provider** to add an HTTP decompiler to the fallback chain. You can add multiple custom providers; each keeps an independent workflow, fallback position, endpoint, authentication, headers, timeout, and health state. The custom-provider editor uses a pannable, zoomable node canvas: add blocks, drag them into place, and connect their ports to define the bytecode-to-source path. Bytecode and Source are permanent boundary blocks. Use Set Variable to name the current raw or base64 value, then reference it in the Request headers or body with `{{variable_name}}`; the optional API key is available as `{{api_key}}`. Type `{{` for autocomplete, use the arrow keys to choose a variable, and press Enter or Tab to insert it. Undo and redo are available from the toolbar or with Command/Ctrl+Z, Command/Ctrl+Shift+Z, and Ctrl+Y. The Request response port can connect directly to Source for plain text or through Parse JSON for a configurable dot-path field.

Luacid is also available as an optional remote fallback. It is disabled by default because enabling it sends bytecode off-device. Keyless HTTP and authenticated WebSocket modes are supported; WebSocket responses are capped at 8 MiB, and only the documented primitive decompiler options are forwarded.

### Railway Luraph worker

Luraph devirtualization is separate from bytecode decompiler fallback selection. The `devirtualize-luraph` MCP tool can read one source from the server-side script index with `operation=run`, or accept up to 4 MiB of directly supplied Lua/Luau in `operation=run-source` without requiring a connected Roblox client. Both operations retain the recovered source in the MCP core for 10 minutes; `operation=read` pages it and `operation=release` removes it early. Deploy the worker with `/services/luraph-worker/Dockerfile`; for a service named `luraph-worker`, use `http://luraph-worker.railway.internal:8080` so the traffic remains on Railway's private network. Set a shared `LURAPH_WORKER_TOKEN` on both services.

The worker uses `luauvmp luraph-full --no-lua-expert`, caps source and result sizes, permits one concurrent job, and removes its temporary directory after completion. `strict` capture avoids staged bootstrap execution but can produce only an intermediate result. `sandboxed` capture enables the devirtualizer's bounded bootstrap decoder and should be used only when strict capture cannot reach the protected application tree. Neither mode intentionally invokes the final protected payload.

## Security

**This server allows arbitrary code execution.** Any connected AI client can run Lua code in your Roblox session, take screenshots, and read client data.

The server binds to loopback unless `ROBLOX_MCP_HOST` is explicitly set.
Non-loopback clients must authenticate. `ROBLOX_MCP_AUTH_TOKEN` protects MCP
agents, while optional `ROBLOX_MCP_CONNECTOR_TOKEN` limits Roblox loaders to
connector routes. Setting either also protects its corresponding local bridge
endpoints. Browser requests are restricted to the bridge's own origin.

**Never expose port `16384` directly to the internet.** Authentication is defense in depth for cross-machine setups:

- Prefer a **VPN**; use a plain local network only when it is isolated and fully trusted
- Use an **SSH tunnel**: `ssh -L 16384:localhost:16384 user@windows-machine`
- Or terminate TLS and set `BridgeURL`/`--baseurl` to the resulting `https://` URL
- **Never** forward the port through a public router or cloud firewall
