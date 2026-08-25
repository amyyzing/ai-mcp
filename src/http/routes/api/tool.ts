import type { IncomingMessage, ServerResponse } from "http";
import {
  DispatchAndWaitForResponse,
} from "../../../bridge/handlers/shared/communication.js";
import type { RobloxResponse } from "../../../bridge/types.js";
import {
  describeTargetResolutionFailure,
  getActiveClients,
  resolveTargetClient,
} from "../../../bridge/handlers/shared/registry.js";
import {
  getScriptSourceIndex,
} from "../../../bridge/handlers/shared/script-source-store.js";
import {
  loadSemanticSettings,
  validateSemanticSettings,
  validateSemanticUploadConfirmation,
} from "../../../semantic/settings.js";
import {
  semanticIndexReadyMessage,
  semanticPartialIndexWarning,
} from "../../../semantic/index-status.js";
import { semanticIndexCodebase, semanticSearchScripts } from "../../../semantic/vector-index.js";
import {
  completeProgressJob,
  createProgressJob,
  failProgressJob,
  updateProgressJob,
} from "../../../semantic/progress.js";
import { readJsonBody } from "../../body.js";
import { formatToolText } from "../../../tools/factory.js";
import { buildListScriptsResult } from "../../../tools/impl/advanced/list-scripts.js";
import {
  devirtualizeIndexedLuraphScript,
  devirtualizeLuraphInputSchema,
  readCachedLuraphResult,
  releaseCachedLuraphResult,
} from "../../../tools/impl/advanced/devirtualize-luraph.js";
import { compileSafeSearchRegExp } from "../../../tools/safe-regex.js";
import { remoteSpyInputSchema } from "../../../tools/impl/remote-spy/remote-spy.js";
import {
  callbackInspectInputSchema,
  executorCapabilitiesInputSchema,
  gcDiffInputSchema,
  gcQueryInputSchema,
  gcSnapshotInputSchema,
  gcStatisticsInputSchema,
  propertyAccessInputSchema,
  runtimeActorsInputSchema,
  runtimeCallInputSchema,
  runtimeEnvironmentsInputSchema,
  runtimeHandlesInputSchema,
  runtimeInspectInputSchema,
  runtimeReadInputSchema,
  runtimeReferencesInputSchema,
  runtimeReleaseInputSchema,
  runtimeScriptsInputSchema,
  runtimeWriteInputSchema,
  signalConnectionsInputSchema,
} from "../../../tools/impl/runtime/schemas.js";


interface ToolRequest {
  type: string;
  clientId?: string;
  [key: string]: unknown;
}

const DEFAULT_SCRIPT_MAX_LINES = 80;
const HARD_SCRIPT_MAX_LINES = 2000;

const runtimeDispatchSchemas = {
  "executor-capabilities": executorCapabilitiesInputSchema,
  "runtime-inspect": runtimeInspectInputSchema,
  "runtime-read": runtimeReadInputSchema,
  "runtime-write": runtimeWriteInputSchema,
  "runtime-call": runtimeCallInputSchema,
  "runtime-release": runtimeReleaseInputSchema,
  "runtime-handles": runtimeHandlesInputSchema,
  "gc-snapshot": gcSnapshotInputSchema,
  "gc-query": gcQueryInputSchema,
  "gc-diff": gcDiffInputSchema,
  "gc-statistics": gcStatisticsInputSchema,
  "runtime-references": runtimeReferencesInputSchema,
  "runtime-environments": runtimeEnvironmentsInputSchema,
  "runtime-scripts": runtimeScriptsInputSchema,
  "signal-connections": signalConnectionsInputSchema,
  "property-access": propertyAccessInputSchema,
  "callback-inspect": callbackInspectInputSchema,
  "runtime-actors": runtimeActorsInputSchema,
} as const;

function jsonOk(res: ServerResponse, data: unknown): void {
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify(data));
}

function jsonErr(res: ServerResponse, error: string): void {
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ error }));
}

function numberParam(value: unknown, fallback: number, min: number, max: number): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, Math.floor(parsed)));
}

