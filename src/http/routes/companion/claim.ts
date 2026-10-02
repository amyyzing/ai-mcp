import { z } from "zod";
import type { RouteHandler } from "../../types.js";
import { readBody } from "../../body.js";
import { companions } from "../../../observation/companions.js";
const schema = z.object({ pairingCode: z.string().min(20).max(100), label: z.string().min(1).max(100),
  bootId: z.string().min(1).max(100), deviceUnixMs: z.number().finite().nonnegative() }).strict();
export const POST: RouteHandler = async (req, res) => {
  try {
    const data = schema.parse(JSON.parse(await readBody(req, 2000)));
    const result = companions.claim(data.pairingCode, data.label, data.bootId, data.deviceUnixMs);
    res.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" }); res.end(JSON.stringify(result));
  } catch { res.writeHead(403, { "Content-Type": "application/json" }); res.end(JSON.stringify({ error: "Invalid, expired, or already used pairing code/request." })); }
};
