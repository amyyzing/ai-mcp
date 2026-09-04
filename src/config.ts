import { randomUUID } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { installationIdentity } from "./shared/installation-identity.mjs";

export const serverStartTime = Date.now();
export const coreInstanceId = randomUUID();
export const SERVER_ROOT = path.resolve(
  process.env.ROBLOX_MCP_SERVER_ROOT ||
    path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
);
export const INSTALLATION_ID = installationIdentity(SERVER_ROOT);

function readPort(value: string | undefined, fallback: number): number {
  if (!value) return fallback;
  const port = Number(value);
  return Number.isInteger(port) && port >= 1 && port <= 65535 ? port : fallback;
}

function readByteLimit(
  value: string | undefined,
  fallback: number,
  maximum: number
): number {
  if (!value) return fallback;
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed >= 1024 && parsed <= maximum
    ? parsed
    : fallback;
}

const isRailwayDeployment = Boolean(
  process.env.RAILWAY_ENVIRONMENT_ID?.trim() ||
    process.env.RAILWAY_PROJECT_ID?.trim()
);
const defaultPort = isRailwayDeployment ? readPort(process.env.PORT, 16384) : 16384;

export const WS_PORT = readPort(process.env.ROBLOX_MCP_PORT, defaultPort);
export const BRIDGE_HOST =
  process.env.ROBLOX_MCP_HOST?.trim() ||
  (isRailwayDeployment ? "0.0.0.0" : "127.0.0.1");

export const HTTP_BODY_LIMIT_BYTES = readByteLimit(
  process.env.ROBLOX_MCP_HTTP_BODY_LIMIT_BYTES,
  2 * 1024 * 1024,
  128 * 1024 * 1024
);
export const SCRIPT_UPLOAD_BODY_LIMIT_BYTES = readByteLimit(
  process.env.ROBLOX_MCP_SCRIPT_UPLOAD_BODY_LIMIT_BYTES,
  16 * 1024 * 1024,
  128 * 1024 * 1024
);
export const DECOMPILE_BODY_LIMIT_BYTES = readByteLimit(
  process.env.ROBLOX_MCP_DECOMPILE_BODY_LIMIT_BYTES,
  64 * 1024 * 1024,
  128 * 1024 * 1024
);
export const WS_MAX_PAYLOAD_BYTES = readByteLimit(
  process.env.ROBLOX_MCP_WS_MAX_PAYLOAD_BYTES,
  4 * 1024 * 1024,
  64 * 1024 * 1024
);

export const HTTP_POLL_TIMEOUT = 10000;
export const PROMOTION_JITTER_MAX = 300;
export const TOOL_RESPONSE_TIMEOUT = 15000;

const args = process.argv.slice(2);
const baseUrlIdx = args.indexOf("--baseurl");
export const BASE_URL: string | null =
  baseUrlIdx !== -1 ? (args[baseUrlIdx + 1] ?? null) : null;

const serverNameIdx = args.indexOf("--server-name");
export const SERVER_NAME =
  serverNameIdx !== -1 && args[serverNameIdx + 1]
    ? args[serverNameIdx + 1]
    : process.env.ROBLOX_MCP_SERVER_NAME || "roblox-mcp";

if (BASE_URL) {
  console.error(
    `[Config] --baseurl specified: ${BASE_URL} (will connect to this background core)`,
  );
}
