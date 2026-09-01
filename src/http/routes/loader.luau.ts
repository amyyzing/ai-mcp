import type { IncomingMessage, ServerResponse } from "node:http";

import { getConnectorAuthToken } from "../bridge-auth.js";
import {
  DEFAULT_BRIDGE_URL,
  buildLoaderSnippet,
} from "../../shared/connector-snippet.mjs";

function bridgeUrlForRequest(req: IncomingMessage): string {
  const railwayDomain = process.env.RAILWAY_PUBLIC_DOMAIN?.trim();
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
  const source = buildLoaderSnippet(bridgeUrlForRequest(req), getConnectorAuthToken());
  res.writeHead(200, {
    "Content-Type": "text/plain; charset=utf-8",
    "Cache-Control": "no-store",
  });
  res.end(source);
}
