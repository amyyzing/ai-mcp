import { z } from "zod";
import { clientIdSchema, maxOutputCharsSchema } from "../../schemas.js";

const boundedTimeoutMsSchema = z
  .number()
  .int()
  .min(100)
  .max(30000)
  .optional()
  .default(5000)
  .describe("How long to wait in milliseconds (default: 5000, max: 30000).");

const primitiveSchema = z.union([z.string(), z.number(), z.boolean()]);

export const instanceTargetSchema = z
  .object({
    path: z
      .string()
      .min(1)
      .max(2000)
      .optional()
      .describe(
        "Strict Roblox instance path rooted at game or workspace. Dot identifiers and quoted bracket segments are supported; code and method calls are rejected."
      ),
    pathSegments: z
      .array(z.string().max(200))
      .min(1)
      .max(100)
      .optional()
      .describe(
        "Unambiguous child/property segments below root. Prefer this when names contain punctuation."
      ),
    root: z
      .enum(["game", "workspace"])
      .optional()
      .default("game")
      .describe("Root used with pathSegments (default: game)."),
  })
  .refine((target) => Boolean(target.path) !== Boolean(target.pathSegments), {
    message: "Provide exactly one of path or pathSegments.",
  });

export const inspectInstanceInputSchema = z.object({
  clientId: clientIdSchema,
  target: instanceTargetSchema,
  properties: z
    .array(z.string().regex(/^[A-Za-z_][A-Za-z0-9_]*$/))
    .max(40)
    .optional()
    .default([])
    .describe("Optional Roblox properties to read (max: 40). Invalid properties are reported, not executed."),
  includeAttributes: z.boolean().optional().default(true),
  includeTags: z.boolean().optional().default(true),
  includeBounds: z.boolean().optional().default(true),
  includeChildren: z.boolean().optional().default(true),
  childLimit: z.number().int().min(0).max(100).optional().default(20),
  maxOutputChars: maxOutputCharsSchema,
});

export const searchGcInputSchema = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("function"),
    clientId: clientIdSchema,
    name: z.string().max(300).optional(),
    hash: z.string().max(500).optional(),
    constants: z.array(primitiveSchema).max(30).optional(),
    upvalues: z.array(primitiveSchema).max(30).optional(),
    ignoreExecutor: z.boolean().optional().default(true),
    limit: z.literal(1).optional().default(1),
    scanLimit: z.number().int().min(100).max(50000).optional().default(10000),
    maxOutputChars: maxOutputCharsSchema,
  }),
  z.object({
    kind: z.literal("table"),
    clientId: clientIdSchema,
    keys: z.array(primitiveSchema).max(30).optional(),
    values: z.array(primitiveSchema).max(30).optional(),
    keyValuePairs: z
      .record(z.string().max(200), primitiveSchema)
      .refine((value) => Object.keys(value).length <= 30, {
        message: "keyValuePairs is limited to 30 entries.",
      })
      .optional(),
    previewKeys: z.array(primitiveSchema).max(30).optional(),
    includeValues: z.boolean().optional().default(false),
    limit: z.literal(1).optional().default(1),
    scanLimit: z.number().int().min(100).max(50000).optional().default(10000),
    maxOutputChars: maxOutputCharsSchema,
  }),
]).superRefine((input, context) => {
  const hasCriteria = input.kind === "function"
    ? input.name !== undefined || input.hash !== undefined || Boolean(input.constants?.length) || Boolean(input.upvalues?.length)
    : Boolean(input.keys?.length) || Boolean(input.values?.length) || Boolean(input.keyValuePairs && Object.keys(input.keyValuePairs).length);
  if (!hasCriteria) {
    context.addIssue({
      code: "custom",
      message: "At least one GC search criterion is required.",
    });
  }
});

const waitBase = {
  clientId: clientIdSchema,
  timeoutMs: boundedTimeoutMsSchema,
  includeExisting: z.boolean().optional().default(false),
  maxOutputChars: maxOutputCharsSchema,
};

const journalCursor = {
  cursor: z
    .number()
    .int()
    .nonnegative()
    .optional()
    .describe("Resume after this journal cursor. Omit to wait only for new events."),
};

