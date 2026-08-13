import { z } from "zod";

export const clientIdSchema = z
  .string()
  .min(1)
  .max(160)
  .describe(
    "Optional connected Roblox client ID (full ID or unique prefix). Required when multiple clients are connected and none is selected."
  )
  .optional();

export const threadContextSchema = z
  .number()
  .int()
  .min(0)
  .max(8)
  .describe(
    "The thread identity to execute the code in (default: 8, normal game scripts run on 2)"
  )
  .optional()
  .default(8);

export const maxOutputCharsSchema = z
  .number()
  .int()
  .min(1000)
  .max(32000)
  .describe(
    "Maximum characters to return to the model (default: 6000, max: 32000). Raise only when a single result genuinely needs more; large outputs degrade model performance."
  )
  .optional()
  .default(6000);
