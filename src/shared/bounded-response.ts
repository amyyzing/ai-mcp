export class ResponseBodyTooLargeError extends Error {
  constructor(readonly limitBytes: number) {
    super(`Response body exceeds the ${limitBytes} byte limit.`);
    this.name = "ResponseBodyTooLargeError";
  }
}

export async function readBoundedResponseText(
  response: Response,
  limitBytes: number
): Promise<string> {
  const advertised = Number(response.headers.get("content-length"));
  if (Number.isFinite(advertised) && advertised > limitBytes) {
    await response.body?.cancel().catch(() => undefined);
    throw new ResponseBodyTooLargeError(limitBytes);
  }
  if (!response.body) return "";

  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let received = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      received += value.byteLength;
      if (received > limitBytes) {
        await reader.cancel().catch(() => undefined);
        throw new ResponseBodyTooLargeError(limitBytes);
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  return Buffer.concat(chunks.map((chunk) => Buffer.from(chunk)), received).toString("utf8");
}
