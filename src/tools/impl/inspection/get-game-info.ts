import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { resolveToolClientId, sendAndWait, type ToolRoutingContext } from "../../factory.js";
import { clientIdSchema, maxOutputCharsSchema } from "../../schemas.js";

export default function register(server: McpServer, routing: ToolRoutingContext): void {
  server.registerTool(
    "get-game-info",
    {
      title: "Get information about the current Roblox game",
      description:
        "Get current Roblox place and universe metadata such as PlaceId, GameId, and PlaceVersion.",
      inputSchema: z.object({
        clientId: clientIdSchema,
        includeDescription: z
          .boolean()
          .describe("When true, include the (potentially long) place description text. Off by default to keep output small.")
          .optional()
          .default(false),
        maxOutputChars: maxOutputCharsSchema,
      }),
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    async ({ clientId, includeDescription, maxOutputChars }) =>
      sendAndWait({
        type: "get-game-info",
        data: { includeDescription },
        clientId: resolveToolClientId(clientId, routing),
        maxOutputChars,
        stampClient: true,
        failureMessage: () => "Failed to get game info.",
      })
  );
}
