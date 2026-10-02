import { randomUUID } from "node:crypto";
import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { ToolRoutingContext } from "./factory.js";
import { publishSchema } from "./schema-publication.js";

// Deliberately explicit: annotations alone do not make mixed-operation tools safe to batch.
export const BATCH_READ_TOOLS = new Set([
  "list-clients", "runtime-status", "get-game-info", "get-console-output", "console-read",
  "script-index-status", "list-scripts", "get-script-content", "search-instances",
  "get-descendants-tree", "inspect-instance", "dex-selection", "dex-inspect", "dex-query",
  "dex-references", "executor-capabilities",
]);
// Registration has heterogeneous SDK generics; keep type erasure at this adapter boundary.
type Config = { inputSchema?: any; description?: string; annotations?: Record<string, unknown>; [key: string]: any };
type Handler = (...args: any[]) => any;
interface Entry { config: Config; schema?: z.ZodType; handler: Handler }
const reply = (value: unknown, isError = false) => ({ content: [{ type: "text" as const, text: JSON.stringify(value) }], ...(isError ? { isError: true } : {}) });

export class WorkflowResults {
  private entries = new Map<string, { text: string; expires: number }>();
  constructor(private now = Date.now) {}
  private cleanup() {
    for (const [id, entry] of this.entries) if (entry.expires <= this.now()) this.entries.delete(id);
  }
  put(text: string): string | undefined {
    this.cleanup();
    if (text.length > 1024 * 1024) return undefined;
    let size = [...this.entries.values()].reduce((sum, entry) => sum + entry.text.length, 0);
    while (this.entries.size >= 16 || size + text.length > 4 * 1024 * 1024) {
      const first = this.entries.entries().next().value;
      if (!first) break;
      size -= first[1].text.length; this.entries.delete(first[0]);
    }
    const id = randomUUID(); this.entries.set(id, { text, expires: this.now() + 300000 }); return id;
  }
  read(id: string, offset: number, limit: number) {
    this.cleanup(); const entry = this.entries.get(id);
    if (!entry) throw new Error("Result unavailable: expired, evicted, released, or from another MCP session. Rerun the original read if a fresh observation is needed.");
    if (offset > entry.text.length) throw new Error("Offset exceeds result length.");
    const end = Math.min(entry.text.length, offset + limit);
    return { resultId: id, offset, totalChars: entry.text.length, text: entry.text.slice(offset, end), nextOffset: end < entry.text.length ? end : null };
  }
  release(id: string) { this.cleanup(); return this.entries.delete(id); }
  has(id: string) { this.cleanup(); return this.entries.has(id); }
}

