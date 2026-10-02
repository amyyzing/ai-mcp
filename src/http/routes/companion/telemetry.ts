import type { RouteHandler } from "../../types.js";
import { readBody } from "../../body.js";
import { companions } from "../../../observation/companions.js";
export const POST: RouteHandler = async (req, res) => {
  const token = /^Bearer ([A-Za-z0-9_-]+)$/.exec(req.headers.authorization || "")?.[1] || "";
  try { companions.authorize(token, "server"); } catch { res.writeHead(403); res.end(); return; }
  try {
    const result = companions.telemetry(token, JSON.parse(await readBody(req, 64000)));
    res.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" }); res.end(JSON.stringify(result));
  } catch { res.writeHead(422, { "Content-Type": "application/json" }); res.end(JSON.stringify({ error: "Telemetry rejected: invalid scope, sequence, or batch." })); }
};
