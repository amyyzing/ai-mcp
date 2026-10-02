import { createHash } from "node:crypto";
import { readFileSync, existsSync } from "node:fs";
import path from "node:path";
import { SERVER_ROOT } from "../config.js";

export const LSP_REVISION = "0f360106d50ee7ec46e4fc304c8e69df5f2505d1";
export const LSP_RELEASE = "v1.69.3";
export const hash = (value: string | Buffer): string => createHash("sha256").update(value).digest("hex");
export const ANALYSIS_CONFIGURATION = {
  platform: { type: "roblox" },
  sourcemap: { enabled: true, autogenerate: false },
  diagnostics: { strictDatamodelTypes: true, workspace: false },
  hover: { strictDatamodelTypes: true },
  remoteTypes: { enabled: false },
  bytecode: { provider: "stub" },
  index: { enabled: true },
};

export interface LspRuntime { binary: string; definitions: string; binaryHash: string; definitionsHash: string; buildId: string }

export function loadLspRuntime(): LspRuntime {
  const root = path.resolve(process.env.ROBLOX_MCP_LSP_DIR || path.join(SERVER_ROOT, ".build-tools", "live-lsp"));
  const manifestPath = path.join(root, "manifest.json");
  if (!existsSync(manifestPath)) throw new Error("Live LSP is not installed on this MCP host. Run npm run install:lsp there; then retry. No client code was executed.");
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  if (manifest.revision !== LSP_REVISION || manifest.platform !== process.platform || manifest.arch !== process.arch)
    throw new Error("Live LSP installation does not match the pinned build/platform. Run npm run install:lsp.");
  const binary = path.join(root, process.platform === "win32" ? "luau-lsp.exe" : "luau-lsp");
  const definitions = path.join(root, "globalTypes.d.luau");
  const binaryHash = hash(readFileSync(binary));
  const definitionsHash = hash(readFileSync(definitions));
  if (binaryHash !== manifest.binaryHash || definitionsHash !== manifest.definitionsHash)
    throw new Error("Live LSP files differ from the installation manifest; reinstall the pinned runtime.");
  return { binary, definitions, binaryHash, definitionsHash, buildId: `${LSP_REVISION}:${binaryHash}` };
}
