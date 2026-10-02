import type { IncomingMessage, ServerResponse } from "http";
import { enumRobloxWindows, isSupported } from "../../../platform/windows-screenshot.js";

export async function GET(_req: IncomingMessage, res: ServerResponse): Promise<void> {
  try {
    if (!isSupported()) {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "Window enumeration is only supported on Windows." }));
      return;
    }
    const windows = await enumRobloxWindows();
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ windows }));
  } catch (err) {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(
      JSON.stringify({ error: `Window enumeration failed: ${(err as Error).message || err}` })
    );
  }
}
