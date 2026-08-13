import path from "node:path";

export const DEFAULT_MCP_SERVER_NAME = "roblox-mcp";

export function mcpServerEntry(serverRoot) {
  return path.join(serverRoot, "dist", "index.js");
}

export function mcpServerArgs(serverEntry, serverName = DEFAULT_MCP_SERVER_NAME) {
  return [serverEntry, "--server-name", serverName];
}

export function mcpServerConfig(serverEntry, serverName = DEFAULT_MCP_SERVER_NAME) {
  return { command: "node", args: mcpServerArgs(serverEntry, serverName) };
}

export function mcpServersRecipe(serverEntry, serverName = DEFAULT_MCP_SERVER_NAME) {
  return { mcpServers: { [serverName]: mcpServerConfig(serverEntry, serverName) } };
}

export function mcpServersRecipeJson(serverEntry, serverName = DEFAULT_MCP_SERVER_NAME) {
  return JSON.stringify(mcpServersRecipe(serverEntry, serverName), null, 2);
}
