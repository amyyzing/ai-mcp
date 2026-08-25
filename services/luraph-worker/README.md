# Railway Luraph worker

Deploy this directory as a second Railway service from the same repository.

1. Create an empty service connected to this repository.
2. Set **Dockerfile Path** to `/services/luraph-worker/Dockerfile`.
3. Do not generate a public domain. Railway assigns the private hostname `luraph-worker.railway.internal` when the service is named `luraph-worker`.
4. Set `LURAPH_WORKER_TOKEN` to a random shared secret.
5. On the main MCP service, set:

   ```text
   LURAPH_WORKER_URL=http://luraph-worker.railway.internal:8080
   LURAPH_WORKER_TOKEN=<the same shared secret>
   ```

The worker pins `luau-vmp-deobf` to a specific archived commit and Lune to a specific release. It always passes `--no-lua-expert`, uses ephemeral job directories, limits execution to one job at a time, and removes each job directory after completion.

From the MCP, call `devirtualize-luraph` with `operation=run` for an indexed game script or `operation=run-source` for up to 4 MiB of directly supplied raw Lua/Luau. Direct source submission does not require a connected Roblox client. Page the returned result with `operation=read`, and remove the in-memory result with `operation=release`. Cached results expire after 10 minutes.

Configure the Railway healthcheck path as `/health`. A volume is not required.
