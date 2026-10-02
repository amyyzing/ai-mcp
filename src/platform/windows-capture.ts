import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { enumRobloxWindows, type RobloxWindowInfo } from "./windows-screenshot.js";

export interface DeviceFrame {
  sequence: number; ptsMs: number; capturedAtUnixMs: number; width: number; height: number;
  sourceWidth?: number; sourceHeight?: number; backend: string; imageBase64: string; coordinateSpace?: string;
}
export function wgcBinary() {
  const bundled = fileURLToPath(new URL("./mcp-window-capture.exe", import.meta.url));
  return process.env.ROBLOX_MCP_WGC_BINARY || (existsSync(bundled) ? bundled : fileURLToPath(new URL("../../native/windows-capture/target/release/mcp-window-capture.exe", import.meta.url)));
}
export async function startWindowCapture(binding: RobloxWindowInfo, options: { fps: number; seconds: number; width?: number }, onFrame: (frame: DeviceFrame) => Promise<void>) {
  if (process.platform !== "win32" || !existsSync(wgcBinary())) throw new Error("WGC is unavailable. On the capture PC run npm run build:capture, or use the Windows companion.");
  const current = (await enumRobloxWindows()).find(row => row.pid === binding.pid && row.hwnd === binding.hwnd && row.processStartedAt === binding.processStartedAt);
  if (!current) throw new Error("Bound Roblox process changed; bind again.");
  const seconds = Math.max(1, Math.min(120, options.seconds));
  const child = spawn(wgcBinary(), [binding.hwnd, String(binding.pid), String(options.width || 1280), String(Math.max(1, Math.min(15, options.fps))), String(seconds)], { windowsHide: true, stdio: ["pipe", "pipe", "pipe"] });
  let buffer = "", busy = false, dropped = 0, frames = 0, lastPts = -1, error: Error | undefined;
  let pending: Promise<void> = Promise.resolve();
  const timer = setTimeout(() => child.kill(), (seconds + 10) * 1000);
  const stop = () => { if (!child.stdin.destroyed) child.stdin.end("stop\n"); };
  child.stdin.on("error", () => {}); child.stderr.resume();
  child.stdout.on("data", chunk => {
    buffer += chunk.toString("utf8");
    if (buffer.length > 4_000_000) { error = new Error("WGC output exceeded frame limit."); child.kill(); return; }
    let end: number;
    while ((end = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
      try {
        const value = JSON.parse(line);
        if (value.type === "error") { error = new Error(`WGC: ${String(value.message).slice(0, 500)}`); stop(); }
        if (value.type !== "frame") continue;
        if (busy || !Number.isFinite(value.ptsMs) || value.ptsMs <= lastPts) { dropped++; continue; }
        lastPts = value.ptsMs; busy = true;
        pending = onFrame(value).then(() => { frames++; }).catch(cause => { error = cause; stop(); }).finally(() => { busy = false; });
      } catch { error = new Error("Invalid WGC response."); stop(); }
    }
  });
  const done = new Promise<{ frames: number; dropped: number }>((resolve, reject) => {
    child.on("error", cause => { error = cause; });
    child.on("close", code => { clearTimeout(timer); void pending.then(() => {
      if (error || code !== 0 || frames === 0) reject(error || new Error(`WGC ended with ${frames} frames (exit ${code}).`));
      else resolve({ frames, dropped });
    }); });
  });
  return { stop, done };
}