async function dispatchClientRequest(
  type: string,
  data: Record<string, unknown>,
  clientId: string,
  timeoutMs: number
): Promise<{ response?: RobloxResponse; error?: string }> {
  const result = await DispatchAndWaitForResponse(type, data, clientId, timeoutMs);
  if (result.dispatch === null) return { error: "No active Roblox client connected." };
  if (result.dispatch === "INVALID_CLIENT") return { error: "Invalid or inactive client." };
  if (result.dispatch === "AMBIGUOUS_CLIENT") {
    return { error: "Multiple Roblox clients are connected; provide clientId." };
  }
  if (result.dispatch === "CLIENT_QUEUE_FULL") {
    return { error: "The Roblox client's command queue is full; request not sent." };
  }
  if (result.dispatch === "BRIDGE_BUSY") {
    return { error: "The MCP bridge has too many pending requests; request not sent." };
  }
  if (!result.response) return { error: "No response returned by the Roblox client." };
  return { response: result.response };
}

function resultText(
  value: unknown,
  params: Record<string, unknown>,
  truncationHint?: string
): string {
  return formatToolText(String(value), {
    maxOutputChars: params.maxOutputChars as number | undefined,
    truncationHint,
  });
}

function formatSourceRange(
  source: string,
  startLine?: number,
  endLine?: number,
  maxLines: number = DEFAULT_SCRIPT_MAX_LINES
): string {
  const lines = source.split(/\r?\n/);
  const totalLines = lines.length;
  const lineBudget = numberParam(maxLines, DEFAULT_SCRIPT_MAX_LINES, 1, HARD_SCRIPT_MAX_LINES);
  const start =
    startLine === undefined
      ? 1
      : Math.max(1, Math.min(Math.floor(startLine), totalLines));
  const requestedEnd =
    endLine === undefined
      ? totalLines
      : Math.max(start, Math.min(Math.floor(endLine), totalLines));
  const end = Math.min(requestedEnd, start + lineBudget - 1);
  const truncated = end < requestedEnd;
  const footer = truncated
    ? `\n-- Output truncated to ${lineBudget} lines. Rerun with startLine=${end + 1} or a tighter range to continue.`
    : "";
  return `-- Lines ${start}-${end} of ${totalLines}\n${lines.slice(start - 1, end).join("\n")}${footer}`;
}

function formatSemanticSearchResult(
  query: string,
  searchResults: Awaited<ReturnType<typeof semanticSearchScripts>>["results"],
  chunkCount: number,
  embeddedChunks: number,
  sourceIndexComplete: boolean,
  isPartialIndex: boolean
): string {
  const parts: string[] = [];
  const warning = isPartialIndex
    ? semanticPartialIndexWarning({ chunkCount, embeddedChunks, sourceIndexComplete })
    : undefined;
  if (warning) parts.push(warning);

  const header = `${searchResults.length} match(es) for "${query}" across ${chunkCount} chunks`;
  parts.push(header);

  const body = searchResults.map((r, i) => {
    const signals = r.features.length > 0 ? `\nSignals: ${r.features.join(", ")}` : "";
    return (
      `${i + 1}. [${r.path}] lines ${r.startLine}-${r.endLine} ` +
      `(${r.chunkType}: ${r.label}; hybrid ${r.score.toFixed(4)}, dense ${r.denseScore.toFixed(4)}, lexical ${r.lexicalScore.toFixed(4)})\n` +
      `Summary: ${r.summary}${signals}\n\n${r.snippet}`
    );
  }).join("\n\n---\n\n");

  if (body) parts.push(body);

  return parts.join("\n\n");
}

