import { spawn, spawnSync } from "node:child_process";
import fsSync from "node:fs";
import fs from "node:fs/promises";
import path from "node:path";

import {
  activateCandidateBuild,
  validateCandidateCore,
} from "./dashboard-update-runtime.mjs";
import {
  advanceCheckout,
  assertFastForward,
  inspectCleanCheckout,
  readCommit,
  restoreCheckout,
} from "./dashboard-update-git.mjs";
import {
  cleanupPreparedSource,
  hasOwnGitCheckout,
  prepareArchiveSource,
  trackingReference,
} from "./update-source.mjs";

function commandExists(command) {
  const probe = process.platform === "win32" ? "where" : "which";
  return spawnSync(probe, [command], { stdio: "ignore", shell: false }).status === 0;
}

function updateCommandInvocation(command, args) {
  const normalized = String(command).toLowerCase().replace(/\.cmd$/, "");
  if (process.platform !== "win32" || !["npm", "pnpm"].includes(normalized)) {
    return { command, args };
  }

  const cliPath = normalized === "npm"
    ? path.join(path.dirname(process.execPath), "node_modules", "npm", "bin", "npm-cli.js")
    : path.join(path.dirname(process.execPath), "node_modules", "corepack", "dist", "pnpm.js");
  if (!fsSync.existsSync(cliPath)) {
    throw new Error(`Could not locate the ${normalized} JavaScript CLI; refusing to invoke a command shell.`);
  }
  return { command: process.execPath, args: [cliPath, ...args] };
}

export async function runUpdateCommand(
  command,
  args,
  { env = process.env, cwd, outputLimit = 8_000 } = {}
) {
  let output = "";
  await new Promise((resolve, reject) => {
    let invocation;
    try {
      invocation = updateCommandInvocation(command, args);
    } catch (error) {
      reject(error);
      return;
    }
    const child = spawn(invocation.command, invocation.args, {
      cwd,
      env: { ...env, CI: "true" },
      shell: false,
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    });
    const capture = (chunk) => {
      output = `${output}${chunk}`.slice(-outputLimit);
    };
    child.stdout.on("data", capture);
    child.stderr.on("data", capture);
    child.once("error", reject);
    child.once("close", (code) => {
      if (code === 0) {
        resolve();
        return;
      }
      reject(
        new Error(
          `${command} ${args.join(" ")} exited with code ${code}${
            output.trim() ? `\n\n${output.trim()}` : ""
          }`
        )
      );
    });
  });
  return output;
}

async function prepareGitSource({ serverRoot, stagingRoot, status, runCommand }) {
  const checkout = inspectCleanCheckout(serverRoot);
  const tracking = trackingReference(serverRoot);
  if (tracking) {
    await status("Downloading the latest version…", { source: "git" });
    await runCommand("git", ["fetch", "--prune"], { cwd: serverRoot });
  } else {
    await status("No tracking remote is configured; rebuilding the committed checkout…", {
      source: "git",
    });
  }
  await runCommand(
    "git",
    ["worktree", "add", "--detach", stagingRoot, tracking || "HEAD"],
    { cwd: serverRoot }
  );
  return {
    kind: "git",
    serverRoot,
    stagingRoot,
    checkout,
  };
}

async function prepareSource(options) {
  if (hasOwnGitCheckout(options.serverRoot)) {
    return prepareGitSource(options);
  }
  if (!commandExists("tar")) {
    throw new Error(
      "ZIP installations require the system tar utility to install an update."
    );
  }
  await options.status("Downloading the latest release archive…", {
    source: "archive",
  });
  return {
    serverRoot: options.serverRoot,
    ...await prepareArchiveSource(options),
  };
}

export async function runStagedUpdate({
  serverRoot,
  runId,
  corePid = null,
  coreInstanceId = null,
  corePort = Number(process.env.ROBLOX_MCP_PORT) || 16384,
  coreExecutable,
  archiveUrl,
  expectedSha256,
  fetchImpl = fetch,
  packageRunner,
  status = async () => undefined,
  runCommand = runUpdateCommand,
}) {
  if (!/^[a-zA-Z0-9-]{1,80}$/.test(String(runId || ""))) {
    throw new Error("Invalid update run ID.");
  }
  const stagingRoot = path.join(serverRoot, `.roblox-mcp-update-${runId}`);
  let source;
  try {
    await status("Checking the update source…");
    source = await prepareSource({
      serverRoot,
      stagingRoot,
      archiveUrl,
      expectedSha256,
      fetchImpl,
      status,
      runCommand,
    });

    const runner = packageRunner || (commandExists("bun")
      ? "bun"
      : commandExists("pnpm")
        ? "pnpm"
        : "npm");
    await status("Installing the staged dependencies…", { source: source.kind });
    await runCommand(runner, ["install", "--ignore-scripts"], {
      cwd: stagingRoot,
    });

    const candidateDist = path.join(stagingRoot, "dist");
    const candidateNodeModules = path.join(stagingRoot, "node_modules");
    await status("Building and validating the update…", { source: source.kind });
    await runCommand(runner, ["run", "build"], { cwd: stagingRoot });
    await Promise.all([
      validateCandidateCore(candidateDist, stagingRoot),
      fs.access(candidateNodeModules),
    ]);

    let revision = source.revision;
    let activateCheckout = async () => undefined;
    let restoreCheckout = async () => undefined;
    if (source.kind === "git") {
      revision = readCommit(stagingRoot);
      assertFastForward(serverRoot, source.checkout.commit, revision);
      let checkoutAdvanced = false;
      activateCheckout = async () => {
        advanceCheckout(serverRoot, revision, source.checkout.commit);
        checkoutAdvanced = true;
      };
      restoreCheckout = async () => {
        if (checkoutAdvanced) {
          restoreCheckoutGit(serverRoot, source.checkout.commit, revision);
        }
      };
    }

    await status("Activating the complete verified release…", {
      source: source.kind,
    });
    try {
      const result = await activateCandidateBuild({
        serverRoot,
        candidateDist,
        candidateNodeModules,
        runId,
        corePid,
        coreInstanceId,
        corePort,
        coreExecutable,
        commit: revision,
        activateCheckout,
        writeStatus: (next) => status(next.message, {
          state: next.state,
          source: source.kind,
        }),
      });
      return { ...result, source: source.kind, revision };
    } catch (error) {
      await restoreCheckout();
      throw error;
    }
  } finally {
    if (source) {
      await cleanupPreparedSource(source, runCommand);
    } else {
      await fs.rm(stagingRoot, { recursive: true, force: true }).catch(() => undefined);
      await fs.rm(`${stagingRoot}.tar.gz`, { force: true }).catch(() => undefined);
    }
  }
}

function restoreCheckoutGit(serverRoot, previousCommit, targetCommit) {
  restoreCheckout(serverRoot, previousCommit, targetCommit);
}
