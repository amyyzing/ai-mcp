import { createServer, IncomingMessage, ServerResponse } from "http";
import { WebSocketServer } from "ws";
import {
  BRIDGE_HOST,
  WS_MAX_PAYLOAD_BYTES,
  WS_PORT,
} from "../../../config.js";
import {
  hasConfiguredBridgeAuthToken,
  hasConfiguredConnectorAuthToken,
  isAllowedRequestOrigin,
  isAuthorizedBridgeRequest,
} from "../../../http/bridge-auth.js";
import { isLoopbackAddress } from "../../../http/local-admin.js";
import { dispatchHttp, dispatchWs, loadRoutes } from "../../../http/router.js";
import { setPrimaryReady } from "../../../http/routes/health.js";
import {
  resetPrimaryState,
  setInstanceRole,
} from "../shared/communication.js";
import { resetRegistry } from "../shared/registry.js";

const MAX_CONNECTIONS = Math.min(
  2_048,
  Math.max(
    16,
    Number.parseInt(process.env.ROBLOX_MCP_MAX_CONNECTIONS || "", 10) || 256
  )
);

export async function startAsPrimary(): Promise<void> {
  setPrimaryReady(false);
  await loadRoutes();

  return new Promise((resolve, reject) => {
    setInstanceRole("primary");
    resetRegistry();
    resetPrimaryState();

    const httpServer = createServer((req: IncomingMessage, res: ServerResponse) => {
      void dispatchHttp(req, res);
    });
    httpServer.headersTimeout = 10_000;
    httpServer.requestTimeout = 120_000;
    httpServer.keepAliveTimeout = 5_000;
    httpServer.maxRequestsPerSocket = 1_000;
    httpServer.maxHeadersCount = 100;
    httpServer.maxConnections = MAX_CONNECTIONS;
    httpServer.on("close", () => setPrimaryReady(false));

    httpServer.on("error", (err: NodeJS.ErrnoException) => {
      setPrimaryReady(false);
      if (err.code === "EADDRINUSE") {
        reject(err);
      } else {
        console.error("[Primary] HTTP server error:", err);
        reject(err);
      }
    });

    httpServer.listen(WS_PORT, BRIDGE_HOST, () => {
      console.error(
        `[Primary] MCP Bridge listening on ${BRIDGE_HOST}:${WS_PORT} (WebSocket + HTTP)`
      );
      if (!isLoopbackAddress(BRIDGE_HOST)) {
        if (hasConfiguredBridgeAuthToken()) {
          console.error("[Security] Remote agent access requires ROBLOX_MCP_AUTH_TOKEN.");
          console.error(
            hasConfiguredConnectorAuthToken()
              ? "[Security] Roblox connectors use the separate ROBLOX_MCP_CONNECTOR_TOKEN."
              : "[Security] Roblox connectors currently share the agent token; set ROBLOX_MCP_CONNECTOR_TOKEN to isolate them."
          );
        } else {
          console.error(
            "[Security] Remote access uses an unprinted per-run pairing token. Configure ROBLOX_MCP_AUTH_TOKEN and a separate ROBLOX_MCP_CONNECTOR_TOKEN for persistent client setup."
          );
        }
      }

      const wss = new WebSocketServer({
        server: httpServer,
        maxPayload: WS_MAX_PAYLOAD_BYTES,
        verifyClient: ({ req }, done) => {
          const url = new URL(req.url || "/", "http://localhost");
          const allowed =
            isAllowedRequestOrigin(req) && isAuthorizedBridgeRequest(req, url);
          if (allowed) {
            done(true);
          } else {
            done(false, 403, "Bridge authentication or same-origin access required");
          }
        },
      });
      const responsiveSockets = new WeakSet<object>();
      wss.on("connection", (ws, req) => {
        if (wss.clients.size > MAX_CONNECTIONS) {
          ws.close(1013, "Connection limit reached");
          return;
        }
        responsiveSockets.add(ws);
        ws.on("pong", () => responsiveSockets.add(ws));
        dispatchWs(ws, req);
      });

      const heartbeat = setInterval(() => {
        for (const ws of wss.clients) {
          if (!responsiveSockets.has(ws)) {
            ws.terminate();
            continue;
          }
          responsiveSockets.delete(ws);
          ws.ping();
        }
      }, 30_000);
      heartbeat.unref();
      wss.on("close", () => clearInterval(heartbeat));

      setPrimaryReady(true);
      resolve();
    });
  });
}
