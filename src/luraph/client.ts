import { readBoundedResponseText } from "../shared/bounded-response.js";

const MAX_WORKER_RESPONSE_BYTES = 8 * 1024 * 1024;
const DEFAULT_TIMEOUT_SECONDS = 180;
const MAX_TIMEOUT_SECONDS = 600;

export type LuraphCaptureMode = "strict" | "sandboxed";

export interface LuraphWorkerResult {
  ok: boolean;
  error?: string;
  outputFile?: string;
  source?: string;
  sourceChars?: number;
  sourceTruncated?: boolean;
  quality?: Record<string, unknown>;
  log?: string;
  durationMs?: number;
}

function workerUrl(): URL {
  const configured = process.env.LURAPH_WORKER_URL?.trim();
  if (!configured) {
    throw new Error(
      "Luraph worker is not configured. Set LURAPH_WORKER_URL to the private Railway worker URL."
    );
  }
  const url = new URL(configured);
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new Error("LURAPH_WORKER_URL must use http:// or https://.");
  }
  return url;
}

function timeoutSeconds(value: number | undefined): number {
  if (!Number.isFinite(value)) return DEFAULT_TIMEOUT_SECONDS;
  return Math.min(MAX_TIMEOUT_SECONDS, Math.max(30, Math.floor(value!)));
}

function workerHeaders(): Record<string, string> {
  const token = process.env.LURAPH_WORKER_TOKEN?.trim();
  if (!token) {
    throw new Error(
      "Luraph worker authentication is not configured. Set LURAPH_WORKER_TOKEN on the MCP service."
    );
  }
  return {
    "Content-Type": "application/json",
    Authorization: `Bearer ${token}`,
  };
}

export async function requestLuraphDevirtualization(input: {
  source: string;
  captureMode: LuraphCaptureMode;
  timeoutSeconds?: number;
  maxResultChars?: number;
}): Promise<LuraphWorkerResult> {
  const timeout = timeoutSeconds(input.timeoutSeconds);
  const url = new URL("devirtualize", workerUrl().toString().replace(/\/?$/, "/"));
  const response = await fetch(url, {
    method: "POST",
    headers: workerHeaders(),
    signal: AbortSignal.timeout((timeout + 30) * 1000),
    body: JSON.stringify({
      source: input.source,
      captureMode: input.captureMode,
      timeoutSeconds: timeout,
      maxResultChars: input.maxResultChars,
    }),
  });
  const raw = await readBoundedResponseText(response, MAX_WORKER_RESPONSE_BYTES);
  let result: LuraphWorkerResult;
  try {
    result = JSON.parse(raw) as LuraphWorkerResult;
  } catch {
    throw new Error(`Luraph worker returned invalid JSON (HTTP ${response.status}).`);
  }
  if (!response.ok || result.ok !== true) {
    throw new Error(result.error || `Luraph worker returned HTTP ${response.status}.`);
  }
  if (
    typeof result.source !== "string" ||
    result.source.length === 0 ||
    typeof result.outputFile !== "string" ||
    !result.outputFile
  ) {
    throw new Error("Luraph worker completed without a recovered source artifact.");
  }
  if (result.sourceChars !== undefined && !Number.isSafeInteger(result.sourceChars)) {
    delete result.sourceChars;
  }
  if (result.durationMs !== undefined && !Number.isFinite(result.durationMs)) {
    delete result.durationMs;
  }
  if (result.quality !== undefined && (
    typeof result.quality !== "object" ||
    result.quality === null ||
    Array.isArray(result.quality)
  )) {
    delete result.quality;
  }
  return result;
}
