import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import {
  getActiveClients,
  resolveTargetClient,
} from "../../../bridge/handlers/shared/registry.js";
import {
  getScriptSourceIndex,
  type ScriptSourceIndex,
  type StoredScriptSource,
} from "../../../bridge/handlers/shared/script-source-store.js";
import {
  AMBIGUOUS_CLIENT_ERROR,
  INVALID_CLIENT_ERROR,
  NO_CLIENT_ERROR,
} from "../../errors.js";
import {
  clientStampPrefix,
  formatToolText,
  isSecondaryRelay,
  relayToolToApi,
  resolveToolClientId,
  type ToolRoutingContext,
} from "../../factory.js";
import { clientIdSchema, maxOutputCharsSchema } from "../../schemas.js";

export const listScriptsInputSchema = z.object({
  clientId: clientIdSchema,
  filter: z
    .string()
    .max(500)
    .optional()
    .describe("Case-insensitive substring matched against path, derived name, debug ID, and script hash."),
  pathPrefix: z.string().max(1000).optional(),
  namePrefix: z.string().max(300).optional(),
  cursor: z.number().int().min(0).optional().describe("Offset cursor returned by a previous page."),
  offset: z.number().int().min(0).max(1_000_000).optional(),
  limit: z.number().int().min(1).max(100).optional().default(25),
  includeSourcePreview: z.boolean().optional().default(false),
  sourcePreviewChars: z.number().int().min(100).max(1000).optional().default(300),
  maxOutputChars: maxOutputCharsSchema,
}).refine((input) => input.cursor === undefined || input.offset === undefined, {
  message: "Use cursor or offset, not both.",
});

export const listScriptsOutputSchema = z.object({
  sync: z.object({
    hasFinishedMapping: z.boolean(),
    sourceIndexComplete: z.boolean(),
    mappedSources: z.number(),
    processedSources: z.number(),
    skippedSources: z.number(),
    sourcesToMap: z.number(),
    sourceGap: z.number(),
    mappingSessionId: z.string().optional(),
    mappingRevision: z.number().optional(),
  }),
  totalMatched: z.number(),
  offset: z.number(),
  nextCursor: z.number().optional(),
  scripts: z.array(z.object({
    debugId: z.string(),
    path: z.string(),
    name: z.string(),
    scriptHash: z.string().optional(),
    sourceHash: z.string(),
    sourceChars: z.number(),
    lineCount: z.number(),
    updatedAt: z.string(),
    sourcePreview: z.string().optional(),
  })),
});

export interface ListScriptsOptions {
  filter?: string;
  pathPrefix?: string;
  namePrefix?: string;
  cursor?: number;
  offset?: number;
  limit: number;
  includeSourcePreview: boolean;
  sourcePreviewChars: number;
}

function derivedName(path: string): string {
  const bracket = path.match(/\["((?:\\.|[^"\\])*)"\]$/);
  if (bracket?.[1] !== undefined) {
    try {
      return JSON.parse(`"${bracket[1]}"`) as string;
    } catch {
      return bracket[1];
    }
  }
  const dot = path.lastIndexOf(".");
  return dot >= 0 ? path.slice(dot + 1) : path;
}

function includesIgnoreCase(value: string | undefined, query: string | undefined): boolean {
  if (!query) return true;
  return (value ?? "").toLocaleLowerCase().includes(query.toLocaleLowerCase());
}

function startsWithIgnoreCase(value: string, prefix: string | undefined): boolean {
  if (!prefix) return true;
  return value.toLocaleLowerCase().startsWith(prefix.toLocaleLowerCase());
}

function countLines(source: string): number {
  let lines = 1;
  for (let index = source.indexOf("\n"); index !== -1; index = source.indexOf("\n", index + 1)) {
    lines += 1;
  }
  return lines;
}

