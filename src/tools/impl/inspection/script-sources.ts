import {
  describeTargetResolutionFailure,
  resolveTargetClient,
} from "../../../bridge/handlers/shared/registry.js";
import {
  getScriptSourceIndex,
  type ScriptSourceIndex,
  type StoredScriptSource,
} from "../../../bridge/handlers/shared/script-source-store.js";
import { toolTextResponse, type ToolTextResponse } from "../../factory.js";

export type ScriptSearchDocument = StoredScriptSource;
export type ScriptSearchIndex = ScriptSourceIndex;

export type ScriptSearchIndexResult =
  | { ok: true; index: ScriptSearchIndex }
  | { ok: false; response: ToolTextResponse };

export function fetchScriptSearchIndex(
  options: { allowIncomplete?: boolean; clientId?: string } = {}
): ScriptSearchIndexResult {
  const target = resolveTargetClient(options.clientId);

  if (!target) {
    return {
      ok: false,
      response: toolTextResponse(
        describeTargetResolutionFailure(options.clientId),
        {},
        true
      ),
    };
  }

  const index = getScriptSourceIndex({
    clientId: target.clientId,
    placeId: target.placeId,
    jobId: target.jobId,
  });

  if (!options.allowIncomplete && !index.hasFinishedMapping) {
    return {
      ok: false,
      response: toolTextResponse(
        "The MCP server is still receiving script sources from the Roblox client " +
          `(${index.processedSources}/${index.sourcesToMap} processed, ${index.mappedSources} uploaded). Please try again later.`,
        {},
        true
      ),
    };
  }

  if (index.scripts.length === 0) {
    return {
      ok: false,
      response: toolTextResponse(
        "No script sources have been received from the Roblox client yet.",
        {},
        true
      ),
    };
  }

  return { ok: true, index };
}
