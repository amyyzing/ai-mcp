export async function legacyServerRequiresShutdown(port) {
  try {
    const response = await fetch(`http://127.0.0.1:${port}/api/server-info`, {
      signal: AbortSignal.timeout(800),
    });
    if (!response.ok) return false;
    const info = await response.json();
    return info?.architecture !== "background-core";
  } catch {
    return false;
  }
}

export async function waitForLegacyServerShutdown(port, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (!await legacyServerRequiresShutdown(port)) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(
    "The legacy MCP server did not stop; close its harness and run the update again."
  );
}
