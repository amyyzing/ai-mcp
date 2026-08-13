import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import {
  describeResponse,
  resolveToolClientId,
  type ToolRoutingContext,
} from "../../factory.js";
import { waitForEventInputSchema, waitForEventOutputSchema } from "./schemas.js";
import { sendAndWaitStructured } from "./structured.js";

export default function register(server: McpServer, routing: ToolRoutingContext): void {
  server.registerTool(
    "wait-for-event",
    {
      title: "Wait for a Roblox runtime event",
      description:
        "Wait for a matching console message, descendant, attribute change, or remote call. Remote mode starts the bundled spy automatically. Console and non-selector instance waits return a resumable journal cursor; selector, attribute, and remote waits observe from call start (or inspect current state with includeExisting). A timeout is a normal result and is bounded to 30 seconds.",
      inputSchema: waitForEventInputSchema,
      outputSchema: waitForEventOutputSchema,
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: true,
      },
    },
    async (input) => {
      const { clientId, maxOutputChars, timeoutMs, ...data } = input;
      return sendAndWaitStructured({
        type: "wait-for-event",
        data: { ...data, timeoutMs },
        clientId: resolveToolClientId(clientId, routing),
        timeoutMs: Math.min(30000, timeoutMs) + 2500,
        maxOutputChars,
        stampClient: true,
        failureMessage: (response) =>
          "Failed while waiting for event: " + describeResponse(response),
      });
    }
  );
}
