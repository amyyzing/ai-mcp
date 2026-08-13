import type { IncomingMessage, ServerResponse } from "http";

const THUMBNAIL_API_MAX_BYTES = 64 * 1024;
const AVATAR_MAX_BYTES = 1024 * 1024;
const FETCH_TIMEOUT_MS = 5_000;

function trustedImageUrl(value: unknown): URL | null {
  if (typeof value !== "string") return null;
  try {
    const url = new URL(value);
    const host = url.hostname.toLowerCase();
    return url.protocol === "https:" &&
      (host === "rbxcdn.com" || host.endsWith(".rbxcdn.com"))
      ? url
      : null;
  } catch {
    return null;
  }
}

async function readBounded(response: Response, maxBytes: number): Promise<Buffer> {
  const advertised = Number(response.headers.get("content-length") || 0);
  if (advertised > maxBytes) throw new Error("Response is too large.");
  if (!response.body) throw new Error("Response body is empty.");

  const chunks: Buffer[] = [];
  const reader = response.body.getReader();
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) throw new Error("Response exceeded its size limit.");
      chunks.push(Buffer.from(value));
    }
  } finally {
    await reader.cancel().catch(() => undefined);
  }
  return Buffer.concat(chunks, total);
}

export async function GET(
  _req: IncomingMessage,
  res: ServerResponse,
  url: URL
): Promise<void> {
  const userId = url.searchParams.get("userId") || "";
  if (!/^[1-9][0-9]{0,19}$/.test(userId)) {
    res.writeHead(400);
    res.end("Invalid userId");
    return;
  }

  try {
    const thumbnailResponse = await fetch(
      `https://thumbnails.roblox.com/v1/users/avatar-headshot?userIds=${userId}&size=150x150&format=Png&isCircular=false`,
      {
        headers: { Accept: "application/json" },
        signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
      }
    );
    if (!thumbnailResponse.ok) throw new Error("Thumbnail API request failed.");
    const thumbnailBody = await readBounded(
      thumbnailResponse,
      THUMBNAIL_API_MAX_BYTES
    );
    const json = JSON.parse(thumbnailBody.toString("utf8")) as {
      data?: { imageUrl?: unknown }[];
    };
    const imageUrl = trustedImageUrl(json.data?.[0]?.imageUrl);
    if (!imageUrl) {
      res.writeHead(404);
      res.end("No trusted thumbnail found");
      return;
    }

    const imageResponse = await fetch(imageUrl, {
      headers: { Accept: "image/png,image/jpeg,image/webp" },
      redirect: "follow",
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
    if (!imageResponse.ok || !trustedImageUrl(imageResponse.url || imageUrl.href)) {
      throw new Error("Avatar image request failed.");
    }
    const contentType = (imageResponse.headers.get("content-type") || "")
      .split(";", 1)[0]
      ?.trim()
      .toLowerCase();
    if (!contentType || !["image/png", "image/jpeg", "image/webp"].includes(contentType)) {
      throw new Error("Avatar response was not an image.");
    }
    const image = await readBounded(imageResponse, AVATAR_MAX_BYTES);
    res.writeHead(200, {
      "Content-Type": contentType,
      "Content-Length": String(image.length),
      "Cache-Control": "public, max-age=300",
    });
    res.end(image);
  } catch {
    res.writeHead(502);
    res.end("Failed to fetch thumbnail");
  }
}
