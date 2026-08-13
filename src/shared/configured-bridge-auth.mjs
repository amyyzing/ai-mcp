export const CONFIGURED_BRIDGE_AUTH_HEADER = "x-roblox-mcp-token";

export function configuredBridgeAuthHeaders(env = process.env) {
  const token = env.ROBLOX_MCP_AUTH_TOKEN?.trim();
  return token ? { [CONFIGURED_BRIDGE_AUTH_HEADER]: token } : {};
}
