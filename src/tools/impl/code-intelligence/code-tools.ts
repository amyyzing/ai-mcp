import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { CODE_TOOLS } from "../../../code-intelligence/session.js";
import { runCodeAnalysis } from "../../../code-intelligence/service.js";
import { resolveTargetClient, describeTargetResolutionFailure } from "../../../bridge/handlers/shared/registry.js";
import { formatToolText, isSecondaryRelay, relayToolToApi, resolveToolClientId, toolTextResponse, type ToolRoutingContext } from "../../factory.js";
import { clientIdSchema, maxOutputCharsSchema } from "../../schemas.js";

export const codeAnalysisSchema = z.object({
  clientId: clientIdSchema,
  scriptId: z.string().min(1).max(512).describe("Exact debugId from list-scripts. Uses the current indexed source; does not execute or decompile code."),
  sourceIds: z.array(z.string().min(1).max(512)).max(2000).optional().describe("Optional bounded analysis scope: include the queried script and its dependencies. Omit to use the active source index."),
  line: z.number().int().min(0).max(1_000_000).default(0).describe("Zero-based line."),
  character: z.number().int().min(0).max(1_000_000).default(0).describe("Zero-based UTF-16 character offset."),
  requireFresh: z.boolean().default(true).describe("Reject answers superseded by newly collected inputs while analysis ran."),
  refreshHierarchy: z.boolean().default(true).describe("Refresh a bounded Dex hierarchy observation. False reuses the timestamped previous observation."),
  limit: z.number().int().min(1).max(100).default(50),
  maxOutputChars: maxOutputCharsSchema,
}).strict();

export default function register(server: McpServer, routing: ToolRoutingContext): void {
  const descriptions = {
    "code-check": "Check indexed Luau syntax/types with the headless language server. Diagnostics respect source checking pragmas and observed hierarchy coverage; a clean result does not prove runtime correctness.",
    "code-definition": "Find the definition at a source position, with source-store script IDs on resolved locations.",
    "code-references": "Find LSP references at a source position. Limited to supplied sources; upstream reference support for returned primitive values is incomplete.",
    "code-type-at": "Read the inferred type/hover at a source position. Inferred types are not observed runtime values.",
    "code-symbols": "List symbols in one indexed source document without executing it.",
  };
  for (const name of CODE_TOOLS) server.registerTool(name, {
    title: name, description: descriptions[name], inputSchema: codeAnalysisSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  }, async ({ clientId, maxOutputChars, ...options }) => {
    const selected = resolveToolClientId(clientId, routing);
    if (isSecondaryRelay()) return relayToolToApi(name, { ...options, clientId: selected, maxOutputChars }, 60000);
    const target = resolveTargetClient(selected);
    if (!target) return toolTextResponse(describeTargetResolutionFailure(selected), {}, true);
    try {
      const result = await runCodeAnalysis(name, target, options);
      return { content: [{ type: "text" as const, text: formatToolText(JSON.stringify(result), { maxOutputChars }) }], structuredContent: result, ...(!result.ok ? { isError: true } : {}) };
    } catch (error) { return toolTextResponse((error as Error).message, {}, true); }
  });
}
