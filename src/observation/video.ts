import { mkdtemp, writeFile, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { ffmpegBinary, mediaProcess, probeRecording } from "./media.js";
import { normalizeFrame } from "./vision.js";

let allocatedBytes = 0;
// Each recording owns its random temporary directory. No caller-supplied output paths.
export class VideoWriter {
  private directory?: string;
  private bytes = 0;
  private closed = false;
  private finalized = false;
  private chain: Promise<unknown> = Promise.resolve();
  readonly frames: { atMs: number; capturedAtUnixMs: number; file: string; width: number; height: number }[] = [];
  private async add(bytes: Buffer, atMs: number, capturedAtUnixMs: number) {
    if (this.closed || this.finalized) throw new Error("Video recording is closed.");
    if (!Number.isFinite(atMs) || atMs < 0 || atMs > 130000 || !Number.isFinite(capturedAtUnixMs)) throw new Error("Invalid capture timestamp.");
    if (this.frames.length && atMs <= this.frames.at(-1)!.atMs) throw new Error("Capture timestamps must increase.");
    if (this.frames.length >= 1800) throw new Error("Video frame limit reached.");
    const frame = await normalizeFrame(bytes);
    if (this.bytes + frame.bytes.length > 128 * 1024 * 1024 || allocatedBytes + frame.bytes.length > 384 * 1024 * 1024) throw new Error("Capture storage is full; release an old recording.");
    this.directory ??= await mkdtemp(path.join(tmpdir(), "roblox-mcp-video-"));
    const file = `frame-${String(this.frames.length).padStart(5, "0")}.jpg`;
    await writeFile(path.join(this.directory, file), frame.bytes, { flag: "wx" });
    this.bytes += frame.bytes.length; allocatedBytes += frame.bytes.length;
    this.frames.push({ atMs, capturedAtUnixMs, file, width: frame.width, height: frame.height });
  }
  append(bytes: Buffer, atMs: number, capturedAtUnixMs: number) {
    const operation = this.chain.then(() => this.add(bytes, atMs, capturedAtUnixMs)); this.chain = operation.catch(() => {}); return operation;
  }
  finish() {
    const operation = this.chain.then(() => this.encode()); this.chain = operation.catch(() => {}); return operation;
  }
  private async encode() {
    if (this.closed || this.finalized || !this.directory || !this.frames.length) throw new Error("No open video frames to encode.");
    this.finalized = true;
    const reservation = 32 * 1024 * 1024;
    if (allocatedBytes + reservation > 384 * 1024 * 1024) throw new Error("Capture storage is full; cannot reserve video output.");
    // Count even partially written failed encodes until this recording is released.
    this.bytes += reservation; allocatedBytes += reservation;
    const lines = ["ffconcat version 1.0"];
    for (let index = 0; index < this.frames.length; index++) {
      const frame = this.frames[index]!;
      lines.push(`file '${frame.file}'`, "option framerate 1000", `duration ${Math.max(0.001, ((this.frames[index + 1]?.atMs ?? frame.atMs + 100) - frame.atMs) / 1000).toFixed(6)}`);
    }
    // The final repeat gives the last real frame a display duration; it is identified in the manifest.
    lines.push(`file '${this.frames.at(-1)!.file}'`, "option framerate 1000");
    const list = path.join(this.directory, "frames.ffconcat"), output = path.join(this.directory, "capture.mp4");
    await writeFile(list, lines.join("\n") + "\n");
    const width = Math.ceil(this.frames[0]!.width / 2) * 2, height = Math.ceil(this.frames[0]!.height / 2) * 2;
    await mediaProcess(ffmpegBinary(), ["-v", "error", "-nostdin", "-protocol_whitelist", "file,pipe", "-f", "concat", "-safe", "0", "-i", list,
      "-an", "-vf", `scale=${width}:${height}:force_original_aspect_ratio=decrease,pad=${width}:${height}:(ow-iw)/2:(oh-ih)/2`, "-fps_mode", "vfr", "-c:v", "libx264", "-threads", "2", "-preset", "ultrafast", "-crf", "25", "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-fs", "33554432", output]);
    const metadata = await probeRecording(output);
    if (metadata.timestamps.length !== this.frames.length + 1) throw new Error("Encoded frame count differs from capture manifest.");
    const origin = this.frames[0]!.atMs;
    for (let index = 0; index < this.frames.length; index++) if (Math.abs(metadata.timestamps[index]! * 1000 - (this.frames[index]!.atMs - origin)) > 5) throw new Error("Encoded presentation timestamps differ from capture manifest.");
    const size = (await stat(output)).size;
    if (size >= 33554432) throw new Error("Encoded video exceeded 32 MiB.");
    this.bytes += size - reservation; allocatedBytes += size - reservation;
    return { file: output, bytes: size, frameCount: this.frames.length, durationSeconds: metadata.durationSeconds,
      timestamps: "VFR from capture PTS; terminal duplicate +100ms", originAtMs: origin,
      geometryChanges: this.frames.filter((frame, index) => index && (frame.width !== this.frames[index - 1]!.width || frame.height !== this.frames[index - 1]!.height)).length };
  }
  async frame(index: number) {
    await this.chain;
    const frame = this.frames[index]; if (this.closed || !this.directory || !frame) throw new Error("Video frame unavailable.");
    return readFile(path.join(this.directory, frame.file));
  }
  async release() {
    this.closed = true; await this.chain;
    if (this.directory) { const directory = this.directory; this.directory = undefined; await rm(directory, { recursive: true, force: true }); }
    allocatedBytes -= this.bytes; this.bytes = 0;
  }
}
