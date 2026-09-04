# Deployment and access control

## Credentials and routes

Set secrets as service environment variables, not committed files or command-line arguments. Existing values do not need to change for this upgrade.

| Setting | Purpose |
| --- | --- |
| `ROBLOX_MCP_AUTH_TOKEN` | Agent access to MCP, the agent WebSocket relay and protected dashboard APIs. |
| `ROBLOX_MCP_CONNECTOR_TOKEN` | Roblox connector registration, polling, responses, connector WebSocket transport and authenticated script/decompiler routes. Use a value distinct from the agent token. |
| `ROBLOX_MCP_PUBLIC_LOADER` | Set to `0` to disable `/loader.luau`; the authenticated `/script.luau` path remains available. Omit to retain the one-line loader. |
| `ROBLOX_MCP_ALLOWED_HOSTS` | Comma-separated additional hostnames, such as a custom domain, without URL schemes or paths. |

The public one-line loader necessarily sends a **connector credential** to whoever downloads it. Keeping the token out of the pasted command does not keep it secret from the executor or downloader. It must never grant agent-level access. `/loader.luau` therefore returns `503` if a separate, distinct connector token is not configured. An explicitly disabled loader returns `404`. Loader responses are not cacheable.

Agent routes require agent header/Bearer credentials even on WebSocket requests; an `Upgrade` header cannot change an HTTP API's authentication scope. Query-string credentials are reserved for `/script.luau` and connector WebSocket compatibility, not agent APIs/relay. Local dashboard administration still requires its existing local-admin checks; this change does not enable remote administration.

For a private installation, disable the public loader and distribute the connector setup privately. The connector token permits registration of clients; select the intended client explicitly, and treat game data from any client as untrusted input. Tokens are not automatically rotated. Generated remote pairing tokens are no longer printed in startup logs; configure the agent token through your service environment.

## Railway settings

Use the MCP repository root for the MCP service, not the separate `services/luraph-worker` directory. Build with `npm run build` and start the background server with `npm run start:core`. This consumes the committed `connector.luau`; regenerate that artifact and run tests before publishing changes to connector sources.

In the service settings, set the healthcheck path to **`/health`**. It returns a minimal `200 {"status":"ready"}` only after HTTP/WS startup and route loading. This is process readiness, not confirmation that a Roblox client is connected or a decompiler worker is healthy. [Railway uses a 200 healthcheck before switching a deployment into service](https://docs.railway.com/deployments/healthchecks); it is not continuous monitoring.

When `RAILWAY_PROJECT_ID` or `RAILWAY_ENVIRONMENT_ID` is present, the default bind address is `0.0.0.0` and the server uses Railway's `PORT`. Explicit `ROBLOX_MCP_HOST` and `ROBLOX_MCP_PORT` retain precedence. If you override the port, align Railway's target/healthcheck port with it. Outside Railway the local defaults remain `127.0.0.1:16384` and an unrelated `PORT` variable is ignored.

A valid `RAILWAY_PUBLIC_DOMAIN` is accepted as the hosted service hostname. The Railway healthcheck hostname is accepted only for readiness requests in Railway mode, not as a blanket exception for protected routes. Custom domains should be added to `ROBLOX_MCP_ALLOWED_HOSTS`.

Keep service-specific settings in Railway's deployment settings or your existing infrastructure configuration. This upgrade does not migrate projects, replace deployment settings, create services or automatically publish local changes.

## Release checks

1. Install the project's pinned Darklua and an official Luau CLI. Run `npm test`; it rebuilds the connector/server and checks authentication, routing, lifecycle and integration regressions. Ensure generated `connector.luau` changes accompany source changes.
2. Run the sibling Dex adapter tests as documented in its `MCP.md`. Preserve unrelated work when choosing files for a commit.
3. Confirm the target Railway project, environment, service and source revision before deploying. Store both credentials in service variables and confirm they are distinct without printing them.
4. Wait for a successful deployment, then check `/health` for the expected JSON. A generic HTTP 200 or successful build is insufficient.
5. Verify that unauthenticated agent requests are rejected, valid agent authentication works, and connector credentials cannot access the agent relay. If using the public loader, verify its response privately without printing its body or token into logs.
6. Reload the connector and Dex in a test client. Check client selection, `runtime-status`, `dex-selection`, a small `dex-inspect`, a watch start/poll/stop cycle and UI reveal before claiming live compatibility.

If verification fails, keep the prior working deployment or use Railway's existing rollback controls. Do not rewrite history, discard local edits, or rotate credentials as a deployment workaround.
