import crypto from "node:crypto";
import type { IncomingMessage } from "node:http";

import type { RobloxClient } from "../bridge/types.js";

export const CLIENT_AUTH_HEADER = "x-roblox-mcp-client-token";

export function createClientToken(): string {
  return crypto.randomBytes(32).toString("base64url");
}

export function clientTokensMatch(
  client: Pick<RobloxClient, "clientToken">,
  received: unknown
): boolean {
  if (typeof received !== "string" || !received) return false;
  const expectedBytes = Buffer.from(client.clientToken);
  const receivedBytes = Buffer.from(received);
  return (
    expectedBytes.length === receivedBytes.length &&
    crypto.timingSafeEqual(expectedBytes, receivedBytes)
  );
}

export function isAuthorizedClientRequest(
  req: IncomingMessage,
  client: Pick<RobloxClient, "clientToken">
): boolean {
  const token = req.headers[CLIENT_AUTH_HEADER];
  return clientTokensMatch(client, token);
}
