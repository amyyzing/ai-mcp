import { spawnSync } from "node:child_process";
import fs from "node:fs";

function git(root, args) {
  const result = spawnSync("git", args, {
    cwd: root,
    encoding: "utf8",
    windowsHide: true,
  });
  if (result.status !== 0) {
    throw new Error(
      result.stderr.trim() || `git ${args.join(" ")} failed with code ${result.status}.`
    );
  }
  return result.stdout.trim();
}

export function inspectCleanCheckout(root) {
  const topLevel = fs.realpathSync.native(git(root, ["rev-parse", "--show-toplevel"]));
  const expectedRoot = fs.realpathSync.native(root);
  if (topLevel !== expectedRoot) {
    throw new Error("Automatic updates require the MCP server's own Git checkout.");
  }
  const changes = git(root, ["status", "--porcelain=v1", "--untracked-files=all"]);
  if (changes) {
    throw new Error(
      "Automatic update stopped because the MCP checkout has local changes. " +
        "Commit, stash, or remove them before updating."
    );
  }
  return {
    commit: git(root, ["rev-parse", "HEAD"]),
  };
}

export function readCommit(root) {
  return git(root, ["rev-parse", "HEAD"]);
}

export function assertFastForward(root, previousCommit, targetCommit) {
  git(root, ["merge-base", "--is-ancestor", previousCommit, targetCommit]);
}

export function advanceCheckout(root, targetCommit, expectedCommit) {
  const current = inspectCleanCheckout(root);
  if (current.commit !== expectedCommit) {
    throw new Error("The MCP checkout changed while the update was being prepared.");
  }
  git(root, ["reset", "--merge", targetCommit]);
}

export function restoreCheckout(root, previousCommit, expectedCurrentCommit) {
  const current = inspectCleanCheckout(root);
  if (expectedCurrentCommit && current.commit !== expectedCurrentCommit) {
    throw new Error(
      "The MCP checkout changed after activation; refusing to rewind the user's commit."
    );
  }
  git(root, ["reset", "--merge", previousCommit]);
}
