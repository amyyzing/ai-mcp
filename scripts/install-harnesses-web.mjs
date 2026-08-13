#!/usr/bin/env node
import crypto from "node:crypto";
import { execFile, spawn } from "node:child_process";
import fs from "node:fs/promises";
import http from "node:http";
import path from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { getAutoexecStatus } from "../src/shared/autoexec.mjs";
import { applyBackgroundService } from "../src/shared/background-service-install.mjs";
import { getBackgroundServicePlan } from "../src/shared/background-service-plan.mjs";
import {
  installRobloxMcpSkill,
  skillAgentForHarness,
} from "../src/shared/skill-install.mjs";
import { mcpServerEntry, mcpServersRecipeJson } from "../src/shared/mcp-recipe.mjs";

const execFileAsync = promisify(execFile);
const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");
const assetsDir = path.join(repoRoot, "src", "http", "assets", "installer");
const installerPath = path.join(scriptDir, "install-harnesses.mjs");

const host = readArg("--host") || "127.0.0.1";
const port = parsePort(readArg("--port") || "18766");
const shouldOpen = !process.argv.includes("--no-open");
const previewMode = process.argv.includes("--preview");
const dryRun = process.env.ROBLOX_MCP_WEB_DRY_RUN === "1";
const installToken = crypto.randomBytes(32).toString("base64url");
const installTokenHeader = "x-roblox-mcp-installer-token";
const maxRequestBytes = 64 * 1024;

let installState = {
  id: null,
  status: "idle",
  step: null,
  message: "Ready to install.",
  details: [],
  startedAt: null,
  finishedAt: null,
};
let installerShutdownTimer = null;

const contentTypes = new Map([
  [".html", "text/html; charset=utf-8"],
  [".css", "text/css; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
]);

const server = http.createServer(async (request, response) => {
  try {
    const url = new URL(
      request.url || "/",
      `http://${request.headers.host || `${host}:${port}`}`
    );

    if (url.pathname === "/api/harnesses") {
      if (request.method !== "GET" && request.method !== "HEAD") {
        sendJson(response, 405, { error: "Method not allowed." }, { Allow: "GET, HEAD" });
        return;
      }
      const harnesses = await readHarnesses();
      sendJson(response, 200, {
        preview: previewMode,
        requiresInstallToken: !previewMode,
        harnesses: harnesses.map((harness) => ({
          ...harness,
          skillAgent: skillAgentForHarness(harness.id),
        })),
        skill: {
          name: "roblox-mcp",
          path: "skills/roblox-mcp",
        },
        connector: connectorPreview(),
        backgroundService: getBackgroundServicePlan(repoRoot),
        manualRecipe: {
          serverName: process.env.ROBLOX_MCP_SERVER_NAME || "roblox-mcp",
          serverEntry: mcpServerEntry(repoRoot),
          json: mcpServersRecipeJson(
            mcpServerEntry(repoRoot),
            process.env.ROBLOX_MCP_SERVER_NAME || "roblox-mcp"
          ),
        },
      });
      return;
    }

    if (url.pathname === "/api/install/status") {
      if (request.method !== "GET") {
        sendJson(response, 405, { error: "Method not allowed." }, { Allow: "GET" });
        return;
      }
      if (!isAuthorizedInstallRequest(request)) {
        sendJson(response, 403, { error: "Invalid or missing installer token." });
        return;
      }
      sendJson(response, 200, publicInstallState());
      return;
    }

    if (url.pathname === "/api/install") {
      if (request.method !== "POST") {
        sendJson(response, 405, { error: "Method not allowed." }, { Allow: "POST" });
        return;
      }
      if (previewMode) {
        sendJson(response, 405, { error: "Preview mode is read-only." }, { Allow: "GET, HEAD" });
        return;
      }
      if (!isAuthorizedInstallRequest(request)) {
        sendJson(response, 403, { error: "Invalid or missing installer token." });
        return;
      }
      if (installState.status === "running") {
        sendJson(response, 409, {
          error: "An installation is already running.",
          installation: publicInstallState(),
        });
        return;
      }

      const body = await readJsonBody(request);
      const harnesses = await readHarnesses();
      const connector = getAutoexecStatus();
      const installRequest = validateInstallRequest(body, harnesses, connector);
      const id = crypto.randomUUID();
      installState = {
        id,
        status: "running",
        step: "prepare",
        message: "Preparing the installation…",
        details: [],
        startedAt: new Date().toISOString(),
        finishedAt: null,
      };
      runInstallJob(installRequest).catch((error) => {
        installState = {
          ...installState,
          status: "error",
          message: error instanceof Error ? error.message : "Installation failed.",
          finishedAt: new Date().toISOString(),
        };
      });
      sendJson(response, 202, { installation: publicInstallState() });
      return;
    }

    if (request.method !== "GET" && request.method !== "HEAD") {
      sendJson(response, 405, { error: "Method not allowed." }, { Allow: "GET, HEAD" });
      return;
    }

    const assetName = url.pathname === "/" ? "index.html" : url.pathname.slice(1);
    if (!["index.html", "installer.css", "installer.js"].includes(assetName)) {
      sendJson(response, 404, { error: "Not found." });
      return;
    }

    const filePath = path.join(assetsDir, assetName);
    const body = await fs.readFile(filePath);
    response.writeHead(200, securityHeaders({
      "Content-Type": contentTypes.get(path.extname(filePath)) || "application/octet-stream",
      "Cache-Control": "no-store",
    }));
    if (request.method === "HEAD") response.end();
    else response.end(body);
  } catch (error) {
    const status = error instanceof HttpError ? error.status : 500;
    sendJson(response, status, {
      error: error instanceof Error ? error.message : "Could not run the installer.",
    });
  }
});

server.on("error", (error) => {
  console.error(`Could not start installer: ${error.message}`);
  process.exitCode = 1;
});

server.listen(port, host, () => {
  const address = server.address();
  const actualPort = typeof address === "object" && address ? address.port : port;
  const displayHost = host === "0.0.0.0" || host === "::" ? "127.0.0.1" : host;
  const baseUrl = `http://${displayHost}:${actualPort}`;
  const installerUrl = previewMode
    ? baseUrl
    : `${baseUrl}/?token=${encodeURIComponent(installToken)}`;
  console.log(`Installer: ${installerUrl}`);
  if (previewMode) {
    console.log("Preview mode is read-only. No files, harnesses, or processes will be changed.");
  } else if (host === "0.0.0.0" || host === "::") {
    console.log("For another device, replace 127.0.0.1 with this computer's LAN or Tailscale IP and keep the token.");
  }
  if (shouldOpen) openBrowser(installerUrl);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    server.close(() => process.exit(0));
  });
}

