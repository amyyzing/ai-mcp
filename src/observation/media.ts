import { spawn } from "node:child_process";
import { realpath, stat } from "node:fs/promises";
import path from "node:path";
import ffmpeg from "ffmpeg-static";
import ffprobe from "ffprobe-static";
export const ffmpegBinary = (): string => process.env.ROBLOX_MCP_FFMPEG || (typeof ffmpeg === "string" ? ffmpeg : "ffmpeg");
export const ffprobeBinary = () => process.env.ROBLOX_MCP_FFPROBE || ffprobe.path;
let activeMediaProcesses = 0;

export function mediaProcess(binary: string, args: string[], binaryOutput = false): Promise<Buffer> {
  if (activeMediaProcesses >= 2) return Promise.reject(new Error("Media worker queue is full; wait for an operation to finish."));
  activeMediaProcesses++;
  return new Promise((resolve, reject) => {
    const child = spawn(binary, args, { windowsHide: true, stdio: ["ignore", "pipe", "pipe"] });
    const chunks: Buffer[] = []; let size = 0, settled = false;
    const finish = (error?: Error) => {
      if (settled) return; settled = true; clearTimeout(timer); activeMediaProcesses--;
      if (error) { child.kill(); reject(error); } else resolve(Buffer.concat(chunks));
    };
    const timer = setTimeout(() => finish(new Error("Media operation timed out after 30 seconds.")), 30000);
    child.stdout.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > (binaryOutput ? 8 : 16) * 1024 * 1024) finish(new Error("Media output exceeded its limit.")); else chunks.push(chunk);
    });
    child.stderr.resume();
    child.on("error", () => finish(new Error(`Media provider unavailable: configure ${path.basename(binary)} on the MCP host.`)));
    child.on("close", (code) => finish(code === 0 ? undefined : new Error(`Media provider exited with code ${code}.`)));
  });
}
export async function resolveRecordingFile(file: string) {
  const configuredRoot = process.env.ROBLOX_MCP_RECORDING_ROOT;
  if (!configuredRoot) throw new Error("Set ROBLOX_MCP_RECORDING_ROOT to the host directory containing explicitly imported recordings.");
  const root = await realpath(configuredRoot), resolved = await realpath(file);
  const relative = path.relative(root, resolved);
  if (!relative || relative.startsWith(`..${path.sep}`) || relative === ".." || path.isAbsolute(relative)) throw new Error("Recording file is outside the configured import directory.");
  const info = await stat(resolved);
  if (!info.isFile() || info.size > 512 * 1024 * 1024) throw new Error("Import requires a regular file of at most 512 MiB.");
  if (!/\.(mp4|mov|mkv|webm|avi)$/i.test(resolved)) throw new Error("Unsupported video container.");
  return resolved;
}
export async function probeRecording(file: string) {
  const result = await mediaProcess(ffprobeBinary(), ["-v", "error", "-protocol_whitelist", "file,pipe", "-format_whitelist", "mov,matroska,avi", "-threads", "2",
    "-select_streams", "v:0", "-read_intervals", "%+120", "-show_entries",
    "stream=width,height,time_base,avg_frame_rate:format=duration:frame=best_effort_timestamp_time,pkt_duration_time,key_frame", "-of", "json", file]);
  const data = JSON.parse(result.toString("utf8"));
  if (!data.streams?.length || !Array.isArray(data.frames)) throw new Error("No supported video stream or frame timestamps.");
  const timestamps = data.frames.map((frame: any) => Number(frame.best_effort_timestamp_time));
  if (!timestamps.length || !timestamps.every(Number.isFinite)) throw new Error("Video has missing presentation timestamps; exact frame indexing is unavailable.");
  return { stream: data.streams[0], durationSeconds: Number(data.format?.duration) || undefined,
    timestamps, indexedThroughSeconds: timestamps[timestamps.length - 1], maximumIndexSeconds: 120 };
}
export async function extractRecordingFrame(file: string, frameIndex: number) {
  if (!Number.isInteger(frameIndex) || frameIndex < 0) throw new Error("Invalid video frame index.");
  return mediaProcess(ffmpegBinary(), ["-v", "error", "-nostdin", "-protocol_whitelist", "file,pipe", "-format_whitelist", "mov,matroska,avi", "-threads", "2",
    "-i", file, "-map", "0:v:0", "-frames:v", "1", "-vf", `select=eq(n\\,${frameIndex}),scale=1280:720:force_original_aspect_ratio=decrease`,
    "-f", "image2pipe", "-c:v", "mjpeg", "pipe:1"], true);
}