/** Capture public registrations, not SDK private maps. Existing handlers/routing remain unchanged. */
export function createWorkflowLayer(server: McpServer, routing: ToolRoutingContext, profile: "full" | "compact" = "full") {
  const entries = new Map<string, Entry>();
  const results = new WorkflowResults();
  const facade = new Proxy(server, { get(target, key) {
    if (key !== "registerTool") { const value = Reflect.get(target, key); return typeof value === "function" ? value.bind(target) : value; }
    return (name: string, config: Config, handler: Handler) => {
      const schema = config.inputSchema instanceof z.ZodType ? config.inputSchema : config.inputSchema ? z.object(config.inputSchema) : undefined;
      const published = schema ? publishSchema(schema) : undefined;
      const wrapped: Handler = async (input, extra) => handler(schema ? await schema.parseAsync(input) : input, extra);
      entries.set(name, { config: { ...config, inputSchema: published }, schema, handler: wrapped });
      // Registrars do not use the returned handle; compact tools remain in this session's catalog.
      if (profile === "compact") return undefined;
      return server.registerTool(name, { ...config, ...(published ? { inputSchema: published } : {}) }, wrapped);
    };
  }});
  const invoke = async (name: string, args: Record<string, unknown>, extra: any) => {
    if (extra?.signal?.aborted) throw new Error("Request cancelled; no further reads dispatched.");
    const entry = entries.get(name);
    if (!entry) throw new Error(`Unknown tool: ${name}`);
    const response = await (entry.schema ? entry.handler(args, extra) : entry.handler(extra));
    if (!response.isError && entry.config.outputSchema) {
      const outputSchema = entry.config.outputSchema instanceof z.ZodType ? entry.config.outputSchema : z.object(entry.config.outputSchema);
      const checked = await outputSchema.safeParseAsync(response.structuredContent);
      if (!checked.success) throw new Error(`Tool ${name} returned invalid structured output. The operation may have completed; verify effects rather than replaying it.`);
    }
    return response;
  };
  const summarize = (name: string, response: any, startedAt: string, previewChars: number) => {
    const text = JSON.stringify(response);
    const resultId = results.put(text);
    // One canonical payload avoids duplicating text and structured data in the model context.
    const display = response.structuredContent !== undefined ? JSON.stringify(response.structuredContent) :
      (response.content ?? []).filter((block: any) => block.type === "text").map((block: any) => block.text).join("\n");
    return { tool: name, ok: response.isError !== true, startedAt, completedAt: new Date().toISOString(),
      preview: display.slice(0, previewChars), truncated: display.length > previewChars,
      ...(response.isError === true ? {errorText:(response.content ?? []).filter((block:any)=>block.type === "text").map((block:any)=>block.text).join("\n").slice(0,500)} : {}),
      resultId, retained: !!resultId, retention: resultId ? "5 minutes; this MCP session; bounded cache" : "Result exceeds cache limit; use original tool with narrower filters",
      totalChars: text.length };
  };
  const requestSchema = z.object({ tool: z.string().min(1).max(100), arguments: z.record(z.string(), z.unknown()).default({}) }).strict();
  const annotations = { readOnlyHint: true, destructiveHint: false, openWorldHint: true };
  const install = () => {
    server.registerTool("tool-call", {
      description:"Call one existing tool by exact name using arguments from tool-catalog. All original validation and client routing apply. Never retries. summary retains the exact response for result-read; full returns the original response. This tool CAN mutate the game when an action tool is explicitly requested. After a timeout verify effects before considering any retry.",
      inputSchema:z.object({tool:z.string().min(1).max(100),arguments:z.record(z.string(),z.unknown()).default({}),format:z.enum(["summary","full"]).default("summary"),previewChars:z.number().int().min(100).max(6000).default(1200)}),
      annotations:{readOnlyHint:false,destructiveHint:true,idempotentHint:false,openWorldHint:true},
    },async ({tool,arguments:args,format,previewChars},extra)=>{
      const startedAt=new Date().toISOString();
      try {const response=await invoke(tool,args,extra);return format==="full"?response:reply(summarize(tool,response,startedAt,previewChars),response.isError===true);}
      catch(error){return reply({tool,error:error instanceof Error?error.message:String(error),next:"No automatic retry was attempted. If this was an action or transport failure, verify effects before retrying."},true);}
    });
    server.registerTool("tool-catalog", {
      description: "Find tools by name/description, or request one tool's full argument schema. Existing tools remain directly callable. Prefer batch-read for independent observations and diagnose-connection for connectivity.",
      inputSchema: z.object({ query: z.string().max(200).default(""), name: z.string().max(100).optional(), offset: z.number().int().min(0).default(0), limit: z.number().int().min(1).max(30).default(12) }), annotations,
    }, async ({query, name, offset, limit}) => {
      if (name) { const entry = entries.get(name); if (!entry) return reply({error:"Unknown tool",name}, true);
        return reply({name, description:entry.config.description, batchRead:BATCH_READ_TOOLS.has(name), inputSchema:entry.config.inputSchema ? z.toJSONSchema(entry.config.inputSchema, {io:"input", unrepresentable:"any"}) : {type:"object",properties:{}}}); }
      const words = query.toLowerCase().split(/\s+/).filter(Boolean);
      const found = [...entries].filter(([name, entry]) => words.every(word => `${name} ${entry.config.description ?? ""}`.toLowerCase().includes(word)));
      return reply({ total:found.length, tools:found.slice(offset,offset+limit).map(([name,entry])=>({name,description:entry.config.description?.slice(0,180),batchRead:BATCH_READ_TOOLS.has(name)})),nextOffset:offset+limit<found.length?offset+limit:null });
    });
    server.registerTool("batch-read", {
      description: "Run 1–6 independent read-only tools in one call, sequentially to avoid connector queue overload. Explicit clientId required for client reads. Each result includes errors, bounded preview and a session-local resultId for full paging. Not an atomic snapshot; no automatic retries or mutations. Use tool-catalog for allowed tools and their schemas.",
      inputSchema:z.object({clientId:z.string().min(1).optional(),requests:z.array(requestSchema).min(1).max(6),previewChars:z.number().int().min(100).max(3000).default(700)}),annotations,
    }, async ({clientId, requests, previewChars}, extra) => {
      const prepared: {tool:string;arguments:Record<string,unknown>}[] = [];
      // Validate the entire batch before dispatching any part of it.
      for (const request of requests) {
        if (!BATCH_READ_TOOLS.has(request.tool) || !entries.has(request.tool)) return reply({error:`Tool not allowed in batch-read: ${request.tool}`,dispatched:0},true);
        const args = {...request.arguments};
        if (request.tool !== "list-clients") {
          const target = args.clientId ?? clientId;
          if (typeof target !== "string" || !target.trim()) return reply({error:"Explicit clientId required for each client read",tool:request.tool,dispatched:0},true);
          args.clientId = target;
        }
        const schema=entries.get(request.tool)!.schema;
        const parsed=schema?.safeParse(args);
        if (parsed && !parsed.success) return reply({error:"Invalid arguments",tool:request.tool,issues:parsed.error.issues,dispatched:0},true);
        prepared.push({tool:request.tool,arguments:args});
      }
      const observations: Record<string, any>[]=[];
      for (const request of prepared) {
        if (extra.signal.aborted) break;
        const startedAt = new Date().toISOString();
        try { observations.push(summarize(request.tool,await invoke(request.tool,request.arguments,extra),startedAt,previewChars)); }
        catch(error) { observations.push({tool:request.tool,ok:false,error:error instanceof Error?error.message:String(error),startedAt}); }
      }
      for (const observation of observations) {
        if (observation.resultId && !results.has(observation.resultId)) {
          observation.retained=false; delete observation.resultId;
          observation.retention="Evicted during this batch; use narrower queries or smaller batches.";
        }
      }
      return reply({atomic:false,requested:requests.length,completed:observations.length,cancelled:extra.signal.aborted,results:observations});
    });
    server.registerTool("result-read", {
      description:"Page or release an exact cached batch/diagnostic response without rerunning its tool. Offsets are UTF-16 characters. Historical observation, not refreshed state. Cache is session-local, five minutes, and may evict older entries.",
      inputSchema:z.object({resultId:z.string().uuid(),offset:z.number().int().min(0).default(0),limit:z.number().int().min(1).max(12000).default(4000),release:z.boolean().default(false)}),annotations,
    }, async ({resultId,offset,limit,release})=>{try{return reply(release?{released:results.release(resultId)}:results.read(resultId,offset,limit));}catch(error){return reply({error:(error as Error).message},true);}});
    server.registerTool("diagnose-connection", {
      description:"One-call connection diagnosis: list clients, resolve explicit/session selection, then probe runtime and capability status. Never selects another client, starts indexing, reloads scripts or retries actions. Full runtime response retained for result-read.",
      inputSchema:z.object({clientId:z.string().min(1).optional(),previewChars:z.number().int().min(100).max(3000).default(1200)}),annotations,
    }, async ({clientId,previewChars},extra)=>{
      try {
        const listed=await invoke("list-clients",{},extra);
        if(listed.isError) return reply({status:"bridge-unavailable",next:"Check the primary bridge connection.",detail:summarize("list-clients",listed,new Date().toISOString(),previewChars)},true);
        const clients=listed.structuredContent?.clients;
        if(!Array.isArray(clients)) return reply({status:"unverified",next:"Client list lacked structured metadata; use list-clients directly."},true);
        const requested=clientId ?? routing.selectedClientId;
        const exact=requested?clients.find((c:any)=>c.clientId===requested):undefined;
        const matches=exact?[exact]:requested?clients.filter((c:any)=>c.clientId.startsWith(requested)):clients;
        if(matches.length!==1) return reply({status:!clients.length?"disconnected":matches.length>1?"target-required":"target-unavailable",clients:clients.map((c:any)=>({clientId:c.clientId,placeName:c.placeName})),next:"Connect the intended client or supply its exact clientId; no client was selected."});
        const target=matches[0].clientId;
        const startedAt=new Date().toISOString();
        const runtime=await invoke("runtime-status",{clientId:target},extra);
        return reply({status:runtime.isError?"probe-failed":"connected",clientId:target,next:runtime.isError?"Inspect the retained error before retrying; no actions were replayed.":"Use batch-read with this clientId for independent reads. A connected transport does not guarantee every executor feature works.",runtime:summarize("runtime-status",runtime,startedAt,previewChars)},runtime.isError===true);
      }catch(error){return reply({status:"diagnostic-failed",error:(error as Error).message},true);}
    });
  };
  return {server:facade,install};
}
