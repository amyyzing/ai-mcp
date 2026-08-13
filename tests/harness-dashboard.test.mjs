import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { promisify } from "node:util";
import { resolveAutoexecHome } from "../src/shared/autoexec.mjs";
import {
  applyBackgroundService,
  getBackgroundServiceStatus,
} from "../src/shared/background-service-install.mjs";
import {
  detectSkillTargets,
  installRobloxMcpSkill,
  resolveNpxInvocation,
  skillAgentIdsForHarnesses,
} from "../src/shared/skill-install.mjs";
import { resolvePackageCommand } from "../scripts/package-command.mjs";

const execFileAsync = promisify(execFile);
const repoRoot = path.resolve(import.meta.dirname, "..");
const installerPath = path.join(repoRoot, "scripts", "install-harnesses.mjs");
const webInstallerPath = path.join(repoRoot, "scripts", "install-harnesses-web.mjs");

test("autoexec detection resolves the original macOS user when launched through sudo", () => {
  const usersRoot = path.join(path.sep, "private", "tmp", "users");
  const resolved = resolveAutoexecHome({
    platform: "darwin",
    homeDir: "/var/root",
    sudoUser: "upio",
    usersRoot,
    folderExists: (folder) => folder === path.join(usersRoot, "upio"),
  });

  assert.equal(resolved, path.join(usersRoot, "upio"));
  assert.equal(resolveAutoexecHome({
    platform: "darwin",
    homeDir: "/var/root",
    sudoUser: "../../etc",
    usersRoot,
    folderExists: () => true,
  }), "/var/root");
});

test("harness installer exposes machine-readable detected targets", async () => {
  const { stdout } = await execFileAsync(process.execPath, [installerPath, "--list-harnesses-json", "--plain"], {
    cwd: repoRoot,
  });
  const targets = JSON.parse(stdout);

  assert.ok(Array.isArray(targets));
  assert.ok(targets.some((target) => target.id === "codex"));
  assert.ok(targets.every((target) => typeof target.detected === "boolean"));
  assert.ok(targets.every((target) => typeof target.restartable === "boolean"));
  assert.ok(targets.every((target) => typeof target.running === "boolean"));
  assert.ok(targets.every((target) => typeof target.manualRestartRequired === "boolean"));
  assert.ok(!targets.some((target) => target.id === "manual"));
});

test("install-only mode selects explicit harnesses and never restarts them", async () => {
  const { stdout } = await execFileAsync(
    process.execPath,
    [installerPath, "--harnesses", "codex", "--yes", "--plain", "--install-only", "--dry-run"],
    { cwd: repoRoot }
  );

  assert.match(stdout, /Codex: configured/);
  assert.match(stdout, /Restart Codex to load the MCP server\./);
  assert.doesNotMatch(stdout, /Restart running harnesses now/);
  assert.doesNotMatch(stdout, /Installing dependencies|Building server/);
  assert.doesNotMatch(stdout, /while not getgenv\(\)\.MCP_Loaded/);
});

test("normal installs automatically restart supported running harnesses without prompting", async () => {
  const installer = await fs.readFile(installerPath, "utf8");
  const restartFunction = installer.slice(
    installer.indexOf("async function maybeRestartHarnesses"),
    installer.indexOf("function findRestartableHarnesses")
  );

  assert.match(restartFunction, /Restarting running harnesses automatically/);
  assert.match(restartFunction, /SKIP_HARNESS_RESTART/);
  assert.doesNotMatch(restartFunction, /askYesNo/);
  assert.match(installer, /--no-restart-harnesses/);
});

