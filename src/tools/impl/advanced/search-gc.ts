import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import {
  describeResponse,
  resolveToolClientId,
  type ToolRoutingContext,
} from "../../factory.js";
import { searchGcInputSchema, searchGcOutputSchema } from "./schemas.js";
import { sendAndWaitStructured } from "./structured.js";

export default function register(server: McpServer, routing: ToolRoutingContext): void {
  server.registerTool(
    "search-gc",
    {
      title: "Search garbage-collected functions or tables",
      description:
        "Find the first garbage-collected function or table matching bounded criteria and return compact metadata rather than raw values. Output and fallback iteration are bounded, but executor-native filtergc/getgc may still allocate or traverse its internal GC snapshot; only one search runs per client at a time.",
      inputSchema: searchGcInputSchema,
      outputSchema: searchGcOutputSchema,
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    async (input) => {
      const { clientId, maxOutputChars, ...data } = input;
      return sendAndWaitStructured({
        type: "search-gc",
        data,
        clientId: resolveToolClientId(clientId, routing),
        timeoutMs: 30000,
        maxOutputChars,
        stampClient: true,
        truncationHint: "Rerun search-gc with more criteria, a lower limit, or includeValues=false.",
        failureMessage: (response) =>
          "Failed to search garbage-collected values: " + describeResponse(response),
      });
    }
  );
}
