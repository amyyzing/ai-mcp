import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import {
  describeResponse,
  resolveToolClientId,
  sendAndWait,
  type ToolRoutingContext,
} from "../../factory.js";
import { unifiedInputSchema } from "./schemas.js";

export default function register(server: McpServer, routing: ToolRoutingContext): void {
  server.registerTool(
    "input",
    {
      title: "Send bounded input to Roblox",
      description:
        "Send keyboard, text, mouse, scroll, proximity-prompt, click-detector, or touch input. Instance targets use strict parsed paths and cannot execute Luau expressions.",
      inputSchema: unifiedInputSchema,
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true,
      },
    },
    async (input) => {
      const { clientId, maxOutputChars, ...data } = input;
      return sendAndWait({
        type: "input",
        data,
        clientId: resolveToolClientId(clientId, routing),
        timeoutMs: 15000,
        maxOutputChars,
        stampClient: true,
        failureMessage: (response) =>
          "Failed to send input: " + describeResponse(response),
      });
    }
  );
}
