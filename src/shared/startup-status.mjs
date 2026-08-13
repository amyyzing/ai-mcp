import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {
  withFileTransaction,
  writeJsonAtomic,
} from "./atomic-json.mjs";

export function startupStatusPath(env = process.env) {
  const configHome =
    typeof env.ROBLOX_MCP_CONFIG_HOME === "string" &&
    path.isAbsolute(env.ROBLOX_MCP_CONFIG_HOME)
      ? env.ROBLOX_MCP_CONFIG_HOME
      : path.join(os.homedir(), ".roblox-mcp");
  return path.join(configHome, "startup-status.json");
}

export async function readStartupStatus(env = process.env) {
  try {
    const value = JSON.parse(
      await fs.readFile(startupStatusPath(env), "utf8")
    );
    return value && typeof value === "object"
      ? value
      : { state: "idle", message: "Startup preference is ready." };
  } catch {
    return { state: "idle", message: "Startup preference is ready." };
  }
}

export async function writeStartupStatus(status, env = process.env) {
  const filePath = startupStatusPath(env);
  return withFileTransaction(filePath, async () => {
    await writeJsonAtomic(filePath, {
      ...status,
      updatedAt: Date.now(),
    });
  });
}
