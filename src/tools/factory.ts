import {
  DispatchAndWaitForResponse,
  getInstanceRole,
} from "../bridge/handlers/shared/communication.js";
import { resolveTargetClient } from "../bridge/handlers/shared/registry.js";
import { RobloxResponse } from "../bridge/types.js";
import { BASE_URL, WS_PORT } from "../config.js";
import { bridgeAuthHeaders } from "../http/bridge-auth.js";
import { readBoundedResponseText } from "../shared/bounded-response.js";
import { AMBIGUOUS_CLIENT_ERROR, BRIDGE_BUSY_ERROR, CLIENT_QUEUE_FULL_ERROR, INVALID_CLIENT_ERROR, NO_CLIENT_ERROR } from "./errors.js";

export const DEFAULT_TOOL_OUTPUT_CHAR_LIMIT = 6000;
export const HARD_TOOL_OUTPUT_CHAR_LIMIT = 32000;
export const MAX_ERROR_RESPONSE_CHARS = 500;
const MAX_RELAY_JSON_BYTES = 1024 * 1024;

async function readRelayJson(response: Response): Promise<Record<string, unknown>> {
  const raw = await readBoundedResponseText(response, MAX_RELAY_JSON_BYTES);
  if (!response.ok) {
    throw new Error(`Primary returned HTTP ${response.status}: ${raw.slice(0, 300)}`);
  }
  try {
    return JSON.parse(raw) as Record<string, unknown>;
  } catch {
    throw new Error(`Primary returned invalid JSON: ${raw.slice(0, 300)}`);
  }
}

/**
 * Check if the current instance is a secondary relay.
 * Secondaries can be created either via --baseurl or automatically when
 * the port is already in use (EADDRINUSE fallback).
 */
export function isSecondaryRelay(): boolean {
  return getInstanceRole() === "secondary";
}

/**
 * Get the base URL of the primary server.
 * If --baseurl was specified, use that. Otherwise fall back to localhost.
 */
function getPrimaryBaseUrl(): string {
  if (BASE_URL) return BASE_URL.replace(/\/$/, "");
  return `http://localhost:${WS_PORT}`;
}

/**
 * Relay a tool call to the primary's /api/tool HTTP endpoint.
 * Handles both immediate results and progress-job-based async responses
 * (polls /api/tool-progress until done).
 */
export async function relayToolToApi(
  type: string,
  params: Record<string, unknown>,
  timeoutMs: number = 60000,
  outputOptions: ToolOutputOptions = {}
): Promise<ToolTextResponse> {
  const primaryBase = getPrimaryBaseUrl();
  const toolUrl = primaryBase + "/api/tool";
  const deadline = Date.now() + Math.max(1000, timeoutMs);
  try {
    const resp = await fetch(toolUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...bridgeAuthHeaders(),
      },
      signal: AbortSignal.timeout(Math.max(1, deadline - Date.now())),
      body: JSON.stringify({
        type,
        ...params,
      }),
    });

    const data = await readRelayJson(resp);

    if (data.error) {
      return toolTextResponse(data.error as string, outputOptions, true);
    }

    // Immediate result
    if (data.result !== undefined) {
      const prefix =
        typeof data.clientId === "string" ? clientStampPrefix(data.clientId) : "";
      const response = toolTextResponse(prefix + String(data.result), outputOptions);
      if (
        data.structuredContent !== null &&
        typeof data.structuredContent === "object" &&
        !Array.isArray(data.structuredContent)
      ) {
        return {
          ...response,
          structuredContent: data.structuredContent as Record<string, unknown>,
        };
      }
      return response;
    }

    // Progress-job based (semantic search/index)
    if (data.jobId && data.progressUrl) {
      const progressUrl = primaryBase + (data.progressUrl as string);

      while (Date.now() < deadline) {
        await new Promise((r) =>
          setTimeout(r, Math.min(1000, Math.max(1, deadline - Date.now())))
        );
        if (Date.now() >= deadline) break;

        const progressResp = await fetch(progressUrl, {
          headers: bridgeAuthHeaders(),
          signal: AbortSignal.timeout(
            Math.max(1, Math.min(10_000, deadline - Date.now()))
          ),
        });
        const job = await readRelayJson(progressResp);

        if (job.status === "done") {
          const prefix =
            typeof data.clientId === "string" ? clientStampPrefix(data.clientId) : "";
          return toolTextResponse(prefix + String(job.result ?? "Done."), outputOptions);
        }
        if (job.status === "error" || job.status === "failed") {
          return toolTextResponse(`Failed: ${(job.error as string) ?? "Unknown error"}`, outputOptions, true);
        }
      }

      return toolTextResponse(
        `Primary job is still running after ${Math.ceil(timeoutMs / 1000)}s. ` +
        `jobId=${String(data.jobId)} progressUrl=${progressUrl}. ` +
        "The work was not discarded; query that authenticated progress URL to recover its result.",
        outputOptions
      );
    }

    return toolTextResponse(JSON.stringify(data), outputOptions);
  } catch (err) {
    return toolTextResponse(`Failed to relay to primary: ${(err as Error).message || err}`, outputOptions, true);
  }
}

export interface ToolTextResponse {
  [x: string]: unknown;
  content: { type: "text"; text: string }[];
  isError?: boolean;
}
/** Selection belongs to one MCP server/session, never the shared core. */
export interface ToolRoutingContext {
  selectedClientId?: string;
}

export function resolveToolClientId(
  inputClientId: string | undefined,
  routing: ToolRoutingContext
): string | undefined {
  const normalized = inputClientId?.trim();
  return normalized || routing.selectedClientId;
}

