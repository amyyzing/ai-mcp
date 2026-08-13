import { execFile, spawnSync } from "node:child_process";
import fs from "node:fs/promises";
import fsSync from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { resolveAutoexecHome } from "./autoexec.mjs";
import {
  findInstallationRuntimeProcesses,
  isCoreProcess,
} from "./process-discovery.mjs";
import { configuredBridgeAuthHeaders } from "./configured-bridge-auth.mjs";

const execFileAsync = promisify(execFile);
const LAUNCHD_LABEL = "com.roblox-mcp.core";
const WINDOWS_TASK_NAME = "Roblox MCP";
const WINDOWS_STARTUP_FILE = "Roblox MCP.vbs";
const SYSTEMD_UNIT_NAME = "roblox-mcp.service";

export async function applyBackgroundService(options) {
  const serverRoot = path.resolve(options.serverRoot);
  const mode = options.mode === "on-demand" ? "on-demand" : "background";
  const platform = options.platform || process.platform;
  const env = options.env || process.env;
  const dryRun = options.dryRun === true;
  const nodePath = options.nodePath || process.execPath;
  const runCommand = options.runCommand || defaultRunCommand;
  const homeDir = resolveServiceHome({ platform, env, homeDir: options.homeDir });
  const coreEntry = path.join(serverRoot, "dist", "core-bootstrap.js");

  if (!dryRun && mode === "background" && !fsSync.existsSync(coreEntry)) {
    throw new Error(`Background core entry is missing at ${coreEntry}`);
  }

  if (platform === "darwin") {
    return applyLaunchdService({
      coreEntry,
      dryRun,
      env,
      homeDir,
      mode,
      nodePath,
      runCommand,
      serverRoot,
    });
  }
  if (platform === "linux") {
    return applySystemdService({
      coreEntry,
      dryRun,
      env,
      homeDir,
      mode,
      nodePath,
      runCommand,
      serverRoot,
    });
  }
  if (platform === "win32") {
    return applyWindowsStartup({
      coreEntry,
      dryRun,
      env,
      homeDir,
      mode,
      nodePath,
      runCommand,
      serverRoot,
      windowsTaskExists: options.windowsTaskExists,
    });
  }
  if (mode === "on-demand") {
    return {
      manager: "on demand",
      configPath: null,
      message: "The server will start when an AI harness connects.",
    };
  }
  throw new Error(`Background service installation is not supported on ${platform}.`);
}

export function getBackgroundServiceStatus(options = {}) {
  const platform = options.platform || process.platform;
  const env = options.env || process.env;
  const homeDir = resolveServiceHome({
    platform,
    env,
    homeDir: options.homeDir,
  });
  const fileExists = options.fileExists || fsSync.existsSync;

  if (platform === "darwin") {
    const configPath = path.join(
      homeDir,
      "Library",
      "LaunchAgents",
      `${LAUNCHD_LABEL}.plist`
    );
    return {
      supported: true,
      enabled: fileExists(configPath),
      manager: "launchd",
      configPath,
    };
  }
  if (platform === "linux") {
    const configPath = path.join(
      homeDir,
      ".config",
      "systemd",
      "user",
      SYSTEMD_UNIT_NAME
    );
    return {
      supported: true,
      enabled: fileExists(configPath),
      manager: "systemd user service",
      configPath,
    };
  }
  if (platform === "win32") {
    const configPath = windowsStartupPath({ env, homeDir });
    const startupEnabled = fileExists(configPath);
    const taskExists = options.windowsTaskExists || defaultWindowsTaskExists;
    const legacyTaskEnabled = taskExists(WINDOWS_TASK_NAME);
    return {
      supported: true,
      enabled: startupEnabled || legacyTaskEnabled,
      manager: legacyTaskEnabled ? "Windows Task Scheduler (legacy)" : "Windows Startup",
      configPath: legacyTaskEnabled ? `Task Scheduler Library\\${WINDOWS_TASK_NAME}` : configPath,
    };
  }
  return {
    supported: false,
    enabled: false,
    manager: "Unsupported platform",
    configPath: null,
  };
}