export async function POST(req: IncomingMessage, res: ServerResponse): Promise<void> {
  try {
    const body = await readJsonBody<ToolRequest>(req);
    const { type, clientId, ...params } = body;

    if (!type) return jsonErr(res, "Missing 'type' field.");

    // Resolve target client
    const target = resolveTargetClient(clientId);
    if (!target) return jsonErr(res, describeTargetResolutionFailure(clientId));
    const jsonClientOk = (data: Record<string, unknown>): void => {
      jsonOk(res, { ...data, clientId: target.clientId });
    };

    // ── Script Grep (server-side search) ──────────────────────────────────────
    if (type === "list-scripts") {
      const index = getScriptSourceIndex({
        clientId: target.clientId,
        placeId: target.placeId,
        jobId: target.jobId,
      });
      const result = buildListScriptsResult(index, {
        filter: typeof params.filter === "string" ? params.filter : undefined,
        pathPrefix: typeof params.pathPrefix === "string" ? params.pathPrefix : undefined,
        namePrefix: typeof params.namePrefix === "string" ? params.namePrefix : undefined,
        cursor: typeof params.cursor === "number" ? params.cursor : undefined,
        offset: typeof params.offset === "number" ? params.offset : undefined,
        limit: numberParam(params.limit, 25, 1, 100),
        includeSourcePreview: params.includeSourcePreview === true,
        sourcePreviewChars: numberParam(params.sourcePreviewChars, 300, 100, 1000),
      });
      return jsonClientOk({
        result: resultText(
          JSON.stringify(result, null, 2),
          params,
          "Use nextCursor, a lower limit, or a narrower filter to page list-scripts."
        ),
        structuredContent: result,
      });
    }

    if (type === "script-grep") {
      const query = params.query;
      if (typeof query !== "string" || query.length === 0) {
        return jsonErr(res, "Missing or invalid 'query' parameter.");
      }

      const index = getScriptSourceIndex({
        clientId: target.clientId,
        placeId: target.placeId,
        jobId: target.jobId,
      });

      const literal = params.literal === true;
      const caseSensitive = params.caseSensitive !== false;
      const limit = numberParam(params.limit, 10, 1, 100);
      const contextLines = numberParam(params.contextLines, 1, 0, 10);
      const maxMatchesPerScript = numberParam(params.maxMatchesPerScript, 3, 1, 50);
      const maxResults = numberParam(params.maxResults, 30, 1, 1000);

      let regex: RegExp;
      try {
        regex = compileSafeSearchRegExp(query, literal, caseSensitive);
      } catch (e) {
        return jsonErr(res, `Invalid regex: ${(e as Error).message}`);
      }

      const results: { path: string; matches: string[] }[] = [];
      let totalMatches = 0;
      let limited = false;

      for (const script of index.scripts) {
        if (results.length >= limit || totalMatches >= maxResults) {
          limited = true;
          break;
        }
        const lines = script.source.split(/\r?\n/);
        const matches: string[] = [];

        for (let i = 0; i < lines.length && matches.length < maxMatchesPerScript && totalMatches + matches.length < maxResults; i++) {
          if (regex.test(lines[i] ?? "")) {
            const start = Math.max(0, i - contextLines);
            const end = Math.min(lines.length - 1, i + contextLines);
            const block: string[] = [];
            for (let j = start; j <= end; j++) {
              block.push(`${j === i ? ">" : " "} ${j + 1}: ${lines[j] ?? ""}`);
            }
            matches.push(block.join("\n"));
          }
        }

        if (matches.length > 0) {
          totalMatches += matches.length;
          results.push({
            path: script.path || `<ScriptProxy: ${script.debugId}>`,
            matches,
          });
          if (matches.length >= maxMatchesPerScript || totalMatches >= maxResults) limited = true;
        }
      }

      const syncNote = index.hasFinishedMapping
        ? ""
        : ` (partial index: ${index.mappedSources}/${index.sourcesToMap} scripts uploaded)`;
      const header = `${totalMatches} match(es) across ${results.length} script(s)${limited ? " (results limited)" : ""}${syncNote}`;
      const body = results.map(r => `[${r.path}] ${r.matches.length} match(es)\n\n${r.matches.join("\n\n")}`).join("\n\n---\n\n");

      return jsonClientOk({
        result: resultText(
          header + (body ? "\n\n" + body : ""),
          params,
          "Rerun script-grep with a narrower query, lower limit, or lower maxResults."
        ),
      });
    }



    // ── Semantic Search (server-side) ─────────────────────────────────────────
    if (type === "semantic-search") {
      const query = params.query as string;
      if (typeof query !== "string" || query.length === 0 || query.length > 4000) {
        return jsonErr(res, "'query' must be a non-empty string of at most 4000 characters.");
      }

      const index = getScriptSourceIndex({
        clientId: target.clientId,
        placeId: target.placeId,
        jobId: target.jobId,
      });

      if (index.scripts.length === 0) {
        return jsonErr(res, `No script sources have been received yet.`);
      }

      const settings = await loadSemanticSettings();
      const settingsError = validateSemanticSettings(settings);
      if (settingsError) return jsonErr(res, `Semantic search not configured: ${settingsError}`);
      const confirmationError = validateSemanticUploadConfirmation(
        settings,
        params.confirmRemoteEmbeddingUpload
      );
      if (confirmationError) {
        return jsonErr(res, `Semantic search confirmation required: ${confirmationError}`);
      }

      const limit = numberParam(params.limit, 5, 1, 50);
      const indexOnly = params.indexOnly === true;
      const requireFullIndex = params.requireFullIndex !== false;
      const minScore = typeof params.minScore === "number" ? params.minScore : undefined;

      const job = createProgressJob(
        indexOnly ? "semantic-index" : "semantic-search",
        indexOnly ? "Starting semantic index" : "Starting semantic search",
        target.clientId
      );

      void (async () => {
        try {
          if (indexOnly || requireFullIndex) {
            const { chunkCount, embeddedChunks, sourceIndexComplete } = await semanticIndexCodebase(
              index,
              settings,
              (progress) => updateProgressJob(job.id, progress)
            );
            if (indexOnly) {
              completeProgressJob(
                job.id,
                semanticIndexReadyMessage(
                  { chunkCount, embeddedChunks, sourceIndexComplete },
                  index
                )
              );
              return;
            }
          }

          const output = await semanticSearchScripts(
            index,
            settings,
            query,
            limit,
            minScore,
            (progress) => updateProgressJob(job.id, progress)
          );

          if (requireFullIndex && output.isPartialIndex) {
            failProgressJob(job.id, "Semantic search did not complete a full index; refusing partial results.");
            return;
          }

          completeProgressJob(
            job.id,
            resultText(
              formatSemanticSearchResult(
                query,
                output.results,
                output.chunkCount,
                output.embeddedChunks,
                output.sourceIndexComplete,
                output.isPartialIndex
              ),
              params,
              "Rerun semantic-search-scripts with a lower limit or higher minScore."
            )
          );
        } catch (error) {
          failProgressJob(
            job.id,
            error instanceof Error ? error.message : String(error)
          );
        }
      })();

      return jsonClientOk({ jobId: job.id, progressUrl: `/api/tool-progress?id=${job.id}` });
    }



    // ── Get Script Content (server-side index + client fallback) ───────────────
    if (type === "get-script-content") {
      const scriptPath = params.scriptPath as string | undefined;
      const scriptGetterSource = params.scriptGetterSource as string | undefined;
      const startLine = params.startLine as number | undefined;
      const endLine = params.endLine as number | undefined;
      const maxLines = numberParam(params.maxLines, DEFAULT_SCRIPT_MAX_LINES, 1, HARD_SCRIPT_MAX_LINES);

      if (scriptGetterSource !== undefined) {
        return jsonErr(res, "scriptGetterSource is no longer accepted; use a strict scriptPath or ScriptProxy debug ID.");
      }
      if (!scriptPath) return jsonErr(res, "Missing 'scriptPath'.");

      const scriptProxyMatch = scriptPath.match(/^<ScriptProxy: (.+)>$/);

      // Try server-side index first
      if (scriptPath) {
        const index = getScriptSourceIndex({
          clientId: target.clientId,
          placeId: target.placeId,
          jobId: target.jobId,
        });

        const stored = index.scripts.find((s) =>
          scriptProxyMatch ? s.debugId === scriptProxyMatch[1] : s.path === scriptPath
        );

        if (stored) {
          return jsonClientOk({
            result: resultText(
              formatSourceRange(stored.source, startLine, endLine, maxLines),
              params,
              "Rerun get-script-content with startLine/endLine or a smaller maxLines value."
            ),
          });
        }
      }

      // Fall back to dispatching to Roblox client
      const data: Record<string, unknown> = scriptProxyMatch
        ? { debugId: scriptProxyMatch[1], startLine, endLine, maxLines }
        : {
            target: { path: scriptPath },
            startLine,
            endLine,
            maxLines,
          };

      const dispatched = await dispatchClientRequest(
        "get-script-content",
        data,
        target.clientId,
        15000
      );
      if (dispatched.error) return jsonErr(res, dispatched.error);
      const response = dispatched.response!;
      if (response.error) return jsonErr(res, response.error);
      return jsonClientOk({
        result: resultText(
          response.output ?? "No output returned.",
          params,
          "Rerun get-script-content with startLine/endLine or a smaller maxLines value."
        ),
      });
    }

    // ── Luraph devirtualization (server-side Railway worker) ──────────────────
    if (type === "devirtualize-luraph") {
      const parsed = devirtualizeLuraphInputSchema.safeParse({
        ...params,
        clientId: target.clientId,
      });
      if (!parsed.success) {
        return jsonErr(
          res,
          `Invalid devirtualize-luraph request: ${parsed.error.issues[0]?.message ?? "schema validation failed"}`
        );
      }
      const result = parsed.data.operation === "run"
        ? await devirtualizeIndexedLuraphScript({
            clientId: target.clientId,
            placeId: target.placeId,
            jobId: target.jobId,
            scriptPath: parsed.data.scriptPath,
            captureMode: parsed.data.captureMode,
            timeoutSeconds: parsed.data.timeoutSeconds,
            previewLines: parsed.data.previewLines,
          })
        : parsed.data.operation === "read"
          ? readCachedLuraphResult({
              clientId: target.clientId,
              resultId: parsed.data.resultId,
              startLine: parsed.data.startLine,
              maxLines: parsed.data.maxLines,
            })
          : releaseCachedLuraphResult(target.clientId, parsed.data.resultId);
      if (!result.ok) return jsonErr(res, result.text);
      return jsonClientOk({
        result: resultText(
          result.text,
          params,
          "Read the recovered script in narrower follow-up analysis rather than requesting a larger tool result."
        ),
        structuredContent: result.structured ?? null,
      });
    }

    // ── Client-dispatched tools ───────────────────────────────────────────────
    const runtimeSchema = runtimeDispatchSchemas[type as keyof typeof runtimeDispatchSchemas];
    if (runtimeSchema) {
      const parsed = runtimeSchema.safeParse({ ...params, clientId: target.clientId });
      if (!parsed.success) {
        return jsonErr(
          res,
          `Invalid ${type} request: ${parsed.error.issues[0]?.message ?? "schema validation failed"}`
        );
      }
      const {
        clientId: _parsedClientId,
        maxOutputChars: _maxOutputChars,
        ...runtimeData
      } = parsed.data as Record<string, unknown>;
      const longRunning = type === "gc-snapshot" || type === "runtime-call" || type === "runtime-references";
      const dispatched = await dispatchClientRequest(
        type,
        runtimeData,
        target.clientId,
        longRunning ? 120_000 : 60_000
      );
      if (dispatched.error) return jsonErr(res, dispatched.error);
      const response = dispatched.response!;
      if (response.error) return jsonErr(res, response.error);
      return jsonClientOk({
        result: resultText(
          response.output ?? "No output returned.",
          params,
          "Use the tool's filters, cursor, and limit fields to request a narrower runtime page."
        ),
        structuredContent:
          response.structured && typeof response.structured === "object"
            ? response.structured
            : null,
      });
    }

    const dispatchTypes: Record<string, string> = {
      "get-data-by-code": "get-data-by-code",
      "execute": "execute",
      "search-instances": "search-instances",
      "get-console-output": "get-console-output",
      "get-descendants-tree": "get-descendants-tree",
      "get-game-info": "get-game-info",
      "remote-spy": "remote-spy",
    };

    const robloxType = dispatchTypes[type];
    if (!robloxType) return jsonErr(res, `Unknown tool type: ${type}`);

    // Build data for the client
    const data: Record<string, unknown> = {};

    if (type === "remote-spy") {
      const parsed = remoteSpyInputSchema.safeParse({
        ...params,
        clientId: target.clientId,
      });
      if (!parsed.success) {
        return jsonErr(res, `Invalid remote-spy request: ${parsed.error.issues[0]?.message ?? "schema validation failed"}`);
      }
      const { clientId: _clientId, ...remoteParams } = parsed.data;
      Object.assign(data, remoteParams);
    }

    if (type === "get-data-by-code") {
      const code = params.code as string;
      if (!code) return jsonErr(res, "Missing 'code' parameter.");
      const timeout = Math.min(Math.max(Number(params.timeout) || 15000, 1000), 120000);
      data.source = `setthreadidentity(8);${code}`;
      const dispatched = await dispatchClientRequest(
        robloxType,
        data,
        target.clientId,
        timeout
      );
      if (dispatched.error) return jsonErr(res, dispatched.error);
      const response = dispatched.response!;
      if (response.error) return jsonErr(res, response.error);
      return jsonClientOk({
        result: resultText(
          response.output ?? "No output returned.",
          params,
          "Rerun get-data-by-code with code that returns fewer fields or pass a smaller maxOutputChars."
        ),
      });
    }

    if (type === "execute") {
      const code = params.code as string;
      if (!code) return jsonErr(res, "Missing 'code' parameter.");
      data.source = `setthreadidentity(8);${code}`;
      if (typeof params.operationId === "string") data.operationId = params.operationId.slice(0, 128);
      const timeout = Math.min(Math.max(Number(params.timeout) || 30000, 1000), 120000);
      const dispatched = await dispatchClientRequest(
        robloxType,
        data,
        target.clientId,
        timeout
      );
      if (dispatched.error) return jsonErr(res, dispatched.error);
      const response = dispatched.response!;
      if (response.error) return jsonErr(res, response.error);
      return jsonClientOk({
        result: `Execution completed successfully (requestId=${response.id}).`,
      });
    }

    if (type === "search-instances") {
      const selector = params.selector as string;
      if (!selector) return jsonErr(res, "Missing 'selector' parameter.");
      data.selector = selector;
      data.root = params.root || "game";
      data.limit = numberParam(params.limit, 20, 1, 100);
    } else if (type === "get-console-output") {
      data.limit = numberParam(params.limit, 10, 1, 200);
      if (typeof params.logsOrder === "string") data.logsOrder = params.logsOrder;
      if (typeof params.filter === "string") data.filter = params.filter;
      if (typeof params.summaryOnly === "boolean") data.summaryOnly = params.summaryOnly;
    } else if (type === "get-descendants-tree") {
      const root = params.root as string;
      if (!root) return jsonErr(res, "Missing 'root' parameter.");
      data.root = root;
      data.maxDepth = numberParam(params.maxDepth, 2, 0, 5);
      data.maxChildren = numberParam(params.maxChildren, 20, 1, 30);
      if (params.classFilter) data.classFilter = params.classFilter;
      if (typeof params.summaryOnly === "boolean") data.summaryOnly = params.summaryOnly;
    } else if (type === "get-game-info") {
      data.includeDescription = params.includeDescription === true;
    }

    const dispatched = await dispatchClientRequest(
      robloxType,
      data,
      target.clientId,
      15000
    );
    if (dispatched.error) return jsonErr(res, dispatched.error);
    const response = dispatched.response!;
    if (response.error) return jsonErr(res, response.error);
    return jsonClientOk({
      result: resultText(
        response.output ?? "No output returned.",
        params,
        "Rerun with narrower filters, lower limits, or summaryOnly=true where supported."
      ),
    });



  } catch (err) {
    jsonErr(res, `Tool execution failed: ${(err as Error).message || err}`);
  }
}
