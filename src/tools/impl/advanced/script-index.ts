import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import {
  describeResponse,
  resolveToolClientId,
  type ToolRoutingContext,
} from "../../factory.js";
import { clientIdSchema } from "../../schemas.js";
import {
  scriptIndexResyncInputSchema,
  scriptIndexStatusOutputSchema,
} from "./schemas.js";
import { sendAndWaitStructured } from "./structured.js";

const readAnnotations = {
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: true,
} as const;

const startAnnotations = {
  readOnlyHint: false,
  destructiveHint: true,
  idempotentHint: true,
  openWorldHint: true,
} as const;

const stopAnnotations = {
  readOnlyHint: false,
  destructiveHint: true,
  idempotentHint: true,
  openWorldHint: true,
} as const;

const clientSelectionSchema = z.object({ clientId: clientIdSchema });

export default function register(server: McpServer, routing: ToolRoutingContext): void {
  server.registerTool(
    "script-index-status",
    {
      title: "Get connector script-index status",
      description:
        "Return live connector scan, worker, upload, job-state, and completion counters for the selected Roblox client.",
      inputSchema: clientSelectionSchema,
      outputSchema: scriptIndexStatusOutputSchema,
      annotations: readAnnotations,
    },
    async ({ clientId }) =>
      sendAndWaitStructured({
        type: "script-index-status",
        data: {},
        clientId: resolveToolClientId(clientId, routing),
        stampClient: true,
        failureMessage: (response) =>
          "Failed to read script-index status: " + describeResponse(response),
      })
  );

  server.registerTool(
    "script-index-start",
    {
      title: "Start connector script indexing",
      description:
        "Start script indexing when it is disabled or stopped. If remote decompilers were explicitly enabled, this may send script bytecode to them. If indexing is already active, this is a no-op; use script-index-resync for a clean rebuild.",
      inputSchema: clientSelectionSchema,
      outputSchema: scriptIndexStatusOutputSchema,
      annotations: startAnnotations,
    },
    async ({ clientId }) =>
      sendAndWaitStructured({
        type: "script-index-start",
        data: {},
        clientId: resolveToolClientId(clientId, routing),
        stampClient: true,
        failureMessage: (response) =>
          "Failed to start script indexing: " + describeResponse(response),
      })
  );

  server.registerTool(
    "script-index-stop",
    {
      title: "Stop connector script indexing",
      description:
        "Stop current script mapping work, remove its descendant watcher, clear pending mapping/upload queues, and publish a disabled empty index state.",
      inputSchema: clientSelectionSchema,
      outputSchema: scriptIndexStatusOutputSchema,
      annotations: stopAnnotations,
    },
    async ({ clientId }) =>
      sendAndWaitStructured({
        type: "script-index-stop",
        data: {},
        clientId: resolveToolClientId(clientId, routing),
        stampClient: true,
        failureMessage: (response) =>
          "Failed to stop script indexing: " + describeResponse(response),
      })
  );

  server.registerTool(
    "script-index-resync",
    {
      title: "Rebuild the connector script index",
      description:
        "Invalidate current mapping work and active source state, then perform a fresh full script scan. This can be expensive in large games and may send bytecode to any remote decompiler the user explicitly enabled.",
      inputSchema: scriptIndexResyncInputSchema,
      outputSchema: scriptIndexStatusOutputSchema,
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true,
      },
    },
    async ({ clientId }) =>
      sendAndWaitStructured({
        type: "script-index-resync",
        data: {},
        clientId: resolveToolClientId(clientId, routing),
        stampClient: true,
        failureMessage: (response) =>
          "Failed to resync script index: " + describeResponse(response),
      })
  );
}
