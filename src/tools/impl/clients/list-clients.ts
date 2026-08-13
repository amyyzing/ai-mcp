import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import crypto from "crypto";
import { WebSocket } from "ws";
import { z } from "zod";
import {
  getInstanceRole,
  getRelaySocket,
  WaitForResponseAfterSend,
} from "../../../bridge/handlers/shared/communication.js";
import {
  formatActiveClientListForTool,
  getActiveClientSummaries,
  type ActiveClientSummary,
} from "../../../bridge/handlers/shared/registry.js";
import { toolTextResponse, type ToolRoutingContext } from "../../factory.js";
import { NO_CLIENT_ERROR } from "../../errors.js";

const clientSummarySchema = z.object({
  clientId: z.string(),
  username: z.string(),
  userId: z.number(),
  placeId: z.number(),
  placeName: z.string(),
  jobId: z.string(),
  transport: z.enum(["ws", "http"]),
  selected: z.boolean(),
});

export default function register(server: McpServer, routing: ToolRoutingContext): void {
  server.registerTool(
    "list-clients",
    {
      title: "List connected Roblox clients",
      description:
        "List connected Roblox game clients with clientId and session metadata. Use before set-active-client when multiple clients are connected or the target client is unknown.",
      outputSchema: z.object({
        clients: z.array(clientSummarySchema),
        selectedClientId: z.string().nullable(),
      }),
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async () => {
      if (getInstanceRole() === "secondary") {
        const id = crypto.randomUUID();
        const socket = getRelaySocket();
        if (socket && socket.readyState === WebSocket.OPEN) {
          const response = await WaitForResponseAfterSend(id, () => {
            socket.send(JSON.stringify({
              id,
              type: "list-clients",
              selectedClientId: routing.selectedClientId,
            }));
          });
          if (response?.error || !response?.output) {
            return toolTextResponse(response?.error ?? "Failed to list clients.", {}, true);
          }
          const clients = Array.isArray(response.clients)
            ? (response.clients as ActiveClientSummary[])
            : [];
          return {
            ...toolTextResponse(response.output),
            structuredContent: {
              clients,
              selectedClientId: routing.selectedClientId ?? null,
            },
          };
        }
        return NO_CLIENT_ERROR;
      }

      const selectedClientId = routing.selectedClientId ?? null;
      return {
        content: [{
          type: "text" as const,
          text: formatActiveClientListForTool(selectedClientId),
        }],
        structuredContent: {
          clients: getActiveClientSummaries(selectedClientId),
          selectedClientId,
        },
      };
    }
  );
}
