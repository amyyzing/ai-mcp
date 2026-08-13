export interface ClientRegistrationInput {
  username?: unknown;
  userId?: unknown;
  placeId?: unknown;
  jobId?: unknown;
  placeName?: unknown;
  sessionId?: unknown;
  clientToken?: unknown;
}

export function normalizeResumeClientToken(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 && value.length <= 256
    ? value
    : undefined;
}

function cleanString(
  value: unknown,
  fallback: string,
  maxLength: number
): string {
  if (typeof value !== "string") return fallback;
  const normalized = value.replace(/[\u0000-\u001f\u007f]/g, "").trim();
  return normalized ? normalized.slice(0, maxLength) : fallback;
}

function cleanId(value: unknown): number {
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : 0;
}

export function normalizeClientRegistration(info: ClientRegistrationInput) {
  const sessionId = cleanString(info.sessionId, "", 160);
  return {
    username: cleanString(info.username, "Unknown", 64),
    userId: cleanId(info.userId),
    placeId: cleanId(info.placeId),
    jobId: cleanString(info.jobId, "", 160),
    placeName: cleanString(info.placeName, "Unknown", 160),
    ...(sessionId ? { sessionId } : {}),
  };
}
