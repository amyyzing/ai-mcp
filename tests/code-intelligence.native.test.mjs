import test from "node:test";
import assert from "node:assert/strict";
import { AnalysisSession } from "../dist/code-intelligence/session.js";
import { loadLspRuntime } from "../dist/code-intelligence/runtime.js";
import { AnalysisHierarchy } from "../dist/code-intelligence/hierarchy.js";
import { createMcpServer } from "../dist/mcp/server.js";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { registerClient, getClientById, resetRegistry } from "../dist/bridge/handlers/shared/registry.js";
import { resetPrimaryState, setInstanceRole, handleRobloxResponse } from "../dist/bridge/handlers/shared/communication.js";
import { upsertScriptSources } from "../dist/bridge/handlers/shared/script-source-store.js";
import { closeAnalysisSessions } from "../dist/code-intelligence/service.js";

let runtime;
try { runtime = loadLspRuntime(); } catch (error) { if (process.env.REQUIRE_LSP_TESTS === "1") throw error; }
const node = (Name, ClassName, id, children = [], sourceId) => ({ Name, ClassName, DebugId: id, ChildrenComplete: true, Children: children, sourceId });
const tree = () => node("game", "DataModel", "root", [node("ReplicatedStorage", "ReplicatedStorage", "storage", [node("A", "ModuleScript", "a", [], "a"), node("B", "ModuleScript", "b", [], "b")])]);

test("native LSP: five tools, dependency invalidation and no editor", { skip: !runtime }, async t => {
  const session = new AnalysisSession("fixture", "mapping", runtime);
  t.after(() => session.close());
  const a = '--!strict\nlocal B = require(script.Parent.B)\nlocal value: string = B.value\nreturn value\n';
  const inputs = b => [{ id: "a", source: a, sourceKind: "original" }, { id: "b", source: '--!strict\n' + b, sourceKind: "original" }];
  await session.synchronize(inputs('return { value = "hello" }'), tree());
  const first = await session.query("code-check", "a");
  assert.deepEqual(first.result, [], JSON.stringify(first));
  const hover = await session.query("code-type-at", "a", 2, 6);
  assert.ok(JSON.stringify(hover.result).includes("string"), JSON.stringify(hover));
  const symbols = await session.query("code-symbols", "a");
  assert.ok(symbols.result.length >= 2);
  const definition = await session.query("code-definition", "a", 2, 24);
  assert.ok(JSON.stringify(definition.result).includes(session.documents.get("b").uri), JSON.stringify(definition));
  const references = await session.query("code-references", "a", 2, 24);
  assert.ok(references.result.length >= 2, JSON.stringify(references));
  await session.synchronize(inputs('return { value = 42 }'), tree());
  const changed = await session.query("code-check", "a");
  assert.ok(changed.result.some(d => d.severity === 1 && d.range.start.line === 2), JSON.stringify(changed));
  assert.equal(changed.document.version, first.document.version);
});

test("native numeric dependency from clean session", { skip: !runtime }, async t => {
  const session = new AnalysisSession("numeric", "mapping", runtime); t.after(() => session.close());
  await session.synchronize([{ id: "a", source: '--!strict\nlocal B = require(script.Parent.B)\nlocal value: string = B.value\nreturn value\n' }, { id: "b", source: '--!strict\nreturn { value = 42 }' }], tree());
  const result = await session.query("code-check", "a");
  assert.ok(result.result.some(d => d.severity === 1), JSON.stringify(result));
});

