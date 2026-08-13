export const DEFAULT_MCP_SERVER_NAME: string;
export function mcpServerEntry(serverRoot: string): string;
export function mcpServerArgs(serverEntry: string, serverName?: string): string[];
export function mcpServerConfig(serverEntry: string, serverName?: string): {
  command: string;
  args: string[];
};
export function mcpServersRecipe(serverEntry: string, serverName?: string): {
  mcpServers: Record<string, { command: string; args: string[] }>;
};
export function mcpServersRecipeJson(serverEntry: string, serverName?: string): string;
