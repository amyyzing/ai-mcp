import fs from "node:fs";
import path from "node:path";
import type { IncomingMessage, ServerResponse } from "node:http";
import { assetsDir } from "../../paths.js";

const assetPath = path.join(assetsDir, "dashboard", "theme-bootstrap.js");
let cached: string | null = null;

export function GET(_req: IncomingMessage, res: ServerResponse): void {
  cached ??= fs.readFileSync(assetPath, "utf8");
  res.writeHead(200, {
    "Content-Type": "application/javascript; charset=utf-8",
    "Cache-Control": "public, max-age=86400",
  });
  res.end(cached);
}
