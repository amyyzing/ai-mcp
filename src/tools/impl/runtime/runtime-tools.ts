import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import {
  resolveToolClientId,
  type ToolRoutingContext,
} from "../../factory.js";
import { sendAndWaitStructured } from "../advanced/structured.js";
import {
  callbackInspectInputSchema,
  executorCapabilitiesInputSchema,
  gcDiffInputSchema,
  gcQueryInputSchema,
  gcSnapshotInputSchema,
  gcStatisticsInputSchema,
  genericRuntimeOutputSchema,
  propertyAccessInputSchema,
  runtimeActorsInputSchema,
  runtimeCallInputSchema,
  runtimeEnvironmentsInputSchema,
  runtimeHandlesInputSchema,
  runtimeInspectInputSchema,
  runtimeReadInputSchema,
  runtimeReferencesInputSchema,
  runtimeReleaseInputSchema,
  runtimeScriptsInputSchema,
  runtimeWriteInputSchema,
  signalConnectionsInputSchema,
} from "./schemas.js";

interface RoutedInput {
  clientId?: string;
  maxOutputChars?: number;
  [key: string]: unknown;
}

function dispatch(
  type: string,
  input: RoutedInput,
  routing: ToolRoutingContext,
  timeoutMs = 30_000,
  truncationHint?: string
) {
  const { clientId, maxOutputChars, ...data } = input;
  return sendAndWaitStructured({
    type,
    data,
    clientId: resolveToolClientId(clientId, routing),
    timeoutMs,
    maxOutputChars,
    stampClient: true,
    truncationHint,
  });
}

