import { createInterface } from "node:readline/promises";
import { stdin, stdout } from "node:process";
import { randomUUID } from "node:crypto";
import { enumRobloxWindows, performScreenshot, closeCaptureWorker } from "../../dist/platform/windows-screenshot.js";
import { startWindowCapture } from "../../dist/platform/windows-capture.js";

const input = createInterface({ input: stdin, output: stdout });
let capture;
try {
  const url = new URL((await input.question("MCP HTTPS server URL (or loopback HTTP): ")).trim());
  if (url.username || url.password || url.search || url.hash || (url.protocol !== "https:" && !(url.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)))) throw new Error("Invalid server URL.");
  const windows = await enumRobloxWindows(); console.table(windows);
  const pid = Number(await input.question("Roblox PID to capture: "));
  const matches = windows.filter(window => window.pid === pid);
  let selected = matches.length === 1 ? matches[0] : undefined;
  if (!selected && matches.length > 1) { const hwnd = await input.question("Exact HWND from the table: "); selected = matches.find(window => window.hwnd === hwnd.trim()); }
  if (!selected) throw new Error("Select an available Roblox window.");
  const pairingCode = (await input.question("One-use code from companion-pair (capture): ")).trim();
  const post = async (route, body, token) => {
    const response = await fetch(new URL(route, url), { method: "POST", redirect: "error", signal: AbortSignal.timeout(10000),
      headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: JSON.stringify(body) });
    if (!response.ok) { await response.body?.cancel(); throw new Error(`Companion endpoint returned HTTP ${response.status}.`); }
    return response.json();
  };
  const pairing = await post("/companion/claim", { pairingCode, label: "Windows Roblox capture", bootId: randomUUID(), deviceUnixMs: Date.now() });
  if (pairing.scope.kind !== "capture") throw new Error("This pairing is not for capture.");
  let sequence = 0, wgcOriginOffset;
  const captureOrigin = performance.now();
  const upload = frame => {
    if (frame.backend === "windows-graphics-capture") wgcOriginOffset ??= performance.now() - captureOrigin;
    const ptsMs = frame.backend === "windows-graphics-capture" ? wgcOriginOffset + frame.ptsMs : performance.now() - captureOrigin;
    return post("/companion/frame", { sequence: ++sequence, ptsMs,
      capturedAtUnixMs: frame.capturedAtUnixMs, imageBase64: frame.imageBase64, backend: frame.backend, coordinateSpace: "window" }, pairing.uploadToken);
  };
  try {
    capture = await startWindowCapture(selected, { fps: 5, seconds: 120, width: 1280 }, upload);
    console.log("Connected. Capturing only the selected Roblox window for up to 120 seconds. Ctrl+C stops capture.");
    process.once("SIGINT", () => capture.stop());
    console.log(await capture.done);
  } catch (error) {
    console.error(`WGC unavailable/failed: ${error.message}`);
    const fallback = await input.question("Use diagnostic PrintWindow screenshots at 1 fps for 30 seconds? (yes/no): ");
    if (fallback.trim().toLowerCase() !== "yes") throw error;
    for (let index = 0; index < 30; index++) {
      const current = (await enumRobloxWindows()).find(window => window.hwnd === selected.hwnd && window.pid === selected.pid && window.processStartedAt === selected.processStartedAt);
      if (!current) throw new Error("Bound process changed.");
      const image = await performScreenshot(pid);
      if (!image.imageBase64) throw new Error(image.error || "Capture unavailable.");
      await upload({ imageBase64: image.imageBase64, capturedAtUnixMs: Date.now(), backend: "printwindow-fallback" });
      await new Promise(resolve => setTimeout(resolve, 1000));
    }
  }
} catch (error) { console.error(error.message); process.exitCode = 1; }
finally { capture?.stop(); input.close(); closeCaptureWorker(); }
