import { createHash, randomBytes, randomUUID } from "node:crypto";
import { z } from "zod";
import { normalizeFrame } from "./vision.js";
import type { DeviceFrame } from "../platform/windows-capture.js";

const hash = (token: string) => createHash("sha256").update(token).digest("hex");
const text = z.string().min(1).max(160);
export const uploadSchema = z.object({
  sequence: z.number().int().positive(), capturedAtUnixMs: z.number().finite().nonnegative(),
  ptsMs: z.number().finite().nonnegative(), imageBase64: z.string().min(4).max(2000000).regex(/^[A-Za-z0-9+/]*={0,2}$/),
  backend: z.enum(["android-mediaprojection", "windows-graphics-capture", "printwindow-fallback"]),
  rotation: z.union([z.literal(0), z.literal(90), z.literal(180), z.literal(270)]).default(0),
  coordinateSpace: z.enum(["window", "app", "display"]).default("app"),
}).strict();
export const telemetrySchema = z.object({
  sequence: z.number().int().positive(), capturedAtUnixMs: z.number().finite().nonnegative(),
  placeId: text, jobId: text, build: z.string().max(200).optional(),
  events: z.array(z.object({ kind: z.enum(["console", "state", "span", "event", "source-map", "gap"]), name: z.string().max(160),
    atUnixMs: z.number().finite().nonnegative(), data: z.unknown() }).strict()).max(50),
}).strict();
export interface CompanionScope { kind: "capture" | "server"; clientId?: string; sessionId?: string; placeId?: string; jobId?: string }
interface Entry {
  id: string; owner: string; scope: CompanionScope; pairingHash?: string; tokenHash?: string; expiresAt: number; pairExpiresAt: number;
  label?: string; bootId?: string; clockOffsetEstimateMs?: number; pairedAt?: number; lastSeen?: number; sequence: number; dropped: number;
  busy: boolean; frame?: DeviceFrame; events: any[]; eventBytes: number; latestBuild?: string; closed?: boolean;
  listener?: (frame: DeviceFrame) => Promise<void>;
}
export class CompanionHub {
  private entries = new Map<string, Entry>();
  private prune() { for (const entry of this.entries.values()) if (Date.now() > entry.expiresAt) this.remove(entry); }
  private remove(entry: Entry) { entry.closed = true; entry.frame = undefined; entry.listener = undefined; this.entries.delete(entry.id); }
  create(owner: string, scope: CompanionScope) {
    this.prune();
    if (this.entries.size >= 32 || [...this.entries.values()].filter(entry => entry.owner === owner).length >= 4) throw new Error("Companion limit reached; revoke an old pairing.");
    const code = randomBytes(24).toString("base64url"), id = randomUUID();
    const entry: Entry = { id, owner, scope: { ...scope }, pairingHash: hash(code), expiresAt: Date.now() + 86400000,
      pairExpiresAt: Date.now() + 600000, sequence: 0, dropped: 0, busy: false, events: [], eventBytes: 0 };
    this.entries.set(id, entry);
    return { companionId: id, pairingCode: code, pairingExpiresAt: entry.pairExpiresAt, expiresAt: entry.expiresAt,
      scope, instruction: "Enter this one-use code in the companion on the capture device or your project server. The upload credential cannot execute tools or read evidence." };
  }
  claim(code: string, label: string, bootId: string, deviceUnixMs: number) {
    this.prune(); const key = hash(code);
    const entry = [...this.entries.values()].find(entry => entry.pairingHash === key && Date.now() <= entry.pairExpiresAt);
    if (!entry) throw new Error("Pairing code is invalid, expired, or already used.");
    const token = randomBytes(32).toString("base64url");
    entry.pairingHash = undefined; entry.tokenHash = hash(token); entry.label = label; entry.bootId = bootId; entry.pairedAt = Date.now();
    entry.clockOffsetEstimateMs = entry.pairedAt - deviceUnixMs;
    return { companionId: entry.id, uploadToken: token, scope: entry.scope, expiresAt: entry.expiresAt, serverUnixMs: entry.pairedAt,
      clockNote: "One-way offset estimate includes network delay; retain device timestamps and receipt time separately." };
  }
  authorize(token: string, kind: CompanionScope["kind"]) {
    this.prune(); const key = hash(token);
    const entry = [...this.entries.values()].find(entry => entry.tokenHash === key && entry.scope.kind === kind);
    if (!entry) throw new Error("Companion credential is invalid, expired, revoked, or has the wrong scope.");
    return entry;
  }
  private accept(entry: Entry, sequence: number) {
    if (entry.closed) throw new Error("Companion was revoked.");
    if (sequence <= entry.sequence) throw new Error("Duplicate or out-of-order companion sequence.");
    entry.dropped += Math.max(0, sequence - entry.sequence - 1); entry.sequence = sequence; entry.lastSeen = Date.now();
  }
  async upload(token: string, input: unknown) {
    const entry = this.authorize(token, "capture"), data = uploadSchema.parse(input);
    if (entry.busy) throw new Error("Previous frame is still processing; drop this frame and continue with a newer sequence.");
    if (entry.frame && data.ptsMs <= entry.frame.ptsMs) throw new Error("Capture clock restarted; pair again.");
    if (data.sequence <= entry.sequence) throw new Error("Duplicate or out-of-order companion sequence.");
    entry.busy = true;
    try {
      const frame = await normalizeFrame(Buffer.from(data.imageBase64, "base64"));
      this.accept(entry, data.sequence);
      entry.frame = { ...data, width: frame.width, height: frame.height, imageBase64: frame.bytes.toString("base64") };
      await entry.listener?.(entry.frame);
      return { accepted: true, sequence: entry.sequence, receivedAtUnixMs: entry.lastSeen, dropped: entry.dropped };
    } finally { entry.busy = false; }
  }
  telemetry(token: string, input: unknown) {
    const entry = this.authorize(token, "server"), data = telemetrySchema.parse(input);
    if (data.placeId !== entry.scope.placeId || (entry.scope.jobId && data.jobId !== entry.scope.jobId)) throw new Error("Project place/job does not match the pairing scope.");
    const json = JSON.stringify(data);
    if (Buffer.byteLength(json) > 64000) throw new Error("Telemetry batch exceeds 64 KB.");
    this.accept(entry, data.sequence); entry.latestBuild = data.build;
    for (const event of data.events) {
      const stored = { ...JSON.parse(JSON.stringify(event)), sequence: entry.sequence, receivedAtUnixMs: entry.lastSeen, jobId: data.jobId };
      entry.events.push(stored); entry.eventBytes += Buffer.byteLength(JSON.stringify(stored));
    }
    while (entry.events.length > 200 || entry.eventBytes > 256000) { entry.eventBytes -= Buffer.byteLength(JSON.stringify(entry.events.shift())); entry.dropped++; }
    return { accepted: true, sequence: entry.sequence, receivedAtUnixMs: entry.lastSeen, dropped: entry.dropped };
  }
  owned(owner: string, id: string) {
    this.prune(); const entry = this.entries.get(id);
    if (!entry || entry.owner !== owner) throw new Error("Companion is unavailable or belongs to another MCP session.");
    return entry;
  }
  list(owner: string) {
    this.prune(); return [...this.entries.values()].filter(entry => entry.owner === owner).map(entry => ({ companionId: entry.id, scope: entry.scope,
      label: entry.label, paired: Boolean(entry.tokenHash), expiresAt: entry.expiresAt, lastSeen: entry.lastSeen, sequence: entry.sequence,
      dropped: entry.dropped, retainedEvents: entry.events.length, latestBuild: entry.latestBuild, clockOffsetEstimateMs: entry.clockOffsetEstimateMs,
      clockUncertainty: "Unknown network delay; not a synchronized clock", recording: Boolean(entry.listener) }));
  }
  revoke(owner: string, id: string) { this.remove(this.owned(owner, id)); }
  close(owner: string) { for (const entry of this.entries.values()) if (entry.owner === owner) this.remove(entry); }
}
export const companions = new CompanionHub();