export function resolveServiceHome({ platform = process.platform, env = process.env, homeDir } = {}) {
  const fallback = homeDir || os.homedir();
  if (platform === "darwin") {
    return resolveAutoexecHome({
      platform,
      homeDir: fallback,
      sudoUser: env.SUDO_USER,
    });
  }
  if (
    platform === "linux"
    && typeof env.SUDO_USER === "string"
    && /^[a-z0-9._-]+$/i.test(env.SUDO_USER)
    && env.SUDO_USER !== "root"
  ) {
    const candidate = path.join("/home", env.SUDO_USER);
    if (fsSync.existsSync(candidate)) return candidate;
  }
  return fallback;
}

function defaultWindowsTaskExists(taskName) {
  return spawnSync(
    "schtasks",
    ["/Query", "/TN", taskName],
    { stdio: "ignore", windowsHide: true }
  ).status === 0;
}

async function applyLaunchdService(options) {
  const uid = numericId(options.env.SUDO_UID) ?? process.getuid?.();
  if (!Number.isInteger(uid)) {
    throw new Error("Could not determine the macOS user ID for launchd.");
  }
  const gid = numericId(options.env.SUDO_GID);
  const configPath = path.join(
    options.homeDir,
    "Library",
    "LaunchAgents",
    `${LAUNCHD_LABEL}.plist`
  );
  const configDir = path.dirname(configPath);
  const logDir = path.join(options.homeDir, "Library", "Logs", "RobloxMCP");
  const serviceTarget = `gui/${uid}/${LAUNCHD_LABEL}`;

  if (options.mode === "on-demand") {
    if (!options.dryRun) {
      await options.runCommand("launchctl", ["bootout", serviceTarget], { allowFailure: true });
      await fs.rm(configPath, { force: true });
    }
    return {
      manager: "launchd",
      configPath,
      message: "Background startup is disabled; harnesses will start the server when needed.",
    };
  }

  const plist = launchdPlist({
    coreEntry: options.coreEntry,
    logDir,
    nodePath: options.nodePath,
    serverRoot: options.serverRoot,
  });
  if (!options.dryRun) {
    await fs.mkdir(configDir, { recursive: true });
    await fs.mkdir(logDir, { recursive: true });
    await fs.writeFile(configPath, plist, "utf8");
    if (numericId(options.env.SUDO_UID) !== null) {
      await fs.chown(configDir, uid, gid ?? uid);
      await fs.chown(configPath, uid, gid ?? uid);
      await fs.chown(logDir, uid, gid ?? uid);
    }
    await options.runCommand("launchctl", ["bootout", serviceTarget], { allowFailure: true });
    await stopExistingCoreProcesses(options.serverRoot, options.runCommand, options.env);
    await bootstrapLaunchdService(options.runCommand, `gui/${uid}`, configPath);
    await options.runCommand(
      "launchctl",
      ["kickstart", "-k", serviceTarget],
      { allowFailure: true }
    );
  }
  return {
    manager: "launchd",
    configPath,
    message: "Roblox MCP is registered to run in the background with your computer.",
  };
}

