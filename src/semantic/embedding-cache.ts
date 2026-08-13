import fs from "node:fs/promises";
import path from "node:path";
import { SEMANTIC_CONFIG_DIR } from "./settings.js";

export const SEMANTIC_EMBEDDINGS_PATH = path.join(
  SEMANTIC_CONFIG_DIR,
  "semantic-embeddings.json"
);

interface PersistedEmbeddingEntry {
  embedding: number[];
  updatedAt: number;
}

interface PersistedEmbeddingCache {
  version?: number;
  entries?: Record<string, PersistedEmbeddingEntry>;
}

const CACHE_VERSION = 1;
const MAX_CACHE_FILE_BYTES = 64 * 1024 * 1024;
const MAX_CACHE_ENTRIES = 10_000;
const MAX_TOTAL_VECTOR_VALUES = 4_000_000;
const MAX_VECTOR_DIMENSIONS = 65_536;
let hasLoaded = false;
let loadPromise: Promise<void> | null = null;
let writeQueue: Promise<void> = Promise.resolve();
const entries = new Map<string, PersistedEmbeddingEntry>();

function isEmbedding(value: unknown): value is number[] {
  return (
    Array.isArray(value) &&
    value.length > 0 &&
    value.length <= MAX_VECTOR_DIMENSIONS &&
    value.every((item) => typeof item === "number" && Number.isFinite(item))
  );
}

function pruneEntries(): void {
  let totalValues = 0;
  for (const entry of entries.values()) totalValues += entry.embedding.length;
  while (entries.size > MAX_CACHE_ENTRIES || totalValues > MAX_TOTAL_VECTOR_VALUES) {
    const oldestKey = entries.keys().next().value as string | undefined;
    if (oldestKey === undefined) break;
    const oldest = entries.get(oldestKey);
    entries.delete(oldestKey);
    totalValues -= oldest?.embedding.length ?? 0;
  }
}

async function loadCache(): Promise<void> {
  try {
    const stat = await fs.stat(SEMANTIC_EMBEDDINGS_PATH);
    if (stat.size > MAX_CACHE_FILE_BYTES) {
      throw new Error(`Embedding cache exceeds the ${MAX_CACHE_FILE_BYTES} byte limit.`);
    }
    const raw = await fs.readFile(SEMANTIC_EMBEDDINGS_PATH, "utf8");
    const parsed = JSON.parse(raw) as PersistedEmbeddingCache;
    if (parsed.version !== CACHE_VERSION || !parsed.entries) return;

    const valid = Object.entries(parsed.entries)
      .filter(([key, entry]) =>
        key.length <= 4096 && Boolean(entry) && isEmbedding(entry.embedding)
      )
      .sort((left, right) =>
        (Number(left[1].updatedAt) || 0) - (Number(right[1].updatedAt) || 0)
      );
    for (const [key, entry] of valid) {
      entries.set(key, {
        embedding: entry.embedding,
        updatedAt:
          typeof entry.updatedAt === "number" && Number.isFinite(entry.updatedAt)
            ? entry.updatedAt
            : 0,
      });
    }
    pruneEntries();
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code !== "ENOENT") {
      console.error(`[Semantic] Failed to load embedding cache: ${String(error)}`);
    }
  }
}

async function ensureLoaded(): Promise<void> {
  if (hasLoaded) return;
  loadPromise ??= loadCache().finally(() => {
    hasLoaded = true;
    loadPromise = null;
  });
  await loadPromise;
}

async function writeCache(): Promise<void> {
  await fs.mkdir(SEMANTIC_CONFIG_DIR, { recursive: true });
  pruneEntries();
  let serialized = "";
  while (true) {
    const payload: PersistedEmbeddingCache = {
      version: CACHE_VERSION,
      entries: Object.fromEntries(entries),
    };
    serialized = JSON.stringify(payload);
    if (Buffer.byteLength(serialized, "utf8") <= MAX_CACHE_FILE_BYTES) break;
    const oldestKey = entries.keys().next().value as string | undefined;
    if (oldestKey === undefined) throw new Error("Embedding cache payload is too large.");
    entries.delete(oldestKey);
  }
  const tmpPath = `${SEMANTIC_EMBEDDINGS_PATH}.tmp`;
  await fs.writeFile(tmpPath, serialized, { mode: 0o600 });
  await fs.rename(tmpPath, SEMANTIC_EMBEDDINGS_PATH);
  await fs.chmod(SEMANTIC_EMBEDDINGS_PATH, 0o600).catch(() => undefined);
}

export async function readPersistedEmbedding(key: string): Promise<number[] | undefined> {
  await ensureLoaded();
  const entry = entries.get(key);
  if (!entry) return undefined;
  entries.delete(key);
  entries.set(key, entry);
  return entry.embedding;
}

export async function writePersistedEmbeddings(
  vectors: { key: string; embedding: number[] }[]
): Promise<void> {
  if (vectors.length === 0) return;

  await ensureLoaded();
  const updatedAt = Date.now();
  for (const vector of vectors) {
    if (vector.key.length > 4096 || !isEmbedding(vector.embedding)) continue;
    entries.delete(vector.key);
    entries.set(vector.key, { embedding: vector.embedding, updatedAt });
  }
  const queuedWrite = writeQueue.catch(() => undefined).then(writeCache);
  writeQueue = queuedWrite;
  await queuedWrite;
}

export async function clearPersistedEmbeddings(): Promise<void> {
  await loadPromise?.catch(() => undefined);
  hasLoaded = true;
  entries.clear();
  await fs.rm(SEMANTIC_EMBEDDINGS_PATH, { force: true }).catch(() => undefined);
}

export function getPersistedEmbeddingCacheStats(): {
  entries: number;
  vectorValues: number;
} {
  let vectorValues = 0;
  for (const entry of entries.values()) vectorValues += entry.embedding.length;
  return { entries: entries.size, vectorValues };
}
