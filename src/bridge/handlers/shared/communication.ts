import crypto from "crypto";
import { WebSocket } from "ws";
import { TOOL_RESPONSE_TIMEOUT } from "../../../config.js";
import type {
  DispatchResult,
  InstanceRole,
  RobloxClient,
  RobloxResponse,
  ResponseResolver,
} from "../../types.js";
import {
  getActiveClients,
  resolveTargetClient,
  setClientUnavailableHandler,
} from "./registry.js";

const MAX_PENDING_HTTP_COMMANDS = 100;
const MAX_PENDING_HTTP_COMMAND_BYTES = 8 * 1024 * 1024;
export const MAX_PENDING_BRIDGE_REQUESTS = 512;

// ─── Instance role ────────────────────────────────────────────────────────────
let instanceRole: InstanceRole = "primary";

export function getInstanceRole(): InstanceRole {
  return instanceRole;
}

export function setInstanceRole(role: InstanceRole): void {
  instanceRole = role;
}

// ─── Primary-mode routing state ───────────────────────────────────────────────
export const httpResponseResolvers: Map<string, ResponseResolver> = new Map();
export const requestToClientId: Map<string, string> = new Map();

export const relayClients: Set<WebSocket> = new Set();
export const relayRequestOrigin: Map<string, WebSocket> = new Map();

// ─── Secondary-mode routing state ─────────────────────────────────────────────
let relaySocket: WebSocket | null = null;
export const secondaryResponseResolvers: Map<string, ResponseResolver> = new Map();

export function rejectPendingRequestsForClient(
  clientId: string,
  reason: string
): void {
  for (const [id, expectedClientId] of [...requestToClientId]) {
    if (expectedClientId !== clientId) continue;

    const error = `Roblox client became unavailable: ${reason}.`;
    const originRelay = relayRequestOrigin.get(id);
    if (originRelay?.readyState === WebSocket.OPEN) {
      try {
        originRelay.send(JSON.stringify({ id, error }));
      } catch (sendError) {
        console.error(`[Bridge] Failed to reject relayed request ${id}:`, sendError);
      }
    }
    relayRequestOrigin.delete(id);

    const resolver = httpResponseResolvers.get(id);
    resolver?.({ id, error });
    httpResponseResolvers.delete(id);
    requestToClientId.delete(id);
  }
}

setClientUnavailableHandler(rejectPendingRequestsForClient);

export function getRelaySocket(): WebSocket | null {
  return relaySocket;
}

export function setRelaySocket(ws: WebSocket | null): void {
  relaySocket = ws;
}

export function resetPrimaryState(): void {
  for (const [id, resolver] of [...httpResponseResolvers]) {
    resolver({ id, error: "Primary bridge state was reset." });
  }
  requestToClientId.clear();
  relayClients.clear();
  relayRequestOrigin.clear();
}

export function resetSecondaryState(): void {
  for (const [id, resolver] of [...secondaryResponseResolvers]) {
    resolver({ id, error: "Secondary relay state was reset." });
  }
}

// ─── Low-level send ───────────────────────────────────────────────────────────
export function SendToClient(target: RobloxClient, message: string): boolean {
  if (target.transport === "ws" && target.ws && target.ws.readyState === WebSocket.OPEN) {
    target.ws.send(message);
    return true;
  } else if (target.transport === "http") {
    const pendingBytes = target.pendingHttpCommands.reduce(
      (total, command) => total + Buffer.byteLength(command, "utf8"),
      0
    );
    if (
      target.pendingHttpCommands.length >= MAX_PENDING_HTTP_COMMANDS ||
      pendingBytes + Buffer.byteLength(message, "utf8") > MAX_PENDING_HTTP_COMMAND_BYTES
    ) {
      return false;
    }
    target.pendingHttpCommands.push(message);

    const waiter = target.pendingPollResolve;
    if (waiter) {
      target.pendingPollResolve = null;
      const batch = target.pendingHttpCommands;
      target.pendingHttpCommands = [];
      waiter(batch);
    }
    return true;
  }
  return false;
}

// ─── Response waiter ──────────────────────────────────────────────────────────
export function GetResponseOfIdFromClient(
  id: string,
  timeoutMs: number = TOOL_RESPONSE_TIMEOUT
): Promise<RobloxResponse> {
  const resolverMap =
    instanceRole === "secondary" ? secondaryResponseResolvers : httpResponseResolvers;
  if (resolverMap.has(id)) {
    return Promise.resolve({ id, error: "Duplicate pending request ID." });
  }
  if (resolverMap.size >= MAX_PENDING_BRIDGE_REQUESTS) {
    return Promise.resolve({
      id,
      error: "The MCP bridge has too many pending requests; request not sent.",
    });
  }

  return new Promise((resolve) => {
    let settled = false;
    let timeout: NodeJS.Timeout;

    const resolveOnce: ResponseResolver = (data) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      resolverMap.delete(id);
      requestToClientId.delete(id);
      relayRequestOrigin.delete(id);
      resolve(data);
    };

    timeout = setTimeout(() => {
      if (
        resolverMap === secondaryResponseResolvers &&
        relaySocket &&
        relaySocket.readyState === WebSocket.OPEN
      ) {
        try {
          relaySocket.send(JSON.stringify({
            type: "cancel-relay-request",
            targetRequestId: id,
          }));
        } catch (error) {
          console.error(`[Secondary] Failed to cancel timed-out relay request ${id}:`, error);
        }
      }

      resolveOnce({
        id,
        output: undefined,
        error: `Timed out waiting for response after ${timeoutMs}ms.`,
      });
    }, timeoutMs);

    resolverMap.set(id, resolveOnce);
  });
}

