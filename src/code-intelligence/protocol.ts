import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";

/** Small bounded LSP transport. No editor, shell, or automatic process attachment. */
export class LspTransport {
  readonly process: ChildProcessWithoutNullStreams;
  private buffer = Buffer.alloc(0);
  private sequence = 0;
  private stopped = false;
  private pending = new Map<number, { resolve: (value: any) => void; reject: (error: Error) => void; timer: NodeJS.Timeout }>();
  private stderr = "";
  onNotification: (method: string, params: any) => void = () => {};
  onRequest: (method: string, params: any) => unknown = () => null;
  onExit: () => void = () => {};

  constructor(binary: string, args: string[], cwd: string) {
    this.process = spawn(binary, args, { cwd, windowsHide: true, stdio: "pipe", shell: false });
    this.process.stdout.on("data", (chunk: Buffer) => {
      try { this.receive(chunk); } catch (error) { this.fail(error as Error); }
    });
    this.process.stderr.on("data", (chunk: Buffer) => { this.stderr = (this.stderr + chunk.toString()).slice(-2000); });
    this.process.stdin.on("error", (error) => this.fail(error));
    this.process.on("error", (error) => this.fail(error));
    this.process.on("exit", (code) => this.fail(new Error(`LSP exited (${code}): ${this.stderr}`)));
  }

  private send(message: unknown): void {
    if (this.stopped) throw new Error("LSP worker is closed.");
    const payload = Buffer.from(JSON.stringify(message));
    if (payload.length > 16 * 1024 * 1024 || this.process.stdin.writableLength > 24 * 1024 * 1024)
      throw new Error("LSP input budget exceeded; reduce the indexed scope.");
    this.process.stdin.write(Buffer.concat([Buffer.from(`Content-Length: ${payload.length}\r\n\r\n`), payload]));
  }

  notify(method: string, params: unknown = {}): void { this.send({ jsonrpc: "2.0", method, params }); }

  request(method: string, params: unknown = {}, timeoutMs = 15000): Promise<any> {
    if (this.pending.size >= 32) return Promise.reject(new Error("LSP request queue is full."));
    const id = ++this.sequence;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        try { this.notify("$/cancelRequest", { id }); } catch {}
        reject(new Error(`LSP ${method} timed out; analysis is not confirmed.`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      try { this.send({ jsonrpc: "2.0", id, method, params }); }
      catch (error) { clearTimeout(timer); this.pending.delete(id); reject(error); }
    });
  }

  private receive(chunk: Buffer): void {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (this.buffer.length) {
      const separator = this.buffer.indexOf("\r\n\r\n");
      if (separator < 0) {
        if (this.buffer.length > 8192) throw new Error("Invalid LSP frame header.");
        return;
      }
      if (separator > 8192) throw new Error("LSP header too large.");
      const matches = [...this.buffer.subarray(0, separator).toString("ascii").matchAll(/^Content-Length: *(\d+)\r?$/gim)];
      const length = Number(matches[0]?.[1]);
      if (matches.length !== 1 || !Number.isSafeInteger(length) || length <= 0 || length > 16 * 1024 * 1024)
        throw new Error("Invalid LSP content length.");
      if (this.buffer.length < separator + 4 + length) return;
      const message = JSON.parse(this.buffer.subarray(separator + 4, separator + 4 + length).toString("utf8"));
      this.buffer = this.buffer.subarray(separator + 4 + length);
      if (typeof message.method === "string") {
        if (message.id !== undefined) {
          try { this.send({ jsonrpc: "2.0", id: message.id, result: this.onRequest(message.method, message.params) ?? null }); }
          catch { this.send({ jsonrpc: "2.0", id: message.id, error: { code: -32603, message: "Client request failed" } }); }
        } else this.onNotification(message.method, message.params);
      } else {
        const pending = this.pending.get(message.id);
        if (!pending) continue; // Canceled, timed-out, or unsolicited response.
        this.pending.delete(message.id);
        clearTimeout(pending.timer);
        if (message.error) pending.reject(new Error(`LSP: ${String(message.error.message)}`));
        else pending.resolve(message.result);
      }
    }
  }

  private fail(error: Error): void {
    if (this.stopped) return;
    this.stopped = true;
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(error); }
    this.pending.clear();
    this.process.kill();
    this.onExit();
  }

  close(): void { this.fail(new Error("LSP worker replaced or closed.")); }
}
