import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";
import { mcpServerEntry, mcpServersRecipe, mcpServersRecipeJson } from "../src/shared/mcp-recipe.mjs";

test("builds the standard mcpServers recipe for a server root", () => {
  const serverEntry = mcpServerEntry("/tmp/roblox-mcp");
  assert.equal(serverEntry, path.join("/tmp/roblox-mcp", "dist", "index.js"));
  assert.deepEqual(mcpServersRecipe(serverEntry, "roblox-mcp"), {
    mcpServers: {
      "roblox-mcp": {
        command: "node",
        args: [serverEntry, "--server-name", "roblox-mcp"],
      },
    },
  });
  assert.match(mcpServersRecipeJson(serverEntry), /"mcpServers"/);
  assert.match(mcpServersRecipeJson(serverEntry), /"--server-name"/);
});
