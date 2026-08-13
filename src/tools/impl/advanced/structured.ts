import {
  DispatchAndWaitForResponse,
} from "../../../bridge/handlers/shared/communication.js";
import type { RobloxResponse } from "../../../bridge/types.js";
import {
  AMBIGUOUS_CLIENT_ERROR,
  BRIDGE_BUSY_ERROR,
  CLIENT_QUEUE_FULL_ERROR,
  INVALID_CLIENT_ERROR,
  NO_CLIENT_ERROR,
} from "../../errors.js";
import {
  clientStampPrefix,
  describeResponse,
  formatToolText,
  type ToolTextResponse,
} from "../../factory.js";

export interface StructuredDispatchOptions {
  type: string;
  data: Record<string, unknown>;
  clientId?: string;
  timeoutMs?: number;
  maxOutputChars?: number;
  truncationHint?: string;
  stampClient?: boolean;
  failureMessage?: (response: RobloxResponse | undefined) => string;
}

function isStructuredObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export async function sendAndWaitStructured(
  options: StructuredDispatchOptions
): Promise<ToolTextResponse> {
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
  if (response === undefined || response.error !== undefined || response.output === undefined) {
    return {
      content: [
        {
          type: "text",
          text:
            options.failureMessage?.(response) ??
            `Failed to ${options.type}: ${describeResponse(response)}`,
        },
      ],
      isError: true,
    };
  }

  const prefix = options.stampClient
    ? clientStampPrefix(response.clientId ?? options.clientId)
    : "";
  const content = formatToolText(prefix + response.output, {
    maxOutputChars: options.maxOutputChars,
    truncationHint: options.truncationHint,
  });
  if (!isStructuredObject(response.structured)) {
    return {
      content: [{ type: "text", text: content }],
      isError: true,
    };
  }

  return {
    content: [{ type: "text", text: content }],
    structuredContent: response.structured,
  };
}
