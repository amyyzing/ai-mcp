import {
  DispatchAndWaitForResponse,
} from "../../../bridge/handlers/shared/communication.js";
import type { RobloxResponse } from "../../../bridge/types.js";
import {
  clientStampPrefix,
  describeResponse,
  formatToolText,
  responseFailed,
  responseText,
  dispatchFailureResponse,
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
  const dispatchFailure = dispatchFailureResponse(dispatch, options.clientId);
  if (dispatchFailure) return dispatchFailure;
  const output = responseText(response);
  if (responseFailed(response) || output === undefined) {
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
    ? clientStampPrefix(response!.clientId ?? options.clientId)
    : "";
  const content = formatToolText(prefix + output, {
    maxOutputChars: options.maxOutputChars,
    truncationHint: options.truncationHint,
  });
  if (!isStructuredObject(response!.structured)) {
    return {
      content: [{ type: "text", text: content }],
      isError: true,
    };
  }

  return {
    content: [{ type: "text", text: content }],
    structuredContent: response!.structured,
  };
}
