import { randomUUID } from "node:crypto";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

import type { ScriptSourceIndex } from "../../../bridge/handlers/shared/script-source-store.js";
import { getScriptSourceIndex } from "../../../bridge/handlers/shared/script-source-store.js";
import {
  describeTargetResolutionFailure,
  resolveTargetClient,
} from "../../../bridge/handlers/shared/registry.js";
import {
  requestLuraphDevirtualization,
  type LuraphCaptureMode,
} from "../../../luraph/client.js";
import {
  clientStampPrefix,
  isSecondaryRelay,
  relayToolToApi,
  resolveToolClientId,
  toolTextResponse,
  type ToolRoutingContext,
  type ToolTextResponse,
} from "../../factory.js";
import { clientIdSchema, maxOutputCharsSchema } from "../../schemas.js";

const DEFAULT_TIMEOUT_SECONDS = 180;
const DEFAULT_PREVIEW_LINES = 120;
const MAX_READ_LINES = 2000;
const RESULT_TTL_MS = 10 * 60 * 1000;
const MAX_CACHED_RESULTS = 12;
const MAX_CACHED_SOURCE_CHARS = 8 * 1024 * 1024;
const MAX_WORKER_RESULT_CHARS = 1024 * 1024;
export const MAX_DIRECT_LURAPH_SOURCE_BYTES = 4 * 1024 * 1024;

const commonSchema = {
  clientId: clientIdSchema,
  maxOutputChars: maxOutputCharsSchema,
};

const runSchema = {
  captureMode: z.enum(["strict", "sandboxed"]).optional().default("strict").describe(
    "strict never runs the staged bootstrap and may stop at an intermediate tree; sandboxed permits the devirtualizer's bounded bootstrap decoder but never invokes the final payload."
  ),
  timeoutSeconds: z.number().int().min(30).max(600).optional().default(DEFAULT_TIMEOUT_SECONDS),
  previewLines: z.number().int().min(1).max(500).optional().default(DEFAULT_PREVIEW_LINES),
};

const directSourceSchema = z.string().min(1).superRefine((source, context) => {
  if (Buffer.byteLength(source, "utf8") > MAX_DIRECT_LURAPH_SOURCE_BYTES) {
    context.addIssue({
      code: "custom",
      message: `Raw source exceeds the ${MAX_DIRECT_LURAPH_SOURCE_BYTES}-byte limit.`,
    });
  }
});

export const devirtualizeLuraphInputSchema = z.discriminatedUnion("operation", [
  z.object({
    operation: z.literal("run"),
    ...commonSchema,
    scriptPath: z.string().min(1).max(2000).describe(
      "Exact indexed script path, or a literal <ScriptProxy: debug-id> returned by list-scripts."
    ),
    ...runSchema,
  }),
  z.object({
    operation: z.literal("run-source"),
    ...commonSchema,
    source: directSourceSchema.describe(
      "Raw Luraph-protected Lua or Luau source. This operation does not require a connected Roblox client or script index."
    ),
    sourceName: z.string().trim().min(1).max(200)
      .regex(/^[^\u0000-\u001f\u007f]+$/, "sourceName cannot contain control characters.")
      .optional()
      .default("raw-source.luau"),
    ...runSchema,
  }),
  z.object({
    operation: z.literal("read"),
    ...commonSchema,
    resultId: z.string().uuid(),
    startLine: z.number().int().min(1).optional().default(1),
    maxLines: z.number().int().min(1).max(MAX_READ_LINES).optional().default(200),
  }),
  z.object({
    operation: z.literal("release"),
    ...commonSchema,
    resultId: z.string().uuid(),
  }),
]);

export interface LuraphExecutionResult {
  ok: boolean;
  text: string;
  structured?: Record<string, unknown>;
}

interface CachedResult {
  id: string;
  clientId?: string;
  sourceKind: "indexed" | "raw";
  scriptPath: string;
  outputFile: string;
  source: string;
  sourceTruncated: boolean;
  createdAt: number;
  expiresAt: number;
}

const cachedResults = new Map<string, CachedResult>();