export default function registerRuntimeTools(
  server: McpServer,
  routing: ToolRoutingContext
): void {
  server.registerTool(
    "executor-capabilities",
    {
      title: "Probe executor runtime capabilities",
      description:
        "Return per-capability descriptors for GC, closure/debug, environment, script, signal, hidden-property, hook, actor, input, and transport APIs. Use this before choosing executor-specific runtime operations.",
      inputSchema: executorCapabilitiesInputSchema,
      outputSchema: genericRuntimeOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: true },
    },
    (input) => dispatch("executor-capabilities", input as RoutedInput, routing)
  );

  server.registerTool(
    "runtime-inspect",
    {
      title: "Inspect a runtime object handle",
      description:
        "Inspect a generation-scoped runtime handle. Tables are paged; functions include debug metadata plus optional constants, upvalues, and prototypes; Instances can return selected properties; connection/thread metadata is normalized.",
      inputSchema: runtimeInspectInputSchema,
      outputSchema: genericRuntimeOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: true },
    },
    (input) => dispatch(
      "runtime-inspect",
      input as RoutedInput,
      routing,
      30_000,
      "Page the handle with cursor/limit or request fewer function collections/properties."
    )
  );

  server.registerTool(
    "runtime-read",
    {
      title: "Read a runtime object member",
      description:
        "Read a table field, Instance property, function upvalue/constant/prototype, or object metatable through a runtime handle. Results use tagged runtime values and return handles for non-serializable objects.",
      inputSchema: runtimeReadInputSchema,
      outputSchema: genericRuntimeOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: true },
    },
    (input) => dispatch("runtime-read", input as RoutedInput, routing)
  );

  server.registerTool(
    "runtime-write",
    {
      title: "Write a runtime object member",
      description:
        "Write a table field, Instance property, function upvalue, or function constant through a runtime handle. Tagged handle values can reference other runtime objects. The previous value is returned.",
      inputSchema: runtimeWriteInputSchema,
      outputSchema: genericRuntimeOutputSchema,
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true },
    },
    (input) => dispatch("runtime-write", input as RoutedInput, routing)
  );

  server.registerTool(
    "runtime-call",
    {
      title: "Call a runtime function handle",
      description:
        "Invoke a function or callable-table handle with up to 32 tagged arguments and return tagged result values. This is useful for testing located closures without serializing or reconstructing them.",
      inputSchema: runtimeCallInputSchema,
      outputSchema: genericRuntimeOutputSchema,
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true },
    },
    (input) => dispatch("runtime-call", input as RoutedInput, routing, 120_000)
  );

  server.registerTool(
    "runtime-release",
    {
      title: "Release runtime object handles",
      description: "Release one or more runtime handles immediately instead of waiting for their connector TTL.",
      inputSchema: runtimeReleaseInputSchema,
      outputSchema: genericRuntimeOutputSchema,
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    },
    (input) => dispatch("runtime-release", input as RoutedInput, routing)
  );

  server.registerTool(
    "runtime-handles",
    {
      title: "List active runtime handles",
      description: "Page active runtime handles and registry statistics, optionally filtering by handle kind.",
      inputSchema: runtimeHandlesInputSchema,
      outputSchema: genericRuntimeOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    },
    (input) => dispatch("runtime-handles", input as RoutedInput, routing)
  );

  server.registerTool(
    "gc-snapshot",
    {
      title: "Create, list, or release GC snapshots",
      description:
        "Create an indexed executor GC snapshot whose functions/tables/threads become runtime handles, list retained snapshots, or release snapshot metadata. Snapshot creation requires getgc support.",
      inputSchema: gcSnapshotInputSchema,
      outputSchema: genericRuntimeOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: false, openWorldHint: true },
    },
    (input) => dispatch("gc-snapshot", input as RoutedInput, routing, 120_000)
  );

  server.registerTool(
    "gc-query",
    {
      title: "Query an indexed GC snapshot",
      description:
        "Page GC objects by kind, name, source, hash, signature, constants, upvalues, table keys/values, or table size. Returns reusable runtime handles instead of raw object dumps.",
      inputSchema: gcQueryInputSchema,
      outputSchema: genericRuntimeOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: true },
    },
    (input) => dispatch(
      "gc-query",
      input as RoutedInput,
      routing,
      60_000,
      "Use cursor/limit and narrower GC criteria, then inspect returned handles individually."
    )
  );

  server.registerTool(
    "gc-diff",
    {
      title: "Compare two GC snapshots",
      description:
        "Compare generation-stable handles across two GC snapshots and report added, removed, retained, and per-kind counts with bounded samples.",
      inputSchema: gcDiffInputSchema,
      outputSchema: genericRuntimeOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: true },
    },
    (input) => dispatch("gc-diff", input as RoutedInput, routing, 60_000)
  );

  server.registerTool(
    "gc-statistics",
    {
      title: "Summarize an indexed GC snapshot",
      description:
        "Report counts, function sources, table signatures, largest tables, and runtime-handle registry health for one GC snapshot.",
      inputSchema: gcStatisticsInputSchema,
      outputSchema: genericRuntimeOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: true },
    },
    (input) => dispatch("gc-statistics", input as RoutedInput, routing)
  );

  server.registerTool(
    "runtime-references",
    {
      title: "Find runtime object references",
      description:
        "Traverse one indexed GC snapshot to find incoming or outgoing table-field, upvalue, prototype, and metatable edges for a runtime handle. Returned objects are reusable handles.",
      inputSchema: runtimeReferencesInputSchema,
      outputSchema: genericRuntimeOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: true },
    },
    (input) => dispatch(
      "runtime-references",
      input as RoutedInput,
      routing,
      120_000,
      "Use direction, scanLimit, perObjectScanLimit, and limit to narrow the reference traversal."
    )
  );

  server.registerTool(
    "runtime-environments",
    {
      title: "Discover runtime environments",
      description:
        "Return handles for executor, Roblox, shared, script, or function environments using whatever APIs the current executor exposes.",
      inputSchema: runtimeEnvironmentsInputSchema,
      outputSchema: genericRuntimeOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: true },
    },
    (input) => dispatch("runtime-environments", input as RoutedInput, routing)
  );

  server.registerTool(
    "runtime-scripts",
    {
      title: "Inspect loaded and running script inventories",
      description:
        "Page executor-provided script, running-script, loaded-module, nil-instance, or all-instance inventories; optionally retrieve a script's runtime closure handle.",
      inputSchema: runtimeScriptsInputSchema,
      outputSchema: genericRuntimeOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: true },
    },
    (input) => dispatch("runtime-scripts", input as RoutedInput, routing, 60_000)
  );

  server.registerTool(
    "signal-connections",
    {
      title: "Inspect and control signal connections",
      description:
        "List getconnections metadata for a selected RBXScriptSignal, inspect returned connection handles, or enable, disable, disconnect, fire, defer, or fire the signal where supported.",
      inputSchema: signalConnectionsInputSchema,
      outputSchema: genericRuntimeOutputSchema,
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true },
    },
    (input) => dispatch("signal-connections", input as RoutedInput, routing)
  );

  server.registerTool(
    "property-access",
    {
      title: "Read and write ordinary or hidden properties",
      description:
        "Read or write an Instance property using ordinary access with hidden-property fallback, inspect scriptability, or change scriptability when the executor exposes those APIs. Values use the tagged runtime codec.",
      inputSchema: propertyAccessInputSchema,
      outputSchema: genericRuntimeOutputSchema,
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true },
    },
    (input) => dispatch("property-access", input as RoutedInput, routing)
  );

  server.registerTool(
    "callback-inspect",
    {
      title: "Inspect or replace callback properties",
      description:
        "Inspect callback-valued properties such as BindableFunction.OnInvoke or RemoteFunction.OnClientInvoke and return a function handle; optionally replace the callback with nil or another function handle.",
      inputSchema: callbackInspectInputSchema,
      outputSchema: genericRuntimeOutputSchema,
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true },
    },
    (input) => dispatch("callback-inspect", input as RoutedInput, routing)
  );

  server.registerTool(
    "runtime-actors",
    {
      title: "Inspect Actor and parallel-Luau inventories",
      description:
        "Page executor-visible Actor Instances or enumerate the thread handles associated with one Actor when getactors/getactorthreads are available.",
      inputSchema: runtimeActorsInputSchema,
      outputSchema: genericRuntimeOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: true },
    },
    (input) => dispatch("runtime-actors", input as RoutedInput, routing, 60_000)
  );
}
