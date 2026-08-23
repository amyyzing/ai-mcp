import { z } from "zod";
import { clientIdSchema, maxOutputCharsSchema } from "../../schemas.js";
import { instanceTargetSchema } from "../advanced/schemas.js";

export const runtimeHandleSchema = z
  .string()
  .min(1)
  .max(160)
  .regex(/^rh_[A-Za-z0-9_]+$/)
  .describe("Generation-scoped runtime handle returned by another runtime tool.");

const runtimeValueSchema = z
  .unknown()
  .refine((value) => value !== undefined, { message: "A tagged or primitive runtime value is required." })
  .describe(
    "A JSON primitive or tagged runtime value. Use {type:'handle',handle:'rh_...'} to pass a previously returned runtime object."
  );

const commonOutput = {
  clientId: clientIdSchema,
  maxOutputChars: maxOutputCharsSchema,
};

export const executorCapabilitiesInputSchema = z.object(commonOutput);

export const runtimeInspectInputSchema = z.object({
  ...commonOutput,
  handle: runtimeHandleSchema,
  cursor: z.number().int().nonnegative().optional().default(0),
  limit: z.number().int().min(1).max(200).optional().default(25),
  properties: z
    .array(z.string().regex(/^[A-Za-z_][A-Za-z0-9_]*$/).max(100))
    .max(100)
    .optional()
    .default([]),
  includeConstants: z.boolean().optional().default(true),
  includeUpvalues: z.boolean().optional().default(true),
  includePrototypes: z.boolean().optional().default(false),
});

const indexedMember = {
  handle: runtimeHandleSchema,
  index: z.number().int().min(1).max(100000),
  ...commonOutput,
};

export const runtimeReadInputSchema = z.discriminatedUnion("member", [
  z.object({ member: z.literal("field"), handle: runtimeHandleSchema, key: runtimeValueSchema, ...commonOutput }),
  z.object({
    member: z.literal("property"),
    handle: runtimeHandleSchema,
    property: z.string().regex(/^[A-Za-z_][A-Za-z0-9_]*$/).max(100),
    ...commonOutput,
  }),
  z.object({ member: z.literal("upvalue"), ...indexedMember }),
  z.object({ member: z.literal("constant"), ...indexedMember }),
  z.object({ member: z.literal("prototype"), ...indexedMember }),
  z.object({ member: z.literal("metatable"), handle: runtimeHandleSchema, ...commonOutput }),
]);

export const runtimeWriteInputSchema = z.discriminatedUnion("member", [
  z.object({
    member: z.literal("field"),
    handle: runtimeHandleSchema,
    key: runtimeValueSchema,
    value: runtimeValueSchema,
    ...commonOutput,
  }),
  z.object({
    member: z.literal("property"),
    handle: runtimeHandleSchema,
    property: z.string().regex(/^[A-Za-z_][A-Za-z0-9_]*$/).max(100),
    value: runtimeValueSchema,
    ...commonOutput,
  }),
  z.object({ member: z.literal("upvalue"), ...indexedMember, value: runtimeValueSchema }),
  z.object({ member: z.literal("constant"), ...indexedMember, value: runtimeValueSchema }),
]);

export const runtimeCallInputSchema = z.object({
  ...commonOutput,
  handle: runtimeHandleSchema,
  arguments: z.array(runtimeValueSchema).max(32).optional().default([]),
  threadIdentity: z.number().int().min(0).max(8).optional(),
});

export const runtimeReleaseInputSchema = z.object({
  ...commonOutput,
  handles: z.array(runtimeHandleSchema).min(1).max(500),
});

export const runtimeHandlesInputSchema = z.object({
  ...commonOutput,
  kind: z
    .enum(["table", "function", "thread", "instance", "connection", "signal", "userdata"])
    .optional(),
  cursor: z.number().int().nonnegative().optional().default(0),
  limit: z.number().int().min(1).max(200).optional().default(50),
});

const gcKindSchema = z.enum([
  "table",
  "function",
  "thread",
  "instance",
  "connection",
  "signal",
  "userdata",
]);

export const gcSnapshotInputSchema = z.discriminatedUnion("operation", [
  z.object({
    operation: z.literal("create"),
    ...commonOutput,
    kinds: z.array(gcKindSchema).max(7).optional().default([]),
    includeTables: z.boolean().optional().default(true),
    includeExecutor: z.boolean().optional().default(false),
    scanLimit: z.number().int().min(100).max(100000).optional().default(20000),
  }),
  z.object({ operation: z.literal("list"), ...commonOutput }),
  z.object({
    operation: z.literal("release"),
    ...commonOutput,
    snapshotId: z.string().min(1).max(160),
  }),
]);

const primitiveSchema = z.union([z.string(), z.number(), z.boolean()]);