function cleanupCachedResults(now = Date.now()): void {
  for (const [id, result] of cachedResults) {
    if (result.expiresAt <= now) cachedResults.delete(id);
  }
  let retainedChars = [...cachedResults.values()]
    .reduce((total, result) => total + result.source.length, 0);
  while (
    cachedResults.size > MAX_CACHED_RESULTS ||
    retainedChars > MAX_CACHED_SOURCE_CHARS
  ) {
    const oldest = cachedResults.entries().next().value as
      | [string, CachedResult]
      | undefined;
    if (!oldest) break;
    cachedResults.delete(oldest[0]);
    retainedChars -= oldest[1].source.length;
  }
}

export function retainLuraphResult(input: Omit<CachedResult, "id" | "createdAt" | "expiresAt">): string {
  cleanupCachedResults();
  const id = randomUUID();
  const now = Date.now();
  cachedResults.set(id, {
    ...input,
    id,
    createdAt: now,
    expiresAt: now + RESULT_TTL_MS,
  });
  cleanupCachedResults(now);
  return id;
}

function countLines(source: string): number {
  if (!source) return 0;
  let lines = 1;
  for (let index = source.indexOf("\n"); index !== -1; index = source.indexOf("\n", index + 1)) {
    lines += 1;
  }
  return lines;
}

export function formatLuraphResultRange(source: string, startLine: number, maxLines: number): {
  text: string;
  startLine: number;
  endLine: number;
  totalLines: number;
  nextStartLine?: number;
} {
  const lines = source.split(/\r?\n/);
  const totalLines = source ? lines.length : 0;
  const start = Math.max(1, Math.min(Math.floor(startLine), Math.max(1, totalLines)));
  const limit = Math.max(1, Math.min(MAX_READ_LINES, Math.floor(maxLines)));
  const end = Math.min(totalLines, start + limit - 1);
  return {
    text: `-- Lines ${start}-${end} of ${totalLines}\n${lines.slice(start - 1, end).join("\n")}`,
    startLine: start,
    endLine: end,
    totalLines,
    ...(end < totalLines ? { nextStartLine: end + 1 } : {}),
  };
}

export function readCachedLuraphResult(input: {
  clientId?: string;
  resultId: string;
  startLine: number;
  maxLines: number;
}): LuraphExecutionResult {
  cleanupCachedResults();
  const result = cachedResults.get(input.resultId);
  if (
    !result ||
    (result.sourceKind === "indexed" && result.clientId !== input.clientId)
  ) {
    return { ok: false, text: "Luraph result was not found, expired, or belongs to another client." };
  }
  result.expiresAt = Date.now() + RESULT_TTL_MS;
  const page = formatLuraphResultRange(result.source, input.startLine, input.maxLines);
  const { text: pageText, ...pageMetadata } = page;
  const text = [
    `Luraph result ${result.id} (${result.outputFile})`,
    page.nextStartLine
      ? `Continue with operation=read, resultId=${result.id}, startLine=${page.nextStartLine}.`
      : "End of recovered source.",
    pageText,
  ].join("\n");
  return {
    ok: true,
    text,
    structured: {
      resultId: result.id,
      sourceKind: result.sourceKind,
      scriptPath: result.scriptPath,
      outputFile: result.outputFile,
      sourceTruncated: result.sourceTruncated,
      ...pageMetadata,
    },
  };
}

export function releaseCachedLuraphResult(clientId: string | undefined, resultId: string): LuraphExecutionResult {
  cleanupCachedResults();
  const result = cachedResults.get(resultId);
  if (!result || (result.sourceKind === "indexed" && result.clientId !== clientId)) {
    return { ok: false, text: "Luraph result was not found, expired, or belongs to another client." };
  }
  cachedResults.delete(resultId);
  return { ok: true, text: `Released cached Luraph result ${resultId}.` };
}

export function findLuraphScript(index: ScriptSourceIndex, scriptPath: string) {
  const proxy = scriptPath.match(/^<ScriptProxy: (.+)>$/);
  return index.scripts.find((script) =>
    proxy ? script.debugId === proxy[1] : script.path === scriptPath
  );
}

