import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { describeResponse, resolveToolClientId, sendAndWait, type ToolRoutingContext } from "../../factory.js";
import { clientIdSchema } from "../../schemas.js";

export default function register(server: McpServer, routing: ToolRoutingContext): void {
  server.registerTool(
    "click-button",
    {
      title: "Click a GuiButton",
      description:
        "Click a Roblox TextButton or ImageButton by firing its GUI signals. Use when direct UI activation is needed inside the active client.",
      inputSchema: z.object({
        clientId: clientIdSchema,
        path: z.string().min(1).max(2000).describe("Strict game/workspace instance path to the Button"),
        action: z
          .enum(["Activated", "MouseButton1Down", "MouseButton2Down", "MouseButton1Click", "MouseButton2Click"])
          .describe(
            "The specific signal to fire (e.g., 'Activated', 'MouseButton1Click'). If omitted, fires all standard click signals."
          )
          .optional(),
      }),
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true,
      },
    },
    async ({ clientId, path, action }) =>
      sendAndWait({
        type: "click-button",
        data: { path, action },
        clientId: resolveToolClientId(clientId, routing),
        failureField: "error",
        failureMessage: (response) =>
          "Failed to click Button: " + describeResponse(response),
        successMessage: (response) =>
          (response.output as string | undefined) || "Successfully fired click signals on Button.",
      })
  );
}
