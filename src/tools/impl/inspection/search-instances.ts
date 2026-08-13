import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { describeResponse, resolveToolClientId, sendAndWait, type ToolRoutingContext } from "../../factory.js";
import { clientIdSchema, maxOutputCharsSchema } from "../../schemas.js";

export default function register(server: McpServer, routing: ToolRoutingContext): void {
  server.registerTool(
    "search-instances",
    {
      title: "Search for instances in the game",
      description:
        "Search Roblox instances with QueryDescendants selector syntax. Use a tight root and selector: Roblox materializes selector matches internally, only one search runs at a time, and queries matching over 1,000 instances are rejected.",
      inputSchema: z.object({
        clientId: clientIdSchema,
        selector: z
          .string()
          .min(1)
          .max(2000)
          .describe(
            "QueryDescendants selector. Supports class (Part), tag (.Tagged), name (#HumanoidRootPart), property ([CanCollide = false]), attribute ([$QuestId]), combinators (> >>), OR (,), :not(), :has(). Chain for AND, e.g. Part.Tagged[Anchored = false]."
          ),
        root: z
          .string()
          .min(1)
          .max(2000)
          .describe(
            "The root instance to search from (e.g., 'game.Workspace', 'game.ReplicatedStorage'). Defaults to 'game' if not specified."
          )
          .optional()
          .default("game"),
        limit: z
          .number()
          .int()
          .min(1)
          .max(100)
          .describe("Maximum number of results to return (default: 20, to avoid overwhelming output)")
          .optional()
          .default(20),
        maxOutputChars: maxOutputCharsSchema,
      }),
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    async ({ clientId, selector, root, limit, maxOutputChars }) =>
      sendAndWait({
        type: "search-instances",
        data: { selector, root, limit },
        clientId: resolveToolClientId(clientId, routing),
        maxOutputChars,
        stampClient: true,
        truncationHint: "Rerun search-instances with a narrower selector, tighter root, or lower limit.",
        failureMessage: (response) =>
          "Failed to search instances: " + describeResponse(response),
      })
  );
}
