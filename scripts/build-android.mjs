// Minimal no-Gradle build for the dependency-free Java companion. Downloads only Google's
// pinned platform/build-tools archives into this checkout; never changes the global SDK.
import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
const root = fileURLToPath(new URL("../", import.meta.url));
if (process.platform !== "win32") throw new Error("This SDK bootstrap currently targets Windows. Build the Java/manifest sources with an Android SDK on other hosts.");
const cache = path.join(root, ".build-tools", "android"); await mkdir(cache, { recursive: true });
const packages = [
  ["platform-35_r02.zip", "0bb560a90a7a2cbd0dd8348224d518b638fe7949", "platform", 64273788],
  ["build-tools_r35.0.1_windows.zip", "1cbfa5564b62504a1111352edda35914cf723a20", "tools", 59876477],
];
const psQuote = value => `'${value.replaceAll("'", "''")}'`;
for (const [name, checksum, folder, size] of packages) {
  const archive = path.join(cache, name), destination = path.join(cache, folder);
  if (!existsSync(archive)) {
    console.log(`Downloading Android ${folder} (${Math.round(size / 1048576)} MiB) from dl.google.com`);
    const response = await fetch(`https://dl.google.com/android/repository/${name}`, { signal: AbortSignal.timeout(120000) });
    if (!response.ok) throw new Error(`Android download HTTP ${response.status}`);
    const bytes = Buffer.from(await response.arrayBuffer());
    if (bytes.length !== size || createHash("sha1").update(bytes).digest("hex") !== checksum) throw new Error("Android archive checksum/size mismatch");
    await writeFile(archive, bytes, { flag: "wx" });
  }
  if (createHash("sha1").update(await readFile(archive)).digest("hex") !== checksum) throw new Error("Cached Android archive checksum mismatch");
  if (!existsSync(destination)) execFileSync("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", `Expand-Archive -LiteralPath ${psQuote(archive)} -DestinationPath ${psQuote(destination)}`], { windowsHide: true, stdio: "inherit" });
}
async function find(directory, name) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const file = path.join(directory, entry.name);
    if (entry.isFile() && entry.name === name) return file;
    if (entry.isDirectory()) { const result = await find(file, name); if (result) return result; }
  }
}
const androidJar = await find(path.join(cache, "platform"), "android.jar"), aapt = await find(path.join(cache, "tools"), "aapt2.exe");
const d8 = await find(path.join(cache, "tools"), "d8.jar"), signer = await find(path.join(cache, "tools"), "apksigner.jar");
if (!androidJar || !aapt || !d8 || !signer) throw new Error("Android SDK archive is incomplete");
const output = path.join(root, "companions", "android", "app", "build"), classes = path.join(output, "classes"), dex = path.join(output, "dex");
await mkdir(classes, { recursive: true }); await mkdir(dex, { recursive: true });
const sources = path.join(root, "companions", "android", "app", "src", "main");
async function javaFiles(directory) {
  const all = []; for (const entry of await readdir(directory, { withFileTypes: true })) {
    const file = path.join(directory, entry.name); if (entry.isDirectory()) all.push(...await javaFiles(file)); else if (file.endsWith(".java")) all.push(file);
  } return all;
}
const run = (binary, args) => execFileSync(binary, args, { cwd: root, windowsHide: true, stdio: "inherit" });
run("javac", ["-encoding", "UTF-8", "--release", "8", "-classpath", androidJar, "-d", classes, ...await javaFiles(sources)]);
const jar = path.join(output, "classes.jar"); run("jar", ["--create", "--file", jar, "-C", classes, "."]);
run("java", ["-cp", d8, "com.android.tools.r8.D8", "--min-api", "26", "--lib", androidJar, "--output", dex, jar]);
const unsigned = path.join(output, "capture-unsigned.apk"), apk = path.join(output, "ai-mcp-capture.apk");
run(aapt, ["link", "-o", unsigned, "-I", androidJar, "--manifest", path.join(sources, "AndroidManifest.xml"), "--version-code", "1", "--version-name", "1.0"]);
run("jar", ["--update", "--file", unsigned, "-C", dex, "classes.dex"]);
const key = path.join(cache, "debug.keystore");
if (!existsSync(key)) run("keytool", ["-genkeypair", "-keystore", key, "-storepass", "android", "-keypass", "android", "-alias", "androiddebugkey", "-dname", "CN=AI-MCP Development", "-keyalg", "RSA", "-keysize", "2048", "-validity", "3650"]);
run("java", ["-jar", signer, "sign", "--ks", key, "--ks-pass", "pass:android", "--key-pass", "pass:android", "--out", apk, unsigned]);
run("java", ["-jar", signer, "verify", "--verbose", apk]);
console.log(`Built development APK: ${apk}`);
