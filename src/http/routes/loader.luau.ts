import type { IncomingMessage, ServerResponse } from "node:http";

import {
  getConnectorAuthToken,
  getRailwayPublicDomain,
  hasDistinctConnectorAuthToken,
} from "../bridge-auth.js";
import {
  DEFAULT_BRIDGE_URL,
  buildLoaderSnippet,
} from "../../shared/connector-snippet.mjs";

function bridgeUrlForRequest(req: IncomingMessage): string {
  const railwayDomain = getRailwayPublicDomain();
  if (railwayDomain) return `https://${railwayDomain}`;

  const host = req.headers.host;
  if (!host) return DEFAULT_BRIDGE_URL;

  const forwardedProto = req.headers["x-forwarded-proto"];
  const protocol =
    typeof forwardedProto === "string" && forwardedProto.split(",", 1)[0]?.trim() === "https"
      ? "https"
      : "http";
  try {
    const parsed = new URL(`${protocol}://${host}`);
    return `${parsed.protocol}//${parsed.host}`;
  } catch {
    return DEFAULT_BRIDGE_URL;
  }
}

export function GET(req: IncomingMessage, res: ServerResponse): void {
  if (process.env.ROBLOX_MCP_PUBLIC_LOADER?.trim() === "0") {
    res.writeHead(404, {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-store",
    });
    res.end("Hosted loader disabled.");
    return;
  }
  if (!hasDistinctConnectorAuthToken()) {
    res.writeHead(503, {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-store",
    });
    res.end(
      "Hosted loader unavailable: configure ROBLOX_MCP_CONNECTOR_TOKEN with a value " +
      "different from ROBLOX_MCP_AUTH_TOKEN. The authenticated /script.luau loader remains available."
    );
    return;
  }
  const source = buildLoaderSnippet(bridgeUrlForRequest(req), getConnectorAuthToken());
  res.writeHead(200, {
    "Content-Type": "text/plain; charset=utf-8",
    "Cache-Control": "no-store",
  });
  res.end(source);
}