async function runInstallJob(request) {
  updateInstallState("server", "Installing and building the Roblox MCP server…");
  const installerArgs = [
    installerPath,
    "--yes",
    "--plain",
    "--no-restart-harnesses",
    "--json-result",
  ];
  if (request.harnessIds.length > 0) {
    installerArgs.push("--harnesses", request.harnessIds.join(","));
  }
  if (request.connectorTargetIds.length > 0) {
    installerArgs.push("--autoexec-targets", request.connectorTargetIds.join(","));
  }
  if (dryRun) installerArgs.push("--dry-run");

  appendInstallDetails(`$ ${[process.execPath, ...installerArgs].map((arg) => /\s/.test(arg) ? JSON.stringify(arg) : arg).join(" ")}`);
  await runProcess(process.execPath, installerArgs, {
    cwd: repoRoot,
    onOutput: appendInstallDetails,
  });

  if (request.installSkill && request.skillAgentIds.length > 0) {
    updateInstallState("skill", "Installing the Roblox MCP skill…");
    if (dryRun) {
      appendInstallDetails(`Would install the Roblox MCP skill for ${request.skillAgentIds.join(", ")}.`);
    } else {
      const result = await installRobloxMcpSkill({
        serverRoot: repoRoot,
        agentIds: request.skillAgentIds,
      });
      appendInstallDetails(result.output);
    }
  } else if (request.installSkill) {
    appendInstallDetails("No compatible skill targets were selected; skipped skill installation.");
  }

  updateInstallState(
    "service",
    request.serviceMode === "background"
      ? "Registering the background server…"
      : "Configuring on-demand startup…"
  );
  const service = await applyBackgroundService({
    serverRoot: repoRoot,
    mode: request.serviceMode,
    dryRun,
  });
  appendInstallDetails(service.message);

  const automaticRestart =
    request.restartMode !== "manual" && request.runningHarnessIds.length > 0;
  const manualRestart = request.manualRestartHarnessIds.length > 0;
  let restartOutcome = { restarted: [], failed: [] };
  if (automaticRestart && !dryRun) {
    updateInstallState("service", "Restarting the selected AI harnesses…");
    restartOutcome = await restartHarnessesAndWait(request.runningHarnessIds);
  }
  const automaticRestartFailed = restartOutcome.failed.length > 0;
  installState = {
    ...installState,
    status: "success",
    step: "complete",
    message: automaticRestartFailed
      ? "Installation complete, but some AI harnesses could not reopen. Restart them manually."
      : automaticRestart
        ? `Installation complete. Running AI harnesses restarted automatically.${manualRestart ? " Restart Codex CLI manually." : ""}`
        : (request.restartMode === "manual" && request.runningHarnessIds.length > 0) || manualRestart
          ? "Installation complete. Restart the selected AI harnesses manually to load Roblox MCP."
          : "Installation complete. Roblox MCP is ready.",
    finishedAt: new Date().toISOString(),
  };
  scheduleInstallerShutdown();
}

