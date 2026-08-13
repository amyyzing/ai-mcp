import { randomUUID } from "node:crypto";
import type { IncomingMessage, ServerResponse } from "node:http";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { isInitializeRequest } from "@modelcontextprotocol/sdk/types.js";

import { SERVER_NAME } from "../../config.js";
import { readJsonBody } from "../body.js";
import { createMcpServer } from "../../mcp/server.js";

interface McpSession {
  transport: StreamableHTTPServerTransport;
  server: ReturnType<typeof createMcpServer>;
  expiry: NodeJS.Timeout;
}

const sessions = new Map<string, McpSession>();
const SERVER_NAME_HEADER = "x-roblox-mcp-server-name";
const DEFAULT_SESSION_IDLE_TIMEOUT_MS = 10 * 60 * 1000;
const SESSION_IDLE_TIMEOUT_MS = Math.max(
  100,
  Number.parseInt(process.env.ROBLOX_MCP_SESSION_TTL_MS || "", 10) ||
    DEFAULT_SESSION_IDLE_TIMEOUT_MS
);
const MAX_MCP_SESSIONS = Math.min(
  1024,
  Math.max(
    1,
    Number.parseInt(process.env.ROBLOX_MCP_MAX_SESSIONS || "", 10) || 64
  )
);
let initializingSessionCount = 0;

function jsonRpcError(
  res: ServerResponse,
  status: number,
  message: string
): void {
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
  });
  res.end(
    JSON.stringify({
      jsonrpc: "2.0",
      error: { code: -32000, message },
      id: null,
    })
  );
}

function disposeSession(id: string): void {
  const session = sessions.get(id);
  if (!session) return;
  sessions.delete(id);
  clearTimeout(session.expiry);
  void Promise.allSettled([
    session.transport.close(),
    session.server.close(),
  ]);
}

function touchSession(id: string, session: McpSession): void {
  clearTimeout(session.expiry);
  session.expiry = setTimeout(() => disposeSession(id), SESSION_IDLE_TIMEOUT_MS);
  session.expiry.unref();
}

export function getActiveMcpSessionCount(): number {
  return sessions.size;
}

function sessionId(req: IncomingMessage): string | null {
  const value = req.headers["mcp-session-id"];
  return typeof value === "string" && value ? value : null;
}

function requestedServerName(req: IncomingMessage): string {
  const value = req.headers[SERVER_NAME_HEADER];
  return typeof value === "string" && /^[a-zA-Z0-9._-]{1,64}$/.test(value)
    ? value
    : SERVER_NAME;
}

function hasJsonContentType(req: IncomingMessage): boolean {
  const contentType = req.headers["content-type"];
  return (
    typeof contentType === "string" &&
    contentType.split(";", 1)[0]?.trim().toLowerCase() === "application/json"
  );
}

export async function POST(
  req: IncomingMessage,
  res: ServerResponse
): Promise<void> {
  if (!hasJsonContentType(req)) {
    jsonRpcError(res, 415, "Content-Type must be application/json.");
    return;
  }

  const body = await readJsonBody<unknown>(req);
  const requestedSessionId = sessionId(req);
  const existing = requestedSessionId ? sessions.get(requestedSessionId) : undefined;
  if (existing) {
    touchSession(requestedSessionId!, existing);
    await existing.transport.handleRequest(req, res, body);
    return;
  }

  if (requestedSessionId) {
    jsonRpcError(res, 404, "MCP session not found.");
    return;
  }
  if (!isInitializeRequest(body)) {
    jsonRpcError(res, 400, "An initialize request is required.");
    return;
  }
  if (sessions.size + initializingSessionCount >= MAX_MCP_SESSIONS) {
    jsonRpcError(res, 503, "The MCP session limit has been reached.");
    return;
  }

  let initializedSessionId: string | null = null;
  const server = createMcpServer(requestedServerName(req));
  const transport = new StreamableHTTPServerTransport({
    sessionIdGenerator: randomUUID,
    enableJsonResponse: true,
    onsessioninitialized: (id) => {
      initializedSessionId = id;
      const session = {
        transport,
        server,
        expiry: setTimeout(() => disposeSession(id), SESSION_IDLE_TIMEOUT_MS),
      };
      session.expiry.unref();
      sessions.set(id, session);
    },
  });
  transport.onclose = () => {
    const id = transport.sessionId || initializedSessionId;
    if (id) disposeSession(id);
  };

  initializingSessionCount += 1;
  try {
    await server.connect(transport);
    await transport.handleRequest(req, res, body);
  } finally {
    initializingSessionCount -= 1;
  }
}

export async function GET(
  req: IncomingMessage,
  res: ServerResponse
): Promise<void> {
  const id = sessionId(req);
  const session = id ? sessions.get(id) : undefined;
  if (!session) {
    jsonRpcError(res, 404, "MCP session not found.");
    return;
  }
  touchSession(id!, session);
  await session.transport.handleRequest(req, res);
}

export async function DELETE(
  req: IncomingMessage,
  res: ServerResponse
): Promise<void> {
  const id = sessionId(req);
  const session = id ? sessions.get(id) : undefined;
  if (!session) {
    jsonRpcError(res, 404, "MCP session not found.");
    return;
  }
  await session.transport.handleRequest(req, res);
}
