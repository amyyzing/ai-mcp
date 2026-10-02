import { z } from "zod";

/** MCP requires a top-level object; operation-specific validation stays authoritative. */
export function publishedObject(variants: readonly z.ZodObject[]) {
  const shapes = variants.map(variant => variant.shape as Record<string, z.ZodType>);
  const fields: Record<string, z.ZodType> = {};
  for (const key of new Set(shapes.flatMap(shape => Object.keys(shape)))) {
    const candidates = [...new Set(shapes.map(shape => shape[key]).filter(Boolean))];
    const required = shapes.every(shape => shape[key] && !shape[key].isOptional());
    const choices = candidates.map(schema => schema instanceof z.ZodDefault ? schema.removeDefault() as z.ZodType : schema);
    const field = choices.length === 1 ? choices[0] : z.union([choices[0], choices[1], ...choices.slice(2)]);
    fields[key] = required ? field : field.optional();
  }
  return z.object(fields).passthrough();
}

export function publishSchema(schema: z.ZodType): z.ZodType {
  if (schema instanceof z.ZodUnion && schema.options.every(option => option instanceof z.ZodObject)) {
    return publishedObject(schema.options as z.ZodObject[]).superRefine((input, context) => {
      const parsed = schema.safeParse(input);
      if (!parsed.success) for (const issue of parsed.error.issues)
        context.addIssue({ code: "custom", path: issue.path, message: issue.message });
    });
  }
  return schema;
}
