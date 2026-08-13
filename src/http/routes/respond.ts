import type { IncomingMessage, ServerResponse } from "http";
import { handleRobloxResponse } from "../../bridge/handlers/shared/communication.js";
import { getClientById } from "../../bridge/handlers/shared/registry.js";
import type { RobloxResponse } from "../../bridge/types.js";
import { readJsonBody } from "../body.js";
import { isAuthorizedClientRequest } from "../client-auth.js";

export async function POST(
  req: IncomingMessage,
  res: ServerResponse,
  url: URL
): Promise<void> {
  try {
    const clientId = url.searchParams.get("clientId");
    const client = clientId ? getClientById(clientId) : undefined;
    if (!clientId || !client || client.transport !== "http") {
      res.writeHead(403);
      res.end("Unknown HTTP client");
      return;
    }
    if (!isAuthorizedClientRequest(req, client)) {
      res.writeHead(403);
      res.end("Invalid client credential");
      return;
    }
    const data = await readJsonBody<RobloxResponse>(req);
    if (!handleRobloxResponse(data, clientId)) {
      res.writeHead(409);
      res.end("Response did not match a pending request");
      return;
    }
    res.writeHead(200);
    res.end("OK");
  } catch {
    res.writeHead(400);
    res.end("Invalid JSON");
  }
}
