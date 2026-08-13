import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import {
  describeResponse,
  resolveToolClientId,
  type ToolRoutingContext,
} from "../../factory.js";
import { inspectInstanceInputSchema, inspectInstanceOutputSchema } from "./schemas.js";
import { sendAndWaitStructured } from "./structured.js";

export default function register(server: McpServer, routing: ToolRoutingContext): void {
  server.registerTool(
    "inspect-instance",
    {
      title: "Inspect one Roblox instance",
      description:
        "Read a known instance's stable path, debug ID, selected properties, attributes, tags, bounds, and bounded child summary. Paths are parsed as data and never evaluated as Luau.",
      inputSchema: inspectInstanceInputSchema,
      outputSchema: inspectInstanceOutputSchema,
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    async ({ clientId, target, maxOutputChars, ...options }) =>
      sendAndWaitStructured({
        type: "inspect-instance",
        data: { target, ...options },
        clientId: resolveToolClientId(clientId, routing),
        maxOutputChars,
        stampClient: true,
        truncationHint:
          "Rerun inspect-instance with fewer properties, includeChildren=false, or a lower childLimit.",
        failureMessage: (response) =>
          "Failed to inspect instance: " + describeResponse(response),
      })
  );
}
