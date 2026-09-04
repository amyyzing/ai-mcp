import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import {
  DispatchAndWaitForResponse,
  getInstanceRole,
  requestToClientId,
  secondaryResponseResolvers,
} from "../../../bridge/handlers/shared/communication.js";
import {
  getActiveClients,
  resolveTargetClient,
} from "../../../bridge/handlers/shared/registry.js";
import { getScriptSourceIndex } from "../../../bridge/handlers/shared/script-source-store.js";
import { getDecompilerHealthSnapshot } from "../../../decompiler/health.js";
import {
  AMBIGUOUS_CLIENT_ERROR,
  BRIDGE_BUSY_ERROR,
  CLIENT_QUEUE_FULL_ERROR,
  INVALID_CLIENT_ERROR,
  NO_CLIENT_ERROR,
} from "../../errors.js";
import {
  clientStampPrefix,
  resolveToolClientId,
  toolTextResponse,
  type ToolRoutingContext,
} from "../../factory.js";
import { clientIdSchema } from "../../schemas.js";

export interface RuntimeStatusServerSnapshot {
  hostCapabilities?: ReturnType<typeof hostInspectionCapabilities>;
  role: "primary" | "secondary";
  selectedClientId?: string;
  activeClientCount?: number;
  pendingCalls: number;
  roundTripLatencyMs: number;
  client?: {
    username: string;
    userId: number;
    placeId: number;
    placeName: string;
    jobId: string;
    transport: "ws" | "http";
  };
  scriptSync?: {
    hasFinishedMapping: boolean;
    mappedSources: number;
    processedSources: number;
    skippedSources: number;
    sourcesToMap: number;
    sourceGap: number;
    sourceIndexComplete: boolean;
  };
  decompilerHealth?: ReturnType<typeof getDecompilerHealthSnapshot>;
  relayLimitations?: string[];
}

export function hostInspectionCapabilities(platform: string = process.platform, role = getInstanceRole()) {
  return {
    platform,
    screenshotLocation: role === "secondary" ? "primary-host" : "this-host",
    screenshotBackend: role === "secondary" ? "primary-host-dependent" : platform === "win32" ? "windows" : "unavailable",
    screenshotAvailable: role === "secondary" ? null : platform === "win32",
    alternatives: ["dex-query", "dex-inspect", "dex-selection"],
    note: "OS screenshots run on the primary MCP host, not on the remote Roblox device. Dex metadata is not a pixel-level screenshot.",
  };
}

export function formatRuntimeStatus(
  serverSnapshot: RuntimeStatusServerSnapshot,
  connectorOutput: string
): string {
  return [
    "Server routing/status:",
    JSON.stringify(serverSnapshot, null, 2),
    "Connector runtime/capabilities:",
    connectorOutput,
  ].join("\n");
}

export default function register(server: McpServer, routing: ToolRoutingContext): void {
  const outputSchema = z.object({
    server: z.record(z.string(), z.unknown()),
    connector: z.record(z.string(), z.unknown()),
  });
  server.registerTool(
    "runtime-status",
    {
      title: "Get Roblox MCP runtime status and capabilities",
      description:
        "Probe the selected client and report routing identity, transport, measured round-trip latency, pending calls, source-sync health, decompiler health, mapping state, and executor capability flags.",
      inputSchema: z.object({ clientId: clientIdSchema }),
      outputSchema,
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    async ({ clientId }) => {
      const selectedClientId = resolveToolClientId(clientId, routing);
      const target = resolveTargetClient(selectedClientId);
      const startedAt = performance.now();
      const { dispatch, response } = await DispatchAndWaitForResponse(
        "runtime-status",
        {},
        selectedClientId,
        10000
      );

      if (dispatch === null) return NO_CLIENT_ERROR;
      if (dispatch === "INVALID_CLIENT") return INVALID_CLIENT_ERROR;
      if (dispatch === "AMBIGUOUS_CLIENT") return AMBIGUOUS_CLIENT_ERROR;
      if (dispatch === "CLIENT_QUEUE_FULL") return CLIENT_QUEUE_FULL_ERROR;
      if (dispatch === "BRIDGE_BUSY") return BRIDGE_BUSY_ERROR;
      if (!response) {
        return toolTextResponse("Runtime probe failed without a response.", {}, true);
      }
      if (response.error !== undefined || response.output === undefined) {
        return toolTextResponse(
          `Runtime probe failed: ${response.error ?? "No response output."}`,
          {},
          true
        );
      }
      if (
        response.structured === null ||
        typeof response.structured !== "object" ||
        Array.isArray(response.structured)
      ) {
        return toolTextResponse(
          "Runtime probe succeeded, but the connector did not return structured status. Rebuild and reload connector.luau.",
          {},
          true
        );
      }

      const roundTripLatencyMs = Math.max(0, Math.round(performance.now() - startedAt));
      const responseClientId = response.clientId ?? target?.clientId ?? selectedClientId;
      const scriptIndex = target
        ? getScriptSourceIndex({
            clientId: target.clientId,
            placeId: target.placeId,
            jobId: target.jobId,
          })
        : undefined;
      const snapshot: RuntimeStatusServerSnapshot = {
        hostCapabilities: hostInspectionCapabilities(),
        role: getInstanceRole(),
        selectedClientId: responseClientId,
        activeClientCount:
          getInstanceRole() === "primary" ? getActiveClients().length : undefined,
        pendingCalls:
          getInstanceRole() === "secondary"
            ? secondaryResponseResolvers.size
            : requestToClientId.size,
        roundTripLatencyMs,
        client: target
          ? {
              username: target.username,
              userId: target.userId,
              placeId: target.placeId,
              placeName: target.placeName,
              jobId: target.jobId,
              transport: target.transport,
            }
          : undefined,
        scriptSync: scriptIndex
          ? {
              hasFinishedMapping: scriptIndex.hasFinishedMapping,
              mappedSources: scriptIndex.mappedSources,
              processedSources: scriptIndex.processedSources,
              skippedSources: scriptIndex.skippedSources,
              sourcesToMap: scriptIndex.sourcesToMap,
              sourceGap: scriptIndex.sourceGap,
              sourceIndexComplete: scriptIndex.sourceIndexComplete,
            }
          : undefined,
        decompilerHealth: target
          ? getDecompilerHealthSnapshot(target.clientId)
          : undefined,
        relayLimitations:
          getInstanceRole() === "secondary"
            ? [
                "Client registry metadata, server-side scriptSync, and decompilerHealth live on the primary and are omitted from this relay-local server snapshot.",
              ]
            : undefined,
      };

      const textResponse = toolTextResponse(
        clientStampPrefix(responseClientId) + formatRuntimeStatus(snapshot, response.output),
        {
        defaultMaxOutputChars: 12000,
        }
      );
      return {
        ...textResponse,
        structuredContent: {
          server: snapshot as unknown as Record<string, unknown>,
          connector: response.structured as Record<string, unknown>,
        },
      };
    }
  );
}
