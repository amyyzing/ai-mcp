import { mkdtempSync, rmdirSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { pathToFileURL, fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import { LspTransport } from "./protocol.js";
import { ANALYSIS_CONFIGURATION, hash, type LspRuntime } from "./runtime.js";

export interface AnalysisDocument {
  id: string; uri: string; version: number; sourceHash: string;
  sourceKind: "original" | "decompiled" | "normalized" | "stub" | "unknown";
}
export interface SourceInput { id: string; source: string; sourceKind?: AnalysisDocument["sourceKind"] }
export interface HierarchyNode {
  Name: string; ClassName: string; DebugId: string; ChildrenComplete: boolean;
  Children: HierarchyNode[]; sourceId?: string; FilePaths?: string[];
}
export type CodeTool = "code-check" | "code-definition" | "code-references" | "code-type-at" | "code-symbols";
export const CODE_TOOLS: CodeTool[] = ["code-check", "code-definition", "code-references", "code-type-at", "code-symbols"];
const METHODS: Record<CodeTool, string> = {
  "code-check": "textDocument/diagnostic", "code-definition": "textDocument/definition",
  "code-references": "textDocument/references", "code-type-at": "textDocument/hover", "code-symbols": "textDocument/documentSymbol",
};
let generation = 0;

export class AnalysisSession {
  readonly sessionId = randomUUID();
  workerGeneration = ++generation;
  readonly workspace = mkdtempSync(path.join(tmpdir(), "ai-mcp-analysis-"));
  readonly configurationHash = hash(JSON.stringify(ANALYSIS_CONFIGURATION));
  readonly documents = new Map<string, AnalysisDocument>();
  worker!: LspTransport;
  ready!: Promise<void>;
  analysisInputRevision = 0; // Desired inputs accepted by the adapter.
  submittedInputRevision = 0; // Inputs actually sent to this worker.
  hierarchyRevision = 0;
  closed = false;
  private sources = new Map<string, string>();
  private inputHash = "";
  private hierarchyHash = "";
  private capabilities: any = {};

  constructor(readonly clientId: string, readonly mappingSessionId: string, readonly runtime: LspRuntime) {
    this.startWorker();
  }

  private startWorker(): void {
    const runtime = this.runtime;
    const worker = new LspTransport(runtime.binary, ["lsp", "--stdio", `--definitions:@roblox=${runtime.definitions}`], this.workspace);
    this.worker = worker;
    this.worker.onRequest = (method, params) => {
      if (method === "workspace/configuration") return (params?.items ?? []).map((item: any) => {
        if (!item.section || item.section === "luau-lsp") return ANALYSIS_CONFIGURATION;
        return item.section.replace(/^luau-lsp\./, "").split(".").reduce((value: any, key: string) => value?.[key], ANALYSIS_CONFIGURATION) ?? null;
      });
      if (method === "workspace/workspaceFolders") return [{ uri: pathToFileURL(this.workspace).href, name: "MCP" }];
      if (method === "workspace/applyEdit") return { applied: false, failureReason: "Analysis is read-only." };
      return null;
    };
    // Push diagnostics have no reliable session-wide revision acknowledgment.
    // Use explicit pull diagnostics; never put unsolicited results in the tool cache.
    this.worker.onNotification = () => {};
    this.worker.onExit = () => { if (this.worker === worker) { this.closed = true; this.analysisInputRevision++; } };
    this.ready = this.initialize().catch(error => { this.close(); throw error; });
    // Construction can precede asynchronous hierarchy collection.
    void this.ready.catch(() => {});
  }

  private async initialize(): Promise<void> {
    const result = await this.worker.request("initialize", {
      processId: process.pid, rootUri: pathToFileURL(this.workspace).href,
      workspaceFolders: [{ uri: pathToFileURL(this.workspace).href, name: "MCP" }],
      capabilities: {
        general: { positionEncodings: ["utf-16"] },
        workspace: { configuration: true, workspaceFolders: true },
        textDocument: { diagnostic: { dynamicRegistration: false, relatedDocumentSupport: true },
          synchronization: { dynamicRegistration: false }, documentSymbol: { hierarchicalDocumentSymbolSupport: true } },
      },
      initializationOptions: { fflags: {} },
    });
    this.capabilities = result.capabilities;
    if (this.capabilities.positionEncoding && this.capabilities.positionEncoding !== "utf-16")
      throw new Error(`Unsupported LSP position encoding: ${this.capabilities.positionEncoding}`);
    this.worker.notify("initialized");
    this.worker.notify("workspace/didChangeConfiguration", { settings: { "luau-lsp": ANALYSIS_CONFIGURATION } });
    this.worker.notify("$/roblox/attachProcess", { pid: 0, autoDetect: false });
    this.worker.notify("$/roblox/moduleSourceProvider", { enabled: false });
    // A request establishes configuration readiness before the first observation.
    await this.worker.request("workspace/symbol", { query: "" });
  }

  invalidate(): void { this.analysisInputRevision++; }

  async synchronize(inputs: SourceInput[], tree: HierarchyNode): Promise<void> {
    const acceptedRevision = this.analysisInputRevision;
    await this.ready;
    if (acceptedRevision !== this.analysisInputRevision) throw new Error("Analysis inputs changed during synchronization; retry with a new source snapshot.");
    if (this.closed) throw new Error("Analysis session is closed.");
    if (inputs.length > 2000 || inputs.reduce((total, item) => total + Buffer.byteLength(item.source), 0) > 8 * 1024 * 1024)
      throw new Error("Analysis source budget exceeded (2000 documents / 8 MiB). Narrow the source index.");
    const hierarchyHash = hash(JSON.stringify(tree));
    const inputHash = hash(JSON.stringify([hierarchyHash, inputs.map(item => [item.id, hash(item.source), item.sourceKind])]));
    if (inputHash === this.inputHash && this.submittedInputRevision === this.analysisInputRevision) return;
    if (inputHash !== this.inputHash) this.analysisInputRevision++;
    if (hierarchyHash !== this.hierarchyHash) this.hierarchyRevision++;
    const wanted = new Set(inputs.map(item => item.id));
    const membershipChanged = wanted.size !== this.documents.size || [...wanted].some(id => !this.documents.has(id));
    for (const [id, document] of this.documents) {
      if (!wanted.has(id)) {
        this.worker.notify("textDocument/didClose", { textDocument: { uri: document.uri } });
        this.documents.delete(id); this.sources.delete(id);
      }
    }
    const changes: { method: string; params: unknown }[] = [];
    for (const input of inputs) {
      const sourceHash = hash(input.source);
      const old = this.documents.get(input.id);
      const uri = old?.uri ?? pathToFileURL(path.join(this.workspace, `${hash(input.id)}.luau`)).href;
      const document: AnalysisDocument = { id: input.id, uri, version: old ? old.version + (old.sourceHash !== sourceHash ? 1 : 0) : 1,
        sourceHash, sourceKind: input.sourceKind ?? "unknown" };
      this.documents.set(input.id, document); this.sources.set(input.id, input.source);
      if (!old) changes.push({ method: "textDocument/didOpen", params: { textDocument: { uri, languageId: "luau", version: document.version, text: input.source } } });
      else if (old.sourceHash !== sourceHash) changes.push({ method: "textDocument/didChange", params: { textDocument: { uri, version: document.version }, contentChanges: [{ text: input.source }] } });
    }
    const attach = (node: HierarchyNode): HierarchyNode => {
      const document = node.sourceId ? this.documents.get(node.sourceId) : undefined;
      return { Name: node.Name, ClassName: node.ClassName, DebugId: node.DebugId, ChildrenComplete: node.ChildrenComplete,
        Children: node.Children.map(attach), ...(document ? { FilePaths: [fileURLToPath(document.uri)] } : {}) };
    };
    for (const change of changes) this.worker.notify(change.method, change.params);
    if (hierarchyHash !== this.hierarchyHash || membershipChanged)
      this.worker.notify("$/executor/full", { tree: attach(tree) });
    this.inputHash = inputHash; this.hierarchyHash = hierarchyHash;
    this.submittedInputRevision = this.analysisInputRevision;
  }

  async query(tool: CodeTool, id: string, line = 0, character = 0, requireFresh = true, limit = 100): Promise<Record<string, any>> {
    await this.ready;
    const document = this.documents.get(id);
    if (!document) throw new Error("Script is not present in the current analysis source snapshot.");
    const lines = this.sources.get(id)!.split("\n");
    if (line < 0 || line >= lines.length || character < 0 || character > lines[line].replace(/\r$/, "").length)
      throw new Error("Position is outside the document. Positions use zero-based UTF-16 line/character units.");
    const revision = this.submittedInputRevision;
    const requestedGeneration = this.workerGeneration;
    if (requireFresh && revision !== this.analysisInputRevision) throw new Error("Analysis inputs changed; synchronize before querying.");
    if (tool === "code-check" && !this.capabilities.diagnosticProvider) throw new Error("Pinned LSP did not advertise pull diagnostics.");
    const value = await this.worker.request(METHODS[tool], {
      textDocument: { uri: document.uri }, position: { line, character }, context: { includeDeclaration: true },
    });
    if (tool === "code-check" && (value?.kind !== "full" || !Array.isArray(value.items)))
      throw new Error("LSP did not provide a complete diagnostic response; analysis is not confirmed.");
    const superseded = this.closed || requestedGeneration !== this.workerGeneration || revision !== this.analysisInputRevision;
    const canonical = (uri: string) => {
      const filename = fileURLToPath(uri);
      return process.platform === "win32" ? filename.toLowerCase() : filename;
    };
    const byUri = new Map([...this.documents.values()].map(doc => [canonical(doc.uri), doc]));
    let normalizedNodes = 0; let normalizationLimited = false;
    const normalize = (item: any, depth = 0): any => {
      if (depth > 32 || ++normalizedNodes > 20000) { normalizationLimited = true; return { omitted: "structure-limit" }; }
      if (Array.isArray(item)) return item.map(child => normalize(child, depth + 1));
      if (!item || typeof item !== "object") return item;
      const output: Record<string, any> = {};
      for (const [key, child] of Object.entries(item)) output[key] = normalize(child, depth + 1);
      for (const key of ["uri", "targetUri"]) {
        if (typeof output[key] !== "string" || !output[key].startsWith("file:")) continue;
        try {
          const found = byUri.get(canonical(output[key]));
          if (found) { output[key] = found.uri; output.scriptId = found.id; }
        } catch {}
      }
      return output;
    };
    const rawItems = tool === "code-check" ? value.items : value;
    const items = normalize(Array.isArray(rawItems) ? rawItems.slice(0, limit) : rawItems);
    const truncated = normalizationLimited || (Array.isArray(rawItems) && rawItems.length > limit);
    return {
      ok: !(requireFresh && superseded),
      ...(requireFresh && superseded ? { error: "Analysis was superseded while the query was running. Retry against current inputs." } : { result: items }),
      truncated,
      context: { sessionId: this.sessionId, clientId: this.clientId, mappingSessionId: this.mappingSessionId,
        workerGeneration: requestedGeneration, hierarchyRevision: this.hierarchyRevision,
        configurationHash: this.configurationHash, definitionsHash: this.runtime.definitionsHash, lspBuildId: this.runtime.buildId },
      document: { ...document },
      freshness: { state: superseded ? "superseded" : "confirmed", requestedInputRevision: revision,
        submittedInputRevision: this.submittedInputRevision, ...(!superseded ? { confirmedInputRevision: revision, confirmationScope: "document" } : {}),
        detail: "Pinned native request ordering; confirmation covers this query against submitted observations, not unobserved live changes or all workspace diagnostics." },
      coverage: { syntaxAndTypes: true, dataModelDiagnostics: "strict-on-observed-hierarchy", hoverDataModelTypes: "strict",
        checkingModes: [...this.sources.values()].reduce((counts, source) => {
          const mode = source.match(/^\s*--!(strict|nonstrict|nocheck)\b/m)?.[1] ?? "nonstrict";
          counts[mode] = (counts[mode] ?? 0) + 1; return counts;
        }, {} as Record<string, number>),
        referencesLimitation: "Supplied sources only; upstream reference lookup for returned primitive values is incomplete.",
        sourceBackedDocuments: [...this.documents.values()].filter(d => d.sourceKind !== "stub").length,
        stubDocuments: [...this.documents.values()].filter(d => d.sourceKind === "stub").length,
        executorRuntimeSupport: "not-validated", positionEncoding: "utf-16", sourceKinds: [...new Set([...this.documents.values()].map(d => d.sourceKind))] },
    };
  }

  close(): void {
    this.closed = true; this.invalidate(); this.worker.close();
    // The analysis directory contains no source files. Never recursively delete.
    try { rmdirSync(this.workspace); } catch {}
  }
}