export interface ToolOutputOptions {
  maxOutputChars?: number;
  defaultMaxOutputChars?: number;
  truncationHint?: string;
}

export function normalizeMaxOutputChars(
  value: unknown,
  fallback: number = DEFAULT_TOOL_OUTPUT_CHAR_LIMIT
): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(HARD_TOOL_OUTPUT_CHAR_LIMIT, Math.max(1000, Math.floor(parsed)));
}

export function formatToolText(text: string, options: ToolOutputOptions = {}): string {
  const maxOutputChars = normalizeMaxOutputChars(
    options.maxOutputChars,
    options.defaultMaxOutputChars ?? DEFAULT_TOOL_OUTPUT_CHAR_LIMIT
  );

  if (text.length <= maxOutputChars) return text;

  const omitted = text.length - maxOutputChars;
  const hint =
    options.truncationHint ??
    "Rerun with narrower filters, line ranges, or a smaller maxOutputChars value.";

  // Head+tail truncation: keep the start (typically headers/most relevant)
  // AND the end (footers, continuation hints, last results) so tail-critical
  // information is not silently discarded (mitigates lost-in-the-middle).
  const marker = `\n\n[... ${omitted} characters omitted in the middle. ${hint} ...]\n\n`;
  const budget = maxOutputChars - marker.length;
  if (budget <= 0) {
    return text.slice(0, maxOutputChars);
  }
  const headChars = Math.ceil(budget * 0.7);
  const tailChars = budget - headChars;
  return text.slice(0, headChars) + marker + text.slice(text.length - tailChars);
}

export function toolTextResponse(
  text: string,
  options: ToolOutputOptions = {},
  isError = false
): ToolTextResponse {
  return {
    content: [{ type: "text", text: formatToolText(text, options) }],
    ...(isError ? { isError: true } : {}),
  };
}

/**
 * Build a compact one-line stamp identifying the client a result came from,
 * so the model does not blend stale results across clients (context poisoning).
 * Returns "" when it can't be resolved (e.g. secondary relay).
 */
export function clientStampPrefix(clientId?: string): string {
  const safe = (value: unknown, max = 120): string =>
    String(value ?? "?").replace(/[\u0000-\u001f\u007f]+/g, " ").slice(0, max);
  try {
    const target = resolveTargetClient(clientId);
    if (target) {
      const place = target.placeName || target.placeId || "?";
      return `[client=${safe(target.clientId)} place=${safe(place)} job=${safe(target.jobId)}]\n`;
    }
  } catch {
    // A secondary has no process-local client registry. The response-bound ID
    // still provides canonical provenance for context isolation.
  }
  return clientId ? `[client=${safe(clientId)}]\n` : "";
}

/**
 * Summarize a Roblox response for an error message without dumping the entire
 * (potentially large) object into the model context.
 */
export function describeResponse(response: RobloxResponse | undefined): string {
  if (response === undefined) return "no response (timed out).";
  if (response.error !== undefined) {
    return String(response.error).slice(0, MAX_ERROR_RESPONSE_CHARS);
  }
  const serialized = JSON.stringify(response);
  return serialized.length > MAX_ERROR_RESPONSE_CHARS
    ? serialized.slice(0, MAX_ERROR_RESPONSE_CHARS) + " …(truncated)"
    : serialized;
}

export interface SendAndWaitOptions {
  type: string;
  data: Record<string, unknown>;
  clientId?: string;
  timeoutMs?: number;
  maxOutputChars?: number;
  truncationHint?: string;
  failureField?: "output" | "error";
  failureMessage?: (response: RobloxResponse | undefined) => string;
  successMessage?: (response: RobloxResponse) => string;
  /** When true, prepend a one-line client identity stamp to successful output. */
  stampClient?: boolean;
}

/**
 * Dispatch a request to the Roblox client and wait for the response.
 * Handles the no-client / invalid-client / timeout boilerplate that every
 * tool used to repeat.
 */
export async function sendAndWait(options: SendAndWaitOptions): Promise<ToolTextResponse> {
  const { dispatch, response } = await DispatchAndWaitForResponse(
    options.type,
    options.data,
    options.clientId,
    options.timeoutMs
  );

  if (dispatch === null) return NO_CLIENT_ERROR;
  if (dispatch === "INVALID_CLIENT") return INVALID_CLIENT_ERROR;
  if (dispatch === "AMBIGUOUS_CLIENT") return AMBIGUOUS_CLIENT_ERROR;
  if (dispatch === "CLIENT_QUEUE_FULL") return CLIENT_QUEUE_FULL_ERROR;
  if (dispatch === "BRIDGE_BUSY") return BRIDGE_BUSY_ERROR;

  const failureField = options.failureField ?? "output";

  const isFailure =
    response === undefined ||
    (failureField === "error"
      ? response.error !== undefined
      : response.output === undefined);

  if (isFailure) {
    const text =
      options.failureMessage?.(response) ??
      `Failed to ${options.type}. Response: ${JSON.stringify(response)}`;
    return toolTextResponse(
      text,
      {
        maxOutputChars: options.maxOutputChars,
        truncationHint: options.truncationHint,
      },
      true
    );
  }

  const text =
    options.successMessage?.(response) ?? (response.output as string);
  const stamped = options.stampClient
    ? clientStampPrefix(response.clientId ?? options.clientId) + text
    : text;
  return toolTextResponse(stamped, {
    maxOutputChars: options.maxOutputChars,
    truncationHint: options.truncationHint,
  });
}
