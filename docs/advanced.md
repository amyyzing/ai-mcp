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
```

Use the same value as `getgenv().MCPAuthToken` in Roblox. If a non-loopback host is enabled without an explicit token, the core generates a token for that run and prints it to stderr; an explicit token is more reliable across restarts.

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

For a remote bridge, append `?token=` plus `HttpService:UrlEncode(getgenv().MCPAuthToken)` to the initial `/script.luau` download URL. The connector then authenticates its WebSocket and HTTP fallback requests automatically.

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

## Security

**This server allows arbitrary code execution.** Any connected AI client can run Lua code in your Roblox session, take screenshots, and read client data.

The server binds to loopback unless `ROBLOX_MCP_HOST` is explicitly set. Non-loopback clients must authenticate, and setting `ROBLOX_MCP_AUTH_TOKEN` also protects local bridge endpoints. Browser requests are restricted to the bridge's own origin.

**Never expose port `16384` directly to the internet.** Authentication is defense in depth for cross-machine setups:

- Prefer a **VPN**; use a plain local network only when it is isolated and fully trusted
- Use an **SSH tunnel**: `ssh -L 16384:localhost:16384 user@windows-machine`
- Or terminate TLS and set `BridgeURL`/`--baseurl` to the resulting `https://` URL
- **Never** forward the port through a public router or cloud firewall
