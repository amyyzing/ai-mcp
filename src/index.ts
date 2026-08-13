#!/usr/bin/env node

import { spawn } from "node:child_process";
import path from "node:path";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  StreamableHTTPClientTransport,
  StreamableHTTPError,
} from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import type { JSONRPCMessage } from "@modelcontextprotocol/sdk/types.js";

import { BASE_URL, SERVER_NAME, SERVER_ROOT, WS_PORT } from "./config.js";
import { bridgeAuthHeaders } from "./http/bridge-auth.js";
import {
  readUpdateLock,
  updateWorkerIsRunning,
} from "./shared/update-status.mjs";
import { resolveActiveReleaseRoot } from "./shared/release-pointer.mjs";

const LOCAL_CORE_BASE_URL = `http://127.0.0.1:${WS_PORT}`;
let activeCoreBaseUrl =
  BASE_URL ||
  process.env.ROBLOX_MCP_CORE_URL ||
  LOCAL_CORE_BASE_URL;
let establishedRemoteCore = false;
const CORE_START_TIMEOUT_MS = 10_000;
const CORE_POLL_INTERVAL_MS = 100;
const CORE_HEALTH_TIMEOUT_MS = 2_000;
const CORE_MONITOR_INTERVAL_MS = Math.max(
  250,
  Number.parseInt(process.env.ROBLOX_MCP_CORE_MONITOR_INTERVAL_MS || "", 10) ||
    2_000
);
const UPDATE_CUTOVER_TIMEOUT_MS =
  Number.parseInt(process.env.ROBLOX_MCP_UPDATE_CUTOVER_TIMEOUT_MS || "", 10) ||
  90_000;
const INTERNAL_INITIALIZE_ID = "__roblox_mcp_adapter_initialize__";

const stdio = new StdioServerTransport();
let upstream: StreamableHTTPClientTransport;
let reconnectPromise: Promise<void> | null = null;
let initializeMessage: JSONRPCMessage | null = null;
let initializedMessage: JSONRPCMessage | null = null;
let internalInitializeResolve: (() => void) | null = null;
let internalInitializeReject: ((error: Error) => void) | null = null;
let connectedCoreInstanceId: string | null = null;
let coreMonitor: NodeJS.Timeout | null = null;
let coreMonitorRunning = false;

function log(message: string): void {
  process.stderr.write(`[Adapter] ${message}\n`);
}

function messageMethod(message: JSONRPCMessage): string | undefined {
  return "method" in message && typeof message.method === "string"
    ? message.method
    : undefined;
}

function messageId(message: JSONRPCMessage): string | number | undefined {
  return "id" in message ? message.id : undefined;
}

function createUpstream(): StreamableHTTPClientTransport {
  const transport = new StreamableHTTPClientTransport(
    new URL("/mcp", activeCoreBaseUrl),
    {
    requestInit: {
      headers: {
        "X-Roblox-MCP-Server-Name": SERVER_NAME,
        ...bridgeAuthHeaders(),
      },
    },
    }
  );

  transport.onmessage = (message) => {
    if (messageId(message) === INTERNAL_INITIALIZE_ID && internalInitializeResolve) {
      const resolve = internalInitializeResolve;
      internalInitializeResolve = null;
      internalInitializeReject = null;
      resolve();
      return;
    }
    void stdio.send(message).catch((error) => {
      log(`Could not write an MCP response: ${error instanceof Error ? error.message : error}`);
    });
  };
  transport.onerror = (error) => {
    if (internalInitializeReject) {
      const reject = internalInitializeReject;
      internalInitializeResolve = null;
      internalInitializeReject = null;
      reject(error);
      return;
    }
    log(`Core transport error: ${error.message}`);
  };

  return transport;
}

interface CoreInfo {
  architecture?: unknown;
  instanceId?: unknown;
}

