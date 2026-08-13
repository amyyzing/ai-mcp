import type { IncomingMessage } from "http";
import {
  DECOMPILE_BODY_LIMIT_BYTES,
  HTTP_BODY_LIMIT_BYTES,
  SCRIPT_UPLOAD_BODY_LIMIT_BYTES,
} from "../config.js";

export class RequestBodyTooLargeError extends Error {
  readonly statusCode = 413;

  constructor(readonly limitBytes: number) {
    super(`Request body exceeds the ${limitBytes} byte limit.`);
    this.name = "RequestBodyTooLargeError";
  }
}

export function requestBodyLimit(req: IncomingMessage): number {
  const pathname = new URL(req.url || "/", "http://localhost").pathname;
  if (pathname === "/decompile") return DECOMPILE_BODY_LIMIT_BYTES;
  if (pathname === "/script-sources") return SCRIPT_UPLOAD_BODY_LIMIT_BYTES;
  return HTTP_BODY_LIMIT_BYTES;
}

export function readBody(
  req: IncomingMessage,
  maxBytes: number = requestBodyLimit(req)
): Promise<string> {
  return new Promise((resolve, reject) => {
    const declaredLength = Number(req.headers["content-length"]);
    if (Number.isFinite(declaredLength) && declaredLength > maxBytes) {
      req.resume();
      reject(new RequestBodyTooLargeError(maxBytes));
      return;
    }

    const chunks: Buffer[] = [];
    let receivedBytes = 0;
    let exceeded = false;

    req.on("data", (chunk: Buffer | string) => {
      if (exceeded) return;
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      receivedBytes += buffer.length;
      if (receivedBytes > maxBytes) {
        exceeded = true;
        chunks.length = 0;
        reject(new RequestBodyTooLargeError(maxBytes));
        return;
      }
      chunks.push(buffer);
    });
    req.on("end", () => {
      if (!exceeded) resolve(Buffer.concat(chunks).toString("utf8"));
    });
    req.on("error", reject);
  });
}

export async function readJsonBody<T>(req: IncomingMessage): Promise<T> {
  const raw = await readBody(req);
  return raw ? (JSON.parse(raw) as T) : ({} as T);
}
