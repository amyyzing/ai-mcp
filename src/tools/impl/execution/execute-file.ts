import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import fs from "fs";
import path from "path";
import { z } from "zod";
import { describeResponse, resolveToolClientId, sendAndWait, toolTextResponse, type ToolRoutingContext } from "../../factory.js";
import { clientIdSchema, threadContextSchema } from "../../schemas.js";

const MAX_EXECUTION_FILE_BYTES = 1_048_576;

export default function register(server: McpServer, routing: ToolRoutingContext): void {
  server.registerTool(
    "execute-file",
    {
      title: "Execute a Luau file in the Roblox Game Client",
      description:
        "Execute a bounded local .luau or .lua file in a Roblox client and wait for the top-level chunk to complete or fail.",
      inputSchema: z.object({
        clientId: clientIdSchema,
        filePath: z
          .string()
          .min(1)
          .max(32768)
          .describe("The absolute path to the .luau or .lua file to execute"),
        operationId: z
          .string()
          .min(1)
          .max(128)
          .describe("Optional caller-provided operation identity included in the connector acknowledgement.")
          .optional(),
        threadContext: threadContextSchema,
        timeout: z
          .number()
          .int()
          .min(1000)
          .max(120000)
          .describe("Milliseconds to wait for completion (default: 30000, max: 120000).")
          .optional()
          .default(30000),
      }),
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true,
      },
    },
    async ({ clientId, filePath, operationId, threadContext, timeout }) => {
      if (!path.isAbsolute(filePath)) {
        return toolTextResponse("filePath must be absolute.", {}, true);
      }
      if (![".lua", ".luau"].includes(path.extname(filePath).toLowerCase())) {
        return toolTextResponse("Only .lua and .luau files can be executed.", {}, true);
      }

      let fileInfo: fs.Stats;
      try {
        fileInfo = fs.statSync(filePath);
      } catch {
        return toolTextResponse(`File not found or unreadable: ${filePath}`, {}, true);
      }
      if (!fileInfo.isFile()) {
        return toolTextResponse(`Not a regular file: ${filePath}`, {}, true);
      }
      if (fileInfo.size > MAX_EXECUTION_FILE_BYTES) {
        return toolTextResponse(
          `File is too large (${fileInfo.size} bytes; maximum ${MAX_EXECUTION_FILE_BYTES}).`,
          {},
          true
        );
      }

      let code: string;
      try {
        code = fs.readFileSync(filePath, "utf-8");
      } catch {
        return toolTextResponse(`File could not be read: ${filePath}`, {}, true);
      }
      const actualBytes = Buffer.byteLength(code, "utf8");
      if (actualBytes > MAX_EXECUTION_FILE_BYTES) {
        return toolTextResponse(
          `File changed while being read and is now too large (${actualBytes} bytes).`,
          {},
          true
        );
      }
      console.error(`Executing file ${filePath} in thread ${threadContext}...`);

      const targetClientId = resolveToolClientId(clientId, routing);
      return sendAndWait({
        type: "execute",
        data: {
          source: `setthreadidentity(${threadContext})\n${code}`,
          ...(operationId ? { operationId } : {}),
        },
        clientId: targetClientId,
        timeoutMs: Math.min(Math.max(timeout, 1000), 120000),
        stampClient: true,
        failureMessage: (response) => {
          const detail = describeResponse(response);
          return detail.includes("Timed out waiting")
            ? `File execution acknowledgement timed out; the outcome is unknown. ${detail}`
            : `File execution failed: ${detail}`;
        },
        successMessage: (response) =>
          `File execution completed successfully: ${filePath} (thread context ${threadContext}, ` +
          `operationId=${operationId ?? response.id}, requestId=${response.id}).`,
      });
    }
  );
}