export function buildListScriptsResult(index: ScriptSourceIndex, options: ListScriptsOptions) {
  const matching = index.scripts
    .map((script) => ({ script, name: derivedName(script.path) }))
    .filter(({ script, name }) => {
      if (!startsWithIgnoreCase(script.path, options.pathPrefix)) return false;
      if (!startsWithIgnoreCase(name, options.namePrefix)) return false;
      if (!options.filter) return true;
      return [script.path, name, script.debugId, script.scriptHash]
        .some((value) => includesIgnoreCase(value, options.filter));
    })
    .sort((left, right) =>
      left.script.path.localeCompare(right.script.path) ||
      left.script.debugId.localeCompare(right.script.debugId)
    );

  const offset = Math.max(0, Math.floor(options.cursor ?? options.offset ?? 0));
  const limit = Math.max(1, Math.min(100, Math.floor(options.limit)));
  const selected = matching.slice(offset, offset + limit);
  const scripts = selected.map(({ script, name }) => {
    const metadata = {
      debugId: script.debugId,
      path: script.path,
      name,
      scriptHash: script.scriptHash,
      sourceHash: script.sourceHash,
      sourceChars: script.source.length,
      lineCount: countLines(script.source),
      updatedAt: new Date(script.updatedAt).toISOString(),
      sourcePreview: options.includeSourcePreview
        ? script.source.slice(0, options.sourcePreviewChars)
        : undefined,
    };
    return metadata;
  });

  return {
    sync: {
      hasFinishedMapping: index.hasFinishedMapping,
      sourceIndexComplete: index.sourceIndexComplete,
      mappedSources: index.mappedSources,
      processedSources: index.processedSources,
      skippedSources: index.skippedSources,
      sourcesToMap: index.sourcesToMap,
      sourceGap: index.sourceGap,
      mappingSessionId: index.mappingSessionId,
      mappingRevision: index.mappingRevision,
    },
    totalMatched: matching.length,
    offset,
    nextCursor: offset + scripts.length < matching.length ? offset + scripts.length : undefined,
    scripts,
  };
}

function toolError(text: string) {
  return { content: [{ type: "text" as const, text }], isError: true as const };
}

export default function register(server: McpServer, routing: ToolRoutingContext): void {
  server.registerTool(
    "list-scripts",
    {
      title: "List indexed Roblox scripts",
      description:
        "Page through compact server-side script metadata without returning source. Filter by path/name and use the returned cursor for stable, bounded exploration. Mapping completeness and revision are included.",
      inputSchema: listScriptsInputSchema,
      outputSchema: listScriptsOutputSchema,
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    async ({ clientId, maxOutputChars, ...options }) => {
      const targetClientId = resolveToolClientId(clientId, routing);
      if (isSecondaryRelay()) {
        return relayToolToApi("list-scripts", {
          ...options,
          clientId: targetClientId,
          maxOutputChars,
        });
      }

      const target = resolveTargetClient(targetClientId);
      if (!target) {
        if (targetClientId) return INVALID_CLIENT_ERROR;
        if (getActiveClients().length > 1) return AMBIGUOUS_CLIENT_ERROR;
        return NO_CLIENT_ERROR;
      }
      const index = getScriptSourceIndex({
        clientId: target.clientId,
        placeId: target.placeId,
        jobId: target.jobId,
      });
      if (index.scripts.length === 0 && !index.hasFinishedMapping) {
        return toolError(
          "No indexed script metadata is available. Indexing may be disabled; call script-index-status, then script-index-start if needed."
        );
      }

      const result = buildListScriptsResult(index, options);
      const prefix = clientStampPrefix(target.clientId);
      return {
        content: [{
          type: "text" as const,
          text: formatToolText(prefix + JSON.stringify(result, null, 2), {
            maxOutputChars,
            truncationHint: "Use nextCursor, a lower limit, or a narrower filter to page list-scripts.",
          }),
        }],
        structuredContent: result,
      };
    }
  );
}
