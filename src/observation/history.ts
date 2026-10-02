import { randomUUID } from "node:crypto";

// Per MCP connection: immutable values, fixed byte/entry limits, explicit eviction.
export class EvidenceHistory {
  private static totalBytes = 0;
  private entries = new Map<string, { json: string; bytes: number }>();
  private bytes = 0;
  private closed = false;
  evicted = 0;
  constructor(private maxBytes = 16 * 1024 * 1024, private maxEntries = 256) {}
  put(value: unknown, id = randomUUID()): string {
    if (this.closed) throw new Error("Evidence session closed.");
    const json = JSON.stringify(value);
    const bytes = Buffer.byteLength(json);
    if (bytes > this.maxBytes) throw new Error("Evidence exceeds history byte limit.");
    this.remove(id);
    while (this.entries.size && (this.entries.size >= this.maxEntries || this.bytes + bytes > this.maxBytes)) {
      this.remove(this.entries.keys().next().value!); this.evicted++;
    }
    if (EvidenceHistory.totalBytes + bytes > 64 * 1024 * 1024) throw new Error("Server evidence memory limit reached; release old evidence or close idle MCP sessions.");
    this.entries.set(id, { json, bytes }); this.bytes += bytes;
    EvidenceHistory.totalBytes += bytes;
    while (this.entries.size > this.maxEntries || this.bytes > this.maxBytes) {
      this.remove(this.entries.keys().next().value!); this.evicted++;
    }
    return id;
  }
  get(id: string): any {
    const entry = this.entries.get(id);
    if (!entry) throw new Error("Evidence expired, was released, or belongs to another MCP connection.");
    return JSON.parse(entry.json);
  }
  remove(id: string) {
    const entry = this.entries.get(id);
    if (entry) { this.bytes -= entry.bytes; EvidenceHistory.totalBytes -= entry.bytes; }
    this.entries.delete(id);
  }
  clear() { for (const id of this.entries.keys()) this.remove(id); }
  close() { this.clear(); this.closed = true; }
  stats() { return { entries: this.entries.size, bytes: this.bytes, evicted: this.evicted }; }
}

export type RecordingEvent = { atMs: number; kind: string; data: any };
export interface Recording {
  recordingId: string; mode: "instrumented" | "imported" | "video"; state: "recording" | "processing" | "stopped" | "failed";
  clientId?: string; sessionId?: string; startedAtUnixMs: number; finishedAtUnixMs?: number;
  events: RecordingEvent[]; dropped: number; bytes: number; failureReason?: string;
  metadata?: any; cancel?: boolean; released?: boolean;
}
let recordingBytes = 0;
export function appendRecording(recording: Recording, event: RecordingEvent) {
  if (recording.released) return;
  const json = JSON.stringify(event);
  const size = Buffer.byteLength(json);
  if (size > 256000 || recordingBytes + size > 64 * 1024 * 1024) { recording.dropped++; return; }
  recording.events.push(JSON.parse(json)); recording.bytes += size;
  recordingBytes += size;
  while (recording.events.length > 1000 || recording.bytes > 4 * 1024 * 1024) {
    const removed = Buffer.byteLength(JSON.stringify(recording.events.shift()));
    recording.bytes -= removed; recordingBytes -= removed; recording.dropped++;
  }
}
export function releaseRecording(recording: Recording) {
  if (recording.released) return;
  recording.cancel = true; recording.released = true;
  recordingBytes -= recording.bytes; recording.bytes = 0; recording.events = [];
}
export function recordingSummary(row: Recording) {
  return { recordingId: row.recordingId, mode: row.mode, state: row.state, clientId: row.clientId,
    sessionId: row.sessionId, startedAtUnixMs: row.startedAtUnixMs, finishedAtUnixMs: row.finishedAtUnixMs,
    retainedEvents: row.events.length, dropped: row.dropped, bytes: row.bytes, failureReason: row.failureReason, metadata: row.metadata };
}
export function recordingPage(row: Recording, cursor = 0, limit = 20, kind?: string, text?: string) {
  const matches: any[] = []; let index = cursor;
  while (index < row.events.length && matches.length < limit) {
    const event = row.events[index++]!;
    if ((!kind || event.kind === kind) && (!text || JSON.stringify(event).toLowerCase().includes(text.toLowerCase()))) matches.push(event);
  }
  return { ...recordingSummary(row), events: matches, nextCursor: index, complete: index >= row.events.length,
    cursorNote: "Offsets refer to retained events; page a stopped recording for stable pagination." };
}
