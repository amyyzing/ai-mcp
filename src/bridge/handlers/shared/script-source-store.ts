import crypto from "crypto";
import { clearSemanticIndexForClient } from "../../../semantic/vector-index.js";

export interface StoredScriptSource {
  debugId: string;
  path: string;
  source: string;
  scriptHash?: string;
  sourceHash: string;
  updatedAt: number;
}

export interface ScriptSourceIndex {
  clientId: string;
  placeId: number;
  jobId: string;
  hasFinishedMapping: boolean;
  mappedSources: number;
  processedSources: number;
  skippedSources: number;
  sourcesToMap: number;
  sourceGap: number;
  sourceIndexComplete: boolean;
  mappingSessionId?: string;
  mappingRevision?: number;
  scripts: StoredScriptSource[];
}

export type ScriptSourceIndexSummary = Omit<ScriptSourceIndex, "scripts">;

export interface ScriptSourceUpsertResult extends ScriptSourceIndexSummary {
  acceptedMappingRevision?: number;
}

export interface ScriptSourceStoreIdentity {
  clientId: string;
  placeId: number;
  jobId: string;
}

interface ClientScriptSourceStore {
  placeId: number;
  jobId: string;
  hasFinishedMapping: boolean;
  processedSources: number;
  skippedSources: number;
  sourcesToMap: number;
  mappingSessionId?: string;
  mappingSessionStartedAt?: number;
  mappingRevision: number;
  activeScripts: Map<string, StoredScriptSource>;
  activeRevisionByScriptId: Map<string, number>;
  scripts: Map<string, StoredScriptSource>;
  scriptsByHash: Map<string, StoredScriptSource>;
  scriptBytes: number;
  hashCacheBytes: number;
}

export interface UpsertScriptSourcesInput {
  hasFinishedMapping?: boolean;
  sourcesToMap?: number;
  processedSources?: number;
  skippedSources?: number;
  mappingSessionId?: unknown;
  mappingSessionStartedAt?: unknown;
  mappingRevision?: unknown;
  beginMappingSession?: unknown;
  removedScriptIds?: unknown[];
  scripts?: {
    debugId?: unknown;
    path?: unknown;
    source?: unknown;
    scriptHash?: unknown;
  }[];
}

export interface CachedScriptSourceByHash {
  scriptHash: string;
  debugId: string;
  path: string;
  source: string;
  sourceHash: string;
  updatedAt: number;
}

const storesByClientId: Map<string, ClientScriptSourceStore> = new Map();

function configuredLimit(name: string, fallback: number, maximum: number): number {
  const parsed = Number(process.env[name]);
  return Number.isSafeInteger(parsed) && parsed > 0 && parsed <= maximum
    ? parsed
    : fallback;
}

export interface CachedScriptSourceResult {
  sources: CachedScriptSourceByHash[];
  limited: boolean;
  omitted: number;
}

const MAX_SOURCE_CHARS = configuredLimit(
  "ROBLOX_MCP_MAX_SCRIPT_SOURCE_CHARS",
  2 * 1024 * 1024,
  16 * 1024 * 1024
);
const MAX_SCRIPTS_PER_CLIENT = configuredLimit(
  "ROBLOX_MCP_MAX_SCRIPTS_PER_CLIENT",
  25_000,
  100_000
);
const MAX_SCRIPT_SOURCE_CHARS_PER_CLIENT = configuredLimit(
  "ROBLOX_MCP_MAX_SCRIPT_SOURCE_CHARS_PER_CLIENT",
  32 * 1024 * 1024,
  512 * 1024 * 1024
);
const MAX_HASH_CACHE_ENTRIES_PER_CLIENT = configuredLimit(
  "ROBLOX_MCP_MAX_SCRIPT_HASH_CACHE_ENTRIES",
  10_000,
  100_000
);
const MAX_HASH_CACHE_CHARS_PER_CLIENT = configuredLimit(
  "ROBLOX_MCP_MAX_SCRIPT_HASH_CACHE_CHARS",
  32 * 1024 * 1024,
  512 * 1024 * 1024
);
const MAX_SCRIPT_SOURCE_CHARS_GLOBAL = configuredLimit(
  "ROBLOX_MCP_MAX_SCRIPT_SOURCE_CHARS_GLOBAL",
  64 * 1024 * 1024,
  1024 * 1024 * 1024
);

function retainedSourceChars(): number {
  let total = 0;
  for (const store of storesByClientId.values()) {
    // The hash cache can retain historical StoredScriptSource objects that are
    // no longer in `scripts`, so count both budgets conservatively.
    total += store.scriptBytes + store.hashCacheBytes;
  }
  return total;
}