async function readCoreInfo(): Promise<CoreInfo | null> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), CORE_HEALTH_TIMEOUT_MS);
  try {
    const response = await fetch(new URL("/api/server-info", activeCoreBaseUrl), {
      cache: "no-store",
      headers: bridgeAuthHeaders(),
      signal: controller.signal,
    });
    if (!response.ok) return null;
    return (await response.json()) as CoreInfo;
  } catch {
    return null;
  } finally {
    clearTimeout(timeout);
  }
}

async function coreIsReady(): Promise<boolean> {
  const info = await readCoreInfo();
  return info?.architecture === "background-core";
}

async function startCore(): Promise<void> {
  const releaseRoot = await resolveActiveReleaseRoot(SERVER_ROOT);
  const child = spawn(process.execPath, [path.join(releaseRoot, "dist", "core.js")], {
    cwd: releaseRoot,
    detached: true,
    env: { ...process.env, ROBLOX_MCP_SERVER_ROOT: SERVER_ROOT },
    stdio: "ignore",
    windowsHide: true,
  });
  child.unref();
}

async function waitForUpdateCutover(): Promise<void> {
  const deadline = Date.now() + UPDATE_CUTOVER_TIMEOUT_MS;
  let announced = false;
  while (Date.now() < deadline) {
    const lock = await readUpdateLock();
    if (!updateWorkerIsRunning(lock)) return;
    if (!announced) {
      log("Waiting for the dashboard update to finish switching cores.");
      announced = true;
    }
    await new Promise((resolve) => setTimeout(resolve, CORE_POLL_INTERVAL_MS));
  }
  throw new Error("Timed out waiting for the dashboard update cutover.");
}

async function ensureCore(): Promise<void> {
  if (await coreIsReady()) return;
  if (BASE_URL && establishedRemoteCore && activeCoreBaseUrl === BASE_URL) {
    log("Remote core is restarting; waiting for it instead of changing machines.");
    const deadline = Date.now() + UPDATE_CUTOVER_TIMEOUT_MS;
    while (Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, CORE_POLL_INTERVAL_MS));
      if (await coreIsReady()) return;
    }
    throw new Error(
      `Remote background MCP core did not return at ${activeCoreBaseUrl}.`
    );
  }
  await waitForUpdateCutover();
  if (await coreIsReady()) return;
  if (BASE_URL) {
    log(`Remote core unavailable at ${activeCoreBaseUrl}; falling back to the local core.`);
    activeCoreBaseUrl = LOCAL_CORE_BASE_URL;
    if (await coreIsReady()) return;
  } else if (process.env.ROBLOX_MCP_CORE_URL) {
    throw new Error(
      `The configured background MCP core is unavailable at ${activeCoreBaseUrl}.`
    );
  }
  await startCore();

  const deadline = Date.now() + CORE_START_TIMEOUT_MS;
  while (Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, CORE_POLL_INTERVAL_MS));
    if (await coreIsReady()) return;
  }
  throw new Error(
    `Background MCP core did not become ready at ${activeCoreBaseUrl}. ` +
      "Stop any older MCP server using the port, then try again."
  );
}

async function startUpstream(): Promise<StreamableHTTPClientTransport> {
  await ensureCore();
  const transport = createUpstream();
  await transport.start();
  if (BASE_URL && activeCoreBaseUrl === BASE_URL) {
    establishedRemoteCore = true;
  }
  return transport;
}

async function replaySession(transport: StreamableHTTPClientTransport): Promise<void> {
  if (!initializeMessage || !initializedMessage) return;

  const replayInitialize = {
    ...initializeMessage,
    id: INTERNAL_INITIALIZE_ID,
  } as JSONRPCMessage;

  await new Promise<void>((resolve, reject) => {
    const timeout = setTimeout(() => {
      internalInitializeResolve = null;
      internalInitializeReject = null;
      reject(new Error("Timed out reinitializing the background MCP session."));
    }, 5_000);

    internalInitializeResolve = () => {
      clearTimeout(timeout);
      resolve();
    };
    internalInitializeReject = (error) => {
      clearTimeout(timeout);
      reject(error);
    };
    void transport.send(replayInitialize).catch(internalInitializeReject);
  });

  await transport.send(initializedMessage);
}

