import type { WebSocket } from "ws";
import { handleRobloxResponse } from "../../bridge/handlers/shared/communication.js";
import {
  getClientIdByWs,
  getClientBySessionId,
  registerClient,
  unregisterClient,
} from "../../bridge/handlers/shared/registry.js";
import type { RobloxResponse } from "../../bridge/types.js";
import {
  normalizeClientRegistration,
  normalizeResumeClientToken,
  type ClientRegistrationInput,
} from "../client-registration.js";
import { clientTokensMatch, createClientToken } from "../client-auth.js";

interface RegisterMessage extends ClientRegistrationInput {
  type: "register";
}

export function WS(ws: WebSocket): void {
  console.error("[Primary] Roblox client connected via WebSocket (awaiting registration).");
  const registrationTimeout = setTimeout(() => {
    if (!getClientIdByWs(ws)) ws.close(1008, "Registration timed out");
  }, 10_000);
  registrationTimeout.unref();

  ws.on("message", (rawData) => {
    try {
      const data = JSON.parse(rawData.toString()) as RegisterMessage | RobloxResponse;

      if ((data as RegisterMessage).type === "register") {
        if (getClientIdByWs(ws)) {
          ws.close(1008, "Client already registered");
          return;
        }
        const info = data as RegisterMessage;
        const registration = normalizeClientRegistration(info);
        const existing = registration.sessionId
          ? getClientBySessionId(registration.sessionId)
          : undefined;
        if (
          existing &&
          !clientTokensMatch(existing, normalizeResumeClientToken(info.clientToken))
        ) {
          ws.close(1008, "Invalid client resume credential");
          return;
        }
        const clientToken = createClientToken();
        const clientId = registerClient({
          ...registration,
          clientToken,
          transport: "ws",
          ws,
        });
        clearTimeout(registrationTimeout);
        ws.send(JSON.stringify({ type: "registered", clientId, clientToken }));
        return;
      }

      if (!getClientIdByWs(ws)) {
        ws.close(1008, "Registration required");
        return;
      }
      const clientId = getClientIdByWs(ws);
      if (!clientId) {
        console.error("[Primary] Ignored response from an unregistered Roblox WebSocket.");
        return;
      }
      handleRobloxResponse(data as RobloxResponse, clientId);
    } catch (e) {
      if (e instanceof Error && e.message.startsWith("Client limit reached")) {
        ws.close(1013, "Client limit reached");
        return;
      }
      console.error("[Primary] Error parsing Roblox WS message:", e);
    }
  });

  ws.on("close", () => {
    clearTimeout(registrationTimeout);
    const clientId = getClientIdByWs(ws);
    if (clientId) unregisterClient(clientId);
    console.error("[Primary] Roblox client disconnected.");
  });
}