function qualityLine(quality: Record<string, unknown> | undefined): string {
  if (!quality || Object.keys(quality).length === 0) return "Quality metrics: unavailable";
  return "Quality metrics: " + Object.entries(quality)
    .map(([key, value]) => `${key}=${String(value)}`)
    .join(", ");
}

async function devirtualizeLuraphSource(options: {
  clientId?: string;
  sourceKind: "indexed" | "raw";
  sourceLabel: string;
  debugId?: string;
  source: string;
  captureMode: LuraphCaptureMode;
  timeoutSeconds: number;
  previewLines: number;
}): Promise<LuraphExecutionResult> {
  try {
    const result = await requestLuraphDevirtualization({
      source: options.source,
      captureMode: options.captureMode,
      timeoutSeconds: options.timeoutSeconds,
      maxResultChars: MAX_WORKER_RESULT_CHARS,
    });
    const resultId = retainLuraphResult({
      clientId: options.clientId,
      sourceKind: options.sourceKind,
      scriptPath: options.sourceLabel,
      outputFile: result.outputFile!,
      source: result.source!,
      sourceTruncated: result.sourceTruncated === true,
    });
    const preview = formatLuraphResultRange(result.source!, 1, options.previewLines);
    const quality = result.quality && typeof result.quality === "object" && !Array.isArray(result.quality)
      ? result.quality
      : {};
    const structured = {
      resultId,
      sourceKind: options.sourceKind,
      scriptPath: options.sourceLabel,
      ...(options.debugId ? { debugId: options.debugId } : {}),
      captureMode: options.captureMode,
      outputFile: result.outputFile,
      sourceChars: result.sourceChars ?? result.source!.length,
      sourceLines: countLines(result.source!),
      sourceTruncated: result.sourceTruncated === true,
      quality,
      durationMs: result.durationMs,
      nextStartLine: preview.nextStartLine,
    };
    const text = [
      `Luraph devirtualization completed for ${options.sourceLabel}.`,
      `Source kind: ${options.sourceKind}.`,
      `Result ID: ${resultId} (cached for 10 minutes; use operation=read to page it).`,
      `Recovered artifact: ${result.outputFile}`,
      `Capture mode: ${options.captureMode}`,
      qualityLine(quality),
      result.sourceTruncated
        ? `The worker limited this artifact to ${MAX_WORKER_RESULT_CHARS} characters.`
        : "",
      preview.nextStartLine
        ? `Continue with operation=read, resultId=${resultId}, startLine=${preview.nextStartLine}.`
        : "",
      "--- Recovered source preview ---",
      preview.text,
    ].filter(Boolean).join("\n");
    return { ok: true, text, structured };
  } catch (error) {
    return {
      ok: false,
      text: `Luraph devirtualization failed: ${error instanceof Error ? error.message : String(error)}`,
    };
  }
}

export async function devirtualizeRawLuraphSource(options: {
  source: string;
  sourceName: string;
  captureMode: LuraphCaptureMode;
  timeoutSeconds: number;
  previewLines: number;
}): Promise<LuraphExecutionResult> {
  const sourceBytes = Buffer.byteLength(options.source, "utf8");
  if (sourceBytes === 0) {
    return { ok: false, text: "Raw Luraph source is empty." };
  }
  if (sourceBytes > MAX_DIRECT_LURAPH_SOURCE_BYTES) {
    return {
      ok: false,
      text: `Raw source exceeds the ${MAX_DIRECT_LURAPH_SOURCE_BYTES}-byte limit.`,
    };
  }
  return devirtualizeLuraphSource({
    sourceKind: "raw",
    sourceLabel: options.sourceName,
    source: options.source,
    captureMode: options.captureMode,
    timeoutSeconds: options.timeoutSeconds,
    previewLines: options.previewLines,
  });
}

