import test from "node:test";
import assert from "node:assert/strict";
import { AnalysisHierarchy } from "../dist/code-intelligence/hierarchy.js";
import { getScriptSourceIndex, upsertScriptSources, clearScriptSourceIndex, onScriptSourceChange } from "../dist/bridge/handlers/shared/script-source-store.js";
import { codeAnalysisSchema } from "../dist/tools/impl/code-intelligence/code-tools.js";
import { LspTransport } from "../dist/code-intelligence/protocol.js";

test("source notifications track active changes and preserve provenance without treating status as edits", t => {
  const identity={clientId:"source-notifications",placeId:1,jobId:"job"}; const events=[];
  const stop=onScriptSourceChange(event=>{if(event.clientId===identity.clientId)events.push(event.kind);});
  t.after(()=>{stop();clearScriptSourceIndex(identity.clientId);});
  const script={debugId:"a",path:"game.A",source:"return 1",sourceKind:"original",sourceProducer:"fixture",producerVersion:"1"};
  upsertScriptSources(identity,{beginMappingSession:true,mappingSessionId:"one",mappingSessionStartedAt:1,mappingRevision:1,scripts:[script]});
  assert.deepEqual(events,["reset"]);
  upsertScriptSources(identity,{mappingSessionId:"one",mappingRevision:2,scripts:[script]});
  upsertScriptSources(identity,{mappingSessionId:"one",mappingRevision:3,hasFinishedMapping:true});
  assert.deepEqual(events,["reset"]);
  upsertScriptSources(identity,{mappingSessionId:"one",mappingRevision:4,scripts:[{...script,source:"return 2"}]});
  assert.equal(events.at(-1),"changed");assert.equal(getScriptSourceIndex(identity).scripts[0].sourceKind,"original");
  upsertScriptSources(identity,{mappingSessionId:"one",mappingRevision:5,removedScriptIds:["a"]});
  assert.equal(getScriptSourceIndex(identity).scripts.length,0);assert.equal(events.at(-1),"changed");
  clearScriptSourceIndex(identity.clientId);assert.equal(events.at(-1),"reset");
});

test("hierarchy does not merge by names, delete on partial scans, or retain another connector generation",()=>{
  const hierarchy=new AnalysisHierarchy();
  const root={Handle:"r",Name:"game",ClassName:"DataModel"};
  const a={Handle:"a",ParentHandle:"r",Name:"Same",ClassName:"Folder"};
  const b={Handle:"b",ParentHandle:"r",Name:"Same",ClassName:"Folder"};
  hierarchy.update([root,a,b],true,"1");
  assert.equal(hierarchy.build([]).coverage.ambiguousSiblingInstances,2);
  hierarchy.update([root],false,"1");assert.equal(hierarchy.build([]).coverage.retainedInstances,3);
  hierarchy.update([root],false,"2");assert.equal(hierarchy.build([]).coverage.retainedInstances,1);
  hierarchy.update([root,{...a,DisplayTruncated:true}],true,"2");assert.equal(hierarchy.build([]).coverage.hierarchyComplete,false);
});

test("analysis schema bounds requests and rejects unrecognized options",()=>{
  assert.equal(codeAnalysisSchema.parse({scriptId:"a"}).requireFresh,true);
  assert.equal(codeAnalysisSchema.safeParse({scriptId:"a",line:-1}).success,false);
  assert.equal(codeAnalysisSchema.safeParse({scriptId:"a",execute:true}).success,false);
  assert.equal(codeAnalysisSchema.safeParse({scriptId:"a",limit:101}).success,false);
});

test("transport times out, cancels, and isolates late responses",async t=>{
  // Transport-only fixture; native analysis is covered by the separate real-server suite.
  const worker=new LspTransport(process.execPath,["-e","process.stdin.resume()"],process.cwd());t.after(()=>worker.close());
  await assert.rejects(worker.request("test/never",{},30),/timed out/);
  const pending=worker.request("test/close",{},1000);worker.close();await assert.rejects(pending,/closed/);
});

test("transport rejects malformed and oversized frames",async()=>{
  for(const header of ['Content-Length: 999999999\\r\\n\\r\\n','Content-Length: nope\\r\\n\\r\\n']) {
    const worker=new LspTransport(process.execPath,["-e",`process.stdout.write('${header}');process.stdin.resume()`],process.cwd());
    try {await assert.rejects(worker.request("test/frame",{},2000),/content length/);}finally{worker.close();}
  }
});
