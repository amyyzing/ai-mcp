// Read-only deployed checks. Credentials remain in memory and are never printed.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

const [base, service, requestedClient] = process.argv.slice(2);
if (!base || new URL(base).protocol !== 'https:' || !service)
  throw new Error('Usage: node scripts/verify-workflow-deployment.mjs HTTPS_URL SERVICE [CLIENT_ID]');
const variables = JSON.parse(execFileSync(process.env.RAILWAY_BIN || 'railway', ['variables', '--service', service, '--json'], {
  encoding: 'utf8', windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'], timeout: 20000,
}));
assert.ok(variables.ROBLOX_MCP_AUTH_TOKEN, 'Missing service credential.');
const clients = [];
const parsed = result => JSON.parse(result.content[0].text);
const connect = async profile => {
  const client = new Client({ name: 'workflow-deployment-check', version: '1' }); clients.push(client);
  await client.connect(new StreamableHTTPClientTransport(new URL('/mcp', base), { requestInit: { headers: {
    Authorization: `Bearer ${variables.ROBLOX_MCP_AUTH_TOKEN}`, 'x-roblox-mcp-tool-profile': profile,
  } } }));
  return client;
};
try {
  const full = await connect('full'); const compact = await connect('compact');
  const fullTools = await full.listTools(); const compactTools = await compact.listTools();
  assert.equal(compactTools.tools.length, 5);
  assert.ok(fullTools.tools.find(tool => tool.name === 'devirtualize-luraph').inputSchema.properties.artifactId);
  const catalog = parsed(await compact.callTool({ name: 'tool-catalog', arguments: { name: 'devirtualize-luraph' } }));
  assert.ok(catalog.inputSchema.properties.artifactId);
  const connected = await compact.callTool({ name: 'tool-call', arguments: { tool: 'list-clients', format: 'full' } });
  assert.ok(!connected.isError);
  const live = connected.structuredContent.clients;
  const clientId = requestedClient || (live.length === 1 ? live[0].clientId : undefined);
  assert.ok(clientId && live.some(c => c.clientId === clientId), 'Supply an exact connected client ID if zero/multiple clients are present.');
  const diagnosis = parsed(await compact.callTool({ name: 'diagnose-connection', arguments: { clientId } }, undefined, { timeout: 60000 }));
  assert.equal(diagnosis.status, 'connected');
  const batchResponse = await compact.callTool({ name: 'batch-read', arguments: { clientId, requests: [
    { tool: 'runtime-status' }, { tool: 'get-console-output', arguments: { limit: 3 } }, { tool: 'script-index-status' },
  ], previewChars: 250 } }, undefined, { timeout: 120000 });
  assert.ok(!batchResponse.isError);
  const batch = parsed(batchResponse); assert.equal(batch.completed, 3);
  assert.ok(batch.results.every(result => result.ok && result.retained), 'One or more live observations failed.');
  let originalChars = 0;
  for (const result of batch.results) {
    let offset = 0; let raw = '';
    do {
      const response = await compact.callTool({ name: 'result-read', arguments: { resultId: result.resultId, offset, limit: 1000 } });
      assert.ok(!response.isError); const page = parsed(response); raw += page.text; offset = page.nextOffset;
    } while (offset !== null);
    assert.equal(raw.length, result.totalChars); assert.ok(!JSON.parse(raw).isError); originalChars += raw.length;
    assert.equal((await full.callTool({ name: 'result-read', arguments: { resultId: result.resultId } })).isError, true);
    await compact.callTool({ name: 'result-read', arguments: { resultId: result.resultId, release: true } });
    assert.equal((await compact.callTool({ name: 'result-read', arguments: { resultId: result.resultId } })).isError, true);
  }
  const denied = await compact.callTool({ name: 'batch-read', arguments: { clientId, requests: [{ tool: 'execute', arguments: {} }] } });
  assert.equal(denied.isError, true); assert.equal(parsed(denied).dispatched, 0);
  console.log(JSON.stringify({ passed: true, fullTools: fullTools.tools.length, compactTools: compactTools.tools.length,
    fullSchemaChars: JSON.stringify(fullTools).length, compactSchemaChars: JSON.stringify(compactTools).length,
    liveDiagnosis: diagnosis.status, liveReadChecks: batch.completed, exactPaging: true, sessionIsolation: true,
    releaseVerified: true, mutationBatchRejected: true, originalResponseChars: originalChars,
    batchResponseChars: batchResponse.content[0].text.length }));
} finally { await Promise.allSettled(clients.map(client => client.close())); }
