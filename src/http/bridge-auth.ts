import crypto from "node:crypto";
import type { IncomingMessage, ServerResponse } from "node:http";
import net from "node:net";

import { BRIDGE_HOST } from "../config.js";
import { isAuthorizedLocalAdminRequest, isLoopbackAddress } from "./local-admin.js";

export const BRIDGE_AUTH_HEADER = "x-roblox-mcp-token";

const configuredBridgeToken = process.env.ROBLOX_MCP_AUTH_TOKEN?.trim() || null;
const bridgeToken =
  configuredBridgeToken || crypto.randomBytes(32).toString("base64url");
const explicitlyAllowedHosts = new Set(
  (process.env.ROBLOX_MCP_ALLOWED_HOSTS || "")
    .split(",")
    .map(normalizeHostname)
    .filter(Boolean)
);

function normalizeHostname(value: string): string {
  return value.trim().toLowerCase().replace(/^\[|\]$/g, "").replace(/\.$/, "");
}

function hostIsAllowed(hostname: string): boolean {
  const normalized = normalizeHostname(hostname);
  if (!normalized) return false;
  if (explicitlyAllowedHosts.has(normalized)) return true;

  const configuredHost = normalizeHostname(BRIDGE_HOST);
  if (isLoopbackAddress(configuredHost)) return isLoopbackAddress(normalized);
  if (configuredHost === "0.0.0.0" || configuredHost === "::") {
    return isLoopbackAddress(normalized) || net.isIP(normalized) !== 0;
  }
  return normalized === configuredHost;
}

function tokensMatch(received: string): boolean {
  const expected = Buffer.from(bridgeToken);
  const actual = Buffer.from(received);
  return (
    expected.length === actual.length &&
    crypto.timingSafeEqual(expected, actual)
  );
}

function bearerToken(req: IncomingMessage): string | null {
  const authorization = req.headers.authorization;
  if (typeof authorization !== "string") return null;
  const match = /^Bearer\s+(.+)$/i.exec(authorization.trim());
  return match?.[1]?.trim() || null;
}

function requestToken(req: IncomingMessage, url: URL): string | null {
  const header = req.headers[BRIDGE_AUTH_HEADER];
  if (typeof header === "string" && header) return header;
  const bearer = bearerToken(req);
  if (bearer) return bearer;

  // Query credentials are supported only where Roblox's loader/WebSocket APIs
  // cannot reliably attach headers. Keeping them off ordinary API URLs avoids
  // leaking bridge credentials through logs, history, and copied links.
  const isWebSocket =
    typeof req.headers.upgrade === "string" &&
    req.headers.upgrade.toLowerCase() === "websocket";
  return url.pathname === "/script.luau" || isWebSocket
    ? url.searchParams.get("token")
    : null;
}

export function getBridgeAuthToken(): string {
  return bridgeToken;
}

export function hasConfiguredBridgeAuthToken(): boolean {
  return configuredBridgeToken !== null;
}

export function bridgeAuthHeaders(): Record<string, string> {
  return configuredBridgeToken
    ? { [BRIDGE_AUTH_HEADER]: configuredBridgeToken }
    : {};
}

export function isAllowedRequestOrigin(req: IncomingMessage): boolean {
  const fetchSite = req.headers["sec-fetch-site"];
  if (typeof fetchSite === "string" && fetchSite === "cross-site") return false;

  const host = req.headers.host;
  if (!host) return false;

  let requestedHost: string;
  try {
    requestedHost = new URL(`http://${host}`).hostname;
  } catch {
    return false;
  }
  if (!hostIsAllowed(requestedHost)) return false;

  const origin = req.headers.origin;
  if (origin === undefined) return true;
  if (typeof origin !== "string") return false;

  try {
    const parsed = new URL(origin);
    return (
      (parsed.protocol === "http:" || parsed.protocol === "https:") &&
      parsed.host === host
    );
  } catch {
    return false;
  }
}

export function requiresBridgeAuth(pathname: string): boolean {
  if (pathname === "/api/admin-session" || pathname === "/api/avatar") {
    return false;
  }
  if (pathname.startsWith("/api/")) return true;

  return (
    pathname === "/mcp" ||
    pathname === "/mcp-relay" ||
    pathname === "/register" ||
    pathname === "/poll" ||
    pathname === "/respond" ||
    pathname === "/script.luau" ||
    pathname === "/script-sources" ||
    pathname === "/script-source-cache" ||
    pathname === "/decompile" ||
    pathname === "/decompile-plan" ||
    pathname === "/decompiler-observations"
  );
}

export function isAuthorizedBridgeRequest(
  req: IncomingMessage,
  url: URL
): boolean {
  if (isAuthorizedLocalAdminRequest(req)) return true;

  const authRequired =
    configuredBridgeToken !== null ||
    !isLoopbackAddress(req.socket.remoteAddress);
  if (!authRequired) return true;

  const token = requestToken(req, url);
  return token !== null && tokensMatch(token);
}

export function rejectForbiddenRequest(
  res: ServerResponse,
  message: string
): void {
  res.writeHead(403, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
  });
  res.end(JSON.stringify({ error: message }));
}

export function setSecurityHeaders(res: ServerResponse): void {
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("Referrer-Policy", "no-referrer");
  res.setHeader("X-Frame-Options", "DENY");
  res.setHeader("Cross-Origin-Resource-Policy", "same-origin");
  res.setHeader(
    "Permissions-Policy",
    "camera=(), microphone=(), geolocation=(), payment=(), usb=()"
  );
  res.setHeader(
    "Content-Security-Policy",
    "default-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; " +
      "form-action 'self'; connect-src 'self'; img-src 'self' data:; " +
      "script-src 'self'; " +
      "style-src 'self' 'unsafe-inline'; font-src 'self'"
  );
}
