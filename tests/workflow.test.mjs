import assert from 'node:assert/strict';
import test from 'node:test';
import { z } from 'zod';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { createWorkflowLayer, WorkflowResults } from '../dist/tools/workflow.js';
import { createMcpServer } from '../dist/mcp/server.js';

async function connect(server) {
 const [a,b]=InMemoryTransport.createLinkedPair(); const client=new Client({name:'workflow-test',version:'1'});
 await server.connect(a); await client.connect(b); return client;
}
const data = result => JSON.parse(result.content[0].text);
const response = value => ({content:[{type:'text',text:JSON.stringify(value)}],structuredContent:value});

test('all real operation schemas are discoverable over the actual MCP protocol', async()=>{
 const server=createMcpServer();const client=await connect(server);
 try{
  const {tools}=await client.listTools();
  for(const name of ['devirtualize-luraph','input','remote-spy','runtime-read','runtime-write','search-gc','wait-for-event','gc-snapshot']){
   const tool=tools.find(t=>t.name===name);assert.ok(tool,name);assert.ok(Object.keys(tool.inputSchema.properties).length>0,name);
  }
  const catalog=data(await client.callTool({name:'tool-catalog',arguments:{name:'devirtualize-luraph'}}));
  assert.ok(catalog.inputSchema.properties.artifactId);
  const invalid=await client.callTool({name:'devirtualize-luraph',arguments:{operation:'read'}});assert.equal(invalid.isError,true);
 }finally{await client.close();await server.close();}
});

test('publication preserves branch defaults, rejects invalid branches and retains passthrough semantics',async()=>{
 const server=new McpServer({name:'test',version:'1'});const layer=createWorkflowLayer(server,{});
 const schema=z.discriminatedUnion('operation',[
  z.object({operation:z.literal('one'),limit:z.number().default(9)}).passthrough(),
  z.object({operation:z.literal('two'),cursor:z.string()}).strict(),
 ]);
 layer.server.registerTool('sample',{inputSchema:schema},async input=>response(input));
 const client=await connect(server);
 try{
  const one=await client.callTool({name:'sample',arguments:{operation:'one',extra:true}});assert.deepEqual(one.structuredContent,{operation:'one',limit:9,extra:true});
  const two=await client.callTool({name:'sample',arguments:{operation:'two',cursor:'a'}});assert.deepEqual(two.structuredContent,{operation:'two',cursor:'a'});
  assert.equal((await client.callTool({name:'sample',arguments:{operation:'two'}})).isError,true);
  assert.equal((await client.callTool({name:'sample',arguments:{operation:'two',cursor:'a',extra:true}})).isError,true);
 }finally{await client.close();await server.close();}
});

test('batch preflight, per-item failure, exact paging, no retries, and session isolation',async()=>{
 const server=new McpServer({name:'test',version:'1'});const layer=createWorkflowLayer(server,{});const calls=[];
 layer.server.registerTool('get-game-info',{inputSchema:z.object({clientId:z.string(),fail:z.boolean().default(false)})},async input=>{calls.push(input);return input.fail?{content:[{type:'text',text:'fixture failure'}],isError:true}:response({body:'😀abc'.repeat(1000)});});
 layer.install();const client=await connect(server);
 try{
  const call=args=>client.callTool({name:'batch-read',arguments:args});
  assert.equal((await call({requests:[{tool:'get-game-info'}]})).isError,true);
  assert.equal((await call({clientId:'a',requests:[{tool:'get-game-info'},{tool:'execute'}]})).isError,true);assert.equal(calls.length,0);
  assert.equal((await call({clientId:'a',requests:[{tool:'get-game-info'},{tool:'get-game-info',arguments:{fail:7}}]})).isError,true);assert.equal(calls.length,0);
  const batch=data(await call({clientId:'a',requests:[{tool:'get-game-info'},{tool:'get-game-info',arguments:{fail:true}}],previewChars:100}));
  assert.equal(calls.length,2);assert.equal(batch.results[0].truncated,true);assert.equal(batch.results[1].ok,false);
  let text='',offset=0;const id=batch.results[0].resultId;
  do{const page=data(await client.callTool({name:'result-read',arguments:{resultId:id,offset,limit:79}}));text+=page.text;offset=page.nextOffset;}while(offset!==null);
  assert.equal(JSON.parse(text).structuredContent.body,'😀abc'.repeat(1000));assert.equal(calls.length,2);
  assert.throws(()=>new WorkflowResults().read(id,0,10),/unavailable/);
  await client.callTool({name:'result-read',arguments:{resultId:id,release:true}});
  assert.equal((await client.callTool({name:'result-read',arguments:{resultId:id}})).isError,true);
 }finally{await client.close();await server.close();}
});

