import { spawn } from "node:child_process";
import { once } from "node:events";
import type { IncomingMessage, ServerResponse } from "node:http";
import { fileURLToPath } from "node:url";

import { SERVER_ROOT } from "../../../config.js";
import {
  getBackgroundServiceStatus,
} from "../../../shared/background-service-install.mjs";
import {
  detectSkillTargets,
  installRobloxMcpSkill,
} from "../../../shared/skill-install.mjs";
import {
  readStartupStatus,
  writeStartupStatus,
} from "../../../shared/startup-status.mjs";
import { processIsRunning } from "../../../shared/update-status.mjs";
import { readJsonBody } from "../../body.js";

const STARTUP_WORKER_PATH = fileURLToPath(
  new URL("../../../updater/dashboard-startup-worker.mjs", import.meta.url)
);
const SKILL_INSTALL_TIMEOUT_MS = 10 * 60 * 1000;

let skillInstallPromise: Promise<{
  installedAgentIds: string[];
  output: string;
}> | null = null;
let skillTargetsCache: {
  expiresAt: number;
  targets: Awaited<ReturnType<typeof detectSkillTargets>>;
} | null = null;

function json(res: ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
  });
  res.end(JSON.stringify(body));
}

async function skillTargets(force = false) {
  if (
    !force &&
    skillTargetsCache &&
    skillTargetsCache.expiresAt > Date.now()
  ) {
    return skillTargetsCache.targets;
  }
  const targets = await detectSkillTargets({ serverRoot: SERVER_ROOT });
  skillTargetsCache = { expiresAt: Date.now() + 5_000, targets };
  return targets;
}

async function currentPayload() {
  let targets: Awaited<ReturnType<typeof detectSkillTargets>> = [];
  let skillError: string | null = null;
  try {
    targets = await skillTargets();
  } catch (error) {
    skillError = error instanceof Error ? error.message : String(error);
  }
  return {
    startup: getBackgroundServiceStatus(),
    startupOperation: await readStartupStatus(),
    skill: {
      available: targets.length > 0,
      targets,
      error: skillError,
    },
  };
}

export async function GET(
  _req: IncomingMessage,
  res: ServerResponse
): Promise<void> {
  json(res, 200, await currentPayload());
}

export async function POST(
  req: IncomingMessage,
  res: ServerResponse
): Promise<void> {
  let body: { action?: string; enabled?: boolean };
  try {
    body = await readJsonBody(req);
  } catch {
    json(res, 400, { error: "Invalid JSON body." });
    return;
  }

  if (body.action === "set-startup") {
    if (typeof body.enabled !== "boolean") {
      json(res, 400, { error: "enabled must be a boolean." });
      return;
    }
    const service = getBackgroundServiceStatus();
    if (!service.supported) {
      json(res, 409, {
        error: "Automatic startup is not supported on this platform.",
      });
      return;
    }
    const current = await readStartupStatus();
    if (
      current.state === "running" &&
      Number.isInteger(current.workerPid) &&
      processIsRunning(current.workerPid!)
    ) {
      json(res, 409, { error: "The startup preference is already changing." });
      return;
    }

    const startedAt = Date.now();
    const starting = {
      state: "running" as const,
      message: body.enabled
        ? "Enabling startup with your computer…"
        : "Disabling startup with your computer…",
      enabled: body.enabled,
      startedAt,
    };
    await writeStartupStatus(starting);
    const child = spawn(
      process.execPath,
      [
        STARTUP_WORKER_PATH,
        "--mode",
        body.enabled ? "background" : "on-demand",
        "--server-root",
        SERVER_ROOT,
        "--started-at",
        String(startedAt),
      ],
      {
        cwd: SERVER_ROOT,
        detached: true,
        env: process.env,
        stdio: "ignore",
        windowsHide: true,
      }
    );
    try {
      await once(child, "spawn");
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      await writeStartupStatus({
        state: "failed",
        message: "The startup worker could not be started.",
        enabled: service.enabled,
        startedAt,
        finishedAt: Date.now(),
        error: message,
      });
      json(res, 500, { error: message });
      return;
    }
    child.unref();
    await writeStartupStatus({
      ...starting,
      workerPid: child.pid,
    });
    json(res, 202, { ...starting, workerPid: child.pid });
    return;
  }

  if (body.action === "install-skill") {
    if (skillInstallPromise) {
      json(res, 409, { error: "The Roblox MCP skill is already installing." });
      return;
    }
    const targets = await skillTargets(true);
    if (targets.length === 0) {
      json(res, 409, { error: "No compatible AI harnesses were detected." });
      return;
    }
    const operation = installRobloxMcpSkill({
      serverRoot: SERVER_ROOT,
      agentIds: targets.map((target) => target.agentId),
    });
    skillInstallPromise = operation;
    const timeout = new Promise<never>((_, reject) => {
      setTimeout(
        () => reject(new Error("Skill installation timed out.")),
        SKILL_INSTALL_TIMEOUT_MS
      ).unref();
    });
    try {
      const result = await Promise.race([operation, timeout]);
      json(res, 200, {
        ok: true,
        installedAgentIds: result.installedAgentIds,
        targetNames: targets.map((target) => target.harnessName),
      });
    } catch (error) {
      json(res, 500, {
        error: error instanceof Error ? error.message : "Skill installation failed.",
      });
    } finally {
      if (skillInstallPromise === operation) skillInstallPromise = null;
    }
    return;
  }

  json(res, 400, { error: "Unsupported setup settings action." });
}
