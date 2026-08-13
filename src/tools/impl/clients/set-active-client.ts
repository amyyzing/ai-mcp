import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import crypto from "crypto";
import { WebSocket } from "ws";
import { z } from "zod";
import {
  getInstanceRole,
  getRelaySocket,
  WaitForResponseAfterSend,
} from "../../../bridge/handlers/shared/communication.js";
import { resolveTargetClient } from "../../../bridge/handlers/shared/registry.js";
import { toolTextResponse, type ToolRoutingContext } from "../../factory.js";
import { NO_CLIENT_ERROR } from "../../errors.js";

export default function register(server: McpServer, routing: ToolRoutingContext): void {
  server.registerTool(
    "set-active-client",
    {
      title: "Set active Roblox client",
      description:
        "Route future Roblox tool calls to the specified connected client. Use list-clients first if you need available clientIds.",
      inputSchema: z.object({
        clientId: z
          .string()
          .min(1)
          .max(160)
          .describe(
            "The client ID to set as active. Use list-clients to get available client IDs."
          ),
      }),
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async ({ clientId }) => {
      const normalizedClientId = clientId.trim();

      if (getInstanceRole() === "secondary") {
        const id = crypto.randomUUID();
        const socket = getRelaySocket();
        if (socket && socket.readyState === WebSocket.OPEN) {
          const response = await WaitForResponseAfterSend(id, () => {
            socket.send(
              JSON.stringify({
                id,
                type: "set-active-client",
                targetClientId: normalizedClientId,
              })
            );
          });
          if (response?.error || !response?.output) {
            return toolTextResponse(response?.error ?? "Failed to set active client.", {}, true);
          }
          const selectedClientId =
            typeof response.clientId === "string" ? response.clientId : normalizedClientId;
          routing.selectedClientId = selectedClientId;
          return toolTextResponse(response.output);
        }
        return NO_CLIENT_ERROR;
      }

      const target = resolveTargetClient(normalizedClientId);
      if (!target) {
        return toolTextResponse(
          `Invalid or inactive client ID: ${normalizedClientId}. Use list-clients to get active client IDs.`,
          {},
          true
        );
      }

      routing.selectedClientId = target.clientId;
      return {
        content: [
          {
            type: "text" as const,
            text:
              `Active client set to ${target.clientId} ` +
              `(${target.username} @ ${target.placeName}, ${target.transport}).`,
          },
        ],
      };
    }
  );
}