function hashSource(source: string): string {
  return crypto.createHash("sha256").update(source).digest("hex");
}

function normalizeScriptHash(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > 512) return undefined;
  return trimmed;
}

function getOrCreateStore(identity: ScriptSourceStoreIdentity): ClientScriptSourceStore {
  let store = storesByClientId.get(identity.clientId);
  if (!store || store.placeId !== identity.placeId || store.jobId !== identity.jobId) {
    if (store) clearSemanticIndexForClient(identity.clientId);
    store = {
      placeId: identity.placeId,
      jobId: identity.jobId,
      hasFinishedMapping: false,
      processedSources: 0,
      skippedSources: 0,
      sourcesToMap: 0,
      mappingRevision: -1,
      activeScripts: new Map(),
      activeRevisionByScriptId: new Map(),
      scripts: new Map(),
      scriptsByHash: new Map(),
      scriptBytes: 0,
      hashCacheBytes: 0,
    };
    storesByClientId.set(identity.clientId, store);
  }
  return store;
}

function updateScriptHashIndex(
  store: ClientScriptSourceStore,
  script: StoredScriptSource
): void {
  if (!script.scriptHash) return;
  const indexed = store.scriptsByHash.get(script.scriptHash);
  if (!indexed || indexed.debugId === script.debugId || script.updatedAt >= indexed.updatedAt) {
    const projectedGlobalChars =
      retainedSourceChars() - (indexed?.source.length ?? 0) + script.source.length;
    if (projectedGlobalChars > MAX_SCRIPT_SOURCE_CHARS_GLOBAL) return;
    if (indexed) {
      store.hashCacheBytes = Math.max(0, store.hashCacheBytes - indexed.source.length);
      store.scriptsByHash.delete(script.scriptHash);
    }
    store.scriptsByHash.set(script.scriptHash, script);
    store.hashCacheBytes += script.source.length;
  }

  while (
    store.scriptsByHash.size > MAX_HASH_CACHE_ENTRIES_PER_CLIENT ||
    store.hashCacheBytes > MAX_HASH_CACHE_CHARS_PER_CLIENT
  ) {
    const oldest = store.scriptsByHash.entries().next().value as
      | [string, StoredScriptSource]
      | undefined;
    if (!oldest) break;
    store.scriptsByHash.delete(oldest[0]);
    store.hashCacheBytes = Math.max(
      0,
      store.hashCacheBytes - oldest[1].source.length
    );
  }
}

function canActivateScriptSource(
  store: ClientScriptSourceStore,
  input: UpsertScriptSourcesInput,
  inputRevision: number | undefined,
  debugId: string
): boolean {
  if (!store.mappingSessionId) return true;
  if (input.mappingSessionId !== store.mappingSessionId || inputRevision === undefined) return false;
  return inputRevision > (store.activeRevisionByScriptId.get(debugId) ?? -1);
}

function getScriptSourceIndexSummary(
  identity: ScriptSourceStoreIdentity,
  store: ClientScriptSourceStore
): ScriptSourceIndexSummary {
  const mappedSources = store.mappingSessionId
    ? store.activeScripts.size
    : store.scripts.size;
  const processedSources = Math.max(store.processedSources, mappedSources);
  const sourceGap = Math.max(store.skippedSources, store.sourcesToMap - mappedSources, 0);
  return {
    clientId: identity.clientId,
    placeId: store.placeId,
    jobId: store.jobId,
    hasFinishedMapping: store.hasFinishedMapping,
    mappedSources,
    processedSources,
    skippedSources: store.skippedSources,
    sourcesToMap: store.sourcesToMap,
    sourceGap,
    sourceIndexComplete:
      store.hasFinishedMapping &&
      processedSources >= store.sourcesToMap &&
      sourceGap === 0,
    mappingSessionId: store.mappingSessionId,
    mappingRevision: store.mappingRevision >= 0 ? store.mappingRevision : undefined,
  };
}

interface MappingRevisionDecision {
  acceptsStatus: boolean;
  acceptedMappingRevision?: number;
}

