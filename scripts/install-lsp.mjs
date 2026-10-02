#!/usr/bin/env node
// Explicit optional install; never runs during a tool call or npm prepare.
import { mkdir, mkdtemp, copyFile, writeFile, chmod } from "node:fs/promises";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import { inflateRawSync } from "node:zlib";

const revision = "0f360106d50ee7ec46e4fc304c8e69df5f2505d1";
const release = "v1.69.3";
const target = `${process.platform}-${process.arch}`;
const archiveHashes = {
  "win32-x64": "a4ae4f0c1e3f6588a9c6dcc5e13f49e10c0d728bccc78ecc363a4d2991ec6568",
  "linux-x64": "a9a459b9105dee9f2b623f608996636b8c9606bcfd780f2319ac9da3a72522b9",
  "darwin-arm64": "8d7f51356ed74d3ee87d478f9e5677d51410f8e537d35a954a0703084fad2b7c",
};
const hash = value => createHash("sha256").update(value).digest("hex");
if (!["win32-x64", "linux-x64", "darwin-arm64"].includes(target)) throw new Error(`No pinned upstream binary for ${target}.`);
const root = path.resolve(process.env.ROBLOX_MCP_LSP_DIR || fileURLToPath(new URL("../.build-tools/live-lsp", import.meta.url)));
const temp = await mkdtemp(path.join(tmpdir(), "ai-mcp-lsp-install-"));
async function download(url, maxBytes) {
  const response = await fetch(url, { signal: AbortSignal.timeout(60000) });
  if (!response.ok) throw new Error(`Download failed: HTTP ${response.status}`);
  const chunks = []; let size = 0;
  for await (const chunk of response.body) {
    size += chunk.length;
    if (size > maxBytes) throw new Error("Runtime download exceeds size budget.");
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}
const base = "https://gitlab.com/upio/roblox-live-lsp";
const archive = await download(`${base}/-/releases/${release}/downloads/luau-lsp-${target}.zip`, 64 * 1024 * 1024);
if (hash(archive) !== archiveHashes[target]) throw new Error("Pinned LSP archive checksum mismatch. Nothing was installed.");
const executable = process.platform === "win32" ? "luau-lsp.exe" : "luau-lsp";
// Read only the known executable from the checksum-pinned ZIP. No archive paths
// are used as filesystem destinations, and deployment needs no unzip dependency.
function extractExecutable(zip, name) {
  const end = zip.lastIndexOf(Buffer.from([0x50,0x4b,0x05,0x06]));
  if (end < 0 || end + 22 > zip.length) throw new Error("Invalid pinned ZIP directory.");
  let offset = zip.readUInt32LE(end + 16);
  const count = zip.readUInt16LE(end + 10);
  if (count > 100) throw new Error("Unexpected ZIP entry count.");
  for (let i = 0; i < count; i++) {
    if (zip.readUInt32LE(offset) !== 0x02014b50) throw new Error("Invalid ZIP entry.");
    const filenameLength = zip.readUInt16LE(offset + 28), extraLength = zip.readUInt16LE(offset + 30), commentLength = zip.readUInt16LE(offset + 32);
    const filename = zip.subarray(offset + 46, offset + 46 + filenameLength).toString("utf8");
    if (filename === name) {
      const method = zip.readUInt16LE(offset + 10), compressed = zip.readUInt32LE(offset + 20), size = zip.readUInt32LE(offset + 24);
      const local = zip.readUInt32LE(offset + 42);
      const start = local + 30 + zip.readUInt16LE(local + 26) + zip.readUInt16LE(local + 28);
      if (size > 32 * 1024 * 1024 || start + compressed > zip.length) throw new Error("ZIP executable exceeds bounds.");
      const data = zip.subarray(start, start + compressed);
      const output = method === 0 ? data : method === 8 ? inflateRawSync(data, {maxOutputLength:32*1024*1024}) : null;
      if (!output || output.length !== size) throw new Error("Unsupported or invalid ZIP executable.");
      return output;
    }
    offset += 46 + filenameLength + extraLength + commentLength;
  }
  throw new Error("Pinned ZIP has no expected executable.");
}
const binary = extractExecutable(archive, executable);
const stagedBinary = path.join(temp, executable);
await writeFile(stagedBinary, binary);
if (process.platform !== "win32") await chmod(stagedBinary, 0o755);
execFileSync(stagedBinary, ["--version"], {windowsHide:true,timeout:10000,stdio:"pipe"});
const definitions = await download(`${base}/-/raw/${revision}/src/luau-lsp/scripts/globalTypes.RobloxScriptSecurity.d.luau`, 8 * 1024 * 1024);
if (hash(definitions) !== "cfd82d871e9bb88f463487b37a6d18cbef239e6391d1a4eca3795e7b0de7087f") throw new Error("Pinned definitions checksum mismatch.");
const license = await download(`${base}/-/raw/${revision}/src/luau-lsp/LICENSE.md`, 128 * 1024);
await mkdir(root, { recursive: true });
await copyFile(stagedBinary, path.join(root, executable));
if (process.platform !== "win32") await chmod(path.join(root, executable), 0o755);
await writeFile(path.join(root, "globalTypes.d.luau"), definitions);
await writeFile(path.join(root, "LICENSE.md"), license);
await writeFile(path.join(root, "manifest.json"), JSON.stringify({ revision, release, platform: process.platform, arch: process.arch,
  binaryHash: hash(binary), definitionsHash: hash(definitions), archiveHash: hash(archive) }, null, 2));
console.log(`Installed pinned Live LSP ${release} in ${root}. Temporary download retained at ${temp}.`);