export interface DispatchAndWaitResult {
  dispatch: DispatchResult;
  response?: RobloxResponse;
}

/** Register a waiter before a custom relay send and reject it if sending throws. */
export async function WaitForResponseAfterSend(
  id: string,
  send: () => void,
  timeoutMs: number = TOOL_RESPONSE_TIMEOUT
): Promise<RobloxResponse> {
  const resolverMap =
    instanceRole === "secondary" ? secondaryResponseResolvers : httpResponseResolvers;
  if (resolverMap.size >= MAX_PENDING_BRIDGE_REQUESTS) {
    return {
      id,
      error: "The MCP bridge has too many pending requests; request not sent.",
    };
  }
  const responsePromise = GetResponseOfIdFromClient(id, timeoutMs);
  try {
    send();
  } catch (error) {
    resolverMap.get(id)?.({
      id,
      error: `Failed to send request: ${error instanceof Error ? error.message : String(error)}`,
    });
  }
  return responsePromise;
}

/** Register the response waiter before sending so a fast WebSocket reply cannot be lost. */
export async function DispatchAndWaitForResponse(
  type: string,
  data: Record<string, unknown>,
  clientId?: string,
  timeoutMs: number = TOOL_RESPONSE_TIMEOUT
): Promise<DispatchAndWaitResult> {
  const resolverMap =
    instanceRole === "secondary" ? secondaryResponseResolvers : httpResponseResolvers;
  if (resolverMap.size >= MAX_PENDING_BRIDGE_REQUESTS) {
    return { dispatch: "BRIDGE_BUSY" };
  }
  const id = crypto.randomUUID();
  const responsePromise = GetResponseOfIdFromClient(id, timeoutMs);
  let dispatch: DispatchResult;
  try {
    dispatch = SendArbitraryDataToClient(type, data, id, clientId);
  } catch (error) {
    resolverMap.get(id)?.({
      id,
      error: `Failed to dispatch request: ${error instanceof Error ? error.message : String(error)}`,
    });
    await responsePromise;
    return { dispatch: null };
  }

  if (dispatch !== id) {
    resolverMap.get(id)?.({
      id,
      error: "The request could not be dispatched.",
    });
    await responsePromise;
    return { dispatch };
  }

  return { dispatch, response: await responsePromise };
}

// ─── High-level dispatch ──────────────────────────────────────────────────────
export function SendArbitraryDataToClient(
  type: string,
  data: Record<string, unknown>,
  id?: string,
  clientId?: string
): DispatchResult {
  if (instanceRole === "secondary") {
    if (!relaySocket || relaySocket.readyState !== WebSocket.OPEN) return null;
    if (secondaryResponseResolvers.size >= MAX_PENDING_BRIDGE_REQUESTS) return "BRIDGE_BUSY";
    const requestId = id ?? crypto.randomUUID();
    const message = {
      ...data,
      id: requestId,
      type,
      ...(clientId ? { targetClientId: clientId } : {}),
    };
    relaySocket.send(JSON.stringify(message));
    return requestId;
  }

  // Primary mode. An unscoped command is safe only when a client was selected
  // or exactly one client is connected. Never broadcast mutations/inspection.
  const target = resolveTargetClient(clientId);
  if (!target) {
    if (clientId !== undefined) return "INVALID_CLIENT";
    if (getActiveClients().length > 1) return "AMBIGUOUS_CLIENT";
    return null;
  }

  const requestId = id ?? crypto.randomUUID();
  if (requestToClientId.size >= MAX_PENDING_BRIDGE_REQUESTS) return "BRIDGE_BUSY";
  const message = { ...data, id: requestId, type };
  requestToClientId.set(requestId, target.clientId);
  try {
    if (!SendToClient(target, JSON.stringify(message))) {
      requestToClientId.delete(requestId);
      return "CLIENT_QUEUE_FULL";
    }
  } catch (error) {
    requestToClientId.delete(requestId);
    console.error(`[Bridge] Failed to send request ${requestId}:`, error);
    return null;
  }
  return requestId;
}

// ─── Route a response from a Roblox client ────────────────────────────────────
export function handleRobloxResponse(
  data: RobloxResponse,
  sourceClientId?: string
): boolean {
  if (!data.id) return false;

  const expectedClientId = requestToClientId.get(data.id);
  if (!expectedClientId || sourceClientId !== expectedClientId) {
    console.error(
      `[Bridge] Ignored response ${data.id} from ${sourceClientId ?? "unregistered client"}; ` +
      `expected ${expectedClientId ?? "no pending request"}.`
    );
    return false;
  }

  // Bind provenance to the authenticated transport origin. A connector cannot
  // choose or overwrite the client identity attached to its response.
  const trustedData: RobloxResponse = { ...data, clientId: expectedClientId };

  // If the request originated from a relayed secondary, forward it back.
  const originRelay = relayRequestOrigin.get(data.id);
  if (originRelay && originRelay.readyState === WebSocket.OPEN) {
    try {
      originRelay.send(JSON.stringify(trustedData));
      return true;
    } catch (error) {
      console.error(`[Bridge] Failed to forward response ${data.id} to relay:`, error);
      return false;
    } finally {
      relayRequestOrigin.delete(data.id);
      requestToClientId.delete(data.id);
    }
  }
  relayRequestOrigin.delete(data.id);

  // Otherwise it's a local primary request.
  const resolver = httpResponseResolvers.get(data.id);
  if (resolver) {
    resolver(trustedData);
  }
  requestToClientId.delete(data.id);
  return Boolean(resolver);
}