function applyMappingRevision(
  store: ClientScriptSourceStore,
  input: UpsertScriptSourcesInput
): MappingRevisionDecision {
  const usesRevisionProtocol =
    input.mappingSessionId !== undefined || input.mappingRevision !== undefined;
  if (!usesRevisionProtocol) return { acceptsStatus: true };

  const sessionId =
    typeof input.mappingSessionId === "string" && input.mappingSessionId.length <= 160
      ? input.mappingSessionId
      : undefined;
  const revision =
    typeof input.mappingRevision === "number" && Number.isSafeInteger(input.mappingRevision)
      ? input.mappingRevision
      : undefined;
  const sessionStartedAt =
    typeof input.mappingSessionStartedAt === "number" &&
    Number.isSafeInteger(input.mappingSessionStartedAt) &&
    input.mappingSessionStartedAt >= 0
      ? input.mappingSessionStartedAt
      : undefined;

  if (!sessionId || revision === undefined || revision < 0) {
    return {
      acceptsStatus: false,
      acceptedMappingRevision: store.mappingRevision,
    };
  }

  if (input.beginMappingSession === true && store.mappingSessionId !== sessionId) {
    if (
      sessionStartedAt === undefined ||
      (store.mappingSessionStartedAt !== undefined &&
        sessionStartedAt <= store.mappingSessionStartedAt)
    ) {
      return {
        acceptsStatus: false,
        acceptedMappingRevision: store.mappingRevision,
      };
    }
    store.mappingSessionId = sessionId;
    store.mappingSessionStartedAt = sessionStartedAt;
    store.mappingRevision = -1;
    store.activeScripts.clear();
    store.activeRevisionByScriptId.clear();
    store.hasFinishedMapping = false;
    store.processedSources = 0;
    store.skippedSources = 0;
    store.sourcesToMap = 0;
  }

  if (store.mappingSessionId !== sessionId || revision <= store.mappingRevision) {
    return {
      acceptsStatus: false,
      acceptedMappingRevision: store.mappingRevision,
    };
  }
  store.mappingSessionId = sessionId;
  store.mappingRevision = revision;
  return { acceptsStatus: true, acceptedMappingRevision: revision };
}

export function upsertScriptSources(
  identity: ScriptSourceStoreIdentity,
  input: UpsertScriptSourcesInput
): ScriptSourceUpsertResult {
  const store = getOrCreateStore(identity);
  const revision = applyMappingRevision(store, input);
  const inputRevision =
    typeof input.mappingRevision === "number" && Number.isSafeInteger(input.mappingRevision)
      ? input.mappingRevision
      : undefined;

  if (revision.acceptsStatus && typeof input.hasFinishedMapping === "boolean") {
    store.hasFinishedMapping = input.hasFinishedMapping;
  }

  if (revision.acceptsStatus && typeof input.sourcesToMap === "number" && Number.isFinite(input.sourcesToMap)) {
    store.sourcesToMap = Math.min(1_000_000, Math.max(0, Math.floor(input.sourcesToMap)));
  }

  if (revision.acceptsStatus && typeof input.processedSources === "number" && Number.isFinite(input.processedSources)) {
    store.processedSources = Math.min(1_000_000, Math.max(0, Math.floor(input.processedSources)));
  }

  if (revision.acceptsStatus && typeof input.skippedSources === "number" && Number.isFinite(input.skippedSources)) {
    store.skippedSources = Math.min(1_000_000, Math.max(0, Math.floor(input.skippedSources)));
  }

  for (const script of input.scripts ?? []) {
    if (
      store.mappingSessionId &&
      typeof input.mappingSessionId === "string" &&
      input.mappingSessionId !== store.mappingSessionId
    ) {
      continue;
    }
    if (
      typeof script.debugId !== "string" ||
      typeof script.path !== "string" ||
      typeof script.source !== "string" ||
      script.debugId.length === 0 ||
      script.debugId.length > 512 ||
      script.path.length === 0 ||
      script.path.length > 4096 ||
      script.source.length > MAX_SOURCE_CHARS
    ) {
      continue;
    }

    const existing = store.scripts.get(script.debugId);
    const sourceHash = hashSource(script.source);
    const scriptHash = normalizeScriptHash(script.scriptHash);

    if (existing && existing.sourceHash === sourceHash) {
      const updated = {
        ...existing,
        path: script.path,
        scriptHash: scriptHash ?? existing.scriptHash,
      };
      store.scripts.set(script.debugId, updated);
      updateScriptHashIndex(store, updated);
      if (canActivateScriptSource(store, input, inputRevision, script.debugId)) {
        store.activeScripts.set(script.debugId, updated);
        if (inputRevision !== undefined) {
          store.activeRevisionByScriptId.set(script.debugId, inputRevision);
        }
      }
      continue;
    }

    if (!existing && store.scripts.size >= MAX_SCRIPTS_PER_CLIENT) continue;
    const projectedBytes =
      store.scriptBytes - (existing?.source.length ?? 0) + script.source.length;
    if (projectedBytes > MAX_SCRIPT_SOURCE_CHARS_PER_CLIENT) continue;
    const projectedGlobalChars =
      retainedSourceChars() - (existing?.source.length ?? 0) + script.source.length;
    if (projectedGlobalChars > MAX_SCRIPT_SOURCE_CHARS_GLOBAL) continue;

    const updated: StoredScriptSource = {
      debugId: script.debugId,
      path: script.path,
      source: script.source,
      scriptHash,
      sourceHash,
      updatedAt: Date.now(),
    };
    store.scripts.set(script.debugId, updated);
    store.scriptBytes = projectedBytes;
    updateScriptHashIndex(store, updated);
    if (canActivateScriptSource(store, input, inputRevision, script.debugId)) {
      store.activeScripts.set(script.debugId, updated);
      if (inputRevision !== undefined) {
        store.activeRevisionByScriptId.set(script.debugId, inputRevision);
      }
    }
  }

  // Tombstones are status-bearing operations and must obey revision ordering.
  // Source payloads may safely heal from stale same-session requests, but a
  // stale removal must never delete a script that a newer revision re-added.
  if (revision.acceptsStatus && Array.isArray(input.removedScriptIds)) {
    for (const debugId of input.removedScriptIds) {
      if (typeof debugId !== "string" || debugId.length === 0 || debugId.length > 512) continue;
      store.activeScripts.delete(debugId);
      if (inputRevision !== undefined) store.activeRevisionByScriptId.set(debugId, inputRevision);
    }
  }

  return {
    ...getScriptSourceIndexSummary(identity, store),
    acceptedMappingRevision: revision.acceptedMappingRevision,
  };
}

