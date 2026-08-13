import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { describeResponse, resolveToolClientId, sendAndWait, type ToolRoutingContext } from "../../factory.js";
import { clientIdSchema, maxOutputCharsSchema } from "../../schemas.js";

export default function register(server: McpServer, routing: ToolRoutingContext): void {
  server.registerTool(
    "get-descendants-tree",
    {
      title: "Get the descendants tree of a Roblox instance",
      description:
        "Explore the structure under a Roblox instance. Defaults to a compact summary (child/class counts); set summaryOnly=false for the full tree. Use search-instances for selector-based filtering.",
      inputSchema: z.object({
        clientId: clientIdSchema,
        root: z
          .string()
          .min(1)
          .max(2000)
          .describe(
            "The instance path to get the tree from (e.g., 'game.Workspace', 'game.Workspace.CurrentRooms')"
          ),
        maxDepth: z
          .number()
          .int()
          .min(0)
          .max(5)
          .describe(
            "Maximum depth to traverse (default: 2, max: 5). Higher values return more detail but larger output."
          )
          .optional()
          .default(2),
        classFilter: z
          .string()
          .max(200)
          .describe(
            "Optional class name filter — only show instances that IsA this class (e.g., 'BasePart', 'Model'). Leave empty to show all."
          )
          .optional(),
        maxChildren: z
          .number()
          .int()
          .min(1)
          .max(30)
          .describe(
            "Maximum number of children to show per node (default: 20, max: 30). Prevents overwhelming output for large containers."
          )
          .optional()
          .default(20),
        summaryOnly: z
          .boolean()
          .describe("When true (default), return compact child counts and class counts instead of the full tree. Set false only when you need the actual hierarchy.")
          .optional()
          .default(true),
        maxOutputChars: maxOutputCharsSchema,
      }),
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    async ({ clientId, root, maxDepth, classFilter, maxChildren, summaryOnly, maxOutputChars }) =>
      sendAndWait({
        type: "get-descendants-tree",
        data: { root, maxDepth, classFilter: classFilter || "", maxChildren, summaryOnly },
        clientId: resolveToolClientId(clientId, routing),
        maxOutputChars,
        stampClient: true,
        truncationHint: "Rerun get-descendants-tree with summaryOnly=true, lower maxDepth, lower maxChildren, or a classFilter.",
        failureMessage: (response) =>
          "Failed to get descendants tree: " + describeResponse(response),
      })
  );
}
