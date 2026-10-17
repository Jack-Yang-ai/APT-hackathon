import assert from 'node:assert/strict';
import { test } from 'node:test';
import { once } from 'node:events';
import { mkdtempSync, writeFileSync, rmSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createMacAgent,agentRequest,modelRequest,warmSources,runWarm,createIndexWarmer,readVectorPrefs,localInputDeviceID,syncedInputSource } from './common_agent.mjs';
import { sync } from '../worker/src/input_memory.js';
import { createInputMemoryServer } from './input_memory_service.mjs';
import { InputMemoryReplica } from './input_memory_store.mjs';
import { execFileSync, execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const request={schema:'apt.agent.request/1',request_id:'aaaaaaaa-1111-2222-3333-123456789abc',query:'今天的项目结论',mode:'reply',context:{app:'fixture.mail',before:'发给设计同学'},force_refresh:false,deep_review:false,scope:'global',materials:[]};
const warmRecordingSource={event_id:'synced_recording_r1',date:'2026-10-14',title:'APT 录音 · 演示',body:'说话人甲：结论尚未确定。'};
const fakeRecordings=()=>({pool:async()=>({offered:new Map([[warmRecordingSource.event_id,{source:warmRecordingSource,snapshot:{}}]]),truncated:false,incomplete:false,watermark:1,coverage:{}}),validate:async()=>true});
test('the warmer embeds exactly the bodies the answer path offers, minus this Mac’s own drafts',async()=>{
  const replica=new InputMemoryReplica(':memory:'),self='aaaaaaaa-1111-2222-3333-123456789abc',other='bbbbbbbb-1111-2222-3333-123456789abc',id='local_input_00000000-1111-2222-3333-000000000001';
  const record=(text,patch={})=>({id,revision:1,created:'2026-10-14T00:00:00Z',updated:'2026-10-14T00:00:00Z',app:'fixture',text,pasted:[],voiced:[],partial:false,deleted:false,...patch});
  const put=async(device,records)=>{const response=await sync(replica.db,new Request('http://localhost/input-memory/sync',{method:'POST',body:JSON.stringify({schema:'growth.input-memory.batch/1',device_id:device,records})}));assert.equal(response.status,200);};
  try {
    await put(self,[record('本机草稿')]);await put(other,[record('另一台的外部粘贴',{pasted:['外部粘贴'],partial:true})]);
    let offered;
    const agent=createMacAgent({replica,check:async()=>host,execute:async input=>{offered=input.synced_materials;return result(input);}});
    await agent.answer({...request,device_id:self});
    const scoped=await warmSources({replica,recordings:fakeRecordings(),excludeDevice:self});
    assert.deepEqual(scoped.input,offered); // same bytes → same content-addressed chunk hashes
    assert.deepEqual(scoped.recording,[warmRecordingSource]);
    assert.equal(scoped.error,null);
    const all=await warmSources({replica,recordings:null});
    assert.equal(all.input.length,2);
    assert.deepEqual(Object.keys(syncedInputSource({payload:JSON.stringify(record('x')),fingerprint:'f'.repeat(64)})),['source','snapshot']);
  } finally {replica.close();}
});
test('a recording pool failure is reported and never blocks input warming',async()=>{
  const replica=new InputMemoryReplica(':memory:');
  try {
    const sources=await warmSources({replica,recordings:{pool:async()=>{throw new Error('upstream down');}}});
    assert.equal(sources.error,'recording_pool_unavailable');
    assert.deepEqual(sources.recording,[]);
  } finally {replica.close();}
});
test('a truncated recording pool is reported so nobody warms vectors no query can reach',async()=>{
  const replica=new InputMemoryReplica(':memory:');
  try {
    const sources=await warmSources({replica,recordings:{pool:async()=>({offered:new Map([[warmRecordingSource.event_id,{source:warmRecordingSource,snapshot:{}}]]),truncated:true})}});
    assert.equal(sources.recording_truncated,true);
    assert.deepEqual(sources.recording,[]);
    assert.equal(sources.error,null);
  } finally {replica.close();}
});
test('both pool failures are reported instead of one overwriting the other',async()=>{
  const replica=new InputMemoryReplica(':memory:');
  try {
    const response=await sync(replica.db,new Request('http://localhost/input-memory/sync',{method:'POST',body:JSON.stringify({schema:'growth.input-memory.batch/1',device_id:'bbbbbbbb-1111-2222-3333-123456789abc',records:[{id:'local_input_00000000-1111-2222-3333-000000000001',revision:1,created:'2026-10-14T00:00:00Z',updated:'2026-10-14T00:00:00Z',app:'fixture',text:'另一台的外部粘贴',pasted:[],voiced:[],partial:false,deleted:false}]})}));
    assert.equal(response.status,200);
    replica.sqlite.prepare('UPDATE input_memory_sources SET payload=?').run('{not json');
    const sources=await warmSources({replica,recordings:{pool:async()=>{throw new Error('upstream down');}}});
    assert.equal(sources.error,'input_source_unreadable');
    assert.equal(sources.recording_truncated,false);
  } finally {replica.close();}
});
test('one unreadable input payload is reported and does not stop the rest of the pool',async()=>{
  const replica=new InputMemoryReplica(':memory:'),self='aaaaaaaa-1111-2222-3333-123456789abc',other='bbbbbbbb-1111-2222-3333-123456789abc',id='local_input_00000000-1111-2222-3333-000000000001';
  const record=(text,patch={})=>({id,revision:1,created:'2026-10-14T00:00:00Z',updated:'2026-10-14T00:00:00Z',app:'fixture',text,pasted:[],voiced:[],partial:false,deleted:false,...patch});
  const put=async(device,records)=>{const response=await sync(replica.db,new Request('http://localhost/input-memory/sync',{method:'POST',body:JSON.stringify({schema:'growth.input-memory.batch/1',device_id:device,records})}));assert.equal(response.status,200);};
  try {
    await put(other,[record('另一台的外部粘贴')]);
    replica.sqlite.prepare('UPDATE input_memory_sources SET payload=? WHERE device_id=?').run('{not json',other);
    const sources=await warmSources({replica,recordings:null,excludeDevice:self});
    assert.equal(sources.error,'input_source_unreadable');
    assert.deepEqual(sources.input,[]);
    replica.sqlite.prepare('UPDATE input_memory_sources SET payload=? WHERE device_id=?').run(JSON.stringify(record('另一台的外部粘贴')),other);
    assert.equal((await warmSources({replica,recordings:null,excludeDevice:self})).input.length,1);
  } finally {replica.close();}
});
test('runWarm sends one bounded warm request and rejects a malformed reply',async()=>{
  let payload;
  const index=await runWarm({app:'/fixture/APT.app',sources:[warmRecordingSource],model:'qwen3-embedding:0.6b',budgetSeconds:45,
    run:async text=>{payload=JSON.parse(text);return {index:{state:'warm',new_chunks:3,pending:0,ms:1200}};}});
  assert.equal(payload.action,'warm');assert.equal(payload.model,'qwen3-embedding:0.6b');assert.equal(payload.budget_seconds,45);
  assert.deepEqual(payload.sources,[warmRecordingSource]);
  assert.equal(index.new_chunks,3);
  await assert.rejects(runWarm({app:'/fixture/APT.app',sources:[warmRecordingSource],run:async()=>({index:{state:'bogus',new_chunks:1,pending:0}})}),/warm_invalid_reply/);
  await assert.rejects(runWarm({app:'/fixture/APT.app',sources:[warmRecordingSource],run:async()=>({index:{state:'warm',new_chunks:1,pending:'x'}})}),/warm_invalid_reply/);
  await assert.rejects(runWarm({app:'/fixture/APT.app',sources:[],run:async()=>({index:{state:'idle',new_chunks:0,pending:0}})}),/warm_sources_required/);
});
test('the warmer coalesces kicks into one cycle, never two at once, and survives failures',async()=>{
  const batches=[];let release;const hold=new Promise(done=>release=done);
  const warmer=createIndexWarmer({replica:null,recordings:fakeRecordings(),resolveModel:async()=>({enabled:true,model:'qwen3-embedding:0.6b'}),verifyApp:async()=>true,excludeDevice:()=>null,
    run:async payload=>{batches.push(JSON.parse(payload).sources.length);await hold;return {index:{state:'warm',new_chunks:1,pending:0,ms:5}};},log:()=>{}});
  warmer.kick('startup');warmer.kick('changes');
  await new Promise(done=>setTimeout(done,10));
  assert.equal(warmer.busy,true);assert.equal(batches.length,1);
  release();await new Promise(done=>setTimeout(done,20));
  assert.equal(warmer.busy,false);assert.equal(batches.length,2); // the queued kick ran once, after
  warmer.stop();warmer.kick('catchup');
  await new Promise(done=>setTimeout(done,10));
  assert.equal(batches.length,2);
  const logs=[];const failing=createIndexWarmer({replica:null,recordings:fakeRecordings(),resolveModel:async()=>({enabled:true,model:null}),verifyApp:async()=>true,excludeDevice:()=>null,
    run:async()=>{throw new Error('warm_spawn_failed');},log:line=>logs.push(line)});
  await failing.cycle();
  assert.equal(logs.length,1);assert.match(logs[0],/warm_spawn_failed/);
  const disabled=createIndexWarmer({replica:null,recordings:fakeRecordings(),resolveModel:async()=>({enabled:false,model:null}),verifyApp:async()=>true,excludeDevice:()=>null,
    run:async()=>{throw new Error('must not run');},log:line=>logs.push(line)});
  await disabled.cycle();assert.equal(logs.length,2);assert.match(logs[1],/disabled/);
  const stale=[];const old=createIndexWarmer({replica:null,recordings:fakeRecordings(),resolveModel:async()=>({enabled:true,model:null}),verifyApp:async()=>true,excludeDevice:()=>null,
    run:async()=>{throw new Error('warm_failed: unsupported_action:warm');},log:line=>stale.push(line)});
  await old.cycle();await old.cycle();
  assert.equal(stale.length,2);assert.match(stale[1],/restart the service/); // disarmed, not retried forever
  assert.equal(old.cycles,1);
});
test('a cycle with work left schedules the next one, and stop cancels it',async()=>{
  const batches=[];
  const warmer=createIndexWarmer({replica:null,recordings:fakeRecordings(),followupMs:20,resolveModel:async()=>({enabled:true,model:null}),verifyApp:async()=>true,excludeDevice:()=>null,
    run:async payload=>{batches.push(1);return {index:{state:'warm',new_chunks:1,pending:0,ms:5}};},log:()=>{}});
  warmer.kick('startup');
  await new Promise(done=>setTimeout(done,80));
  assert.ok(batches.length>=2,'expected a follow-up cycle, got '+batches.length);
  warmer.stop();
  await new Promise(done=>setTimeout(done,40));
  const seen=batches.length;
  await new Promise(done=>setTimeout(done,60));
  assert.equal(batches.length,seen);
});
test('vector preferences and the local device id come from the input method, and default to on',async()=>{
  assert.deepEqual(await readVectorPrefs({read:()=>'1'}),{enabled:true,model:null});
  assert.deepEqual(await readVectorPrefs({read:(domain,key)=>key==='memoryEmbeddingModel'?'qwen3-embedding:4b\n':'0'}),{enabled:false,model:'qwen3-embedding:4b'});
  assert.deepEqual(await readVectorPrefs({read:(domain,key)=>key==='memoryEmbeddingModel'?'bogus-model':'1'}),{enabled:true,model:null});
  assert.deepEqual(await readVectorPrefs({read:()=>{throw new Error('missing');}}),{enabled:true,model:null});
  assert.deepEqual(await readVectorPrefs({read:async()=>'1'}),{enabled:true,model:null});
  assert.equal(localInputDeviceID('/nonexistent-directory'),null);
  const dir=mkdtempSync(join(tmpdir(),'echo-warm-'));
  try {
    writeFileSync(join(dir,'state.json'),JSON.stringify({device_id:'0A0A0A0A-0000-4000-8000-000000000001'}));
    assert.equal(localInputDeviceID(dir),'0a0a0a0a-0000-4000-8000-000000000001');
    writeFileSync(join(dir,'state.json'),JSON.stringify({device_id:'not-a-uuid'}));
    assert.equal(localInputDeviceID(dir),null);
  } finally {rmSync(dir,{recursive:true,force:true});}
});
const host={schema:'apt.agent.host/1',version:'fixture',build:'1',source_fingerprint:'a'.repeat(64)};
const result=input=>({schema:'apt.agent.reply/1',request_id:input.request_id,host,run:{run_id:input.request_id,retrieve:{withecho:{cache:'local'}}},replies:['结论尚未确定。'],sources:[],dependencies:[],insertable:true});
const modelInput={schema:'apt.model.request/1',request_id:request.request_id,operation:'text',scene:'voice_polish',system:'轻整理',prompt:'我还没确定。',background:false,deep_review:false,json:true,timeout:12,max_tokens:2048,credential:{endpoint:'https://approved.example',key:'fixture'}};
test('model gateway preserves text/ASR identity, bounded scenes and captured credential origin',async()=>{
 assert.equal(modelRequest(modelInput).scene,'voice_polish');
 for(const patch of [{scene:'extract'},{background:true},{timeout:241},{max_tokens:64001},{credential:{endpoint:'x',key:''}}])assert.throws(()=>modelRequest({...modelInput,...patch}));
 const asr=modelRequest({...modelInput,operation:'asr',scene:'asr',audio_base64:'UklGRg==',language:'auto',hotwords:[],route:'plan'});
 for(const key of ['system','prompt','background','deep_review','json','route','hotwords'])assert.ok(Object.hasOwn(asr,key));
 const agent=createMacAgent({check:async()=>host,execute:async input=>({schema:'apt.model.reply/1',request_id:input.request_id,text:input.prompt,host,calls:[],hotwords_refused:false,pcm_retry:false})});
 assert.equal((await agent.model(modelInput)).text,modelInput.prompt);
 const invalid=createMacAgent({check:async()=>host,execute:async()=>({schema:'apt.model.reply/1',request_id:'foreign',text:'x',host})});
 await assert.rejects(invalid.model(modelInput),/invalid_model_result/);
});
test('two devices keep identical record IDs distinct; deletion during generation rejects a shared answer',async()=>{
 const replica=new InputMemoryReplica(':memory:'),a=request.request_id,b='bbbbbbbb-1111-2222-3333-123456789abc',id='local_input_00000000-1111-2222-3333-000000000001';
 const record=(text,patch={})=>({id,revision:1,created:'2026-10-14T00:00:00Z',updated:'2026-10-14T00:00:00Z',app:'fixture',text,pasted:[],voiced:[],partial:false,deleted:false,...patch});
 const put=async(device,records)=>{const response=await sync(replica.db,new Request('http://localhost/input-memory/sync',{method:'POST',body:JSON.stringify({schema:'growth.input-memory.batch/1',device_id:device,records})}));assert.equal(response.status,200);};
 try {
  await put(a,[record('本机内容')]);await put(b,[record('另一台的外部粘贴',{pasted:['外部粘贴'],partial:true})]);
  const agent=createMacAgent({replica,check:async()=>host,execute:async input=>{assert.equal(input.synced_materials.length,1);const source=input.synced_materials[0];assert.ok(source.event_id.includes(b));assert.ok(source.body.includes('pasted') && source.body.includes('partial'));return {...result(input),sources:[source],dependencies:[source]};}});
  const reply=await agent.answer({...request,device_id:a});assert.equal(reply.coverage.synced_sources,1);
  const reverse=createMacAgent({replica,check:async()=>host,execute:async input=>{assert.ok(input.synced_materials[0].event_id.includes(a));return result(input);}});await reverse.answer({...request,device_id:b});
  const changed=createMacAgent({replica,check:async()=>host,execute:async input=>{const source=input.synced_materials[0];await put(b,[record('',{revision:2,deleted:true,updated:'2026-10-14T00:01:00Z'})]);return {...result(input),sources:[source],dependencies:[source]};}});
  await assert.rejects(changed.answer({...request,device_id:a}),/input_sources_changed/);
  const offline=createMacAgent({replica,refresh:async()=>{throw Error('offline');},check:async()=>host,execute:async input=>{assert.equal(input.synced_materials,undefined);return result(input);}});
  const local=await offline.answer({...request,device_id:a});assert.equal(local.coverage.synced_state,'unavailable');assert.equal(local.coverage.input,'local_drafts');
 }finally{replica.close();}
});
test('cross-device day digests are offered, citable and validated like drafts',async()=>{
 const replica=new InputMemoryReplica(':memory:'),mine=request.request_id,other='bbbbbbbb-1111-2222-3333-123456789abc';
 const put=async(device,records)=>{const response=await sync(replica.db,new Request('http://localhost/input-memory/sync',{method:'POST',body:JSON.stringify({schema:'growth.input-memory.batch/1',device_id:device,records})}));assert.equal(response.status,200);};
 const digest=(patch={})=>({id:'echo_day_2026-10-13',revision:1,created:'2026-10-12T16:00:00Z',updated:'2026-10-13T13:00:00Z',app:'echo.day',text:'概要：敲定了项目计划。',pasted:[],voiced:[],partial:false,deleted:false,...patch});
 try{
  await put(other,[digest()]);
  const agent=createMacAgent({replica,check:async()=>host,execute:async input=>{const source=input.synced_materials.find(s=>s.event_id.startsWith('synced_day_'));assert.ok(source,'another device\'s day digest is offered');assert.ok(source.body.includes('项目计划'));assert.equal(source.title,'已同步每日整理 · 2026-10-13');assert.equal(source.date,'2026-10-13');return {...result(input),sources:[source],dependencies:[source]};}});
  const reply=await agent.answer({...request,device_id:mine});
  assert.equal(reply.coverage.synced_days,1);assert.equal(reply.coverage.synced_sources,1);
  assert.equal(reply.native_snapshots.length,0,'a day digest is a synced source, never a native one');
  const changed=createMacAgent({replica,check:async()=>host,execute:async input=>{const source=input.synced_materials.find(s=>s.event_id.startsWith('synced_day_'));await put(other,[digest({revision:2,text:'概要：计划被改掉了。',updated:'2026-10-13T14:00:00Z'})]);return {...result(input),sources:[source],dependencies:[source]};}});
  await assert.rejects(changed.answer({...request,device_id:mine}),/input_sources_changed/);
  await put(mine,[digest({text:'本机自己的整理'})]);
  const own=createMacAgent({replica,check:async()=>host,execute:async input=>{assert.equal(input.synced_materials.filter(s=>s.event_id.includes(mine)).length,0,'own days stay excluded like own drafts');return result(input);}});
  const ownReply=await own.answer({...request,device_id:mine});
  assert.equal(ownReply.coverage.synced_days,1,'only the other device\'s day counts');
 }finally{replica.close();}
});
test('dated queries filter day digests by their own day and keep them through the ranked fallback',async()=>{
 const replica=new InputMemoryReplica(':memory:'),device='bbbbbbbb-1111-2222-3333-123456789abc';
 const batch=async records=>{for(let i=0;i<records.length;i+=30){const response=await sync(replica.db,new Request('http://localhost/input-memory/sync',{method:'POST',body:JSON.stringify({schema:'growth.input-memory.batch/1',device_id:device,records:records.slice(i,i+30)})}));assert.equal(response.status,200);}};
 const day=(date,text)=>({id:'echo_day_'+date,revision:1,created:new Date(Date.parse(date+'T00:00:00+08:00')).toISOString(),updated:date+'T13:00:00Z',app:'echo.day',text,pasted:[],voiced:[],partial:false,deleted:false});
 try{
  await batch([day('2026-10-13','概要：第3天敲定项目计划。'),day('2026-10-01','概要：10月1日休息，明天出发。'),day('2026-09-20','概要：过去一周的复盘。')]);
  const narrow=createMacAgent({replica,check:async()=>host,execute:async input=>{assert.deepEqual(input.synced_materials.map(s=>s.date),['2026-10-13'],'time words inside other days do not exempt them');return result(input);}});
  await narrow.answer({...request,query:'2026-10-13 项目计划'});
  await batch(Array.from({length:2001},(_,n)=>({id:'local_input_00000000-1111-2222-3333-'+String(n).padStart(12,'0'),revision:1,created:'2026-10-20T00:00:00Z',updated:'2026-10-20T00:00:00Z',app:'fixture',text:'明天再说项目计划 '+n,pasted:[],voiced:[],partial:false,deleted:false})));
  const fallback=createMacAgent({replica,check:async()=>host,execute:async input=>{assert.equal(input.synced_truncated,true);assert.ok(input.synced_materials.some(s=>s.event_id.startsWith('synced_day_') && s.date==='2026-10-13'),'the in-range day survives the ranked cut');return result(input);}});
  assert.equal((await fallback.answer({...request,query:'2026-10-13 项目计划'})).coverage.synced_state,'limited');
 }finally{replica.close();}
});
test('synced day IDs cannot be smuggled through native validation',async()=>{
 const agent=createMacAgent({check:async()=>({...host,capabilities:['source_validation']}),execute:async()=>{throw Error('must not reach host');}});
 await assert.rejects(agent.validate({schema:'apt.agent.validation/1',snapshots:[],native_snapshots:[{event_id:'synced_day_bbbbbbbb-1111-2222-3333-123456789abc_2026-10-13',date:'2026-10-13',title:'t',fingerprint:'a'.repeat(64)}]}),/invalid_native_snapshots/);
});
test('large remote history cannot block a small dated or keyword query',async()=>{
 const replica=new InputMemoryReplica(':memory:'),device='bbbbbbbb-1111-2222-3333-123456789abc';
 const records=Array.from({length:2001},(_,n)=>({id:'local_input_00000000-1111-2222-3333-'+String(n).padStart(12,'0'),revision:1,created:n===2000?'2026-10-14T00:00:00Z':'2026-01-01T00:00:00Z',updated:'2026-10-14T00:00:00Z',app:'fixture',text:n===2000?'APT目标保留来源依据':'无关历史',pasted:[],voiced:[],partial:false,deleted:false}));
 try{
  for(let i=0;i<records.length;i+=30){const response=await sync(replica.db,new Request('http://localhost/input-memory/sync',{method:'POST',body:JSON.stringify({schema:'growth.input-memory.batch/1',device_id:device,records:records.slice(i,i+30)})}));assert.equal(response.status,200);}
  const agent=createMacAgent({replica,check:async()=>host,execute:async input=>{assert.ok(input.synced_materials.some(s=>s.body.includes('APT目标')));if(input.query.includes('2026-10-14'))assert.equal(input.synced_materials.length,1);else{assert.equal(input.synced_truncated,true);assert.equal(input.synced_materials.length,30);}return result(input);}});
  await agent.answer({...request,query:'2026-10-14 APT目标'});assert.equal((await agent.answer({...request,query:'APT目标'})).coverage.synced_state,'limited');
 }finally{replica.close();}
});
test('explicit dates keep Chinese and English relative-day drafts; mixed scopes are not prefiltered',async()=>{
 const replica=new InputMemoryReplica(':memory:'),device='bbbbbbbb-1111-2222-3333-123456789abc';
 const records=['明日召开发布评审','Tomorrow we discuss the release'].map((text,n)=>({id:'local_input_00000000-1111-2222-3333-'+String(n).padStart(12,'0'),revision:1,created:'2026-10-13T00:00:00Z',updated:'2026-10-13T00:00:00Z',app:'fixture',text,pasted:[],voiced:[],partial:false,deleted:false}));
 try{
  const response=await sync(replica.db,new Request('http://localhost/input-memory/sync',{method:'POST',body:JSON.stringify({schema:'growth.input-memory.batch/1',device_id:device,records})}));assert.equal(response.status,200);
  const agent=createMacAgent({replica,check:async()=>host,execute:async input=>{assert.equal(input.synced_materials.length,2);return result(input);}});
  for(const query of ['2026-10-14 发布评审','2026-10-14 yesterday release','最近三天发布评审'])await agent.answer({...request,query});
 }finally{replica.close();}
});
test('fingerprint inspection imports the service without starting a second instance',()=>{
 const module=fileURLToPath(new URL('./input_memory_service.mjs',import.meta.url));
 const output=execFileSync(process.execPath,['--input-type=module','-e','const m=await import(process.argv[1]);process.stdout.write(m.sourceFingerprint());',module],
   {encoding:'utf8',timeout:5000,env:{...process.env,GROWTH_INPUT_MEMORY_TOKEN:'fixture',GROWTH_INPUT_MEMORY_DB:':memory:',GROWTH_INPUT_MEMORY_PORT:'0'}});
 assert.match(output,/^[0-9a-f]{64}$/);
});
test('request keeps app context and phone namespaces separate, rejects malformed scopes',()=>{
 assert.deepEqual(agentRequest(request).context,request.context);
 assert.deepEqual(agentRequest({...request,credential:{endpoint:"https://approved.example",key:"fixture",extra:"drop"}}).credential,{endpoint:"https://approved.example",key:"fixture"});
 for(const patch of [{scope:'everything'},{context:{before:'x'.repeat(8001)}},{materials:[{event_id:'local_input_1'}]},{force_refresh:'yes'},{credential:{endpoint:'https://approved.example',key:''}}]) assert.throws(()=>agentRequest({...request,...patch}));
});
test('a native host printing null, an array or a number fails the request and never crashes the service',async()=>{
 const dir=mkdtempSync(join(tmpdir(),'apt-host-')),app=join(dir,'APT.app'),out=join(dir,'out');
 mkdirSync(join(app,'Contents/MacOS'),{recursive:true});
 writeFileSync(join(app,'Contents/MacOS/APT'),'#!/bin/sh\ncat >/dev/null\ncat '+JSON.stringify(out)+'\nexit "$(cat '+JSON.stringify(out+'.code')+')"\n',{mode:0o755});
 const crashes=[],crash=error=>crashes.push(error);process.on('uncaughtException',crash);
 try {
  const agent=createMacAgent({app,check:async()=>host});
  for(const code of [0,1])for(const text of ['null','[]','42','"x"','{bad']) {
   writeFileSync(out,text);writeFileSync(out+'.code',String(code));
   await assert.rejects(agent.answer(request),error=>error.message==='agent_host_unavailable' && error.status===503);
   await assert.rejects(agent.model(modelInput),/agent_host_unavailable/);
  }
  writeFileSync(out,JSON.stringify({error:'model_key_authorization'}));writeFileSync(out+'.code','1');
  await assert.rejects(agent.model(modelInput),error=>error.message==='model_key_authorization' && error.status===502);
  await new Promise(done=>setTimeout(done,20));assert.deepEqual(crashes,[]);
 } finally {process.off('uncaughtException',crash);rmSync(dir,{recursive:true,force:true});}
});
test('a host reply with malformed dependencies is an invalid result, not a server crash',async()=>{
 for(const dependencies of ['x',[null],[{date:'2026-10-14',title:'t',body:'b'}],[{event_id:'native_1',date:'2026-10-14',title:'t'}],[{event_id:'synced_input_x',date:'2026-10-14',title:'t'}]]) {
  const agent=createMacAgent({check:async()=>host,execute:async input=>({...result(input),dependencies})});
  await assert.rejects(agent.answer(request),error=>error.message==='invalid_agent_result' && error.status===503);
 }
 const replica=new InputMemoryReplica(':memory:');
 const agent=createMacAgent({check:async()=>host,execute:async input=>({...result(input),dependencies:[{event_id:'native_1',date:'2026-10-14',title:'t'}]})});
 const {server}=createInputMemoryServer({replica,token:'fixture',agent,logger:()=>{}});
 server.listen(0,'127.0.0.1');await once(server,'listening');
 try {
  const response=await fetch('http://127.0.0.1:'+server.address().port+'/agent/answer',{method:'POST',headers:{'Content-Type':'application/json','X-Growth-Token':'fixture'},body:JSON.stringify(request)});
  assert.equal(response.status,503);assert.equal((await response.json()).error,'invalid_agent_result');
 } finally {server.closeAllConnections();await new Promise(done=>server.close(done));replica.close();}
});
test('the common host returns the same request and version; late cancelled results are discarded',async()=>{
 let entered,release;
 const started=new Promise(done=>entered=done),hold=new Promise(done=>release=done);
 const agent=createMacAgent({check:async()=>host,execute:async input=>{entered();await hold;return result(input);}});
 const controller=new AbortController(),pending=agent.answer(request,{signal:controller.signal});
 await started;controller.abort();release();await assert.rejects(pending,/agent_cancelled/);
 const answer=await agent.answer(request);assert.equal(answer.coverage.phone,'unavailable');assert.deepEqual(answer.request_id,request.request_id);
});
test('common endpoint requires authentication and forwards the actual context; no payload is logged',async()=>{
 const replica=new InputMemoryReplica(':memory:'),logs=[];
 const agent=createMacAgent({check:async()=>host,execute:async input=>{assert.deepEqual(input.context,request.context);return result(input);}});
 const {server}=createInputMemoryServer({replica,token:'fixture',agent,logger:value=>logs.push(value)});
 server.listen(0,'127.0.0.1');await once(server,'listening');const base='http://127.0.0.1:'+server.address().port;
 try{
  const send=headers=>fetch(base+'/agent/answer',{method:'POST',headers:{'Content-Type':'application/json',...headers},body:JSON.stringify(request)});
  assert.equal((await send({})).status,401);
  assert.equal((await send({'X-Growth-Token':'fixture',Origin:'https://foreign.example'})).status,403);
  const response=await send({'X-Growth-Token':'fixture'});assert.equal(response.status,200);assert.equal((await response.json()).request_id,request.request_id);
  const health=await(await fetch(base+'/health',{headers:{'X-Growth-Token':'fixture'}})).json();assert.equal(health.agent.ready,true);assert.ok(health.capabilities.includes('agent_answer'));
  assert.ok(logs.every(value=>Object.keys(value).join(',')==='status'));
 }finally{server.closeAllConnections();await new Promise(done=>server.close(done));replica.close();}
});
test('runWarm talks to the real bridge process and keeps its reply shape',async()=>{
  const dir=mkdtempSync(join(tmpdir(),'apt-bridge-')),app=join(dir,'APT.app');
  mkdirSync(join(app,'Contents/Resources'),{recursive:true});
  const bridge=join(app,'Contents/Resources','bridge.py'),marker=join(dir,'fail');
  writeFileSync(bridge,['#!/usr/bin/env python3','import json,sys,os','payload=json.loads(sys.stdin.read())','assert payload["action"]=="warm" and payload["sources"]','if os.path.exists('+JSON.stringify(marker)+'):',
    '    print(json.dumps({"error":"warm_failed: stub refused"}));sys.exit(3)','print(json.dumps({"index":{"state":"warm","model":payload["model"],"chunks":2,"new_chunks":2,"cached_chunks":0,"pending":0,"ms":1}}))'].join('\n'));
  const sources=[syncedInputSource({payload:JSON.stringify({id:'local_input_1',revision:1,created:'2026-10-14T00:00:00Z',device_id:'bbbbbbbb-1111-2222-3333-123456789abc',app:'fixture',text:'正文'}),fingerprint:'f'}).source];
  try {
    assert.deepEqual(await runWarm({app,sources,model:'qwen3-embedding:0.6b'}),{state:'warm',model:'qwen3-embedding:0.6b',chunks:2,new_chunks:2,cached_chunks:0,pending:0,ms:1});
    writeFileSync(marker,'1');
    await assert.rejects(runWarm({app,sources,model:'qwen3-embedding:0.6b'}),/warm_failed: stub refused/);
    await assert.rejects(runWarm({app,sources,model:'qwen3-embedding:0.6b',run:()=>{throw new Error('spawn exploded');}}),/spawn exploded/);
    await assert.rejects(runWarm({app,sources,model:'qwen3-embedding:0.6b',run:async()=>({index:{state:'warm',new_chunks:1.5,pending:0}})}),/warm_invalid_reply/);
  } finally {rmSync(dir,{recursive:true,force:true});}
});
test('a bridge printing null, an array or a number fails the warm and never crashes the service',async()=>{
  const dir=mkdtempSync(join(tmpdir(),'apt-bridge-')),app=join(dir,'APT.app'),out=join(dir,'out');
  mkdirSync(join(app,'Contents/Resources'),{recursive:true});
  writeFileSync(join(app,'Contents/Resources/bridge.py'),['import sys','sys.stdin.read()','sys.stdout.write(open('+JSON.stringify(out)+').read())','sys.exit(int(open('+JSON.stringify(out+'.code')+').read()))'].join('\n'));
  const crashes=[],crash=error=>crashes.push(error);process.on('uncaughtException',crash);
  try {
    for(const code of [0,3])for(const text of ['null','[]','42','"x"','{bad']) {
      writeFileSync(out,text);writeFileSync(out+'.code',String(code));
      await assert.rejects(runWarm({app,sources:[warmRecordingSource]}),/warm_bad_reply/);
    }
    await new Promise(done=>setTimeout(done,20));assert.deepEqual(crashes,[]);
  } finally {process.off('uncaughtException',crash);rmSync(dir,{recursive:true,force:true});}
});
test('the warmer only follows up on real progress, and a throwing log sink cannot kill it',async()=>{
  const calls=[],sources=[{event_id:'e',date:'2026-10-14',title:'t',body:'b'}];
  const run=async()=>({index:{state:'warm',new_chunks:0,cached_chunks:0,pending:5,ms:1,skipped_sources:0}});
  let sink=null;
  const warmer=createIndexWarmer({replica:null,recordings:{pool:async()=>({offered:new Map([['a',{source:sources[0]}]]),truncated:false})},
    resolveModel:async()=>({enabled:true,model:'qwen3-embedding:0.6b'}),run,excludeDevice:()=>null,verifyApp:async()=>true,
    followupMs:20,log:line=>{calls.push(line);if(sink)throw new Error('log sink exploded');}});
  warmer.kick('startup');await new Promise(done=>setTimeout(done,120));
  assert.equal(calls.filter(line=>line.includes('pending=5')).length,1,'pending alone must not schedule another cycle');
  sink=true;warmer.kick('changes');await new Promise(done=>setTimeout(done,60));
  // The throwing sink is swallowed inside the cycle: the warmer keeps running and the process lives.
  assert.equal(warmer.cycles,2);
  warmer.stop();
  // M1: a sink that throws from inside the cycle's own catch block must not escape the cycle,
  // and a cycle that rejects must not escape the kick chain either.
  const failing=createIndexWarmer({replica:null,recordings:fakeRecordings(),resolveModel:async()=>({enabled:true,model:'qwen3-embedding:0.6b'}),
    verifyApp:async()=>true,excludeDevice:()=>null,run:async()=>{throw new Error('warm_spawn_failed');},log:()=>{throw new Error('log sink exploded');}});
  assert.equal(await failing.cycle(),false);
  failing.kick('startup');await new Promise(done=>setTimeout(done,30));
  assert.equal(process.exitCode??0,0);
  failing.stop();
});
test('the warmer disarms when the installed bundle no longer matches the source tree',async()=>{
  const calls=[],sources=[{event_id:'e',date:'2026-10-14',title:'t',body:'b'}];
  const warmer=createIndexWarmer({replica:null,recordings:{pool:async()=>({offered:new Map([['a',{source:sources[0]}]]),truncated:false})},
    resolveModel:async()=>({enabled:true,model:'qwen3-embedding:0.6b'}),run:async()=>{throw new Error('must not run');},
    excludeDevice:()=>null,verifyApp:async()=>false,log:line=>calls.push(line)});
  warmer.kick('startup');await new Promise(done=>setTimeout(done,30));
  assert.equal(calls.length,1);assert.match(calls[0],/does not match this source tree/);
  warmer.stop();
});