function updateInstallState(step, message) {
  installState = { ...installState, step, message };
  appendInstallDetails(message);
}

function appendInstallDetails(output) {
  const normalized = stripAnsi(output)
    .split(/\r?\n/)
    .map((line) => line.trimEnd())
    .filter((line) => line.trim())
    .slice(-100);
  installState = {
    ...installState,
    details: [...installState.details, ...normalized].slice(-200),
  };
}

async function restartHarnessesAndWait(harnessIds) {
  const output = await runProcess(process.execPath, [
    installerPath,
    "--restart-harnesses-only",
    "--harnesses",
    harnessIds.join(","),
    "--plain",
    "--json-result",
  ], { cwd: repoRoot });
  appendInstallDetails(output);

  const marker = output
    .split(/\r?\n/)
    .find((line) => line.startsWith("HARNESS_RESULT_JSON="));
  if (!marker) {
    return { restarted: [], failed: ["Restart worker returned no result."] };
  }
  try {
    const result = JSON.parse(marker.slice("HARNESS_RESULT_JSON=".length));
    return {
      restarted: Array.isArray(result.restarted) ? result.restarted : [],
      failed: Array.isArray(result.failed) ? result.failed : [],
    };
  } catch {
    return { restarted: [], failed: ["Restart worker returned an invalid result."] };
  }
}

function scheduleInstallerShutdown() {
  if (previewMode || installerShutdownTimer) return;

  // Leave enough time for the browser's next status poll before returning
  // control to the terminal. Harness restarts have already completed here.
  installerShutdownTimer = setTimeout(() => {
    console.log("Installation complete. Closing installer server.");
    server.close(() => process.exit(0));
    server.closeIdleConnections?.();

    const forceExitTimer = setTimeout(() => {
      server.closeAllConnections?.();
      process.exit(0);
    }, 1_000);
    forceExitTimer.unref();
  }, 2_000);
  installerShutdownTimer.unref();
}

function validateInstallRequest(body, harnesses, connector) {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new HttpError(400, "Installation request must be an object.");
  }
  const harnessIds = uniqueStringArray(body.harnessIds, "harnessIds");
  const connectorTargetIds = uniqueStringArray(
    body.connectorTargetIds,
    "connectorTargetIds"
  );
  const harnessById = new Map(harnesses.map((harness) => [harness.id, harness]));
  const connectorById = new Map(
    connector.detectedTargets.map((target) => [target.id, target])
  );
  const unknownHarnesses = harnessIds.filter((id) => !harnessById.has(id));
  const unknownConnectors = connectorTargetIds.filter((id) => !connectorById.has(id));
  if (unknownHarnesses.length > 0) {
    throw new HttpError(400, `Unknown harnesses: ${unknownHarnesses.join(", ")}`);
  }
  if (unknownConnectors.length > 0) {
    throw new HttpError(
      400,
      `Unknown or unavailable connector targets: ${unknownConnectors.join(", ")}`
    );
  }

  const serviceMode = body.serviceMode === "on-demand" ? "on-demand" : "background";
  const restartMode = body.restartMode === "manual" ? "manual" : "automatic";
  const skipHarnessSetup = body.skipHarnessSetup === true;
  const selectedHarnesses = harnessIds.map((id) => harnessById.get(id));
  const skillHarnesses = skipHarnessSetup
    ? harnesses.filter((harness) => harness.detected)
    : selectedHarnesses;
  const selectedSkillAgentIds = [
    ...new Set(
      skillHarnesses
        .map((harness) => skillAgentForHarness(harness.id))
        .filter(Boolean)
    ),
  ];
  const runningHarnessIds = skipHarnessSetup
    ? []
    : selectedHarnesses
      .filter((harness) => harness.running)
      .map((harness) => harness.id);
  const manualRestartHarnessIds = skipHarnessSetup
    ? []
    : selectedHarnesses
      .filter((harness) => harness.manualRestartRequired)
      .map((harness) => harness.id);

  return {
    harnessIds: skipHarnessSetup ? [] : harnessIds,
    connectorTargetIds,
    installSkill: body.installSkill !== false,
    restartMode,
    runningHarnessIds,
    manualRestartHarnessIds,
    serviceMode,
    skillAgentIds: selectedSkillAgentIds,
  };
}

