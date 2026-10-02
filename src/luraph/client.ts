import { readBoundedResponseText } from "../shared/bounded-response.js";
import { createHash } from "node:crypto";

const MAX_WORKER_RESPONSE_BYTES = 16 * 1024 * 1024;
const DEFAULT_TIMEOUT_SECONDS = 180;
const MAX_TIMEOUT_SECONDS = 600;

export type LuraphCaptureMode = "strict" | "sandboxed";
export interface RecoveryArtifact {
  id: string;
  name: string;
  representation: string;
  validation: string;
  sha256: string;
  byteSize: number;
  lineCount?: number;
  contentBase64: string;
}

export interface LuraphWorkerResult {
  schemaVersion?: number;
  artifacts?: RecoveryArtifact[];
  omittedArtifacts?: unknown[];
  recoveryStatus?: string;
  engineExitCode?: number;
  diagnostics?: Array<Record<string, unknown>>;
  validation?: { semanticEquivalence: "not-tested"; liveRoblox: "not-tested" };
  inputSha256?: string;
  ok: boolean;
  error?: string;
  outputFile?: string;
  source?: string;
  sourceChars?: number;
  sourceTruncated?: boolean;
  quality?: Record<string, unknown>;
  qualityEvidence?: Array<{ path: Array<string | number>; value: unknown }>;
  qualityNotice?: string;
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
  if (!result || typeof result !== "object" || Array.isArray(result)) {
    throw new Error("Luraph worker returned an invalid result object.");
  }
  if (result.schemaVersion !== undefined && result.schemaVersion !== 2) {
    throw new Error("Unsupported Luraph worker schema version.");
  }
  if (result.schemaVersion === 2) {
    if (result.recoveryStatus !== "partial" && result.recoveryStatus !== "unverified") {
      throw new Error("Invalid recovery status.");
    }
    if (result.engineExitCode !== undefined && !Number.isSafeInteger(result.engineExitCode)) {
      throw new Error("Invalid engine exit code.");
    }
    if (result.engineExitCode && result.recoveryStatus !== "partial") {
      throw new Error("Failed engine result must be marked partial.");
    }
    if (result.diagnostics !== undefined && (!Array.isArray(result.diagnostics) ||
        result.diagnostics.length > 257 || result.diagnostics.some(d => !d || typeof d !== "object" || Array.isArray(d)))) {
      throw new Error("Invalid recovery diagnostics.");
    }
    if (result.validation !== undefined && (!result.validation ||
        result.validation.semanticEquivalence !== "not-tested" || result.validation.liveRoblox !== "not-tested")) {
      throw new Error("Unsupported recovery validation claim.");
    }
    if (result.qualityEvidence !== undefined && (!Array.isArray(result.qualityEvidence) ||
        result.qualityEvidence.length > 256 || result.qualityEvidence.some(e => !e ||
          !Array.isArray(e.path) || e.path.length > 34 || e.path.some(p => typeof p !== "string" && typeof p !== "number")))) {
      throw new Error("Invalid recovery quality evidence.");
    }
    if (result.omittedArtifacts !== undefined && (!Array.isArray(result.omittedArtifacts) || result.omittedArtifacts.length > 129)) {
      throw new Error("Invalid omitted artifact manifest.");
    }
    if (!Array.isArray(result.artifacts) || result.artifacts.length > 128 ||
        result.inputSha256 !== createHash("sha256").update(input.source).digest("hex")) {
      throw new Error("Invalid recovery artifact manifest or input hash.");
    }
    let total = 0;
    const ids = new Set<string>();
    for (const artifact of result.artifacts) {
      if (!artifact || typeof artifact.id !== "string" || ids.has(artifact.id) ||
          typeof artifact.name !== "string" || typeof artifact.representation !== "string" ||
          typeof artifact.validation !== "string" || typeof artifact.contentBase64 !== "string" ||
          !Number.isSafeInteger(artifact.byteSize) || artifact.byteSize < 0) {
        throw new Error("Invalid recovery artifact metadata.");
      }
      ids.add(artifact.id);
      const bytes = Buffer.from(artifact.contentBase64, "base64");
      total += bytes.length;
      if (total > 4 * 1024 * 1024 || bytes.length !== artifact.byteSize ||
          bytes.toString("base64") !== artifact.contentBase64 ||
          createHash("sha256").update(bytes).digest("hex") !== artifact.sha256) {
        throw new Error("Recovery artifact failed byte-size or hash verification.");
      }
    }
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