export const waitForEventInputSchema = z.discriminatedUnion("mode", [
  z.object({
    mode: z.literal("console"),
    ...waitBase,
    ...journalCursor,
    contains: z.string().max(500).optional(),
    caseSensitive: z.boolean().optional().default(false),
    level: z.string().max(100).optional(),
  }),
  z.object({
    mode: z.literal("instance"),
    ...waitBase,
    ...journalCursor,
    root: instanceTargetSchema.optional(),
    selector: z.string().max(1000).optional(),
    name: z.string().max(300).optional(),
    className: z.string().max(200).optional(),
    pathContains: z.string().max(500).optional(),
  }),
  z.object({
    mode: z.literal("attribute"),
    ...waitBase,
    target: instanceTargetSchema,
    attribute: z.string().min(1).max(200),
    condition: z.enum(["changed", "equals", "exists"]).optional().default("changed"),
    equals: z.union([z.string(), z.number(), z.boolean()]).optional(),
  }),
  z.object({
    mode: z.literal("remote"),
    ...waitBase,
    direction: z.enum(["Incoming", "Outgoing", "Both"]).optional().default("Both"),
    nameContains: z.string().max(300).optional(),
  }),
]).superRefine((input, context) => {
  if (input.mode === "attribute" && input.condition === "equals" && input.equals === undefined) {
    context.addIssue({ code: "custom", message: "equals is required when condition is equals." });
  }
  if (input.mode === "instance" && input.selector && input.cursor !== undefined) {
    context.addIssue({
      code: "custom",
      message: "cursor is not supported for selector waits; omit selector to use the instance journal.",
    });
  }
});

const inputBase = {
  clientId: clientIdSchema,
  maxOutputChars: maxOutputCharsSchema,
};

export const unifiedInputSchema = z.discriminatedUnion("action", [
  z.object({
    action: z.literal("key"),
    ...inputBase,
    key: z.string().min(1).max(80).describe("Enum.KeyCode name, such as E, Space, or LeftShift."),
    state: z.enum(["press", "down", "up"]).optional().default("press"),
    durationMs: z.number().int().min(0).max(2000).optional().default(40),
    repeatCount: z.number().int().min(1).max(20).optional().default(1),
  }),
  z.object({
    action: z.literal("text"),
    ...inputBase,
    text: z.string().max(2000),
    target: instanceTargetSchema.optional().describe("Optional TextBox to focus before sending text."),
    submit: z.boolean().optional().default(false),
  }),
  z.object({
    action: z.literal("mouse"),
    ...inputBase,
    event: z.enum(["move", "click", "down", "up"]),
    button: z.enum(["left", "right", "middle"]).optional().default("left"),
    x: z.number().finite().optional(),
    y: z.number().finite().optional(),
  }),
  z.object({
    action: z.literal("scroll"),
    ...inputBase,
    direction: z.enum(["up", "down"]),
    clicks: z.number().int().min(1).max(50).optional().default(1),
    x: z.number().finite().optional(),
    y: z.number().finite().optional(),
  }),
  z.object({
    action: z.literal("proximity-prompt"),
    ...inputBase,
    target: instanceTargetSchema,
    holdDuration: z.number().min(0).max(10).optional(),
  }),
  z.object({
    action: z.literal("click-detector"),
    ...inputBase,
    target: instanceTargetSchema,
    distance: z.number().min(0).max(10000).optional(),
  }),
  z.object({
    action: z.literal("touch"),
    ...inputBase,
    first: instanceTargetSchema,
    second: instanceTargetSchema,
    state: z.enum(["begin", "end", "tap"]).optional().default("tap"),
  }),
]);

export const scriptIndexResyncInputSchema = z.object({
  clientId: clientIdSchema,
  confirm: z
    .literal(true)
    .describe("Must be true because a full resync invalidates current mapping work and cached active source state."),
});

export const inspectInstanceOutputSchema = z.object({
  Name: z.string(),
  ClassName: z.string(),
  Path: z.string(),
  FullName: z.string().optional(),
  DebugId: z.string().optional(),
}).catchall(z.unknown());

export const searchGcOutputSchema = z.object({
  kind: z.enum(["function", "table"]),
  count: z.number(),
  limited: z.boolean(),
  results: z.array(z.record(z.string(), z.unknown())),
  fallbackUsed: z.boolean(),
}).catchall(z.unknown());

export const waitForEventOutputSchema = z.object({
  matched: z.boolean(),
  cursor: z.number().int().nonnegative(),
  timedOut: z.boolean().optional(),
  event: z.record(z.string(), z.unknown()).optional(),
}).catchall(z.unknown());

export const scriptIndexStatusOutputSchema = z.object({
  action: z.string(),
  enabled: z.boolean(),
  generation: z.number(),
  initialScanRunning: z.boolean(),
  initialScanFinished: z.boolean(),
  scanLimit: z.number().int().nonnegative(),
  scanTruncated: z.boolean(),
  scanOmitted: z.number().int().nonnegative(),
  finished: z.boolean(),
  total: z.number(),
  processed: z.number(),
  skipped: z.number(),
}).catchall(z.unknown());