test('cache expires and enforces count, size and offset bounds',()=>{
 let now=0;const cache=new WorkflowResults(()=>now);const id=cache.put('abc');assert.throws(()=>cache.read(id,4,1),/Offset/);
 assert.equal(cache.put('x'.repeat(1024*1024+1)),undefined);
 now=300000;assert.throws(()=>cache.read(id,0,3),/unavailable/);
 const oldest=cache.put('a');for(let i=0;i<16;i++)cache.put('b');assert.throws(()=>cache.read(oldest,0,1),/unavailable/);
});

test('compact profile preserves every legacy tool through catalog and validated calls',async()=>{
 const full=createMcpServer('full','full');const compact=createMcpServer('compact','compact');
 const a=await connect(full);const b=await connect(compact);
 try{
  const fullTools=await a.listTools();const compactTools=await b.listTools();
  assert.equal(compactTools.tools.length,5);
  const names=['batch-read','diagnose-connection','result-read','tool-call','tool-catalog'];
  assert.deepEqual(compactTools.tools.map(t=>t.name).sort(),names);
  const fullSize=JSON.stringify(fullTools).length;const compactSize=JSON.stringify(compactTools).length;
  assert.ok(compactSize < fullSize/5);console.log(JSON.stringify({fullTools:fullTools.tools.length,compactTools:5,fullSchemaChars:fullSize,compactSchemaChars:compactSize}));
  const catalog=[];let offset=0;
  do{const page=data(await b.callTool({name:'tool-catalog',arguments:{offset,limit:30}}));catalog.push(...page.tools);offset=page.nextOffset;}while(offset!==null);
  assert.deepEqual(catalog.map(t=>t.name).sort(),fullTools.tools.filter(t=>!names.includes(t.name)).map(t=>t.name).sort());
  const direct=await a.callTool({name:'list-clients',arguments:{}});
  const via=await b.callTool({name:'tool-call',arguments:{tool:'list-clients',format:'full'}});assert.deepEqual(via,direct);
  const invalid=await b.callTool({name:'tool-call',arguments:{tool:'devirtualize-luraph',arguments:{operation:'read'}}});assert.equal(invalid.isError,true);
  const recursive=await b.callTool({name:'tool-call',arguments:{tool:'tool-call'}});assert.equal(recursive.isError,true);
 }finally{await a.close();await b.close();await full.close();await compact.close();}
});

test('diagnostics never probe an ambiguous or stale selection',async()=>{
 const routing={};const server=new McpServer({name:'test',version:'1'});const layer=createWorkflowLayer(server,routing);let probes=0;
 layer.server.registerTool('list-clients',{},async()=>response({clients:[{clientId:'abc',placeName:'one'},{clientId:'abd',placeName:'two'}]}));
 layer.server.registerTool('runtime-status',{inputSchema:z.object({clientId:z.string()})},async input=>{probes++;return response(input);});
 layer.install();const client=await connect(server);
 try{
  const call=args=>client.callTool({name:'diagnose-connection',arguments:args});
  assert.equal(data(await call({})).status,'target-required');assert.equal(probes,0);
  routing.selectedClientId='gone';assert.equal(data(await call({})).status,'target-unavailable');assert.equal(probes,0);
  assert.equal(data(await call({clientId:'abc'})).status,'connected');assert.equal(probes,1);assert.equal(routing.selectedClientId,'gone');
 }finally{await client.close();await server.close();}
});

test('gateway validates output and invokes an explicit action exactly once',async()=>{
 const server=new McpServer({name:'test',version:'1'});const layer=createWorkflowLayer(server,{},'compact');let actions=0;
 layer.server.registerTool('action-fixture',{inputSchema:z.object({value:z.number()}),outputSchema:z.object({ok:z.boolean()})},async()=>{actions++;return response({wrong:true});});
 layer.install();const client=await connect(server);
 try{
  const result=await client.callTool({name:'tool-call',arguments:{tool:'action-fixture',arguments:{value:1}}});
  assert.equal(result.isError,true);assert.match(data(result).error,/invalid structured output/);assert.equal(actions,1);
  const invalid=await client.callTool({name:'tool-call',arguments:{tool:'action-fixture',arguments:{value:'wrong'}}});assert.equal(invalid.isError,true);assert.equal(actions,1);
 }finally{await client.close();await server.close();}
});
