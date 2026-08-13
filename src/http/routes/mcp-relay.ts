import type { WebSocket } from "ws";
import {
  relayClients,
  relayRequestOrigin,
  requestToClientId,
  MAX_PENDING_BRIDGE_REQUESTS,
  SendToClient,
} from "../../bridge/handlers/shared/communication.js";
import {
  describeTargetResolutionFailure,
  formatActiveClientListForTool,
  getActiveClientSummaries,
  resolveTargetClient,
} from "../../bridge/handlers/shared/registry.js";

interface RelayMessage {
  id?: string;
  type?: string;
  targetClientId?: string;
  [key: string]: unknown;
}

export function WS(ws: WebSocket): void {
  console.error(`[Primary] Relay client connected. Total: ${relayClients.size + 1}`);
  relayClients.add(ws);

  ws.on("message", (rawData) => {
    try {
      const message: RelayMessage = JSON.parse(rawData.toString());

      if (
        message.type === "cancel-relay-request" &&
        typeof message.targetRequestId === "string"
      ) {
        const targetRequestId = message.targetRequestId;
        if (relayRequestOrigin.get(targetRequestId) === ws) {
          relayRequestOrigin.delete(targetRequestId);
          requestToClientId.delete(targetRequestId);
        }
        return;
      }

      // Relay-level request handled directly by the primary.
      if (message.type === "list-clients" && message.id) {
        const selectedClientId =
          typeof message.selectedClientId === "string" ? message.selectedClientId : null;
        ws.send(
          JSON.stringify({
            id: message.id,
            output: formatActiveClientListForTool(selectedClientId),
            clients: getActiveClientSummaries(selectedClientId),
            selectedClientId,
          })
        );
        return;
      }

      if (message.type === "set-active-client" && message.id) {
        const requestedClientId =
          typeof message.targetClientId === "string" ? message.targetClientId : "";
        const target = resolveTargetClient(requestedClientId);
        if (!target) {
          ws.send(
            JSON.stringify({
              id: message.id,
              output: undefined,
              error: `Invalid or inactive client ID: ${requestedClientId}. Use list-clients to get active client IDs.`,
            })
          );
          return;
        }

        ws.send(
          JSON.stringify({
            id: message.id,
            output:
              `Active client set to ${target.clientId} ` +
              `(${target.username} @ ${target.placeName}, ${target.transport}).`,
            clientId: target.clientId,
          })
        );
        return;
      }

      if (
        typeof message.id !== "string" ||
        message.id.length === 0 ||
        message.id.length > 160
      ) {
        console.error("[Primary] Ignored relay command with a missing or invalid request ID.");
        return;
      }

      if (message.id && requestToClientId.size >= MAX_PENDING_BRIDGE_REQUESTS) {
        ws.send(JSON.stringify({
          id: message.id,
          error: "The MCP bridge has too many pending requests; request not sent.",
        }));
        return;
      }
      if (
        message.id &&
        (requestToClientId.has(message.id) || relayRequestOrigin.has(message.id))
      ) {
        ws.send(JSON.stringify({
          id: message.id,
          error: "Duplicate pending request ID; request not sent.",
        }));
        return;
      }

      if (message.id) {
        relayRequestOrigin.set(message.id, ws);
      }

      const targetClientId = message.targetClientId;
      if (targetClientId) {
        delete message.targetClientId;
      }

      const target = resolveTargetClient(targetClientId);
      if (target) {
        if (message.id) requestToClientId.set(message.id, target.clientId);
        let sent = false;
        try {
          sent = SendToClient(target, JSON.stringify(message));
        } catch (error) {
          console.error("[Primary] Failed to relay request to Roblox client:", error);
        }
        if (!sent && message.id) {
          requestToClientId.delete(message.id);
          relayRequestOrigin.delete(message.id);
          ws.send(JSON.stringify({
            id: message.id,
            error: "The Roblox client's pending command queue is full; request not sent.",
          }));
        }
      } else if (message.id) {
        relayRequestOrigin.delete(message.id);
        ws.send(
          JSON.stringify({
            id: message.id,
            output: undefined,
            error: describeTargetResolutionFailure(targetClientId),
          })
        );
      }
    } catch (e) {
      console.error("[Primary] Error parsing relay message:", e);
    }
  });

  ws.on("close", () => {
    relayClients.delete(ws);
    console.error(`[Primary] Relay client disconnected. Total: ${relayClients.size}`);
    for (const [id, origin] of relayRequestOrigin.entries()) {
      if (origin === ws) {
        relayRequestOrigin.delete(id);
        requestToClientId.delete(id);
      }
    }
  });

  ws.on("error", (err) => {
    console.error("[Primary] Relay client error:", err.message);
    relayClients.delete(ws);
  });
}
