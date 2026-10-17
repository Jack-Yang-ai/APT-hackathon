import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync,rmSync,statSync,readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { RecordingMemoryReplica as LocalReplica,RecordingMemoryPuller,RecordingMemoryProvider } from './recording_memory.mjs';
import { syncRecordings,recordingChanges,handleRecordingMemory } from '../worker/src/recording_memory.js';
import { createMacAgent } from './common_agent.mjs';
import { createInputMemoryServer } from './input_memory_service.mjs';
import { InputMemoryReplica } from './input_memory_store.mjs';
// Cloud-only ownership schema; the installed Mac mirror deliberately stays unchanged.
class RecordingMemoryReplica extends LocalReplica {
  constructor(path) { super(path); if(path===':memory:' && !this.sqlite.prepare("SELECT 1 FROM sqlite_master WHERE name='recording_memory_owners'").get())
    this.sqlite.exec(readFileSync(new URL('../worker/migrations/0003_recording_producers.sql',import.meta.url),'utf8')); }
}

const device='11111111-1111-4111-8111-111111111111',id='apt_recording_22222222-2222-4222-8222-222222222222';
const record=(revision=1,extra={})=>({id,revision,created:'2026-10-15T02:00:00Z',updated:'2026-10-15T04:00:00Z',title:'方案讨论',
  text:JSON.stringify({session_id:1,transcript_id:1,events:[{semantic_id:1,title:'方案讨论'}],lines:[{line_id:10,text:'预算尚未决定，周五再确认。'}]}),partial:false,deleted:false,...extra});