async function applySystemdService(options) {
  if (
    !options.dryRun
    && process.getuid?.() === 0
    && typeof options.env.SUDO_USER === "string"
    && options.env.SUDO_USER !== "root"
  ) {
    throw new Error("Install the systemd user service without sudo so it can reach your user session.");
  }
  const configPath = path.join(
    options.homeDir,
    ".config",
    "systemd",
    "user",
    SYSTEMD_UNIT_NAME
  );

  if (options.mode === "on-demand") {
    if (!options.dryRun) {
      await options.runCommand(
        "systemctl",
        ["--user", "disable", "--now", SYSTEMD_UNIT_NAME],
        { allowFailure: true }
      );
      await fs.rm(configPath, { force: true });
      await options.runCommand("systemctl", ["--user", "daemon-reload"], { allowFailure: true });
    }
    return {
      manager: "systemd user service",
      configPath,
      message: "Background startup is disabled; harnesses will start the server when needed.",
    };
  }

  const unit = systemdUnit({
    coreEntry: options.coreEntry,
    nodePath: options.nodePath,
    serverRoot: options.serverRoot,
  });
  if (!options.dryRun) {
    await fs.mkdir(path.dirname(configPath), { recursive: true });
    await fs.writeFile(configPath, unit, "utf8");
    await options.runCommand("systemctl", ["--user", "daemon-reload"]);
    await options.runCommand("systemctl", ["--user", "enable", SYSTEMD_UNIT_NAME]);
    await stopExistingCoreProcesses(options.serverRoot, options.runCommand, options.env);
    await options.runCommand("systemctl", ["--user", "restart", SYSTEMD_UNIT_NAME]);
  }
  return {
    manager: "systemd user service",
    configPath,
    message: "Roblox MCP is registered to run in the background with your computer.",
  };
}

async function applyWindowsStartup(options) {
  const configPath = windowsStartupPath(options);
  const taskExists = options.windowsTaskExists || defaultWindowsTaskExists;
  if (options.mode === "on-demand") {
    if (!options.dryRun) {
      await fs.rm(configPath, { force: true });
      await options.runCommand(
        "schtasks",
        ["/Delete", "/TN", WINDOWS_TASK_NAME, "/F"],
        { allowFailure: true }
      );
    }
    return {
      manager: "Windows Startup",
      configPath,
      message: "Background startup is disabled; harnesses will start the server when needed.",
    };
  }

  if (taskExists(WINDOWS_TASK_NAME)) {
    if (!options.dryRun) {
      await fs.rm(configPath, { force: true });
      await stopExistingCoreProcesses(options.serverRoot, options.runCommand, options.env);
      await options.runCommand("schtasks", ["/Run", "/TN", WINDOWS_TASK_NAME], { allowFailure: true });
    }
    return {
      manager: "Windows Task Scheduler (legacy)",
      configPath: `Task Scheduler Library\\${WINDOWS_TASK_NAME}`,
      message: "Roblox MCP will continue using its existing Windows scheduled task.",
    };
  }

  const startupScript = windowsStartupScript(options);
  if (!options.dryRun) {
    await fs.mkdir(path.dirname(configPath), { recursive: true });
    await fs.writeFile(configPath, startupScript, "utf8");
    await stopExistingCoreProcesses(options.serverRoot, options.runCommand, options.env);
    await options.runCommand("wscript.exe", ["//B", "//NoLogo", configPath]);
  }
  return {
    manager: "Windows Startup",
    configPath,
    message: "Roblox MCP is registered to run in the background with your computer.",
  };
}

function windowsStartupPath({ env = process.env, homeDir = os.homedir() } = {}) {
  const appData = env.APPDATA || path.join(homeDir, "AppData", "Roaming");
  return path.join(appData, "Microsoft", "Windows", "Start Menu", "Programs", "Startup", WINDOWS_STARTUP_FILE);
}

function windowsStartupScript({ coreEntry, nodePath, serverRoot }) {
  return [
    'Set shell = CreateObject("WScript.Shell")',
    `shell.CurrentDirectory = "${vbsEscape(serverRoot)}"`,
    `shell.Environment("PROCESS")("ROBLOX_MCP_SERVER_ROOT") = "${vbsEscape(serverRoot)}"`,
    `launcher = Chr(34) & "${vbsEscape(nodePath)}" & Chr(34) & " " & Chr(34) & "${vbsEscape(coreEntry)}" & Chr(34)`,
    "shell.Run launcher, 0, False",
    "",
  ].join("\r\n");
}