test("native stub replacement, source removal, hierarchy rename and reparent", { skip: !runtime }, async t => {
  const session = new AnalysisSession("lifecycle", "mapping", runtime); t.after(() => session.close());
  const a = '--!strict\nlocal B = require(script.Parent.B)\nlocal value: string = B.value\nreturn value';
  const inputs = [{id:"a",source:a,sourceKind:"original"},{id:"b",source:'--!strict\nreturn {} :: any',sourceKind:"stub"}];
  await session.synchronize(inputs, tree());
  assert.deepEqual((await session.query("code-check","a")).result, []);
  inputs[1] = {id:"b",source:'--!strict\nreturn {value=42}',sourceKind:"original"};
  await session.synchronize(inputs, tree());
  assert.ok((await session.query("code-check","a")).result.some(d=>d.severity===1));
  const renamed = tree(); renamed.Children[0].Children[1].Name = "C";
  await session.synchronize(inputs, renamed);
  assert.ok((await session.query("code-check","a")).result.some(d=>/B|require/.test(d.message)));
  inputs[0].source = a.replace('Parent.B','Parent.Folder.C');
  const moved = tree(); moved.Children[0].Children.splice(1,1,node("Folder","Folder","folder",[node("C","ModuleScript","b",[],"b")]));
  await session.synchronize(inputs,moved);
  const definition = await session.query("code-definition","a",2,24);
  assert.ok(definition.result.some(location=>location.scriptId==='b'),JSON.stringify(definition));
  await session.synchronize([inputs[0]], moved);
  assert.ok((await session.query("code-check","a")).result.some(d=>d.severity===1));
});

test("native partial hierarchy retains omitted nodes; duplicate names never pick a source", { skip: !runtime }, async t => {
  const session = new AnalysisSession("partial","mapping",runtime);t.after(()=>session.close());
  const hierarchy = new AnalysisHierarchy();
  const rows = [
    {Handle:"root",Name:"game",ClassName:"DataModel",DebugId:"root"},
    {Handle:"storage",ParentHandle:"root",Name:"ReplicatedStorage",ClassName:"ReplicatedStorage",DebugId:"storage"},
    {Handle:"a",ParentHandle:"storage",Name:"A",ClassName:"ModuleScript",DebugId:"a"},
    {Handle:"b",ParentHandle:"storage",Name:"B",ClassName:"ModuleScript",DebugId:"b"},
  ];
  const scripts = [{debugId:"a",source:'--!strict\nreturn require(script.Parent.B)'},{debugId:"b",source:'--!strict\nreturn {value=42}'}];
  const inputs=scripts.map(s=>({id:s.debugId,source:s.source}));
  hierarchy.update(rows,true,"gen1");await session.synchronize(inputs,hierarchy.build(scripts).tree);
  hierarchy.update(rows.slice(0,3),false,"gen1");await session.synchronize(inputs,hierarchy.build(scripts).tree);
  assert.deepEqual((await session.query("code-check","a")).result,[]);
  hierarchy.update([...rows,{Handle:"other-b",ParentHandle:"storage",Name:"B",ClassName:"ModuleScript",DebugId:"other-b"}],true,"gen1");
  const ambiguous=hierarchy.build(scripts);assert.equal(ambiguous.coverage.ambiguousSiblingInstances,2);
  await session.synchronize(inputs,ambiguous.tree);
  const definition=await session.query("code-definition","a",1,30);
  assert.ok(!JSON.stringify(definition.result).includes(session.documents.get("b").uri));
  hierarchy.update(rows.slice(0,3),true,"gen1");await session.synchronize(inputs,hierarchy.build(scripts).tree);
  assert.ok((await session.query("code-check","a")).result.some(d=>d.severity===1));
});

test("native UTF-16 locations, invalid positions, superseded requests and worker isolation", { skip: !runtime }, async t => {
  const session = new AnalysisSession("unicode","first",runtime);t.after(()=>session.close());
  const source='--!strict\nlocal emoji = "😀"; local value: number = "bad"\nreturn {value=value,emoji=emoji}';
  const inputs=[{id:"a",source}];await session.synchronize(inputs,tree());
  const definition=await session.query("code-definition","a",2,15);
  assert.equal(definition.result[0].range.start.character,source.split('\n')[1].indexOf('value'));
  await assert.rejects(session.query("code-type-at","a",999,0),/outside/);
  const pending=session.query("code-check","a");await Promise.resolve();session.invalidate();
  const stale=await pending;assert.equal(stale.ok,false);assert.equal(stale.freshness.state,'superseded');assert.equal(stale.result,undefined);
  const next=new AnalysisSession("unicode","second",runtime);t.after(()=>next.close());
  await next.synchronize([{id:"a",source:'--!strict\nreturn {fresh=true}'}],tree());
  assert.notEqual(next.workerGeneration,session.workerGeneration);
  assert.deepEqual((await next.query("code-check","a")).result,[]);
  assert.ok((await session.query("code-check","a",0,0,false)).result.some(d=>d.severity===1));
  const closing=next.query("code-check","a");await Promise.resolve();next.close();
  await assert.rejects(closing,/closed|replaced/);
});

