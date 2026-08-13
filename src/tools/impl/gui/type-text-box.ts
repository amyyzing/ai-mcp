import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { describeResponse, resolveToolClientId, sendAndWait, type ToolRoutingContext } from "../../factory.js";
import { clientIdSchema } from "../../schemas.js";

export default function register(server: McpServer, routing: ToolRoutingContext): void {
  server.registerTool(
    "type-text-box",
    {
      title: "Type into a TextBox",
      description:
        "Enter text into a Roblox TextBox by path. Can simulate keystrokes or set Text directly based on useKeyPress.",
      inputSchema: z.object({
        clientId: clientIdSchema,
        path: z.string().min(1).max(2000).describe("Strict game/workspace instance path to the TextBox"),
        text: z.string().max(2000).describe("The string to type into the TextBox"),
        enter: z
          .boolean()
          .describe("Whether to press Enter after typing")
          .optional()
          .default(false),
        useKeyPress: z
          .boolean()
          .describe(
            "If true, simulates real keystrokes using VirtualInputManager / keypress. If false, directly sets the Text property."
          )
          .optional()
          .default(true),
      }),
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true,
      },
    },
    async ({ clientId, path, text, enter, useKeyPress }) =>
      sendAndWait({
        type: "type-text-box",
        data: { path, text, string: text, enter, useKeyPress },
        clientId: resolveToolClientId(clientId, routing),
        failureField: "error",
        failureMessage: (response) =>
          "Failed to type into TextBox: " + describeResponse(response),
        successMessage: (response) =>
          (response.output as string | undefined) || "Successfully typed into TextBox.",
      })
  );
}