function launchdPlist({ coreEntry, logDir, nodePath, serverRoot }) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCHD_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${xmlEscape(nodePath)}</string>
    <string>${xmlEscape(coreEntry)}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${xmlEscape(serverRoot)}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>ROBLOX_MCP_SERVER_ROOT</key>
    <string>${xmlEscape(serverRoot)}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>${xmlEscape(path.join(logDir, "core.log"))}</string>
  <key>StandardErrorPath</key>
  <string>${xmlEscape(path.join(logDir, "core.error.log"))}</string>
</dict>
</plist>
`;
}

function systemdUnit({ coreEntry, nodePath, serverRoot }) {
  return `[Unit]
Description=Roblox MCP background core
After=network.target

[Service]
Type=simple
ExecStart=${systemdQuote(nodePath)} ${systemdQuote(coreEntry)}
WorkingDirectory=${systemdQuote(serverRoot)}
Environment=${systemdQuote(`ROBLOX_MCP_SERVER_ROOT=${serverRoot}`)}
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
`;
}

async function defaultRunCommand(command, args, options = {}) {
  try {
    await execFileAsync(command, args, {
      windowsHide: true,
      maxBuffer: 1024 * 1024,
    });
  } catch (error) {
    if (options.allowFailure) return;
    const details = String(error?.stderr || error?.stdout || error?.message || error).trim();
    throw new Error(`${command} failed${details ? `: ${details}` : ""}`);
  }
}

async function bootstrapLaunchdService(runCommand, domain, configPath) {
  let lastError;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      await runCommand("launchctl", ["bootstrap", domain, configPath]);
      return;
    } catch (error) {
      lastError = error;
      if (attempt === 2) break;
      await new Promise((resolve) => setTimeout(resolve, 200 * (attempt + 1)));
    }
  }
  throw lastError;
}

async function stopExistingCoreProcesses(serverRoot, runCommand, env = process.env) {
  const runtimeProcesses = findInstallationRuntimeProcesses(serverRoot);
  const architecture = await inspectRunningCoreArchitecture(env);
  const processes = architecture && architecture !== "background-core"
    ? runtimeProcesses
    : runtimeProcesses.filter(isCoreProcess);
  for (const processInfo of processes) {
    if (process.platform === "win32") {
      await runCommand(
        "taskkill",
        ["/PID", String(processInfo.pid), "/T", "/F"],
        { allowFailure: true }
      );
      continue;
    }
    try {
      process.kill(processInfo.pid, "SIGTERM");
    } catch (error) {
      if (error?.code !== "ESRCH") throw error;
    }
  }
  if (process.platform === "win32" || processes.length === 0) return;

  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    const remaining = processes.filter((processInfo) => processExists(processInfo.pid));
    if (remaining.length === 0) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  for (const processInfo of processes) {
    if (!processExists(processInfo.pid)) continue;
    try {
      process.kill(processInfo.pid, "SIGKILL");
    } catch (error) {
      if (error?.code !== "ESRCH") throw error;
    }
  }
}

async function inspectRunningCoreArchitecture(env = process.env) {
  const configuredPort = Number(env.ROBLOX_MCP_PORT);
  const port = Number.isInteger(configuredPort) && configuredPort > 0 && configuredPort <= 65535
    ? configuredPort
    : 16384;
  try {
    const response = await fetch(`http://127.0.0.1:${port}/api/server-info`, {
      headers: configuredBridgeAuthHeaders(env),
      signal: AbortSignal.timeout(750),
    });
    if (!response.ok) return null;
    const info = await response.json();
    return typeof info?.architecture === "string" ? info.architecture : "legacy";
  } catch {
    return null;
  }
}

function processExists(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

function numericId(value) {
  if (value === undefined || value === null || value === "") return null;
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed >= 0 ? parsed : null;
}

function vbsEscape(value) {
  return String(value).replace(/"/g, '""');
}

function xmlEscape(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}

function systemdQuote(value) {
  return `"${String(value).replaceAll("\\", "\\\\").replaceAll('"', '\\"').replaceAll("%", "%%")}"`;
}
