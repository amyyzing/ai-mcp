export const DEFAULT_BRIDGE_URL: string;
export const SERVER_PORT: number;
export function normalizeBridgeUrl(value?: unknown): string;
export function buildLoaderSnippet(bridgeUrl?: string, authToken?: string): string;
export function buildOneLineLoaderSnippet(bridgeUrl?: string, authToken?: string): string;
export function buildHostedLoaderSnippet(bridgeUrl?: string): string;