test("MCP tools route source-store data and structured Dex observations into the real worker", {skip:!runtime},async t=>{
  resetPrimaryState();resetRegistry();setInstanceRole("primary");
  const id=registerClient({username:"analysis-test",userId:1,placeId:1,jobId:"fixture",sessionId:"fixture",transport:"http"});
  const target=getClientById(id);
  upsertScriptSources(target,{scripts:[{debugId:"a",path:"game.A",source:'--!strict\nlocal value: string = 42\nreturn value',sourceKind:"original"}]});
  target.pendingPollResolve=commands=>{
    assert.equal(commands.length,1);const command=JSON.parse(commands[0]);assert.equal(command.type,"dex-query");
    handleRobloxResponse({id:command.id,success:true,structured:{results:[
      {Handle:"r",DebugId:"r",Name:"game",ClassName:"DataModel"},
      {Handle:"a",DebugId:"a",ParentHandle:"r",Name:"A",ClassName:"ModuleScript"}],
      complete:true,done:true,detailsComplete:true,projectionComplete:true,connectorGeneration:1}},id);
  };
  const server=createMcpServer("analysis-test");const client=new Client({name:"analysis-fixture",version:"1"});
  const [ct,st]=InMemoryTransport.createLinkedPair();await server.connect(st);await client.connect(ct);
  t.after(async()=>{await client.close();await server.close();closeAnalysisSessions();resetRegistry();resetPrimaryState();});
  const tools=await client.listTools();assert.equal(tools.tools.filter(tool=>tool.name.startsWith("code-")).length,5);
  const checked=await client.callTool({name:"code-check",arguments:{clientId:id,scriptId:"a"}});
  assert.ok(!checked.isError,JSON.stringify(checked));assert.ok(checked.structuredContent.result.some(d=>d.severity===1));
  assert.equal(checked.structuredContent.coverage.linkedSources,1);
  for(const name of ["code-type-at","code-symbols","code-definition","code-references"]){
    const result=await client.callTool({name,arguments:{clientId:id,scriptId:"a",line:2,character:8,refreshHierarchy:false}});
    assert.ok(!result.isError,JSON.stringify(result));assert.equal(result.structuredContent.freshness.state,"confirmed");
  }
  function partialHierarchy(connectorId, includeOld) {
    target.pendingPollResolve = commands => {
      const command = JSON.parse(commands[0]);
      const results = [
        {Handle:"r",DebugId:"r",Name:"game",ClassName:"DataModel"},
        {Handle:"a",DebugId:"a",ParentHandle:"r",Name:"A",ClassName:"ModuleScript"},
      ];
      if (includeOld) results.push({Handle:"old",ParentHandle:"r",Name:"Old",ClassName:"Folder"});
      handleRobloxResponse({id:command.id,success:true,structured:{results,
        complete:false,done:true,detailsComplete:true,projectionComplete:true,connectorId,connectorGeneration:1}},id);
    };
  }
  partialHierarchy("registry-a", true);
  const beforeReload = await client.callTool({name:"code-check",arguments:{clientId:id,scriptId:"a",refreshHierarchy:true}});
  assert.ok(!beforeReload.isError, JSON.stringify(beforeReload));
  assert.equal(beforeReload.structuredContent.coverage.retainedInstances, 3);
  partialHierarchy("registry-b", false);
  const afterReload = await client.callTool({name:"code-check",arguments:{clientId:id,scriptId:"a",refreshHierarchy:true}});
  assert.ok(!afterReload.isError, JSON.stringify(afterReload));
  assert.equal(afterReload.structuredContent.coverage.retainedInstances, 2,
    "same-number generations from different connector loads must not retain stale hierarchy nodes");
});