export function getCachedScriptSourcesByScriptHashResult(
  identity: ScriptSourceStoreIdentity,
  scriptHashes: unknown[]
): CachedScriptSourceResult {
  const store = getOrCreateStore(identity);
  const wanted = new Set<string>();
  let omitted = 0;
  for (const hash of scriptHashes) {
    const normalized = normalizeScriptHash(hash);
    if (!normalized || wanted.has(normalized)) continue;
    if (wanted.size >= 2_048) {
      omitted += 1;
      continue;
    }
    wanted.add(normalized);
  }

  if (wanted.size === 0) return { sources: [], limited: omitted > 0, omitted };

  const results: CachedScriptSourceByHash[] = [];
  let resultChars = 0;
  for (const scriptHash of wanted) {
    const script = store.scriptsByHash.get(scriptHash);
    if (!script) continue;
    if (results.length >= 64) {
      omitted += 1;
      continue;
    }
    const encodedChars =
      JSON.stringify(script.source).length +
      script.path.length +
      script.debugId.length +
      scriptHash.length +
      256;
    if (resultChars + encodedChars > 8 * 1024 * 1024) {
      omitted += 1;
      continue;
    }
    results.push({
      scriptHash,
      debugId: script.debugId,
      path: script.path,
      source: script.source,
      sourceHash: script.sourceHash,
      updatedAt: script.updatedAt,
    });
    resultChars += encodedChars;
  }

  return { sources: results, limited: omitted > 0, omitted };
}

export function getCachedScriptSourcesByScriptHash(
  identity: ScriptSourceStoreIdentity,
  scriptHashes: unknown[]
): CachedScriptSourceByHash[] {
  return getCachedScriptSourcesByScriptHashResult(identity, scriptHashes).sources;
}

export function getScriptSourceIndex(identity: ScriptSourceStoreIdentity): ScriptSourceIndex {
  const store = getOrCreateStore(identity);
  const scripts = store.mappingSessionId
    ? [...store.activeScripts.values()]
    : [...store.scripts.values()];
  return {
    ...getScriptSourceIndexSummary(identity, store),
    scripts,
  };
}

export function clearScriptSourceIndex(clientId: string): void {
  storesByClientId.delete(clientId);
  clearSemanticIndexForClient(clientId);
}

export function getScriptSourceStoreStats(): {
  clients: number;
  retainedSourceChars: number;
  maxRetainedSourceChars: number;
} {
  return {
    clients: storesByClientId.size,
    retainedSourceChars: retainedSourceChars(),
    maxRetainedSourceChars: MAX_SCRIPT_SOURCE_CHARS_GLOBAL,
  };
}
