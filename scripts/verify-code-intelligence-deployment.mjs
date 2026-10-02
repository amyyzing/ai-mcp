// Read-only deployed-tool checks for an explicitly prepared client-local fixture.
// No game mutation, source acquisition, credential output, or automatic client selection.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const [base, service, clientId, scriptId, dependencyId, mode = "initial"] = process.argv.slice(2);
if (!base || new URL(base).protocol !== "https:" || !service || !clientId || !scriptId || !dependencyId || !["initial","changed"].includes(mode))
  throw new Error("Usage: node scripts/verify-code-intelligence-deployment.mjs HTTPS_URL SERVICE CLIENT_ID SCRIPT_ID DEPENDENCY_ID [initial|changed]");
const variables = JSON.parse(execFileSync(process.env.RAILWAY_BIN || "railway", ["variables", "--service", service, "--json"], {
  encoding:"utf8", windowsHide:true, stdio:["ignore","pipe","pipe"],timeout:20000,
}));
assert.ok(variables.ROBLOX_MCP_AUTH_TOKEN,"Selected service has no agent credential.");
const client = new Client({name:"code-intelligence-deployment-verification",version:"1"});
try {
  await client.connect(new StreamableHTTPClientTransport(new URL("/mcp",base),{requestInit:{headers:{Authorization:`Bearer ${variables.ROBLOX_MCP_AUTH_TOKEN}`}}}));
  const listed = await client.listTools();
  assert.equal(listed.tools.filter(tool=>tool.name.startsWith("code-")).length,5);
  const connected=await client.callTool({name:"list-clients",arguments:{}});
  assert.ok(connected.structuredContent.clients.some(c=>c.clientId===clientId),"Explicit fixture client disconnected.");
  const call=async (name,refreshHierarchy=false)=>{
    const response=await client.callTool({name,arguments:{clientId,scriptId,sourceIds:[scriptId,dependencyId],line:2,character:24,refreshHierarchy}},undefined, {timeout:60000});
    assert.ok(!response.isError,JSON.stringify(response));
    assert.equal(response.structuredContent.freshness.state,"confirmed");
    return response.structuredContent;
  };
  const checked=await call("code-check",true);
  assert.equal(checked.document.sourceProducer,"ai-mcp-controlled-fixture");
  assert.equal(checked.coverage.linkedSources,2,JSON.stringify(checked.coverage));
  if(mode==="changed") {
    assert.ok(checked.result.some(d=>d.severity===1&&d.range.start.line===2),JSON.stringify(checked));
    console.log(JSON.stringify({mode,dependencyInvalidation:true,documentVersion:checked.document.version,freshness:checked.freshness.state,lspBuildId:checked.context.lspBuildId}));
  } else {
    assert.deepEqual(checked.result,[]);
    const definition=await call("code-definition");assert.ok(definition.result.some(location=>location.scriptId===dependencyId));
    const references=await call("code-references");assert.ok(references.result.length>=2);
    const type=await call("code-type-at");assert.ok(JSON.stringify(type.result).includes("string"));
    const symbols=await call("code-symbols");assert.ok(symbols.result.length>=2);
    console.log(JSON.stringify({mode,toolCount:listed.tools.length,fiveToolsPassed:true,linkedSources:checked.coverage.linkedSources,hierarchyComplete:checked.coverage.hierarchyComplete,lspBuildId:checked.context.lspBuildId}));
  }
} finally {await client.close();}