test("macOS harness restarts force-close consented apps before reopening", async () => {
  const installer = await fs.readFile(installerPath, "utf8");
  const restartMacFunction = installer.slice(
    installer.indexOf("async function restartMacApp"),
    installer.indexOf("async function waitForMacProcessState")
  );
  const quitWait = "await waitForMacProcessState(processName, false, 15_000)";
  const reopen = 'spawnSync("open", ["-a", appName]';

  assert.match(installer, /codex:\s*\{[\s\S]*?macApps: \["ChatGPT", "Codex"\]/);
  assert.match(installer, /processNames: \["ChatGPT", "Codex"\]/);
  assert.match(installer, /find\(\(candidate\) => macProcessIsRunning\(candidate\)\)/);
  assert.match(restartMacFunction, /spawnSync\("\/usr\/bin\/killall", \["-KILL", "-q", "-c", processName\]/);
  assert.doesNotMatch(restartMacFunction, /tell application|osascript/);
  assert.match(installer, /await waitForMacProcessState\(processName, false, 15_000\)/);
  assert.ok(installer.indexOf(quitWait) < installer.indexOf(reopen));
  assert.match(installer, /await waitForMacProcessState\(processName, true, 15_000\)/);
  assert.match(installer, /harness\.id === "codex" && interactiveCodexCliIsRunning\(\)/);
  assert.match(installer, /function interactiveCodexCliIsRunning\(\)/);
});

test("legacy update entry delegates to the shared staged updater", async () => {
  const [installer, command] = await Promise.all([
    fs.readFile(installerPath, "utf8"),
    fs.readFile(path.join(repoRoot, "scripts", "update-command.mjs"), "utf8"),
  ]);
  assert.match(installer, /Running the shared Roblox MCP updater/);
  assert.match(installer, /path\.join\(CURRENT_REPO_DIR, "scripts", "update\.mjs"\)/);
  assert.match(command, /legacyServerRequiresShutdown\(corePort\)/);
  assert.match(command, /waitForLegacyServerShutdown\(corePort\)/);
});

test("web installer preview serves harness and skill data and rejects mutations", async (t) => {
  const child = spawn(process.execPath, [webInstallerPath, "--preview", "--port", "0", "--no-open"], {
    cwd: repoRoot,
    stdio: ["ignore", "pipe", "pipe"],
  });
  t.after(() => child.kill("SIGTERM"));

  const url = await new Promise((resolve, reject) => {
    let stdout = "";
    const timer = setTimeout(() => reject(new Error("web installer did not start")), 5000);
    child.once("error", reject);
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
      const match = stdout.match(/Installer: (http:\/\/[^\s]+)/);
      if (!match) return;
      clearTimeout(timer);
      resolve(match[1]);
    });
  });

  const [pageResponse, harnessResponse, mutationResponse] = await Promise.all([
    fetch(url),
    fetch(`${url}/api/harnesses`),
    fetch(`${url}/api/harnesses`, { method: "POST" }),
  ]);
  const [page, harnessData] = await Promise.all([
    pageResponse.text(),
    harnessResponse.json(),
  ]);

  assert.equal(pageResponse.status, 200);
  assert.match(page, /id="modeLabelText">Loading installer/);
  assert.equal(harnessResponse.status, 200);
  assert.equal(harnessData.preview, true);
  assert.equal(harnessData.skill.name, "roblox-mcp");
  assert.equal(harnessData.skill.path, "skills/roblox-mcp");
  assert.equal(harnessData.connector.scriptName, "roblox-executor-mcp.lua");
  assert.equal(harnessData.connector.platform, process.platform);
  assert.ok(Array.isArray(harnessData.connector.targets));
  assert.ok(Array.isArray(harnessData.connector.detectedTargets));
  assert.equal(typeof harnessData.backgroundService.manager, "string");
  assert.equal(typeof harnessData.backgroundService.configPath, "string");
  assert.equal(harnessData.manualRecipe.serverName, "roblox-mcp");
  assert.match(harnessData.manualRecipe.json, /"mcpServers"/);
  assert.match(harnessData.manualRecipe.json, /"--server-name"/);
  assert.ok(harnessData.harnesses.some((harness) =>
    harness.id === "codex" && harness.skillAgent === "codex"
  ));
  assert.equal(mutationResponse.status, 405);
  assert.equal(mutationResponse.headers.get("allow"), "GET, HEAD");
});