export async function devirtualizeIndexedLuraphScript(options: {
  clientId: string;
  placeId: number;
  jobId: string;
  scriptPath: string;
  captureMode: LuraphCaptureMode;
  timeoutSeconds: number;
  previewLines: number;
}): Promise<LuraphExecutionResult> {
  const index = getScriptSourceIndex({
    clientId: options.clientId,
    placeId: options.placeId,
    jobId: options.jobId,
  });
  if (index.scripts.length === 0) {
    return {
      ok: false,
      text: "No indexed script sources are available. Call script-index-status, then script-index-start if needed.",
    };
  }
  const script = findLuraphScript(index, options.scriptPath);
  if (!script) {
    return {
      ok: false,
      text: "The requested script is not in the current source index. Use list-scripts to obtain its exact path or ScriptProxy debug ID.",
    };
  }

  return devirtualizeLuraphSource({
    clientId: options.clientId,
    sourceKind: "indexed",
    sourceLabel: script.path || `<ScriptProxy: ${script.debugId}>`,
    debugId: script.debugId,
    source: script.source,
    captureMode: options.captureMode,
    timeoutSeconds: options.timeoutSeconds,
    previewLines: options.previewLines,
  });
}

export default function register(server: McpServer, routing: ToolRoutingContext): void {
  server.registerTool(
    "devirtualize-luraph",
    {
      title: "Devirtualize and page Luraph-protected source",
      description:
        "Run an indexed Roblox script (operation=run) or directly supplied raw source without a connected Roblox client (operation=run-source) through the configured private Railway Luraph worker, then page or release the cached result. The worker uses the pinned luau-vmp-deobf engine with lua.expert uploads disabled. Start with strict capture; use sandboxed only if strict capture stops before the protected application tree.",
      inputSchema: devirtualizeLuraphInputSchema,
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: true,
      },
    },
    async (input) => {
      const targetClientId = resolveToolClientId(input.clientId, routing);
      if (isSecondaryRelay()) {
        const timeout = input.operation === "run" || input.operation === "run-source"
          ? input.timeoutSeconds
          : 30;
        return relayToolToApi(
          "devirtualize-luraph",
          { ...input, ...(targetClientId ? { clientId: targetClientId } : {}) },
          (timeout + 45) * 1000,
          {
            maxOutputChars: input.maxOutputChars,
            truncationHint: "Use operation=read with the returned nextStartLine to page the recovered source.",
          }
        );
      }

      let target: ReturnType<typeof resolveTargetClient> | undefined;
      let result: LuraphExecutionResult;
      if (input.operation === "run-source") {
        result = await devirtualizeRawLuraphSource({
          source: input.source,
          sourceName: input.sourceName,
          captureMode: input.captureMode,
          timeoutSeconds: input.timeoutSeconds,
          previewLines: input.previewLines,
        });
      } else if (input.operation === "run") {
        target = resolveTargetClient(targetClientId);
        if (!target) {
          return toolTextResponse(describeTargetResolutionFailure(targetClientId), {}, true);
        }
        result = await devirtualizeIndexedLuraphScript({
          clientId: target.clientId,
          placeId: target.placeId,
          jobId: target.jobId,
          scriptPath: input.scriptPath,
          captureMode: input.captureMode,
          timeoutSeconds: input.timeoutSeconds,
          previewLines: input.previewLines,
        });
      } else {
        result = input.operation === "read"
          ? readCachedLuraphResult({
              resultId: input.resultId,
              startLine: input.startLine,
              maxLines: input.maxLines,
            })
          : releaseCachedLuraphResult(undefined, input.resultId);
        if (!result.ok) {
          target = resolveTargetClient(targetClientId);
          if (target) {
            result = input.operation === "read"
              ? readCachedLuraphResult({
                  clientId: target.clientId,
                  resultId: input.resultId,
                  startLine: input.startLine,
                  maxLines: input.maxLines,
                })
              : releaseCachedLuraphResult(target.clientId, input.resultId);
          }
        }
      }
      const response: ToolTextResponse = toolTextResponse(
        result.ok && target ? clientStampPrefix(target.clientId) + result.text : result.text,
        {
          maxOutputChars: input.maxOutputChars,
          truncationHint: "Use operation=read with the returned nextStartLine to page the recovered source.",
        },
        !result.ok
      );
      return result.structured
        ? { ...response, structuredContent: result.structured }
        : response;
    }
  );
}
