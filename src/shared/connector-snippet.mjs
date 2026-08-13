export const DEFAULT_BRIDGE_URL = "localhost:16384";
export const SERVER_PORT = 16384;

export function normalizeBridgeUrl(value) {
  const trimmed = String(value || "").trim().replace(/\/+$/, "");
  if (!trimmed) return DEFAULT_BRIDGE_URL;
  const withProtocol = /^https?:\/\//i.test(trimmed) ? trimmed : `http://${trimmed}`;
  try {
    const url = new URL(withProtocol);
    if (!url.port) url.port = String(SERVER_PORT);
    const address = `${url.hostname}:${url.port}`;
    return url.protocol === "https:" ? `https://${address}` : address;
  } catch {
    return DEFAULT_BRIDGE_URL;
  }
}

function luaHttpBaseExpression(variableName) {
  return `local bridgeBase = string.match(${variableName}, "^https?://") and ${variableName} or ("http://" .. ${variableName})`;
}

export function buildLoaderSnippet(bridgeUrl = DEFAULT_BRIDGE_URL) {
  const normalized = normalizeBridgeUrl(bridgeUrl);
  if (normalized === DEFAULT_BRIDGE_URL) {
    return `while not getgenv().MCP_Loaded do\n    local bridgeUrl = getgenv().BridgeURL or "${DEFAULT_BRIDGE_URL}"\n    ${luaHttpBaseExpression("bridgeUrl")}\n    pcall(function() loadstring(game:HttpGet(bridgeBase .. "/script.luau"))() end)\n\n    task.wait(0.15)\nend`;
  }
  return `getgenv().BridgeURL = "${normalized}"\nwhile not getgenv().MCP_Loaded do\n    local bridgeUrl = getgenv().BridgeURL or "${DEFAULT_BRIDGE_URL}"\n    ${luaHttpBaseExpression("bridgeUrl")}\n    pcall(function() loadstring(game:HttpGet(bridgeBase .. "/script.luau"))() end)\n\n    task.wait(0.15)\nend`;
}
