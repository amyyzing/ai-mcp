import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import type { RouteHandler } from "../../types.js";
import { videoArtifact } from "../../../observation/artifacts.js";
// /api/* is agent-authenticated by the router. Upload-only credentials cannot download artifacts.
export const GET: RouteHandler = async (req, res, url) => {
  const id = url.searchParams.get("id") || "", file = videoArtifact(id);
  if (!file) { res.writeHead(404); res.end(); return; }
  try {
    const size = (await stat(file)).size;
    let start = 0, end = size - 1;
    if (req.headers.range) {
      const range = /^bytes=(\d+)-(\d*)$/.exec(req.headers.range);
      if (!range) { res.writeHead(416, { "Content-Range": `bytes */${size}` }); res.end(); return; }
      start = Number(range[1]); end = range[2] ? Math.min(Number(range[2]), size - 1) : end;
      if (start > end || !Number.isSafeInteger(start)) { res.writeHead(416, { "Content-Range": `bytes */${size}` }); res.end(); return; }
    }
    res.writeHead(req.headers.range ? 206 : 200, { "Content-Type": "video/mp4", "Content-Length": end - start + 1,
      "Accept-Ranges": "bytes", "Cache-Control": "no-store", "Content-Disposition": "inline; filename=capture.mp4",
      ...(req.headers.range ? { "Content-Range": `bytes ${start}-${end}/${size}` } : {}) });
    const stream = createReadStream(file, { start, end }); res.on("close", () => stream.destroy());
    stream.on("error", () => res.destroy()); stream.pipe(res);
  } catch { if (!res.headersSent) res.writeHead(404); res.end(); }
};
