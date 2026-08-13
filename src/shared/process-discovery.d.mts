export interface McpRuntimeProcess {
  pid: number;
  command: string;
}
export function normalizeProcessPath(value: unknown): string;
export function isCoreProcess(processInfo: McpRuntimeProcess | null): boolean;
export function listMcpRuntimeProcesses(): McpRuntimeProcess[];
export function findInstallationRuntimeProcesses(
  serverRoot: string,
): McpRuntimeProcess[];
