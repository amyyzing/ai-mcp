import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { resolveToolClientId, type ToolRoutingContext } from "../../factory.js";
import { sendAndWaitStructured } from "../advanced/structured.js";
import {
  dexInspectInputSchema,
  dexOutputSchema,
  dexQueryInputSchema,
  dexReferencesInputSchema,
  dexSelectionInputSchema,
  dexRevealInputSchema,
  dexSnapshotInputSchema,
  dexWatchInputSchema,
} from "./schemas.js";

interface RoutedInput {
  clientId?: string;
  maxOutputChars?: number;
  [key: string]: unknown;
}

// The MCP SDK publishes only top-level objects. Keep the strict union as the
// validator, but advertise its fields in an object so tools/list is not empty.
// Defaults are applied by the original schema AFTER operation validation;
// otherwise defaults from an initial query could pollute a continuation.
function publishedObject(variants: readonly z.ZodObject[]) {
  const shapes = variants.map((variant) => variant.shape as Record<string, z.ZodType>);
  const fields: Record<string, z.ZodType> = {};
  const keys = new Set(shapes.flatMap((shape) => Object.keys(shape)));
  for (const key of keys) {
    const candidates = [...new Set(shapes.map((shape) => shape[key]).filter(Boolean))];
    const required = candidates.length > 0 && shapes.every((shape) => shape[key] && !shape[key].isOptional());
    const choices = candidates.map((schema) => schema instanceof z.ZodDefault ? schema.removeDefault() as z.ZodType : schema);
    const field = choices.length === 1 ? choices[0] : z.union([choices[0], choices[1], ...choices.slice(2)]);
    fields[key] = required ? field : field.optional();
  }
  return z.object(fields).strict();
}

function dispatch(type: string, input: RoutedInput, routing: ToolRoutingContext) {
  const { clientId, maxOutputChars, ...data } = input;
  return sendAndWaitStructured({
    type,
    data: { ...data, maxChars: maxOutputChars ?? 20000 },
    clientId: resolveToolClientId(clientId, routing),
    timeoutMs: 30000,
    maxOutputChars: maxOutputChars ?? 20000,
    stampClient: true,
    truncationHint: "Use the returned cursor with a smaller limit, or request fewer projected properties/targets. Results cover only client-visible, currently streamed instances.",
  });
}

export default function registerDexTools(server: McpServer, routing: ToolRoutingContext): void {
  const definitions = [
    {
      name: "dex-selection",
      title: "Read the selection in the Dex explorer",
      description: "Read the current compatible Dex UI selection in this Roblox client as exact reusable instance handles. Dex and the MCP connector must run in the same executor. Does not search the game or modify selection.",
      inputSchema: dexSelectionInputSchema,
      idempotent: true,
    },
    {
      name: "dex-reveal",
      title: "Reveal one instance in the Dex explorer",
      description: "Select and reveal an exact instance handle or path in the compatible Dex UI on this client. Changes only explorer UI selection, not the Roblox instance. Prefer a handle for duplicate-name siblings or renamed instances.",
      inputSchema: dexRevealInputSchema,
      idempotent: true,
    },
    {
      name: "dex-inspect",
      title: "Inspect Roblox instances with class-aware Dex profiles",
      description: "Inspect up to 20 instances by strict path or stable runtime handle, including class-aware property profiles, selected properties, attributes, tags, bounds, ancestors and paged children. Hidden-property reads are opt-in. Returns per-field errors instead of requiring handwritten probes. Client-only: streamed-out objects and server-only source/state are unavailable.",
      inputSchema: dexInspectInputSchema,
      idempotent: true,
    },
    {
      name: "dex-query",
      title: "Query and page the client-visible Roblox hierarchy",
      description: "Perform a bounded, resumable Dex scan with name/class/tag/attribute/text filters and selected property projections. Continue captured scans using only the returned cursor and page/time budgets, even if a page has no matches. Optionally retain projected results for dex-snapshot. Scans are not atomic and cover only currently client-visible streamed instances, never hidden server-only source.",
      inputSchema: dexQueryInputSchema,
      idempotent: false,
    },
    {
      name: "dex-snapshot",
      title: "Inspect and compare retained Dex scan snapshots",
      description: "List, page, diff or release snapshots retained by dex-query. Diffs compare only retained projected fields and instance identities; missing fields are not evidence of no change. Snapshots are non-atomic client-visible scans, scoped to the connector generation, not complete server or streamed-out game state.",
      inputSchema: dexSnapshotInputSchema,
      idempotent: false,
    },
    {
      name: "dex-references",
      title: "Find instance-valued property references",
      description: "Find client-visible instances whose selected ordinary properties reference one target, including ObjectValue.Value, joints, attachments, model PrimaryPart, GUI Adornee and camera subjects. Uses bounded resumable scans. Continue with cursor only plus page/time budgets. This is not a GC reference search and does not reveal server-only or streamed-out references.",
      inputSchema: dexReferencesInputSchema,
      idempotent: false,
    },
    {
      name: "dex-watch",
      title: "Observe bounded instance property and hierarchy changes",
      description: "Start, poll or stop an expiring observation of selected properties/attributes, child additions/removals and ancestry changes on up to 10 instances. Poll cursors expose bounded event history without repeated full scans. Reads only game state; watcher lifecycle changes connector-local caches. Events describe observed client state, not proof of server-side effects.",
      inputSchema: dexWatchInputSchema,
      idempotent: false,
    },
  ];
  for (const definition of definitions) {
    const validationSchema = definition.inputSchema;
    const inputSchema = validationSchema instanceof z.ZodObject ? validationSchema :
      publishedObject(validationSchema.options).superRefine((input, context) => {
        const parsed = validationSchema.safeParse(input);
        if (!parsed.success) {
          for (const issue of parsed.error.issues) {
            context.addIssue({ code: "custom", path: issue.path, message: issue.message });
          }
        }
      });
    server.registerTool(definition.name, {
      title: definition.title,
      description: definition.description,
      inputSchema,
      outputSchema: dexOutputSchema,
      annotations: {
        readOnlyHint: definition.name !== "dex-reveal",
        destructiveHint: false,
        idempotentHint: definition.idempotent,
        openWorldHint: true,
      },
    }, (input: RoutedInput) => dispatch(definition.name, validationSchema.parse(input), routing));
  }
}