function uniqueStringArray(value, field) {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > 100) {
    throw new HttpError(400, `${field} must be an array.`);
  }
  const result = [];
  for (const item of value) {
    if (typeof item !== "string" || !/^[a-z0-9._-]+$/i.test(item)) {
      throw new HttpError(400, `${field} contains an invalid identifier.`);
    }
    if (!result.includes(item)) result.push(item);
  }
  return result;
}

function publicInstallState() {
  return { ...installState };
}

function connectorPreview() {
  const status = getAutoexecStatus();
  return {
    platform: status.platform,
    scriptName: status.scriptName,
    targets: status.targets.map(serializeConnectorTarget),
    detectedTargets: status.detectedTargets.map(serializeConnectorTarget),
  };
}

function serializeConnectorTarget(target) {
  return {
    id: target.id,
    name: target.name,
    folder: target.folder,
    exists: target.exists,
    installed: target.installed,
    installedPath: target.installedPath,
    scriptPath: target.scriptPath,
  };
}

async function readHarnesses() {
  const { stdout } = await execFileAsync(
    process.execPath,
    [installerPath, "--list-harnesses-json", "--skip-running-status", "--plain"],
    { cwd: repoRoot, maxBuffer: 1024 * 1024 }
  );
  const harnesses = JSON.parse(stdout);
  if (!Array.isArray(harnesses)) {
    throw new Error("Harness detection returned invalid data.");
  }
  return harnesses;
}

async function runProcess(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    let stdout = "";
    let stderr = "";
    const pending = { stdout: "", stderr: "" };
    const child = spawn(command, args, {
      cwd: options.cwd || repoRoot,
      env: { ...process.env, CI: "true", ROBLOX_MCP_INSTALLER_STREAM_OUTPUT: "1" },
      stdio: ["ignore", "pipe", "pipe"],
      shell: options.shell === true,
      windowsHide: true,
    });
    const collect = (stream, chunk) => {
      const value = chunk.toString();
      if (stream === "stdout") stdout += value;
      else stderr += value;
      const lines = (pending[stream] + value).split(/\r?\n/);
      pending[stream] = lines.pop() || "";
      if (lines.length > 0) options.onOutput?.(lines.join("\n"));
    };
    child.stdout.on("data", (chunk) => collect("stdout", chunk));
    child.stderr.on("data", (chunk) => collect("stderr", chunk));
    child.once("error", reject);
    child.once("close", (code) => {
      for (const stream of ["stdout", "stderr"]) {
        if (pending[stream]) options.onOutput?.(pending[stream]);
      }
      if (code === 0) {
        resolve([stdout, stderr].filter(Boolean).join("\n"));
        return;
      }
      const details = stripAnsi([stderr, stdout].filter(Boolean).join("\n")).trim();
      reject(new Error(details || `${command} exited with code ${code}.`));
    });
  });
}

async function readJsonBody(request) {
  let total = 0;
  const chunks = [];
  for await (const chunk of request) {
    total += chunk.length;
    if (total > maxRequestBytes) {
      throw new HttpError(413, "Installation request is too large.");
    }
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
  } catch {
    throw new HttpError(400, "Installation request contains invalid JSON.");
  }
}

function isAuthorizedInstallRequest(request) {
  const received = request.headers[installTokenHeader];
  if (typeof received !== "string" || !tokensMatch(received, installToken)) {
    return false;
  }
  const fetchSite = request.headers["sec-fetch-site"];
  if (typeof fetchSite === "string" && !["same-origin", "none"].includes(fetchSite)) {
    return false;
  }
  const origin = request.headers.origin;
  if (!origin) return true;
  try {
    return new URL(origin).host === request.headers.host;
  } catch {
    return false;
  }
}

function tokensMatch(left, right) {
  const leftBuffer = Buffer.from(left);
  const rightBuffer = Buffer.from(right);
  return (
    leftBuffer.length === rightBuffer.length
    && crypto.timingSafeEqual(leftBuffer, rightBuffer)
  );
}

function sendJson(response, status, value, extraHeaders = {}) {
  response.writeHead(status, securityHeaders({
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    ...extraHeaders,
  }));
  response.end(JSON.stringify(value));
}

function securityHeaders(headers) {
  return {
    "Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    ...headers,
  };
}

function openBrowser(url) {
  const command = process.platform === "darwin"
    ? { file: "open", args: [url] }
    : process.platform === "win32"
      ? { file: "cmd", args: ["/c", "start", "", url] }
      : { file: "xdg-open", args: [url] };
  const child = execFile(command.file, command.args, () => {});
  child.unref();
}

function readArg(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : null;
}

function parsePort(value) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 0 || parsed > 65535) {
    throw new Error(`Invalid port: ${value}`);
  }
  return parsed;
}

function stripAnsi(value) {
  return String(value || "").replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "");
}

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}
