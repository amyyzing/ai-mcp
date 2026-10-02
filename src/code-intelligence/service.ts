import { AnalysisSession, type CodeTool } from "./session.js";
import { AnalysisHierarchy, type DexRecord } from "./hierarchy.js";
import { loadLspRuntime, type LspRuntime } from "./runtime.js";
import { getScriptSourceIndex, onScriptSourceChange } from "../bridge/handlers/shared/script-source-store.js";
import { DispatchAndWaitForResponse } from "../bridge/handlers/shared/communication.js";
import { resolveTargetClient } from "../bridge/handlers/shared/registry.js";
import type { RobloxClient } from "../bridge/types.js";

interface Entry { session: AnalysisSession; identity: string; hierarchy: AnalysisHierarchy; busy: boolean; lastUsed: number }
const entries = new Map<string, Entry>();
let runtime: LspRuntime | undefined;
onScriptSourceChange(event => {
  const entry = entries.get(event.clientId);
  if (!entry) return;
  if (event.kind === "reset") { entry.session.close(); entries.delete(event.clientId); }
  else entry.session.invalidate();
});
export function closeAnalysisSessions(): void {
  for (const entry of entries.values()) entry.session.close();
  entries.clear();
}
const sweep = setInterval(() => {
  for (const [id, entry] of entries) if (!entry.busy && (Date.now() - entry.lastUsed > 5 * 60_000 || !resolveTargetClient(id))) {
    entry.session.close(); entries.delete(id);
  }
}, 30_000);
sweep.unref();
process.once("exit", closeAnalysisSessions);

async function collectHierarchy(clientId: string): Promise<{ records: DexRecord[]; complete: boolean; generation?: string }> {
  const records: DexRecord[] = []; let cursor: string | undefined; let generation: string | undefined;
  let complete = false; let detailsComplete = true;
  const deadline = Date.now() + 15000;
  for (let page = 0; page < 12 && Date.now() < deadline; page++) {
    const data: Record<string, unknown> = { limit: 100, scanBudget: 1000, timeBudgetMs: 8, maxOutputChars: 32000 };
    if (cursor) data.cursor = cursor;
    else Object.assign(data, { root: { path: "game", root: "game" }, maxDepth: 64, maxNodes: 1000, properties: [], includeAttributes: false, includeTags: false, retainSnapshot: false });
    const { response, dispatch } = await DispatchAndWaitForResponse("dex-query", data, clientId, Math.max(1, Math.min(5000, deadline - Date.now())));
    if (typeof dispatch !== "string" || !response || response.error || response.success === false || response.isError || response.clientId !== clientId)
      throw new Error("Hierarchy refresh failed; verify the current connector supports dex-query. No fallback execution was attempted.");
    const result = response.structured as Record<string, any> | undefined;
    if (!result || !Array.isArray(result.results)) throw new Error("Dex returned no structured hierarchy page.");
    // Separate connector loads can both start at generation 1.
    const nextGeneration = JSON.stringify([result.connectorId ?? null, result.connectorGeneration ?? null]);
    if (generation !== undefined && generation !== nextGeneration) throw new Error("Connector changed during hierarchy collection; retry.");
    generation = nextGeneration;
    detailsComplete &&= result.detailsComplete === true && result.projectionComplete === true;
    records.push(...result.results);
    complete = result.complete === true && result.depthLimited !== true && detailsComplete;
    cursor = typeof result.nextCursor === "string" ? result.nextCursor : undefined;
    if (!cursor || result.done) break;
  }
  return { records, complete, generation };
}

export interface AnalysisOptions { scriptId: string; sourceIds?: string[]; line: number; character: number; requireFresh: boolean; refreshHierarchy: boolean; limit: number }
export async function runCodeAnalysis(tool: CodeTool, target: RobloxClient, options: AnalysisOptions): Promise<Record<string, any>> {
  runtime ??= loadLspRuntime();
  const index = getScriptSourceIndex(target);
  const wanted = options.sourceIds ? new Set([options.scriptId, ...options.sourceIds]) : undefined;
  const selected = index.scripts.filter(s => !wanted || wanted.has(s.debugId));
  const script = index.scripts.find(item => item.debugId === options.scriptId);
  if (!script) throw new Error("Script ID is not in the active source store. Use list-scripts, or collect its source with the existing indexing tools.");
  if (selected.length > 2000 || selected.reduce((n, s) => n + Buffer.byteLength(s.source), 0) > 8 * 1024 * 1024)
    throw new Error("Current source index exceeds the analysis budget (2000 scripts / 8 MiB); use sourceIds to select the script and relevant dependencies.");
  const identity = JSON.stringify([target.placeId, target.jobId, target.sessionId, index.mappingSessionId]);
  let entry = entries.get(target.clientId);
  if (entry && (entry.identity !== identity || entry.session.closed)) {
    entry.session.close(); entries.delete(target.clientId); entry = undefined;
  }
  if (!entry) {
    if (entries.size >= 2) throw new Error("Two analysis workers are already active. Retry after an idle worker expires.");
    entry = { identity, hierarchy: new AnalysisHierarchy(), busy: false, lastUsed: Date.now(),
      session: new AnalysisSession(target.clientId, index.mappingSessionId ?? "legacy", runtime) };
    entries.set(target.clientId, entry);
  }
  if (entry.busy) throw new Error("An analysis request is already running for this client. Retry after it completes.");
  entry.busy = true;
  try {
    await entry.session.ready;
    if (options.refreshHierarchy || !entry.hierarchy.observedAt) {
      const snapshot = await collectHierarchy(target.clientId);
      entry.hierarchy.update(snapshot.records, snapshot.complete, snapshot.generation);
    }
    // Re-read after the asynchronous observation; source changes may have arrived.
    const current = getScriptSourceIndex(target);
    if (entries.get(target.clientId) !== entry || entry.session.closed || !resolveTargetClient(target.clientId)
      || JSON.stringify([target.placeId, target.jobId, target.sessionId, current.mappingSessionId]) !== identity)
      throw new Error("Client or mapping session changed during analysis setup; retry.");
    const sources = current.scripts.filter(s => !wanted || wanted.has(s.debugId));
    const observed = entry.hierarchy.build(sources);
    await entry.session.synchronize(sources.map(s => ({ id: s.debugId, source: s.source, sourceKind: s.sourceKind })), observed.tree);
    const result = await entry.session.query(tool, options.scriptId, options.line, options.character, options.requireFresh, options.limit);
    if (!resolveTargetClient(target.clientId) || entries.get(target.clientId) !== entry) throw new Error("Client disconnected or was replaced while analysis ran; result discarded.");
    result.coverage = { ...result.coverage, ...observed.coverage, sourceIndexComplete: current.sourceIndexComplete, sourceGap: current.sourceGap,
      selectedSources: sources.length, indexedSources: current.scripts.length, missingRequestedSources: wanted ? [...wanted].filter(id => !sources.some(s => s.debugId === id)) : [] };
    result.document.path = current.scripts.find(s => s.debugId === options.scriptId)?.path;
    result.document.sourceProducer = current.scripts.find(s => s.debugId === options.scriptId)?.sourceProducer;
    if (JSON.stringify(result.result ?? null).length > 24000) {
      delete result.result; result.ok = false; result.truncated = true;
      result.error = "Analysis result exceeds the output budget. Reduce limit or choose a narrower symbol query.";
    }
    return result;
  } catch (error) {
    if (entry.session.closed) { entry.session.close(); if (entries.get(target.clientId) === entry) entries.delete(target.clientId); }
    throw error;
  } finally { entry.busy = false; entry.lastUsed = Date.now(); }
}