async function put(replica,records,sourceDevice=device) {
  const response=await syncRecordings(replica.db,new Request('https://fixture/recording-memory/sync',{method:'POST',body:JSON.stringify({schema:'apt.recording-memory.batch/1',device_id:sourceDevice,records})}));
  assert.equal(response.status,200);return response.json();
}
function bridge(cloud,mirror,extra={}) {
  return new RecordingMemoryPuller(mirror,{origin:'https://fixture.example',token:'fixture',fetcher:async(url,options)=> {
    assert.equal(new URL(url).pathname,'/recording-memory/changes');assert.equal(options.redirect,'error');
    return recordingChanges(cloud.db,new URL(url));
  },...extra});
}
test('cloud receipt is exact, conflicts/stale cannot revive a tombstone, old events expose current text only',async()=> {
  const cloud=new RecordingMemoryReplica(':memory:');try {
    assert.equal((await put(cloud,[record()])).accepted.length,1);
    assert.equal((await put(cloud,[record(1,{text:'same-version conflict'})])).conflicts.length,1);
    assert.equal((await put(cloud,[record(3,{deleted:true,text:'must never be retained'})])).accepted.length,1);
    assert.equal((await put(cloud,[record(2)])).stale.length,1);
    const page=await (await recordingChanges(cloud.db,new URL('https://fixture/recording-memory/changes'))).json();
    assert.equal(page.records.length,2);assert(page.records.every(r=>r.deleted && r.text===''));
    assert.equal(JSON.stringify(page).includes('must never be retained'),false);
  }finally{cloud.close();}
});
test('recording source mirror persists namespace/cursor with sources and rejects an unrelated database',async()=> {
  const root=mkdtempSync(join(tmpdir(),'apt-recording-')),cloud=new RecordingMemoryReplica(':memory:');
  const path=join(root,'recordings.sqlite');let mirror=new RecordingMemoryReplica(path);
  try {
    await put(cloud,[record()]);let puller=bridge(cloud,mirror);await puller.refresh();
    const provider=new RecordingMemoryProvider(mirror,{refresh:()=>puller.refresh({fresh:true})});
    const pool=await provider.pool('方案',['2026-10-15','2026-10-15']);assert.equal(pool.offered.size,1);assert.equal(pool.truncated,false);
    const source=[...pool.offered.values()][0];assert.match(source.source.body,/预算尚未决定/);assert.match(source.source.event_id,/^synced_recording_/);
    assert(await provider.validate([source.snapshot]));mirror.close();mirror=new RecordingMemoryReplica(path);puller=bridge(cloud,mirror);
    assert.equal(mirror.sqlite.prepare('SELECT cursor FROM recording_memory_upstreams').get().cursor,1);
    await put(cloud,[record(2,{text:'预算取消。'})]);await puller.refresh();
    const restarted=new RecordingMemoryProvider(mirror,{refresh:()=>puller.refresh({fresh:true})});assert.equal(await restarted.validate([source.snapshot]),false);
    assert.equal(statSync(path).mode & 0o777,0o600);
    const other=new InputMemoryReplica(join(root,'input.sqlite'));other.close();assert.throws(()=>new RecordingMemoryReplica(join(root,'input.sqlite')),/incompatible/);
  }finally{mirror.close();cloud.close();rmSync(root,{recursive:true,force:true});}
});
test('a malformed or conflicting page cannot advance the recording cursor',async()=> {
  const mirror=new RecordingMemoryReplica(':memory:');try {
    const fetcher=async()=>Response.json({schema:'apt.recording-memory.changes/1',records:[{...record(),device_id:device,event_seq:1},{...record(1,{text:'conflict'}),device_id:device,event_seq:2}],cursor:2,watermark:2,has_more:false});
    const puller=new RecordingMemoryPuller(mirror,{origin:'https://fixture.example',token:'fixture',fetcher});
    await assert.rejects(puller.refresh(),/conflict/);assert.equal(mirror.sqlite.prepare('SELECT COUNT(*) n FROM recording_memory_sources').get().n,0);
    assert.equal(mirror.sqlite.prepare('SELECT COUNT(*) n FROM recording_memory_upstreams').get().n,0);
  }finally{mirror.close();}
});
test('global and recording-only Agent requests offer actual phone evidence and validate every supplied dependency after generation',async()=> {
  const cloud=new RecordingMemoryReplica(':memory:'),mirror=new RecordingMemoryReplica(':memory:');
  try {
    await put(cloud,[record()]);const puller=bridge(cloud,mirror),provider=new RecordingMemoryProvider(mirror,{refresh:()=>puller.refresh({fresh:true})});
    const host={schema:'apt.agent.host/1',version:'fixture',build:'1',source_fingerprint:'a'.repeat(64),capabilities:['recording_sources']};
    let during=async()=>{},seen;
    const agent=createMacAgent({recordings:provider,check:async()=>host,execute:async input=> {
      seen=input;assert.equal(input.recording_materials.length,1);await during();
      return {schema:'apt.agent.reply/1',request_id:input.request_id,run:{run_id:input.request_id},host,
        replies:['预算尚未决定。'],sources:input.recording_materials,dependencies:input.recording_materials,insertable:true};
    }});
    const request={schema:'apt.agent.request/1',request_id:'33333333-3333-4333-8333-333333333333',query:'2026-10-15 方案的预算',mode:'reply',force_refresh:false,deep_review:false};
    const reply=await agent.answer(request);assert.equal(reply.source_snapshots.length,1);assert.equal(reply.coverage.recording_state,'ready');
    assert.equal((await agent.validate({schema:'apt.agent.validation/1',snapshots:reply.source_snapshots})).valid,true);
    await agent.answer({...request,scope:'recording'});assert.equal(seen.scope,'recording');assert.equal(seen.synced_materials,undefined);
    during=async()=>{await put(cloud,[record(2,{deleted:true,text:''})]);};
    await assert.rejects(agent.answer(request),/recording_sources_changed/);
    await assert.rejects(agent.validate({schema:'apt.agent.validation/1',snapshots:reply.source_snapshots}),/agent_sources_changed/);
  }finally{cloud.close();mirror.close();}
});
test('old native host cannot silently omit recording materials and unavailable recording feed is explicit',async()=> {
  const mirror=new RecordingMemoryReplica(':memory:');try {
    await put(mirror,[record()]);
    const request={schema:'apt.agent.request/1',request_id:'33333333-3333-4333-8333-333333333333',query:'预算',mode:'reply',force_refresh:false,deep_review:false};
    const old=createMacAgent({recordings:new RecordingMemoryProvider(mirror),check:async()=>({source_fingerprint:'a'.repeat(64)}),execute:async()=>assert.fail('old host must not run')});
    await assert.rejects(old.answer(request),/host_update/);
    const offline=createMacAgent({check:async()=>({source_fingerprint:'a'.repeat(64)}),recordings:new RecordingMemoryProvider(mirror,{refresh:async()=>{throw Error('offline');}})});
    await assert.rejects(offline.answer({...request,scope:'recording'}),/recording_sources_unavailable/);
  }finally{mirror.close();}
});
test('recording evidence labels Shanghai clock time across the UTC day boundary without changing canonical evidence',async()=> {
  for(const [created,local] of [['2026-10-15T09:48:43.728Z','2026-10-15 17:48:43'],['2026-10-14T16:05:00Z','2026-10-15 00:05:00']]) {
    const mirror=new RecordingMemoryReplica(':memory:');try {
      await put(mirror,[record(1,{created,updated:'2026-10-15T10:10:00Z'})]);
      const before=mirror.sqlite.prepare('SELECT payload,fingerprint FROM recording_memory_sources').get();
      const provider=new RecordingMemoryProvider(mirror),pool=await provider.pool('今天录音',['2026-10-15','2026-10-15']);
      assert.equal(pool.offered.size,1);const offered=[...pool.offered.values()][0];
      assert.equal(offered.source.date,'2026-10-15');assert(offered.source.body.includes('北京时间，UTC+08:00）：'+local));
      assert(offered.source.body.endsWith(JSON.parse(before.payload).text));
      assert.deepEqual(mirror.sqlite.prepare('SELECT payload,fingerprint FROM recording_memory_sources').get(),before);
      assert(await provider.validate([offered.snapshot],pool.watermark));
    }finally{mirror.close();}
  }
});
test('recording endpoint is behind the existing Worker gate; local final-validation endpoint requires authentication',async()=> {
  const cloud=new RecordingMemoryReplica(':memory:'),inputs=new InputMemoryReplica(':memory:');let runtime;
  try {
    const worker=await import('../worker/src/index.js');
    const response=await worker.default.fetch(new Request('https://fixture/recording-memory/changes'),{CLIENT_TOKEN:'fixture',INPUT_MEMORY:cloud.db},{});assert.equal(response.status,401);
    assert.equal((await handleRecordingMemory(new Request('https://fixture/recording-memory/changes'),{INPUT_MEMORY:cloud.db},new URL('https://fixture/recording-memory/changes'))).status,200);
    const agent=createMacAgent({recordings:new RecordingMemoryProvider(cloud)});runtime=createInputMemoryServer({replica:inputs,token:'fixture',agent});
    await new Promise(done=>runtime.server.listen(0,'127.0.0.1',done));const url='http://127.0.0.1:'+runtime.server.address().port+'/agent/validate';
    assert.equal((await fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'})).status,401);
    const checked=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json','X-Growth-Token':'fixture'},body:JSON.stringify({schema:'apt.agent.validation/1',snapshots:[]})});assert.equal(checked.status,200);
  }finally{if(runtime)await new Promise(done=>runtime.server.close(done));cloud.close();inputs.close();}
});
test('large atomic transcript writes and idempotent receipts stay within the Free D1 query and value budgets',async()=> {
  const cloud=new RecordingMemoryReplica(':memory:');try {
    const original=cloud.db.batch.bind(cloud.db);let queries=0;
    cloud.db.batch=async statements=> {
      queries+=statements.length;assert(statements.length<50);
      for(const s of statements)for(const arg of s.args)if(typeof arg==='string')assert(Buffer.byteLength(arg)<2000000);
      return original(statements);
    };
    const records=Array.from({length:2000},(_,i)=>record(1,{id:'apt_recording_'+i.toString(16).padStart(8,'0')+'-2222-4222-8222-222222222222'}));
    assert.equal((await put(cloud,records)).accepted.length,2000);assert(queries<50);queries=0;
    assert.equal((await put(cloud,records)).accepted.length,2000);assert(queries<50);
  }finally{cloud.close();}
});
test('feed snapshots never join future payloads to an old boundary; additions invalidate an otherwise unchanged selected source',async()=> {
  const cloud=new RecordingMemoryReplica(':memory:'),mirror=new RecordingMemoryReplica(':memory:');try {
    await put(cloud,[record()]);const puller=bridge(cloud,mirror),provider=new RecordingMemoryProvider(mirror,{refresh:()=>puller.refresh({fresh:true})});
    // A real cloud transaction lands immediately after the feed's snapshot transaction.
    cloud.db.afterBatch=()=>put(cloud,[record(1,{id:'apt_recording_44444444-4444-4444-8444-444444444444',text:'新增了另一个承诺。'})]);
    const offered=await provider.pool('全部承诺');assert.equal(offered.offered.size,1);
    const snapshots=[...offered.offered.values()].map(v=>v.snapshot);
    assert.equal(await provider.validate(snapshots,offered.watermark),false);
    assert.equal((await provider.pool('全部承诺')).offered.size,2);
    const before=await (await recordingChanges(cloud.db,new URL('https://fixture/recording-memory/changes?limit=1'))).json();
    await put(cloud,[record(2,{text:'修订后的内容。'})]);
    const later=await recordingChanges(cloud.db,new URL('https://fixture/recording-memory/changes?after='+before.cursor+'&through='+before.watermark));
    assert.equal(later.status,409);assert.equal((await later.json()).error,'recording_watermark_changed');
  }finally{cloud.close();mirror.close();}
});
test('date planning happens in the existing native parser before a large recording pool is limited; partial sources block full statistics',async()=> {
  const mirror=new RecordingMemoryReplica(':memory:');try {
    await put(mirror,[record(1,{partial:true})]);
    const provider=new RecordingMemoryProvider(mirror),host={source_fingerprint:'a'.repeat(64),capabilities:['recording_sources','source_range']};
    let sawRange=false;
    const agent=createMacAgent({recordings:provider,check:async()=>host,execute:async input=> {
      if(input.schema==='apt.agent.range/1') {sawRange=true;return {schema:input.schema,request_id:input.request_id,from:'2026-10-15',to:'2026-10-15',host};}
      assert(sawRange);assert.equal(input.recording_truncated,true);assert.equal(input.recording_materials.length,1);
      return {schema:'apt.agent.reply/1',request_id:input.request_id,run:{run_id:input.request_id},host,dependencies:input.recording_materials};
    }});
    const result=await agent.answer({schema:'apt.agent.request/1',request_id:'33333333-3333-4333-8333-333333333333',query:'昨天的全部录音',mode:'reply',force_refresh:false,deep_review:false});
    assert.equal(result.coverage.recording_state,'limited');
  }finally{mirror.close();}
});
test('final validation reuses the native source reader and has the same concurrency and cancellation budget',async()=> {
  const host={source_fingerprint:'a'.repeat(64),capabilities:['source_validation']};let calls=0;
  const agent=createMacAgent({check:async()=>host,execute:async(input,{signal})=> {
    calls++;assert.equal(input.schema,'apt.agent.source-validation/1');assert.equal(input.snapshots.length,1);
    await new Promise(done=>setTimeout(done,20));
    return {schema:input.schema,request_id:input.request_id,valid:true,host};
  }});
  const request={schema:'apt.agent.validation/1',snapshots:[],native_snapshots:[{event_id:'echo_fixture',date:'2026-10-15',title:'原话',fingerprint:'a'.repeat(64)}]};
  const controller=new AbortController(),a=agent.validate(request,{signal:controller.signal}),b=agent.validate(request);
  await assert.rejects(agent.validate(request),/agent_busy/);controller.abort();
  await assert.rejects(a,/agent_cancelled/);assert.equal((await b).valid,true);assert.equal(calls,2);
});
