#!/usr/bin/env node

import { registerLocalDecompilerLifetime } from "./decompiler/local-process-lifetime.js";
import { startAsPrimary } from "./bridge/handlers/server/primary.js";
import { installServerLogCapture } from "./http/server-logs.js";

installServerLogCapture();
registerLocalDecompilerLifetime();

startAsPrimary()
  .then(() => {
    console.error("[Core] Background MCP core is ready.");
  })
  .catch((error: NodeJS.ErrnoException) => {
    if (error.code === "EADDRINUSE") {
      console.error("[Core] Another process already owns the MCP core port.");
    } else {
      console.error("[Core] Failed to start:", error);
    }
    process.exit(1);
  });
