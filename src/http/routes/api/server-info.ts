import type { IncomingMessage, ServerResponse } from "http";
import {
  coreInstanceId,
  INSTALLATION_ID,
  serverStartTime,
} from "../../../config.js";
import { getActiveClients } from "../../../bridge/handlers/shared/registry.js";
import { getActiveMcpSessionCount } from "../mcp.js";


export function GET(_req: IncomingMessage, res: ServerResponse): void {
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(
    JSON.stringify({
      startTime: serverStartTime,
      pid: process.pid,
      instanceId: coreInstanceId,
      installationId: INSTALLATION_ID,
      clientCount: getActiveClients().length,
      mcpSessionCount: getActiveMcpSessionCount(),
      version: "1.0.0",
      architecture: "background-core",
    })
  );
}