async function reconnect(failedTransport: StreamableHTTPClientTransport): Promise<void> {
  if (failedTransport !== upstream) return;
  if (reconnectPromise) return reconnectPromise;

  reconnectPromise = (async () => {
    await failedTransport.terminateSession().catch(() => {});
    await failedTransport.close().catch(() => {});
    const replacement = await startUpstream();
    await replaySession(replacement);
    upstream = replacement;
    const info = await readCoreInfo();
    connectedCoreInstanceId =
      typeof info?.instanceId === "string" ? info.instanceId : null;
    log("Reconnected to the background MCP core.");
  })().finally(() => {
    reconnectPromise = null;
  });

  return reconnectPromise;
}

async function monitorCoreInstance(): Promise<void> {
  if (coreMonitorRunning || reconnectPromise || !upstream) return;
  coreMonitorRunning = true;
  try {
    const info = await readCoreInfo();
    if (
      info?.architecture !== "background-core" ||
      typeof info.instanceId !== "string" ||
      !connectedCoreInstanceId ||
      info.instanceId === connectedCoreInstanceId
    ) return;

    log("Background core instance changed; reconnecting the MCP session.");
    await reconnect(upstream);
  } catch (error) {
    log(
      `Could not monitor the background core: ${
        error instanceof Error ? error.message : error
      }`
    );
  } finally {
    coreMonitorRunning = false;
  }
}

async function forwardToCore(message: JSONRPCMessage): Promise<void> {
  const method = messageMethod(message);
  if (method === "initialize") initializeMessage = message;
  if (method === "notifications/initialized") initializedMessage = message;

  const current = upstream;
  try {
    await current.send(message);
  } catch (error) {
    await reconnect(current).catch((reconnectError) => {
      log(
        `Could not reconnect to the background core: ${
          reconnectError instanceof Error ? reconnectError.message : reconnectError
        }`
      );
    });
    if (
      error instanceof StreamableHTTPError &&
      error.code === 404
    ) {
      await upstream.send(message);
      return;
    }
    const id = messageId(message);
    if (id !== undefined) {
      await stdio.send({
        jsonrpc: "2.0",
        id,
        error: {
          code: -32001,
          message:
            "The core connection changed while this request was in flight. " +
            "Its outcome is unknown, so the adapter did not retry it automatically.",
          data: {
            cause: error instanceof Error ? error.message : String(error),
          },
        },
      });
    } else {
      log("A notification was dropped while the core connection was changing.");
    }
  }
}

async function shutdown(): Promise<void> {
  if (coreMonitor) clearInterval(coreMonitor);
  await upstream?.terminateSession().catch(() => {});
  await Promise.allSettled([stdio.close(), upstream?.close()]);
}

async function main(): Promise<void> {
  upstream = await startUpstream();
  const info = await readCoreInfo();
  connectedCoreInstanceId =
    typeof info?.instanceId === "string" ? info.instanceId : null;
  stdio.onmessage = (message) => {
    void forwardToCore(message).catch((error) => {
      log(`Could not forward MCP traffic: ${error instanceof Error ? error.message : error}`);
      process.exitCode = 1;
    });
  };
  stdio.onerror = (error) => {
    log(`Stdio transport error: ${error.message}`);
  };
  await stdio.start();
  coreMonitor = setInterval(() => {
    void monitorCoreInstance();
  }, CORE_MONITOR_INTERVAL_MS);
  coreMonitor.unref();
  log(`Connected ${SERVER_NAME} to the background MCP core.`);
}

process.stdin.on("end", () => {
  void shutdown();
});
for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    void shutdown().finally(() => process.exit(0));
  });
}

main().catch((error) => {
  log(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