test("web installer presents harness, skill, connector, background, and install progress", async () => {
  const [html, script, styles] = await Promise.all([
    fs.readFile(path.join(repoRoot, "src", "http", "assets", "installer", "index.html"), "utf8"),
    fs.readFile(path.join(repoRoot, "src", "http", "assets", "installer", "installer.js"), "utf8"),
    fs.readFile(path.join(repoRoot, "src", "http", "assets", "installer", "installer.css"), "utf8"),
  ]);

  assert.doesNotMatch(html, /data-screen="review"|Review Your Setup/);
  assert.match(html, /data-screen="skill"/);
  assert.match(html, /data-screen="connector"/);
  assert.match(html, /data-screen="service"/);
  assert.match(html, /Skip harness setup/);
  assert.match(html, /class="section-manual" id="manualInstallButton"/);
  assert.match(html, /id="manualInstallDialog" hidden/);
  assert.match(html, /mcpServers\.json/);
  assert.match(html, /These require restarts/);
  assert.match(html, /Install Roblox MCP skill/);
  assert.match(html, /Install the Roblox Connector/);
  assert.match(html, /Keep Roblox MCP Available/);
  assert.match(html, /Roblox MCP will run in the background/);
  assert.match(html, /Advanced options/);
  assert.doesNotMatch(html, /<details class="service-advanced">/);
  assert.match(html, /class="service-advanced-button" id="openServiceDialog"/);
  assert.match(html, /id="serviceDialog" hidden/);
  assert.match(html, /Server startup options/);
  assert.match(html, /Run in the background/);
  assert.match(html, /Start when needed/);
  assert.match(html, /class="skill-flow"/);
  assert.match(html, /class="toggle-switch"[\s\S]*id="installSkillCheckbox"[\s\S]*class="toggle-track"/);
  assert.match(html, /What it adds/);
  assert.match(html, /Why install it/);
  assert.doesNotMatch(html, /Command preview|id="skillCommand"/);
  assert.match(html, /class="harness-list connector-targets"/);
  assert.match(html, /class="toggle-switch"[\s\S]*id="installConnectorCheckbox"[\s\S]*class="toggle-track"/);
  assert.match(html, /class="empty-state connector-empty-state"/);
  assert.match(html, /No connector paths found/);
  assert.match(html, /class="service-choice-grid"/);
  assert.match(html, /class="service-choice-icon"/);
  assert.match(html, /id="installDialog" hidden/);
  assert.match(html, /Installing Roblox MCP/);
  assert.match(html, /data-install-step="server"/);
  assert.match(html, /id="installConsole"/);
  assert.match(html, /id="installationSuccess"/);
  assert.match(html, /Successfully installed!/);
  assert.match(html, /You can now close this page\./);
  assert.match(script, /state\.skipHarnessSetup = true/);
  assert.match(script, /function openManualInstallDialog\(\)/);
  assert.match(script, /function copyManualRecipe\(\)/);
  assert.match(script, /state\.manualRecipe/);
  assert.match(script, /filter\(\(harness\) => harness\.running === true\)/);
  assert.match(script, /chooseRestartMode\("manual"\)/);
  assert.match(script, /chooseRestartMode\("automatic"\)/);
  assert.match(script, /state\.installConnector/);
  assert.match(script, /selectedConnectorTargets/);
  assert.match(script, /harness-row connector-target/);
  assert.match(script, /state\.serviceMode/);
  assert.match(script, /function openServiceDialog\(\)/);
  assert.match(script, /function closeServiceDialog\(/);
  assert.match(html, /class="step-button"/);
  assert.match(script, /targetIndex <= state\.furthestScreenIndex/);
  assert.match(script, /stepIndex > state\.furthestScreenIndex/);
  assert.match(script, /fetch\("\/api\/install"/);
  assert.match(script, /method:\s*["']POST["']/);
  assert.match(script, /X-Roblox-MCP-Installer-Token/);
  assert.match(script, /pollInstallStatus/);
  assert.match(script, /function showInstallationSuccess\(/);
  assert.match(script, /function launchSuccessConfetti\(/);
  assert.match(script, /harness\.manualRestartRequired/);
  assert.match(styles, /\.spinner\s*\{[\s\S]*?display: block;/);
  assert.match(styles, /\.status\.is-manual \{ color: var\(--amber\); \}/);
  assert.match(styles, /\.success-confetti\s*\{/);
  assert.match(styles, /@media \(prefers-reduced-motion: reduce\)/);
  assert.match(styles, /animation: dialog-enter 220ms var\(--ease-out\)/);
  assert.match(styles, /animation-delay: min\(calc\(var\(--row-index, 0\) \* 25ms\), 200ms\)/);
});

test("web installer completes a safe dry-run and exits after success", async (t) => {
  const child = spawn(process.execPath, [webInstallerPath, "--port", "0", "--no-open"], {
    cwd: repoRoot,
    env: { ...process.env, ROBLOX_MCP_WEB_DRY_RUN: "1" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  t.after(() => child.kill("SIGTERM"));

  const installerUrl = await new Promise((resolve, reject) => {
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(
      () => reject(new Error(`web installer did not start\n${stdout}\n${stderr}`)),
      5000
    );
    child.once("error", reject);
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
      const match = stdout.match(/Installer: (http:\/\/[^\s]+)/);
      if (!match) return;
      clearTimeout(timer);
      resolve(new URL(match[1]));
    });
  });
  const token = installerUrl.searchParams.get("token");
  assert.ok(token);

  const body = {
    harnessIds: [],
    skipHarnessSetup: true,
    installSkill: false,
    connectorTargetIds: [],
    serviceMode: "on-demand",
    restartMode: "manual",
  };
  const unauthorized = await fetch(`${installerUrl.origin}/api/install`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  assert.equal(unauthorized.status, 403);

  const started = await fetch(`${installerUrl.origin}/api/install`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Roblox-MCP-Installer-Token": token,
    },
    body: JSON.stringify(body),
  });
  assert.equal(started.status, 202);

  let status;
  for (let attempt = 0; attempt < 30; attempt += 1) {
    const response = await fetch(`${installerUrl.origin}/api/install/status`, {
      headers: { "X-Roblox-MCP-Installer-Token": token },
    });
    assert.equal(response.status, 200);
    status = await response.json();
    if (status.status !== "running") break;
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  assert.equal(status?.status, "success", status?.message);
  assert.equal(status?.step, "complete");
  assert.doesNotMatch(status?.message || "", /restarting/i);

  const exitCode = await new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error("installer server did not exit after installation")),
      5000
    );
    child.once("exit", (code) => {
      clearTimeout(timer);
      resolve(code);
    });
  });
  assert.equal(exitCode, 0);
});

test("web installer waits for harnesses to reopen before reporting success", async () => {
  const installer = await fs.readFile(webInstallerPath, "utf8");
  const restartCall = installer.indexOf(
    "restartOutcome = await restartHarnessesAndWait(request.runningHarnessIds)"
  );
  const successState = installer.indexOf('status: "success"', restartCall);

  assert.ok(restartCall >= 0);
  assert.ok(successState > restartCall);
  assert.doesNotMatch(installer, /function scheduleHarnessRestart/);
  assert.doesNotMatch(installer, /detached: true/);
  assert.match(installer, /--json-result/);
  assert.match(installer, /automaticRestartFailed/);
});

test("background service installer supports native managers and on-demand removal in dry runs", async () => {
  const cases = [
    ["darwin", "launchd"],
    ["linux", "systemd user service"],
    ["win32", "Windows Startup"],
  ];
  for (const [platform, manager] of cases) {
    const background = await applyBackgroundService({
      serverRoot: repoRoot,
      platform,
      dryRun: true,
      env: { SUDO_UID: "501" },
      homeDir: path.join(path.sep, "tmp", "roblox-mcp-service-test"),
    });
    const onDemand = await applyBackgroundService({
      serverRoot: repoRoot,
      platform,
      mode: "on-demand",
      dryRun: true,
      env: { SUDO_UID: "501" },
      homeDir: path.join(path.sep, "tmp", "roblox-mcp-service-test"),
    });
    assert.equal(background.manager, manager);
    assert.equal(onDemand.manager, manager);
    assert.match(background.message, /background with your computer/);
    assert.match(onDemand.message, /start the server when needed/);
  }
});

test("background startup status follows each platform's native registration", () => {
  assert.deepEqual(
    getBackgroundServiceStatus({
      platform: "darwin",
      homeDir: "/Users/test",
      fileExists: (filePath) => filePath.endsWith("com.roblox-mcp.core.plist"),
    }),
    {
      supported: true,
      enabled: true,
      manager: "launchd",
      configPath: path.join(
        "/Users/test",
        "Library",
        "LaunchAgents",
        "com.roblox-mcp.core.plist"
      ),
    }
  );
  assert.equal(
    getBackgroundServiceStatus({
      platform: "linux",
      homeDir: "/home/test",
      fileExists: () => false,
    }).enabled,
    false
  );
  assert.equal(
    getBackgroundServiceStatus({
      platform: "win32",
      windowsTaskExists: (taskName) => taskName === "Roblox MCP",
    }).enabled,
    true
  );
});

test("skill installation targets only compatible detected harnesses", async () => {
  const targets = await detectSkillTargets({
    serverRoot: repoRoot,
    runCommand: async () => ({
      stdout: JSON.stringify([
        { id: "codex", name: "Codex", detected: true },
        { id: "cursor", name: "Cursor", detected: false },
        { id: "blackbox", name: "BLACKBOX", detected: true },
      ]),
      stderr: "",
    }),
  });
  assert.deepEqual(targets, [
    { harnessId: "codex", harnessName: "Codex", agentId: "codex" },
  ]);
  assert.deepEqual(
    skillAgentIdsForHarnesses(["codex", "vscode-copilot", "github-copilot"]),
    ["codex", "github-copilot"]
  );
  assert.deepEqual(
    await installRobloxMcpSkill({
      serverRoot: repoRoot,
      agentIds: ["codex", "github-copilot", "codex"],
      dryRun: true,
    }),
    { installedAgentIds: ["codex", "github-copilot"], output: "" }
  );
  let invocation;
  const installed = await installRobloxMcpSkill({
    serverRoot: repoRoot,
    agentIds: ["codex", "cursor"],
    platform: "linux",
    execPath: "/usr/bin/node",
    fileExists: () => false,
    runCommand: async (command, args, options) => {
      invocation = { command, args, options };
      return { stdout: "installed", stderr: "" };
    },
  });
  assert.deepEqual(installed.installedAgentIds, ["codex", "cursor"]);
  assert.match(path.basename(invocation.command), /^npx(?:\.cmd)?$/);
  assert.deepEqual(invocation.args.slice(0, 7), [
    "--yes",
    "skills",
    "add",
    repoRoot,
    "--skill",
    "roblox-mcp",
    "-g",
  ]);
  assert.deepEqual(invocation.args.slice(7), ["-a", "codex", "-a", "cursor", "-y"]);

  const windowsNode = String.raw`C:\Program Files\nodejs\node.exe`;
  const windowsNpxCli = String.raw`C:\Program Files\nodejs\node_modules\npm\bin\npx-cli.js`;
  const windowsInvocation = resolveNpxInvocation({
    platform: "win32",
    execPath: windowsNode,
    env: {},
    fileExists: (filePath) => filePath === windowsNpxCli,
  });
  assert.deepEqual(windowsInvocation, {
    command: windowsNode,
    argsPrefix: [windowsNpxCli],
    shell: false,
  });

  let windowsInstallInvocation;
  await installRobloxMcpSkill({
    serverRoot: repoRoot,
    agentIds: ["codex"],
    platform: "win32",
    execPath: windowsNode,
    env: {},
    fileExists: (filePath) => filePath === windowsNpxCli,
    runCommand: async (command, args, options) => {
      windowsInstallInvocation = { command, args, options };
      return { stdout: "installed", stderr: "" };
    },
  });
  assert.equal(windowsInstallInvocation.command, windowsNode);
  assert.equal(windowsInstallInvocation.args[0], windowsNpxCli);
  assert.equal(windowsInstallInvocation.options.shell, false);
  assert.throws(
    () => resolveNpxInvocation({
      platform: "win32",
      execPath: windowsNode,
      env: {},
      fileExists: () => false,
    }),
    /refusing to invoke npx through a command shell/
  );

  const skillInstallerSource = await fs.readFile(
    path.join(repoRoot, "src", "shared", "skill-install.mjs"),
    "utf8"
  );
  assert.match(skillInstallerSource, /"node_modules", "npm", "bin", "npx-cli\.js"/);
  assert.match(skillInstallerSource, /command: execPath,[\s\S]*?shell: false/);
  assert.match(skillInstallerSource, /PATH: \[nodeBin, inheritedPath\]/);
  await assert.rejects(
    installRobloxMcpSkill({
      serverRoot: repoRoot,
      agentIds: ["not-a-real-agent"],
      dryRun: true,
    }),
    /Unsupported skill targets/
  );
});

test("background service installer starts each native manager immediately", async (t) => {
  const temporaryRoot = await fs.mkdtemp(path.join(import.meta.dirname, ".service-install-"));
  t.after(() => fs.rm(temporaryRoot, { recursive: true, force: true }));
  await fs.mkdir(path.join(temporaryRoot, "server", "dist"), { recursive: true });
  await fs.writeFile(
    path.join(temporaryRoot, "server", "dist", "core-bootstrap.js"),
    "// test entry\n"
  );

  const cases = [
    ["darwin", "launchctl", "kickstart"],
    ["linux", "systemctl", "restart"],
    ["win32", "wscript.exe", "//B"],
  ];
  let windowsCalls = [];
  for (const [platform, commandName, startArgument] of cases) {
    const calls = [];
    await applyBackgroundService({
      serverRoot: path.join(temporaryRoot, "server"),
      platform,
      env: { SUDO_UID: "501" },
      homeDir: path.join(temporaryRoot, platform),
      runCommand: async (command, args) => {
        calls.push([command, ...args]);
      },
    });
    assert.ok(calls.some((call) =>
      call[0] === commandName && call.includes(startArgument)
    ), `${platform} did not start its registered service`);
    if (platform === "win32") windowsCalls = calls;
  }
  const windowsStartupFile = path.join(
    temporaryRoot, "win32", "AppData", "Roaming", "Microsoft", "Windows",
    "Start Menu", "Programs", "Startup", "Roblox MCP.vbs"
  );
  const windowsStartupScript = await fs.readFile(windowsStartupFile, "utf8");
  assert.match(windowsStartupScript, /CreateObject\("WScript\.Shell"\)/);
  assert.match(windowsStartupScript, /shell\.Run launcher, 0, False/);
  assert.ok(!windowsCalls.some((call) => call[0] === "schtasks"));

  await applyBackgroundService({
    serverRoot: path.join(temporaryRoot, "server"),
    platform: "win32",
    mode: "on-demand",
    homeDir: path.join(temporaryRoot, "win32"),
    env: { SUDO_UID: "501" },
    runCommand: async () => undefined,
  });
  await assert.rejects(fs.access(windowsStartupFile));
});

test("launchd setup stops conflicting runtimes before bootstrap and retries transient failures", async () => {
  const source = await fs.readFile(
    path.join(repoRoot, "src", "shared", "background-service-install.mjs"),
    "utf8"
  );
  const launchdSection = source.slice(
    source.indexOf("async function applyLaunchdService"),
    source.indexOf("async function applySystemdService")
  );
  assert.ok(
    launchdSection.indexOf("await stopExistingCoreProcesses(")
      < launchdSection.indexOf("await bootstrapLaunchdService(")
  );
  assert.match(source, /for \(let attempt = 0; attempt < 3; attempt \+= 1\)/);
  assert.match(source, /architecture && architecture !== "background-core"/);
  assert.match(source, /return typeof info\?\.architecture === "string" \? info\.architecture : "legacy"/);
});

test("dashboard startup worker records a completed native-service change", async (t) => {
  const configHome = await fs.mkdtemp(path.join(import.meta.dirname, ".startup-status-"));
  t.after(() => fs.rm(configHome, { recursive: true, force: true }));
  await execFileAsync(
    process.execPath,
    [
      path.join(repoRoot, "dist", "updater", "dashboard-startup-worker.mjs"),
      "--mode",
      "background",
      "--server-root",
      repoRoot,
      "--started-at",
      "123",
    ],
    {
      cwd: repoRoot,
      env: {
        ...process.env,
        ROBLOX_MCP_CONFIG_HOME: configHome,
        ROBLOX_MCP_DASHBOARD_SETUP_DRY_RUN: "1",
      },
    }
  );
  const status = JSON.parse(
    await fs.readFile(path.join(configHome, "startup-status.json"), "utf8")
  );
  assert.equal(status.state, "complete");
  assert.equal(status.enabled, true);
  assert.equal(status.startedAt, 123);
});

test("browser installer is the default and the terminal installer remains explicit", async () => {
  const [packageSource, setup] = await Promise.all([
    fs.readFile(path.join(repoRoot, "package.json"), "utf8"),
    fs.readFile(path.join(repoRoot, "setup.cmd"), "utf8"),
  ]);
  const packageJson = JSON.parse(packageSource);
  assert.equal(packageJson.scripts["install:harnesses"], "node scripts/install-harnesses-web.mjs");
  assert.match(packageJson.scripts["install:harnesses:cli"], /install-harnesses\.mjs/);
  assert.match(packageJson.scripts["install:harnesses:preview"], /--preview/);
  assert.equal(packageJson.scripts.update, "node scripts/update.mjs");
  assert.ok(packageJson.files.includes("scripts/update.mjs"));
  assert.ok(packageJson.files.includes("setup.cmd"));
  assert.match(setup, /winget install --id OpenJS\.NodeJS\.LTS/);
  assert.match(setup, /scripts\\install-harnesses-web\.mjs/);
});

test("background service previews use the pointer-aware stable core bootstrap", async () => {
  const [plan, bootstrap, build] = await Promise.all([
    fs.readFile(
      path.join(repoRoot, "src", "shared", "background-service-plan.mjs"),
      "utf8"
    ),
    fs.readFile(path.join(repoRoot, "scripts", "core-bootstrap.mjs"), "utf8"),
    fs.readFile(path.join(repoRoot, "scripts", "build-server.mjs"), "utf8"),
  ]);
  assert.match(plan, /dist", "core-bootstrap\.js/);
  assert.doesNotMatch(plan, /dist", "core\.js/);
  assert.match(bootstrap, /readReleasePointerSync/);
  assert.match(bootstrap, /active\?\.releaseRoot \|\| serverRoot/);
  assert.match(build, /core-bootstrap\.mjs/);
});

test("packaged Roblox MCP skill enforces modern inspection and execution defaults", async () => {
  const [skill, functions, runtimePatterns, badPractices] = await Promise.all([
    fs.readFile(path.join(repoRoot, "skills", "roblox-mcp", "SKILL.md"), "utf8"),
    fs.readFile(path.join(repoRoot, "skills", "roblox-mcp", "references", "functions.md"), "utf8"),
    fs.readFile(path.join(repoRoot, "skills", "roblox-mcp", "references", "runtime-patterns.md"), "utf8"),
    fs.readFile(path.join(repoRoot, "skills", "roblox-mcp", "references", "bad-practices.md"), "utf8"),
  ]);

  assert.match(skill, /^---\r?\nname: roblox-mcp\r?\n/m);
  assert.match(skill, /live tool schemas as the source of truth/);
  assert.match(skill, /Use `search-gc` for a compact first-match garbage-collector search/);
  assert.match(skill, /Use `search-instances` for filtered instance discovery/);
  assert.match(skill, /Use `get-data-by-code` when the task needs values returned from Luau/);
  assert.match(skill, /Use `execute` or `execute-file` only for intentional side effects/);
  assert.match(functions, /semantic-search-scripts/);
  assert.match(functions, /script-index-status/);
  assert.match(functions, /wait-for-event/);
  assert.match(runtimePatterns, /filtergc\("function"/);
  assert.match(runtimePatterns, /workspace:QueryDescendants/);
  assert.match(runtimePatterns, /Fall back to `getgc` only when/);
  assert.match(runtimePatterns, /Use `execute` or `execute-file` only when the primary purpose is a side effect/);
  assert.match(badPractices, /Project-specific additions/);
});

test("dashboard add menu routes harness installs through the client setup API", async () => {
  const [html, clientSetupJs, route] = await Promise.all([
    fs.readFile(path.join(repoRoot, "src", "http", "assets", "dashboard", "index.html"), "utf8"),
    fs.readFile(path.join(repoRoot, "src", "http", "assets", "dashboard", "client-setup.js"), "utf8"),
    fs.readFile(path.join(repoRoot, "src", "http", "routes", "api", "client-setup.ts"), "utf8"),
  ]);

  assert.match(html, /data-add-client-kind="roblox"/);
  assert.match(html, /data-add-client-kind="mcp"/);
  assert.match(html, /data-add-client-kind="harness"/);
  assert.match(clientSetupJs, /action: 'install-harnesses'/);
  assert.match(clientSetupJs, /show-harness-manual/);
  assert.match(clientSetupJs, /copy-harness-recipe/);
  assert.match(route, /"--install-only"/);
  assert.match(route, /restartMessage/);
  assert.match(route, /harnessRecipe/);
  assert.match(route, /mcpServersRecipeJson/);
});

test("decompiler add menu shows one custom provider creation option", async () => {
  const dashboardScript = await fs.readFile(
    path.join(repoRoot, "src", "http", "assets", "dashboard", "dashboard.js"),
    "utf8"
  );
  const menuRenderer = dashboardScript.slice(
    dashboardScript.indexOf("function renderDecompilerAddMenu()"),
    dashboardScript.indexOf("function collectDecompilerSettings()")
  );

  assert.match(menuRenderer, /!isCustomDecompilerProviderId\(id\)/);
  assert.equal(
    [...menuRenderer.matchAll(/data-add-custom-provider/g)].length,
    1
  );
});

test("dashboard exposes Luacid transport, allowlisted options, and key links", async () => {
  const dashboardScript = await fs.readFile(
    path.join(repoRoot, "src", "http", "assets", "dashboard", "dashboard.js"),
    "utf8"
  );
  assert.match(dashboardScript, /https:\/\/luacid\.dev\/#pricing/);
  assert.match(dashboardScript, /https:\/\/luacid\.dev\/getkey/);
  assert.match(dashboardScript, /decompilerModalLuacidTransport/);
  assert.match(dashboardScript, /decompilerModalLuacidOptions/);
  assert.match(dashboardScript, /Automatic \(WebSocket with a key\)/);
  assert.match(dashboardScript, /const LUACID_DEFAULT_OPTIONS = \{/);
  assert.match(dashboardScript, /optionKey in LUACID_DEFAULT_OPTIONS/);
});

test("every dashboard feature script referenced by HTML has a production route", async () => {
  const html = await fs.readFile(
    path.join(repoRoot, "src", "http", "assets", "dashboard", "index.html"),
    "utf8"
  );
  const featureScripts = [...html.matchAll(/<script(?:\s+type="module")?\s+src="([^"/][^"]*\.js)"/g)]
    .map((match) => match[1])
    .filter((script) => !script.includes("://"));

  assert.ok(featureScripts.includes("custom-provider-editor.js"));
  for (const script of featureScripts) {
    const route = path.join(repoRoot, "src", "http", "routes", "(dashboard)", `${script}.ts`);
    await assert.doesNotReject(fs.access(route), `missing production route for ${script}`);
  }
});

test("dashboard update control starts and monitors the automatic updater", async () => {
  const [html, dashboardScript, updateScript, route, worker, runner, source, command, runtime, packageJson] = await Promise.all([
    fs.readFile(path.join(repoRoot, "src", "http", "assets", "dashboard", "index.html"), "utf8"),
    fs.readFile(path.join(repoRoot, "src", "http", "assets", "dashboard", "dashboard.js"), "utf8"),
    fs.readFile(path.join(repoRoot, "src", "http", "assets", "dashboard", "update-settings.js"), "utf8"),
    fs.readFile(path.join(repoRoot, "src", "http", "routes", "api", "update.ts"), "utf8"),
    fs.readFile(path.join(repoRoot, "scripts", "dashboard-update-worker.mjs"), "utf8"),
    fs.readFile(path.join(repoRoot, "scripts", "update-runner.mjs"), "utf8"),
    fs.readFile(path.join(repoRoot, "scripts", "update-source.mjs"), "utf8"),
    fs.readFile(path.join(repoRoot, "scripts", "update-command.mjs"), "utf8"),
    fs.readFile(path.join(repoRoot, "scripts", "dashboard-update-runtime.mjs"), "utf8"),
    fs.readFile(path.join(repoRoot, "package.json"), "utf8"),
  ]);

  assert.match(html, /id="settingsUpdateBtn"/);
  assert.match(html, /id="settingsRestartBtn"/);
  assert.match(html, /restart the background core automatically/);
  assert.match(dashboardScript, /createUpdateSettings/);
  assert.match(updateScript, /body: JSON\.stringify\(\{ action \}\)/);
  assert.match(updateScript, /startOperation\('restart'\)/);
  assert.match(updateScript, /Waiting for the updated server to restart/);
  assert.match(updateScript, /disconnectStartedAt \|\|= Date\.now\(\)/);
  assert.doesNotMatch(updateScript, /updateStartedAt/);
  assert.match(updateScript, /RECONNECT_GRACE_MS = 90_000/);
  assert.match(route, /dashboard-update-worker\.mjs/);
  assert.match(route, /--restart-only/);
  assert.ok(route.indexOf("writeUpdateStatus(initialStatus)") < route.indexOf("const child = spawn("));
  assert.match(route, /String\(process\.pid\)/);
  assert.match(route, /coreInstanceId/);
  assert.match(route, /updateWorkerIsRunning/);
  assert.match(route, /return "archive"/);
  assert.match(worker, /acquireUpdateLock\(runId\)/);
  assert.match(worker, /runStagedUpdate/);
  assert.match(worker, /restartActiveCore/);
  assert.match(command, /runStagedUpdate/);
  assert.match(packageJson, /"update": "node scripts\/update\.mjs"/);
  assert.match(runner, /"git", \["fetch", "--prune"\]/);
  assert.match(runner, /"worktree",\s+"add"/);
  assert.doesNotMatch(runner, /\["pull"/);
  assert.doesNotMatch(runner, /remote.*set-url/);
  assert.match(runner, /inspectCleanCheckout\(serverRoot\)/);
  assert.match(runner, /prepareArchiveSource/);
  assert.match(
    runner,
    /advanceCheckout\(serverRoot, revision, source\.checkout\.commit\)/
  );
  assert.match(runner, /restoreCheckoutGit/);
  assert.match(runner, /Installing the staged dependencies/);
  assert.match(runner, /candidateNodeModules/);
  assert.doesNotMatch(source, /codeload\.github\.com\/notpoiu\/roblox-mcp/);
  assert.match(source, /DEFAULT_UPDATE_ARCHIVE_URL = ""/);
  assert.match(source, /ROBLOX_MCP_UPDATE_ARCHIVE_URL/);
  assert.match(source, /ROBLOX_MCP_UPDATE_ARCHIVE_SHA256/);
  assert.match(source, /unsafe path/);
  assert.match(runtime, /architecture === "background-core"/);
  assert.match(runtime, /previous build was restored/);
  await fs.access(
    path.join(repoRoot, "src", "http", "routes", "(dashboard)", "update-settings.js.ts")
  );
  await fs.access(path.join(repoRoot, "dist", "updater", "dashboard-update-git.mjs"));
  await fs.access(path.join(repoRoot, "dist", "updater", "update-runner.mjs"));
  await fs.access(path.join(repoRoot, "dist", "updater", "update-source.mjs"));
});

test("Windows package shims resolve without cmd.exe", () => {
  const windowsNode = String.raw`C:\Program Files\nodejs\node.exe`;
  const windowsNpmShim = String.raw`C:\Program Files\nodejs\npm.cmd`;
  const windowsNpmCli = String.raw`C:\Program Files\nodejs\node_modules\npm\bin\npm-cli.js`;
  assert.deepEqual(resolvePackageCommand(windowsNpmShim, ["install"], {
    platform: "win32",
    execPath: windowsNode,
    env: { npm_execpath: windowsNpmCli },
    fileExists: (filePath) => filePath === windowsNpmCli,
  }), { command: windowsNode, args: [windowsNpmCli, "install"], shell: false });

  const claudeShim = String.raw`C:\Users\Jordan\AppData\Roaming\npm\claude.cmd`;
  const claudeExe = String.raw`C:\Users\Jordan\AppData\Roaming\npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe`;
  assert.deepEqual(resolvePackageCommand(claudeShim, ["mcp", "add"], {
    platform: "win32",
    execPath: windowsNode,
    fileExists: (filePath) => filePath === claudeExe,
  }), { command: claudeExe, args: ["mcp", "add"], shell: false });

  const codeShim = String.raw`C:\Program Files\Microsoft VS Code\bin\code.cmd`;
  const codeExe = String.raw`C:\Program Files\Microsoft VS Code\Code.exe`;
  assert.deepEqual(resolvePackageCommand(codeShim, ["--add-mcp", "{}"], {
    platform: "win32",
    execPath: windowsNode,
    fileExists: (filePath) => filePath === codeExe,
  }), { command: codeExe, args: ["--add-mcp", "{}"], shell: false });
});

test("dashboard settings expose system startup and skill installation controls", async () => {
  const [html, dashboardScript, systemScript, route, worker, router] = await Promise.all([
    fs.readFile(path.join(repoRoot, "src", "http", "assets", "dashboard", "index.html"), "utf8"),
    fs.readFile(path.join(repoRoot, "src", "http", "assets", "dashboard", "dashboard.js"), "utf8"),
    fs.readFile(path.join(repoRoot, "src", "http", "assets", "dashboard", "system-settings.js"), "utf8"),
    fs.readFile(path.join(repoRoot, "src", "http", "routes", "api", "setup-settings.ts"), "utf8"),
    fs.readFile(path.join(repoRoot, "scripts", "dashboard-startup-worker.mjs"), "utf8"),
    fs.readFile(path.join(repoRoot, "src", "http", "router.ts"), "utf8"),
  ]);
  assert.match(html, /id="settingsSystemStartup"/);
  assert.match(html, /Start with your computer/);
  assert.match(html, /Roblox MCP uses the native startup service for your computer/);
  assert.match(
    html,
    /settings-card-footer settings-card-footer--status[\s\S]*?Roblox MCP uses the native startup service for your computer\.[\s\S]*?id="settingsSystemStartupStatus"/
  );
  assert.match(
    html,
    /settings-card-footer settings-card-footer--status">\s*<span class="settings-update-status settings-card-footer-status" id="settingsUpdateStatus"/
  );
  assert.match(
    html,
    /settings-card-footer settings-card-footer--status">\s*<span class="settings-update-status settings-card-footer-status" id="settingsInstallSkillStatus"/
  );
  assert.match(html, /id="settingsInstallSkillBtn"/);
  const settingsOrder = [
    ['General', '<h2 class="settings-title">General</h2>'],
    ['Appearance', 'id="themeSettingsCard"'],
    ['Start with your computer', '<div class="settings-card-title">Start with your computer</div>'],
    ['Installation', '<h2 class="settings-title">Installation</h2>'],
    ['Server updates', '<div class="settings-card-title">Server updates</div>'],
    ['Roblox MCP skill', '<div class="settings-card-title">Roblox MCP skill</div>'],
    ['Indexing', '<h2 class="settings-title">Indexing</h2>'],
    ['Decompiler fallbacks', '<div class="settings-card-title">Decompiler fallbacks</div>'],
    ['Semantic', '<h2 class="settings-title">Semantic</h2>'],
  ];
  const settingsPositions = settingsOrder.map(([label, marker]) => {
    const position = html.indexOf(marker);
    assert.notEqual(position, -1, `missing ${label} settings marker`);
    return position;
  });
  for (let index = 1; index < settingsPositions.length; index += 1) {
    assert.ok(
      settingsPositions[index - 1] < settingsPositions[index],
      `${settingsOrder[index - 1][0]} should appear before ${settingsOrder[index][0]}`
    );
  }
  assert.match(dashboardScript, /createSystemSettings/);
  assert.match(systemScript, /action: 'set-startup'/);
  assert.match(systemScript, /action: 'install-skill'/);
  assert.match(systemScript, /Waiting for the server to restart/);
  assert.match(route, /applyBackgroundService|dashboard-startup-worker/);
  assert.match(route, /installRobloxMcpSkill/);
  assert.match(worker, /applyBackgroundService/);
  assert.match(router, /"\/api\/setup-settings"/);
  await fs.access(
    path.join(repoRoot, "src", "http", "routes", "(dashboard)", "system-settings.js.ts")
  );
  await fs.access(
    path.join(repoRoot, "dist", "updater", "dashboard-startup-worker.mjs")
  );
});
