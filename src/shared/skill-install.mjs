import { execFile } from "node:child_process";
import fsSync from "node:fs";
import path from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export const SKILL_AGENT_BY_HARNESS = Object.freeze({
  codex: "codex",
  "claude-code": "claude-code",
  opencode: "opencode",
  cursor: "cursor",
  trae: "trae",
  antigravity: "antigravity",
  "gemini-cli": "gemini-cli",
  "github-copilot": "github-copilot",
  "vscode-copilot": "github-copilot",
  amp: "amp",
  cline: "cline",
  "deep-agents": "deepagents",
  "kimi-cli": "kimi-code-cli",
  augment: "augment",
  continue: "continue",
  "devin-terminal": "devin",
  goose: "goose",
  "iflow-cli": "iflow-cli",
  "kilo-code": "kilo",
  "kiro-cli": "kiro-cli",
  "mistral-vibe": "mistral-vibe",
  openhands: "openhands",
  "qwen-code": "qwen-code",
  "rovo-dev": "rovodev",
  "roo-code": "roo",
  "tabnine-cli": "tabnine-cli",
  windsurf: "windsurf",
  zcode: "zcode",
});

const knownAgentIds = new Set(Object.values(SKILL_AGENT_BY_HARNESS));

export function resolveNpxInvocation(options = {}) {
  const platform = options.platform || process.platform;
  const execPath = options.execPath || process.execPath;
  const environment = options.env || process.env;
  const fileExists = options.fileExists || fsSync.existsSync;
  const pathApi = platform === "win32" ? path.win32 : path;
  if (platform !== "win32") {
    const adjacentNpx = pathApi.join(pathApi.dirname(execPath), "npx");
    return {
      command: fileExists(adjacentNpx) ? adjacentNpx : "npx",
      argsPrefix: [],
      shell: false,
    };
  }

  const npxCliCandidates = [
    pathApi.join(pathApi.dirname(execPath), "node_modules", "npm", "bin", "npx-cli.js"),
    environment.npm_execpath
      ? pathApi.join(pathApi.dirname(environment.npm_execpath), "npx-cli.js")
      : null,
  ].filter(Boolean);
  const npxCli = npxCliCandidates.find((candidate) => fileExists(candidate));
  if (npxCli) {
    return {
      command: execPath,
      argsPrefix: [npxCli],
      shell: false,
    };
  }

  throw new Error(
    "Could not locate npx-cli.js; refusing to invoke npx through a command shell. Reinstall Node.js/npm and retry."
  );
}

export function skillAgentForHarness(harnessId) {
  return SKILL_AGENT_BY_HARNESS[harnessId] || null;
}

export function skillAgentIdsForHarnesses(harnessIds) {
  return [
    ...new Set(
      harnessIds
        .map((harnessId) => skillAgentForHarness(harnessId))
        .filter(Boolean)
    ),
  ];
}

export async function detectSkillTargets(options) {
  const serverRoot = path.resolve(options.serverRoot);
  const installerPath = path.join(serverRoot, "scripts", "install-harnesses.mjs");
  const runCommand = options.runCommand || defaultRunCommand;
  const result = await runCommand(
    process.execPath,
    [installerPath, "--list-harnesses-json", "--plain"],
    { cwd: serverRoot }
  );
  const harnesses = JSON.parse(result.stdout || "[]");
  if (!Array.isArray(harnesses)) {
    throw new Error("Harness detection returned invalid data.");
  }
  return harnesses
    .filter((harness) => harness?.detected === true)
    .map((harness) => ({
      harnessId: harness.id,
      harnessName: harness.name,
      agentId: skillAgentForHarness(harness.id),
    }))
    .filter((target) => Boolean(target.agentId));
}

export async function installRobloxMcpSkill(options) {
  const serverRoot = path.resolve(options.serverRoot);
  const requestedAgentIds = Array.isArray(options.agentIds)
    ? options.agentIds
    : (await detectSkillTargets({ serverRoot, runCommand: options.runCommand }))
      .map((target) => target.agentId);
  const agentIds = [...new Set(requestedAgentIds)];
  const unknownAgentIds = agentIds.filter((agentId) => !knownAgentIds.has(agentId));
  if (unknownAgentIds.length > 0) {
    throw new Error(`Unsupported skill targets: ${unknownAgentIds.join(", ")}`);
  }
  if (agentIds.length === 0) {
    throw new Error("No compatible AI harnesses were detected.");
  }
  if (options.dryRun === true) {
    return { installedAgentIds: agentIds, output: "" };
  }

  const npx = resolveNpxInvocation(options);
  const args = [
    ...npx.argsPrefix,
    "--yes",
    "skills",
    "add",
    serverRoot,
    "--skill",
    "roblox-mcp",
    "-g",
  ];
  for (const agentId of agentIds) args.push("-a", agentId);
  args.push("-y");
  const result = await (options.runCommand || defaultRunCommand)(
    npx.command,
    args,
    { cwd: serverRoot, shell: npx.shell }
  );
  return {
    installedAgentIds: agentIds,
    output: [result.stdout, result.stderr].filter(Boolean).join("\n"),
  };
}

async function defaultRunCommand(command, args, options = {}) {
  try {
    const nodeBin = path.dirname(process.execPath);
    const inheritedPath = process.env.PATH || "";
    return await execFileAsync(command, args, {
      cwd: options.cwd,
      env: {
        ...process.env,
        CI: "true",
        PATH: [nodeBin, inheritedPath].filter(Boolean).join(path.delimiter),
      },
      maxBuffer: 10 * 1024 * 1024,
      shell: options.shell === true,
      windowsHide: true,
    });
  } catch (error) {
    const message = String(
      error?.stderr || error?.stdout || error?.message || error
    ).trim();
    throw new Error(message || "Skill installation failed.");
  }
}
