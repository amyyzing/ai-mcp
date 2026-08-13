import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, "..");
const src = path.join(root, "src", "http", "assets");
const dist = path.resolve(process.env.ROBLOX_MCP_DIST_DIR || path.join(root, "dist"));
const dest = path.join(dist, "http", "assets");
const sharedSrc = path.join(root, "src", "shared");
const sharedDest = path.join(dist, "shared");

if (!fs.existsSync(src)) {
  console.error(`[copy-assets] Source not found: ${src}`);
  process.exit(1);
}

fs.rmSync(dest, { recursive: true, force: true });
fs.cpSync(src, dest, { recursive: true });

// Keep executable dashboard dependencies local. Loading syntax-highlighter
// JavaScript from a public CDN would turn every dashboard visit into a remote
// code-execution/supply-chain dependency.
const highlightAssets = path.join(root, "node_modules", "@highlightjs", "cdn-assets");
const highlightDest = path.join(dest, "dashboard", "vendor", "highlight.js");
const highlightFiles = [
  ["highlight.min.js", "highlight.min.js"],
  [path.join("languages", "lua.min.js"), "lua.min.js"],
  [path.join("styles", "github.min.css"), "github.min.css"],
  [path.join("styles", "github-dark.min.css"), "github-dark.min.css"],
];
fs.mkdirSync(highlightDest, { recursive: true });
for (const [sourceName, destinationName] of highlightFiles) {
  fs.copyFileSync(
    path.join(highlightAssets, sourceName),
    path.join(highlightDest, destinationName)
  );
}
console.log(`[copy-assets] ${src} → ${dest}`);

if (fs.existsSync(sharedSrc)) {
  fs.mkdirSync(sharedDest, { recursive: true });
  for (const entry of fs.readdirSync(sharedSrc)) {
    if (!entry.endsWith(".mjs") && !entry.endsWith(".d.mts")) continue;
    fs.copyFileSync(path.join(sharedSrc, entry), path.join(sharedDest, entry));
  }
  console.log(`[copy-assets] runtime modules from ${sharedSrc} → ${sharedDest}`);
}
