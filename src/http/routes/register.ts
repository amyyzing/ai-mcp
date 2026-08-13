import type { IncomingMessage, ServerResponse } from "http";
import {
  getClientBySessionId,
  registerClient,
} from "../../bridge/handlers/shared/registry.js";
import { readJsonBody } from "../body.js";
import {
  normalizeClientRegistration,
  normalizeResumeClientToken,
  type ClientRegistrationInput,
} from "../client-registration.js";
import { clientTokensMatch, createClientToken } from "../client-auth.js";

type RegisterBody = ClientRegistrationInput;

export async function POST(req: IncomingMessage, res: ServerResponse): Promise<void> {
  try {
    const info = await readJsonBody<RegisterBody>(req);
    const registration = normalizeClientRegistration(info);
    const existing = registration.sessionId
      ? getClientBySessionId(registration.sessionId)
      : undefined;
    if (
      existing &&
      !clientTokensMatch(existing, normalizeResumeClientToken(info.clientToken))
    ) {
      res.writeHead(403);
      res.end("Invalid client resume credential");
      return;
    }
    const clientToken = createClientToken();
    const clientId = registerClient({
      ...registration,
      clientToken,
      transport: "http",
    });
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ clientId, clientToken }));
  } catch (error) {
    const atCapacity =
      error instanceof Error && error.message.startsWith("Client limit reached");
    res.writeHead(atCapacity ? 503 : 400);
    res.end(atCapacity ? error.message : "Invalid JSON");
  }
}
