import type { IncomingMessage, ServerResponse } from "node:http";

let primaryReady = false;

// Only the primary listener marks readiness, after HTTP routes and WebSocket
// handlers are installed. No Roblox client connection is required to be ready.
export function setPrimaryReady(ready: boolean): void {
  primaryReady = ready;
}

export function GET(_req: IncomingMessage, res: ServerResponse): void {
  res.writeHead(primaryReady ? 200 : 503, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
  });
  res.end(JSON.stringify({ status: primaryReady ? "ready" : "starting" }));
}
