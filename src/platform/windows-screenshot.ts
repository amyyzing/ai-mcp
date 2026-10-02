import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";

export interface RobloxWindowInfo { pid: number; hwnd: string; title: string; processStartedAt?: string }
export interface FrameMetadata {
  frameId: string; captureSourceId: string; capturedAtMs: number; captureStartedAtMs: number;
  sourceWidth: number; sourceHeight: number; returnedWidth: number; returnedHeight: number;
  crop: { x: number; y: number; width: number; height: number };
  geometryRevision: string; cursorIncluded: boolean; status: "fresh" | "stale" | "unavailable";
  backend: string; captureLocation: string; pid: number; hwnd: string;
  clientOrigin: { x: number; y: number }; dpi: number;
}
export interface ScreenshotResult {
  error?: string; needsDisambiguation?: boolean; windows?: RobloxWindowInfo[];
  imageBase64?: string; mimeType?: string; frame?: FrameMetadata;
}
export const DEFAULT_SCREENSHOT_MAX_WIDTH = 1280;
export const DEFAULT_SCREENSHOT_JPEG_QUALITY = 70;
export function isSupported(): boolean { return process.platform === "win32"; }

// Persistent asynchronous IPC; no interpolated commands or temporary frame files.
let worker: ChildProcessWithoutNullStreams | undefined;
let serial = 0;
let idle: NodeJS.Timeout | undefined;
const pending = new Map<number, { resolve: (value: any) => void; reject: (error: Error) => void; timer: NodeJS.Timeout }>();
function failWorker(error: Error) {
  const previous = worker; worker = undefined;
  for (const job of pending.values()) { clearTimeout(job.timer); job.reject(error); }
  pending.clear(); previous?.kill();
}
export function closeCaptureWorker() { if (idle) clearTimeout(idle); failWorker(new Error("Capture worker closed.")); }
function request(operation: string, args: Record<string, unknown> = {}): Promise<any> {
  if (!isSupported()) return Promise.reject(new Error("Native capture requires a Windows device companion."));
  if (pending.size >= 4) return Promise.reject(new Error("Capture queue is full; wait for the current frame."));
  if (idle) clearTimeout(idle);
  if (!worker) {
    const child = spawn("powershell.exe", ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
      fileURLToPath(new URL("./capture-worker.ps1", import.meta.url))], { windowsHide: true, stdio: "pipe" });
    worker = child;
    let bytes = 0;
    child.stdout.on("data", (chunk) => { if (worker !== child) return; bytes += chunk.length; if (bytes > 32 * 1024 * 1024) failWorker(new Error("Capture response exceeded its limit.")); });
    const lines = createInterface({ input: child.stdout });
    lines.on("line", (line) => {
      if (worker !== child) return;
      bytes = 0;
      try {
        const value = JSON.parse(line); const job = pending.get(value.id);
        if (!job) return;
        pending.delete(value.id); clearTimeout(job.timer);
        if (value.error) job.reject(new Error(value.error)); else job.resolve(value.result);
        if (!pending.size) { idle = setTimeout(closeCaptureWorker, 30000); idle.unref(); }
      } catch { failWorker(new Error("Capture worker returned malformed JSON.")); }
    });
    child.stderr.resume();
    child.stdin.on("error", () => { if (worker === child) failWorker(new Error("Capture worker input closed.")); });
    child.on("error", () => { if (worker === child) failWorker(new Error("Capture worker could not start.")); });
    child.on("exit", () => { if (worker === child) failWorker(new Error("Capture worker exited.")); });
  }
  return new Promise((resolve, reject) => {
    const id = ++serial;
    const timer = setTimeout(() => failWorker(new Error("Capture timed out; no frame was accepted.")), 15000);
    pending.set(id, { resolve, reject, timer });
    worker!.stdin.write(JSON.stringify({ id, operation, ...args }) + "\n");
  });
}
process.once("exit", () => worker?.kill());
export async function enumRobloxWindows(): Promise<RobloxWindowInfo[]> { return request("windows"); }
export async function performScreenshot(pid?: number, maxWidth = DEFAULT_SCREENSHOT_MAX_WIDTH): Promise<ScreenshotResult> {
  const windows = await enumRobloxWindows();
  const targets = pid === undefined ? windows : windows.filter((window) => window.pid === pid);
  if (!targets.length) return { error: "No matching visible Roblox window is available." };
  if (targets.length !== 1) return { needsDisambiguation: true, windows: targets };
  const target = targets[0]!;
  const started = Date.now();
  const captured = await request("capture", { ...target, maxWidth: Math.max(320, Math.min(3840, Math.floor(maxWidth))), quality: DEFAULT_SCREENSHOT_JPEG_QUALITY });
  const geometryRevision = [target.hwnd, target.processStartedAt, captured.width, captured.height, captured.x, captured.y, captured.dpi].join(":");
  return { imageBase64: captured.imageBase64, mimeType: "image/jpeg", frame: {
    frameId: randomUUID(), captureSourceId: `${target.pid}:${target.hwnd}:${target.processStartedAt}`,
    capturedAtMs: captured.capturedAtMs, captureStartedAtMs: started,
    sourceWidth: captured.width, sourceHeight: captured.height, returnedWidth: captured.returnedWidth, returnedHeight: captured.returnedHeight,
    crop: { x: 0, y: 0, width: captured.width, height: captured.height }, geometryRevision,
    cursorIncluded: false, status: "fresh", backend: "persistent-printwindow", captureLocation: "mcp-host",
    pid: target.pid, hwnd: target.hwnd, clientOrigin: { x: captured.x, y: captured.y }, dpi: captured.dpi,
  } };
}
export function imagePointToClient(frame: FrameMetadata, x: number, y: number, expectedRevision: string) {
  if (frame.status !== "fresh" || frame.geometryRevision !== expectedRevision) throw new Error("Frame geometry is stale.");
  if (![x, y].every(Number.isFinite) || x < 0 || y < 0 || x >= frame.returnedWidth || y >= frame.returnedHeight) throw new Error("Point is outside the returned frame.");
  return { x: frame.crop.x + x * frame.crop.width / frame.returnedWidth, y: frame.crop.y + y * frame.crop.height / frame.returnedHeight };
}