export const gcQueryInputSchema = z.object({
  ...commonOutput,
  snapshotId: z.string().min(1).max(160),
  kind: gcKindSchema.optional(),
  name: z.string().max(300).optional(),
  hash: z.string().max(500).optional(),
  sourceContains: z.string().max(1000).optional(),
  signatureContains: z.string().max(1000).optional(),
  constants: z.array(primitiveSchema).max(50).optional(),
  upvalues: z.array(primitiveSchema).max(50).optional(),
  keys: z.array(primitiveSchema).max(50).optional(),
  values: z.array(primitiveSchema).max(50).optional(),
  keyValuePairs: z
    .record(z.string().max(200), primitiveSchema)
    .refine((value) => Object.keys(value).length <= 100, {
      message: "keyValuePairs is limited to 100 entries.",
    })
    .optional(),
  minEntries: z.number().int().nonnegative().optional(),
  maxEntries: z.number().int().nonnegative().optional(),
  ignoreExecutor: z.boolean().optional().default(true),
  cursor: z.number().int().nonnegative().optional().default(0),
  limit: z.number().int().min(1).max(200).optional().default(25),
});

export const gcDiffInputSchema = z.object({
  ...commonOutput,
  beforeSnapshotId: z.string().min(1).max(160),
  afterSnapshotId: z.string().min(1).max(160),
  sampleLimit: z.number().int().min(0).max(200).optional().default(50),
});

export const gcStatisticsInputSchema = z.object({
  ...commonOutput,
  snapshotId: z.string().min(1).max(160),
  largestTableLimit: z.number().int().min(0).max(100).optional().default(20),
});

export const runtimeReferencesInputSchema = z.object({
  ...commonOutput,
  snapshotId: z.string().min(1).max(160),
  handle: runtimeHandleSchema,
  direction: z.enum(["incoming", "outgoing", "both"]).optional().default("both"),
  limit: z.number().int().min(1).max(500).optional().default(100),
  scanLimit: z.number().int().min(100).max(100000).optional().default(20000),
  perObjectScanLimit: z.number().int().min(10).max(10000).optional().default(250),
});

export const runtimeEnvironmentsInputSchema = z.discriminatedUnion("operation", [
  z.object({ operation: z.literal("list"), ...commonOutput }),
  z.object({ operation: z.literal("script"), target: instanceTargetSchema, ...commonOutput }),
  z.object({ operation: z.literal("handle"), handle: runtimeHandleSchema, ...commonOutput }),
]);

export const runtimeScriptsInputSchema = z.discriminatedUnion("operation", [
  z.object({
    operation: z.literal("list"),
    ...commonOutput,
    collection: z
      .enum(["scripts", "running", "loaded-modules", "nil-instances", "all-instances"])
      .optional()
      .default("scripts"),
    includeHashes: z.boolean().optional().default(false),
    cursor: z.number().int().nonnegative().optional().default(0),
    limit: z.number().int().min(1).max(200).optional().default(50),
  }),
  z.object({ operation: z.literal("closure"), target: instanceTargetSchema, ...commonOutput }),
]);

const connectionOperationSchema = z.enum([
  "inspect",
  "enable",
  "disable",
  "disconnect",
  "fire",
  "defer",
]);

export const signalConnectionsInputSchema = z.union([
  z.object({
    operation: z.literal("list"),
    ...commonOutput,
    target: instanceTargetSchema,
    signal: z.string().regex(/^[A-Za-z_][A-Za-z0-9_]*$/).max(100),
    cursor: z.number().int().nonnegative().optional().default(0),
    limit: z.number().int().min(1).max(200).optional().default(50),
  }),
  z.object({
    operation: z.literal("fire-signal"),
    ...commonOutput,
    target: instanceTargetSchema,
    signal: z.string().regex(/^[A-Za-z_][A-Za-z0-9_]*$/).max(100),
    arguments: z.array(runtimeValueSchema).max(32).optional().default([]),
  }),
  z.object({
    operation: connectionOperationSchema,
    ...commonOutput,
    handle: runtimeHandleSchema,
    arguments: z.array(runtimeValueSchema).max(32).optional().default([]),
  }),
]);

const propertyBase = {
  ...commonOutput,
  target: instanceTargetSchema,
  property: z.string().regex(/^[A-Za-z_][A-Za-z0-9_]*$/).max(100),
};

export const propertyAccessInputSchema = z.discriminatedUnion("operation", [
  z.object({ operation: z.literal("read"), ...propertyBase }),
  z.object({
    operation: z.literal("write"),
    ...propertyBase,
    value: runtimeValueSchema,
    preferHidden: z.boolean().optional().default(true),
  }),
  z.object({ operation: z.literal("scriptable-status"), ...propertyBase }),
  z.object({
    operation: z.literal("set-scriptable"),
    ...propertyBase,
    scriptable: z.boolean(),
  }),
]);

export const callbackInspectInputSchema = z.discriminatedUnion("operation", [
  z.object({ operation: z.literal("inspect"), ...propertyBase }),
  z.object({
    operation: z.literal("replace"),
    ...propertyBase,
    value: runtimeValueSchema,
  }),
]);

export const runtimeActorsInputSchema = z.discriminatedUnion("operation", [
  z.object({
    operation: z.literal("list"),
    ...commonOutput,
    cursor: z.number().int().nonnegative().optional().default(0),
    limit: z.number().int().min(1).max(200).optional().default(50),
  }),
  z
    .object({
      operation: z.literal("threads"),
      ...commonOutput,
      handle: runtimeHandleSchema.optional(),
      target: instanceTargetSchema.optional(),
    })
    .refine((input) => Boolean(input.handle) !== Boolean(input.target), {
      message: "Provide exactly one Actor handle or target.",
    }),
]);

export const genericRuntimeOutputSchema = z.record(z.string(), z.unknown());
