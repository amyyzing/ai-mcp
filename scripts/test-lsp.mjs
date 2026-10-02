import { spawnSync } from "node:child_process";
import { readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadLspRuntime } from "../dist/code-intelligence/runtime.js";

loadLspRuntime(); // Missing/mismatched native dependencies must not become skips.
const root = fileURLToPath(new URL("../", import.meta.url));
const files = readdirSync(path.join(root, "tests")).filter(name => /^code-intelligence.*\.test\.mjs$/.test(name)).sort();
if (!files.length) throw new Error("Native LSP regression files are missing.");
const result = spawnSync(process.execPath, ["--test", ...files.map(name => path.join(root, "tests", name))], {
  cwd: root, windowsHide: true, stdio: "inherit", env: {...process.env, REQUIRE_LSP_TESTS:"1"},
});
if (result.error) throw result.error;
process.exit(result.status ?? 1);
