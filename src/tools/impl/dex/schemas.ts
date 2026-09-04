import { z } from "zod";
import { clientIdSchema } from "../../schemas.js";
import { instanceTargetSchema } from "../advanced/schemas.js";
import { runtimeHandleSchema } from "../runtime/schemas.js";

const propertyName = z.string().regex(/^[A-Za-z_][A-Za-z0-9_]*$/).max(100);
const identifier = z.string().min(1).max(160);
const common = {
  clientId: clientIdSchema,
  maxOutputChars: z.number().int().min(2000).max(32000).optional().default(20000)
    .describe("Page output budget; continuation metadata is preserved. Default 20000, maximum 32000 characters."),
};

export const dexTargetSchema = z.union([
  instanceTargetSchema.strict(),
  z.object({ handle: runtimeHandleSchema }).strict(),
]).describe("An unambiguous strict instance path or a generation-scoped Instance handle returned by Dex/runtime tools.");

export const dexInspectInputSchema = z.object({
  ...common,
  targets: z.array(dexTargetSchema).min(1).max(20),
  properties: z.array(propertyName).max(80).optional().default([]),
  profile: z.enum(["auto", "none"]).optional().default("auto"),
  includeHidden: z.boolean().optional().default(false),
  includeAttributes: z.boolean().optional().default(true),
  includeTags: z.boolean().optional().default(true),
  includeBounds: z.boolean().optional().default(true),
  includeChildren: z.boolean().optional().default(true),
  includeAncestors: z.boolean().optional().default(true),
  childOffset: z.number().int().nonnegative().optional().default(0),
  childLimit: z.number().int().min(0).max(100).optional().default(20),
}).strict();

const scanPage = {
  ...common,
  limit: z.number().int().min(1).max(100).optional().default(25),
  scanBudget: z.number().int().min(1).max(10000).optional().default(1000),
  timeBudgetMs: z.number().int().min(1).max(50).optional().default(8),
};
const scanScope = {
  root: dexTargetSchema.optional().default({ path: "workspace", root: "game" }),
  maxDepth: z.number().int().min(0).max(100).optional().default(64),
  maxNodes: z.number().int().min(1).max(100000).optional().default(50000),
};
const scanContinuation = z.object({
  ...scanPage,
  cursor: identifier.describe("Opaque cursor from the previous page. Continue with only cursor and page/time/output budgets; scope and projections are captured by the initial request."),
}).strict();

export const dexQueryFiltersSchema = z.object({
  nameContains: z.string().max(200).optional(),
  className: z.string().max(100).optional(),
  isA: z.string().max(100).optional(),
  tag: z.string().max(100).optional(),
  attribute: z.object({
    name: z.string().min(1).max(100),
    equals: z.union([z.string().max(1000), z.number(), z.boolean()]).optional(),
  }).strict().optional(),
  textContains: z.string().max(200).optional(),
  caseSensitive: z.boolean().optional().default(false),
}).strict();

// Separate initial and continuation shapes prevent a new query silently replacing a captured scan.
export const dexQueryInputSchema = z.union([
  z.object({
    ...scanPage,
    ...scanScope,
    filters: dexQueryFiltersSchema.optional(),
    properties: z.array(propertyName).max(20).optional().default([]),
    includeAttributes: z.boolean().optional().default(false),
    includeTags: z.boolean().optional().default(false),
    retainSnapshot: z.boolean().optional().default(false),
  }).strict(),
  scanContinuation,
]);

const snapshotPage = {
  ...common,
  cursor: z.number().int().nonnegative().optional().default(0),
  limit: z.number().int().min(1).max(100).optional().default(25),
};

export const dexSnapshotInputSchema = z.discriminatedUnion("operation", [
  z.object({ ...common, operation: z.literal("list") }).strict(),
  z.object({ ...snapshotPage, operation: z.literal("page"), snapshotId: identifier }).strict(),
  z.object({ ...snapshotPage, operation: z.literal("diff"), beforeId: identifier, afterId: identifier }).strict(),
  z.object({ ...common, operation: z.literal("release"), snapshotId: identifier }).strict(),
]);

export const DEFAULT_REFERENCE_PROPERTIES = [
  "Value", "PrimaryPart", "Adornee", "Part0", "Part1", "Attachment0", "Attachment1", "CameraSubject", "CurrentCamera",
];

export const dexReferencesInputSchema = z.union([
  z.object({
    ...scanPage,
    ...scanScope,
    target: dexTargetSchema,
    properties: z.array(propertyName).max(20).optional().default(DEFAULT_REFERENCE_PROPERTIES),
  }).strict(),
  scanContinuation,
]);

export const dexWatchInputSchema = z.discriminatedUnion("operation", [
  z.object({
    ...common,
    operation: z.literal("start"),
    targets: z.array(dexTargetSchema).min(1).max(10),
    properties: z.array(propertyName).max(20).optional().default([]),
    attributes: z.array(z.string().min(1).max(100)).max(20).optional().default([]),
    includeChildren: z.boolean().optional().default(true),
    includeAncestry: z.boolean().optional().default(true),
    maxEvents: z.number().int().min(1).max(500).optional().default(200),
    ttlSeconds: z.number().int().min(30).max(3600).optional().default(300),
  }).strict(),
  z.object({
    ...common,
    operation: z.literal("poll"),
    watcherId: identifier,
    cursor: z.number().int().nonnegative().optional(),
    limit: z.number().int().min(1).max(100).optional().default(50),
  }).strict(),
  z.object({ ...common, operation: z.literal("stop"), watcherId: identifier }).strict(),
]);

export const dexOutputSchema = z.object({}).passthrough();

export const dexSelectionInputSchema = z.object({
  ...common,
  offset: z.number().int().min(0).max(100).optional().default(0),
  limit: z.number().int().min(1).max(50).optional().default(25),
}).strict();

export const dexRevealInputSchema = z.object({ ...common, target: dexTargetSchema }).strict();
