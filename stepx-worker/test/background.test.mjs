import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';
import { createHash } from 'node:crypto';
import { RecordingCoordinator } from '../src/recording_coordinator.js';
import { RecordingMemoryReplica,RecordingMemoryPuller,RecordingMemoryProvider } from '../../mac/recording_memory.mjs';
import { handleRecordingMemory,recordingChanges } from '../../worker/src/recording_memory.js';
test('background retry consent is durable before a lost paid submission and is not replayed',async()=>{
  const runtime=productionRuntime(),retryId=crypto.randomUUID();
  const job={id:'piece',recordingId:'record',index:0,uploaded:true,remoteKey:'audio',session:'fixture',seconds:1,
    state:'transcribing',retryFailed:true,retryId,nextAt:0,attempts:0};
  const source={matters:[{id:'record',startedAt:0}],segments:[{id:'piece',matterId:'record',index:0,capturedAt:0,durationSec:1}],jobs:[]};
  const calls=[];let saved=structuredClone(job);
  const save=async row=>{saved=structuredClone(row);};
  await assert.rejects(runtime.advance(source,job,async(path,body)=>{calls.push(structuredClone(body));throw Error('unknown_result');},save),/unknown_result/);
  assert.equal(saved.retryFailed,false);assert.equal(calls[0].retryId,retryId);assert.equal(calls[0].retryFailed,true);
  await runtime.advance(source,structuredClone(saved),async(path,body)=>{
    calls.push(structuredClone(body));return path==='/asr/submit'?{task_id:'same_key_receipt'}:{state:'done',result:[]};
  },save);
  assert.equal(calls[1].retryFailed,undefined);assert.equal(calls[1].retryId,undefined);assert.equal(saved.state,'done');
});
test('background retry consent storage failure prevents dispatch and a legacy boolean grants no retry',async()=>{
  const runtime=productionRuntime(),base={id:'piece',recordingId:'record',index:0,uploaded:true,remoteKey:'audio',session:'fixture',seconds:1,
    state:'transcribing',retryFailed:true,retryId:crypto.randomUUID(),nextAt:0,attempts:0};
  const source={matters:[{id:'record'}],segments:[{id:'piece'}],jobs:[]};let calls=0;
  await assert.rejects(runtime.advance(source,structuredClone(base),async()=>{calls++;throw Error('dispatched');},async()=>{throw Error('storage_failed');}),/storage_failed/);
  assert.equal(calls,0);
  const legacy={...base};delete legacy.retryId;
  await assert.rejects(runtime.advance(source,legacy,async(path,body)=>{assert.equal(body.retryFailed,undefined);assert.equal(body.retryId,undefined);throw Error('unknown_result');},async()=>{}),/unknown_result/);
});
const device='11111111-1111-4111-8111-111111111111',recording='22222222-2222-4222-8222-222222222222';
const generation='33333333-3333-4333-8333-333333333333',capture='44444444-4444-4444-8444-444444444444';
const handoff='55555555-5555-4555-8555-555555555555',client='66666666-6666-4666-8666-666666666666',start=1792044000000;
const hash=value=>createHash('sha256').update(value).digest('hex');
const plain=value=>JSON.parse(JSON.stringify(value));
function productionRuntime() {
  const c={crypto,TextEncoder,structuredClone,console,Date};vm.createContext(c);
  const files=[['processing-data.ts',['parseASR','parseEvents','freezeLines','SEMANTIC_RECIPE','retryProcessingJob']],
    ['source-scope.ts',['projectedEvents','previousContext','fragmentMaterial','recordingMaterial','lineStamp']],
    ['quote-normalize.ts',['normalizeQuote','isVerbatim']],['personal-action-data.ts',['ACTION_PROTOCOL','parsePersonalActions']],
    ['recording-memory-data.ts',['projectRecordingMemory','canonicalRecording']]];
  for(const [file,names] of files) {
    const source=fs.readFileSync(new URL('../../stepx-client/src/growth/'+file,import.meta.url),'utf8').replace(/^import .*\n/gm,'').replace(/export /g,'');
    vm.runInContext('(function(){'+stripTypeScriptTypes(source,{mode:'transform'})+'\n'+names.map(name=>'globalThis.'+name+'='+name+';').join('')+'})()',c);
  }
  const source=fs.readFileSync(new URL('../src/recording_runtime.ts',import.meta.url),'utf8').replace(/^import .*\n/gm,'')
    .replace(/^export \{.*\}.*\n/gm,'').replace(/export /g,'');
  vm.runInContext('(function(){'+stripTypeScriptTypes(source,{mode:'transform'})+'\nglobalThis.advance=advance;globalThis.wholeActions=wholeActions;})()',c);
  return c;
}
class Storage {
  data=new Map();alarm=null;serial=Promise.resolve();
  async get(key){return structuredClone(this.data.get(key));}
  async put(key,value){this.data.set(key,structuredClone(value));if(this.afterPut)await this.afterPut(key);}
  async delete(key){return this.data.delete(key);}
  async list({prefix}){return new Map([...this.data].filter(([key])=>key.startsWith(prefix)).map(([key,v])=>[key,structuredClone(v)]));}
  async setAlarm(at){this.alarm=at;}
  async deleteAlarm(){this.alarm=null;}
  transaction(fn){const work=this.serial.catch(()=>undefined).then(async()=>{
    const before=structuredClone(this.data),alarm=this.alarm;
    try{return await fn(this);}catch(error){this.data=before;this.alarm=alarm;throw error;}
  });this.serial=work.catch(()=>undefined);return work;}
}
class Bucket {
  data=new Map();metadata=new Map();
  async put(key,body,options={}){const bytes=typeof body==='string'?Buffer.from(body):Buffer.from(body);this.data.set(key,bytes);this.metadata.set(key,options.customMetadata);}
  async get(key){const bytes=this.data.get(key);if(!bytes)return null;return {size:bytes.length,etag:hash(bytes),customMetadata:this.metadata.get(key),text:async()=>bytes.toString(),
    json:async()=>JSON.parse(bytes.toString()),arrayBuffer:async()=>Uint8Array.from(bytes).buffer};}
  async head(key){return this.get(key);}
}
function fixture() {
  const runtime=productionRuntime(),storage=new Storage(),bucket=new Bucket(),cloud=new RecordingMemoryReplica(':memory:');
  cloud.sqlite.exec(fs.readFileSync(new URL('../../worker/migrations/0003_recording_producers.sql',import.meta.url),'utf8'));
  const workerEnv={INPUT_MEMORY:cloud.db,RECORDING_PRODUCER_TOKEN:'server-fixture'};
  let intercept=null,modelIntercept=null;const calls=[],tickets=new Map();
  const env={AUDIO:bucket,GROWTH_CLIENT_TOKEN:'client-fixture',RECORDING_PRODUCER_TOKEN:workerEnv.RECORDING_PRODUCER_TOKEN,
    GROWTH_UPSTREAM:{async fetch(request){if(intercept)return intercept(request,()=>handleRecordingMemory(request,workerEnv,new URL(request.url)));
      return handleRecordingMemory(request,workerEnv,new URL(request.url));}}};
  const call=async(path,body)=>{
    calls.push({path,body:structuredClone(body)});if(modelIntercept){const result=await modelIntercept(path,body);if(result)return result;}
    if(path==='/asr/submit')return {task_id:'task_'+hash(body.key).slice(0,16)};
    if(path==='/asr/query')return {state:'done',result:[{utterances:[{text:'Public recorded words',start_time:0,end_time:1000,speaker:{id:'speaker_0'}}]}]};
    if(path==='/extract/enqueue') {
      const ticket=body.session+'-'+body.part+'-'+hash(JSON.stringify(body.lines)).slice(0,16);tickets.set(ticket,structuredClone(body));return {state:'queued',ticket};
    }
    if(path==='/extract/result') {
      const first=tickets.get(body.ticket).lines[0];return {state:'done',payload:{pipeline_version:'v3-semantic-continuity',action_protocol:'personal-actions/v1',personal_actions:[],
        events:first.action_only?[]:[{title:'Public event',summary:'Validated public words',line_from:first.line_id,line_to:first.line_id,
          ...(first.stream_context?{continuation_id:first.stream_context.event_id}:{})}]}};
    }
    throw Error('unexpected_model_path');
  };
  let coordinator=new RecordingCoordinator({storage},env,call,async()=>runtime);
  const invoke=async(route,input={})=>{const response=await coordinator.fetch(new Request('https://internal/'+route,{method:'POST',body:JSON.stringify({device_id:device,recording_id:recording,generation,...input})}));return {status:response.status,body:await response.json()};};
  const snapshot=()=>({matter:{id:recording,startedAt:start,endedAt:null,origin:'record',title:null,progress:null,personalActionsEnabled:false,captureComplete:false},segments:[],jobs:[],memory:[]});
  const claim=(s=snapshot())=>invoke('claim',{handoff_id:handoff,snapshot:s});
  async function piece(index=0,captureId=capture,indexBase=0,capturedAt=start+index*5000,compact=false) {
    const id=`root:${captureId}:${index}`,digest=hash(id),uuid=`${digest.slice(0,8)}-${digest.slice(8,12)}-${digest.slice(12,16)}-${digest.slice(16,20)}-${digest.slice(20,32)}`;
    const bytes=compact?fs.readFileSync(new URL('./fixtures/aac-mono-16k.m4a',import.meta.url)):Buffer.alloc(160044,index+1);
    const frames=compact?16000:80000,sha256=hash(bytes),key=`stepx/${client}/${recording}/${uuid}-${sha256}.${compact?'m4a':'wav'}`;
    await bucket.put(key,bytes,compact?{customMetadata:{audioFormat:'m4a',profile:'apt.aac-lc-16k-mono/1',sourceFrames:String(frames),sha256}}:{});
    return {capture_id:captureId,piece:index,index_base:indexBase,frames,frame_offset:index*80000,captured_at:capturedAt,sha256,key,upload_client:client};
  }
  const captureFacts=(extra={})=>({capture_id:capture,index_base:0,started_at:start,chunk_frames:80000,frames:0,closed:false,finish:false,...extra});
  return {runtime,storage,bucket,cloud,calls,invoke,snapshot,claim,piece,captureFacts,
    coordinator:()=>coordinator,
    alarm:()=>coordinator.alarm(),restart:()=>{coordinator=new RecordingCoordinator({storage},env,call,async()=>runtime);},
    intercept:fn=>intercept=fn,modelIntercept:fn=>modelIntercept=fn};
}
test('no foreground client is needed for uploaded PCM to become a validated Mac memory source',async()=>{
  const f=fixture(),mirror=new RecordingMemoryReplica(':memory:');try {
    assert.equal((await f.claim()).status,200);
    await f.invoke('capture',{capture:f.captureFacts({closed:true,finish:true,frames:80000,ended_at:start+5000})});
    assert.equal((await f.invoke('piece',{piece:await f.piece()})).status,200);
    for(let i=0;i<4;i++){await f.alarm();f.restart();}
    const status=(await f.invoke('status')).body;assert.equal(status.jobs[0].state,'done');assert.equal(status.memory.pending,0);assert.equal(status.memory.partial,false);
    assert.equal(f.calls.filter(row=>row.path==='/asr/submit').length,1);assert.equal(f.calls.filter(row=>row.path==='/extract/enqueue').length,1);
    const puller=new RecordingMemoryPuller(mirror,{origin:'https://fixture.example',token:'fixture',fetcher:url=>recordingChanges(f.cloud.db,new URL(url))});await puller.refresh();
    const provider=new RecordingMemoryProvider(mirror,{refresh:()=>puller.refresh({fresh:true})}),pool=await provider.pool('Public',['2026-10-15','2026-10-15']);
    assert.equal(pool.offered.size,1);assert.match([...pool.offered.values()][0].source.body,/Public recorded words/);
    assert(await provider.validate([...pool.offered.values()].map(row=>row.snapshot)));
  }finally{mirror.close();f.cloud.close();}
});
test('compact AAC crosses background ASR, semantic processing and memory with immutable source frames',async()=>{
 const f=fixture();try {
  assert.equal((await f.claim()).status,200);
  await f.invoke('capture',{capture:f.captureFacts({closed:true,finish:true,frames:16000,ended_at:start+1000})});
  const piece=await f.piece(0,capture,0,start,true);assert.equal((await f.invoke('piece',{piece})).status,200);
  for(let i=0;i<4;i++){await f.alarm();f.restart();}
  const status=(await f.invoke('status')).body;
  assert.equal(status.jobs[0].state,'done');assert.equal(f.calls.find(row=>row.path==='/asr/submit').body.seconds,1);
  const material=await f.coordinator().source(await f.storage.get('head'));
  assert.equal(material.segments[0].rootAudioFormat,'m4a');assert.ok(material.segments[0].sizeBytes<32044);
  assert.equal(status.memory.pending,0);assert.equal(status.memory.partial,false);
  assert.equal(f.calls.filter(row=>row.path==='/asr/submit').length,1);
  assert.ok(f.calls.find(row=>row.path==='/asr/submit').body.key.endsWith('.m4a'));
 } finally {f.cloud.close();}
});
test('a phone finish control before native preparation cannot fence late background closure',async()=>{
  const f=fixture();try {
    await f.claim();await f.invoke('capture',{capture:f.captureFacts()});
    const snapshot=f.snapshot();snapshot.matter={...snapshot.matter,endedAt:start+5000,captureComplete:false,rootFinalizing:true};
    assert.equal((await f.invoke('control',{mutation_id:crypto.randomUUID(),control_version:1,state:'active',snapshot})).status,200);
    f.restart();await f.invoke('capture',{capture:f.captureFacts({closed:true,finish:true,frames:80000,ended_at:start+5000})});
    await f.invoke('piece',{piece:await f.piece()});for(let i=0;i<4;i++){await f.alarm();f.restart();}
    const status=(await f.invoke('status')).body;
    assert.equal(status.matter.captureComplete,true);assert.equal(status.matter.rootFinalizing,false);
    assert.equal(status.matter.endedAt,start+5000);assert.equal(status.memory.partial,false);
    assert.equal((await f.storage.get('head')).formalClose,false);
  }finally{f.cloud.close();}
});
test('legacy prefix frame identity tolerates floating point round trips but rejects fractional frames',async()=>{
  for(const fractional of [false,true]) {
    const f=fixture();try {
      const p=await f.piece(),s=f.snapshot(),id=`root:${capture}:0`,frames=1025024;
      s.segments=[{id,matterId:recording,index:0,capturedAt:start,durationSec:(frames+(fractional?.01:0))/16000,sizeBytes:44+frames*2,
        rootUpload:{captureId:capture,piece:0,sha256:p.sha256,client}}];
      s.jobs=[{id,recordingId:recording,index:0,state:'transcribing',remoteKey:p.key,session:`stepx_${client}_${recording}`,seconds:frames/16000,uploaded:true,nextAt:0}];
      s.captures=[{captureId:capture,matterId:recording,indexBase:0,chunkSeconds:300,state:'stopped',frames,startedAt:start,uploadClient:client}];
      assert.equal((await f.claim(s)).status,fractional?400:200);
    }finally{f.cloud.close();}
  }
});
test('formal phone closure survives a first late capture and only a controlled resume can reopen it',async()=>{
  const f=fixture();try {
    await f.claim();const snapshot=f.snapshot();
    snapshot.matter={...snapshot.matter,endedAt:start+12345,captureComplete:true,rootFinalizing:false};
    assert.equal((await f.invoke('control',{mutation_id:crypto.randomUUID(),control_version:1,state:'active',snapshot})).status,200);
    assert.equal((await f.storage.get('head')).formalClose,true);
    assert.equal((await f.invoke('capture',{capture:f.captureFacts({closed:true,finish:true,frames:80000,ended_at:start+5000})})).status,200);
    await f.invoke('piece',{piece:await f.piece()});for(let i=0;i<4;i++){await f.alarm();f.restart();}
    let head=await f.storage.get('head');assert.equal(head.formalClose,true);
    assert.equal(head.matter.endedAt,start+12345);assert.equal(head.matter.captureComplete,true);
    const material=await f.coordinator().source(head);
    const resumed={matter:{...material.matters[0],endedAt:null,captureComplete:false,rootFinalizing:false},segments:material.segments,jobs:material.jobs,memory:[]};
    assert.equal((await f.invoke('control',{mutation_id:crypto.randomUUID(),control_version:2,state:'active',snapshot:resumed})).status,200);
    assert.equal((await f.invoke('capture',{capture:f.captureFacts({capture_id:crypto.randomUUID(),index_base:1,started_at:start+13000})})).status,200);
    head=await f.storage.get('head');assert.equal(head.formalClose,false);assert.equal(head.matter.endedAt,null);assert.equal(head.matter.captureComplete,false);
  }finally{f.cloud.close();}
});
test('legacy formal closure without a phone resume snapshot is not cleared by a new capture',async()=>{
  const f=fixture();try {
    await f.claim();const head=await f.storage.get('head');delete head.phoneMatter;
    await f.storage.put('head',{...head,formalClose:true,matter:{...head.matter,endedAt:start+12345,captureComplete:true}});
    assert.equal((await f.invoke('capture',{capture:f.captureFacts()})).status,200);
    const current=await f.storage.get('head');assert.equal(current.formalClose,true);assert.equal(current.matter.endedAt,start+12345);assert.equal(current.matter.captureComplete,true);
  }finally{f.cloud.close();}
});
test('late capture metadata cannot downgrade a committed close and an old closer cannot overwrite a new capture',async()=>{
  const f=fixture();try {
    await f.claim();const original=f.storage.transaction.bind(f.storage);let release,entered,first=true;
    const blocked=new Promise(resolve=>release=resolve),waiting=new Promise(resolve=>entered=resolve);
    f.storage.transaction=async fn=>{if(first){first=false;entered();await blocked;}return original(fn);};
    const late=f.invoke('capture',{capture:f.captureFacts()});await waiting;
    assert.equal((await f.invoke('capture',{capture:f.captureFacts({closed:true,finish:true,frames:80000,ended_at:start+5000})})).status,200);
    release();assert.equal((await late).status,409);assert.equal((await f.storage.get('capture:'+capture)).finish,true);
    await f.invoke('piece',{piece:await f.piece()});const head=await f.storage.get('head'),list=f.storage.list.bind(f.storage);
    let releaseClose,enteredClose,once=true;const gate=new Promise(resolve=>releaseClose=resolve),read=new Promise(resolve=>enteredClose=resolve);
    f.storage.list=async options=>{const rows=await list(options);if(options.prefix==='manifest:'&&once){once=false;enteredClose();await gate;}return rows;};
    const closing=f.coordinator().closeMatter(head);await read;
    assert.equal((await f.invoke('capture',{capture:f.captureFacts({capture_id:crypto.randomUUID(),index_base:1,started_at:start+6000})})).status,200);
    releaseClose();await closing;const current=await f.storage.get('head');assert.equal(current.matter.endedAt,null);assert.equal(current.matter.captureComplete,false);
  }finally{f.cloud.close();}
});
test('concurrent metadata for the same piece is immutable inside its final commit',async()=>{
  const f=fixture();try {
    await f.claim();const first=await f.piece(),other=await f.piece(0,capture,1);
    let release,entered,once=true;const gate=new Promise(resolve=>release=resolve),waiting=new Promise(resolve=>entered=resolve);
    const transaction=f.storage.transaction.bind(f.storage);
    f.storage.transaction=async fn=>{if(once){once=false;entered();await gate;}return transaction(fn);};
    const delayed=f.invoke('piece',{piece:first});await waiting;
    assert.equal((await f.invoke('piece',{piece:other})).status,200);release();assert.equal((await delayed).status,409);
    assert.equal((await f.storage.get('manifest:root:'+capture+':0')).index_base,1);
  }finally{f.cloud.close();}
});
test('a verified stopped legacy prefix closes after a resumed native capture without foreground reconciliation',async()=>{
  const f=fixture();try {
    const p=await f.piece(),id=`root:${capture}:0`,s=f.snapshot();
    s.segments=[{id,matterId:recording,index:0,capturedAt:start,durationSec:5,sizeBytes:160044,cloudEligible:true,
      rootUpload:{captureId:capture,piece:0,sha256:p.sha256,client}}];
    s.jobs=[{id,recordingId:recording,index:0,state:'transcribing',remoteKey:p.key,session:`stepx_${client}_${recording}`,seconds:5,uploaded:true,nextAt:0}];
    s.captures=[{captureId:capture,matterId:recording,indexBase:0,chunkSeconds:300,state:'stopped',frames:80000,startedAt:start,uploadClient:client}];
    assert.equal((await f.claim(s)).status,200);
    const resumed=crypto.randomUUID();await f.invoke('capture',{capture:f.captureFacts({capture_id:resumed,index_base:1,started_at:start+6000,closed:true,finish:true,frames:80000,ended_at:start+11000})});
    await f.invoke('piece',{piece:await f.piece(0,resumed,1,start+6000)});
    for(let i=0;i<6;i++)await f.alarm();const status=(await f.invoke('status')).body;
    assert(status.jobs.every(j=>j.state==='done'));assert.equal(status.matter.captureComplete,true);assert.equal(status.memory.partial,false);
    const bad=fixture();try{s.captures[0].frames++;assert.equal((await bad.claim(s)).status,400);assert.equal(await bad.storage.get('head'),undefined);}finally{bad.cloud.close();}
  }finally{f.cloud.close();}
});
test('whole actions keep in-flight paid identity on retry and persist terminal failure without hot polling',async()=>{
  const f=fixture();try {
    const s=f.snapshot();s.matter.personalActionsEnabled=true;await f.claim(s);
    await f.invoke('capture',{capture:f.captureFacts({closed:true,finish:true,frames:80000,ended_at:start+5000})});await f.invoke('piece',{piece:await f.piece()});
    let wholeTicket,terminal=false;
    f.modelIntercept(async(path,body)=>{
      if(path==='/extract/enqueue'&&body.lines[0].action_only)wholeTicket=body.session;
      if(path==='/extract/result'&&body.ticket.startsWith(wholeTicket+'-'))return terminal?{state:'done',payload:{terminal:true,error:'fixture_invalid_result'}}:{state:'running'};
      return null;
    });
    for(let i=0;i<3;i++)await f.alarm();const action=await f.storage.get('actions'),old=await f.coordinator().unblob(action.ref);
    const current=plain(await f.coordinator().source(await f.storage.get('head')));
    assert.equal((await f.invoke('control',{state:'active',control_version:1,mutation_id:crypto.randomUUID(),retry:'actions',snapshot:{matter:current.matters[0],segments:current.segments,jobs:current.jobs,memory:[]}})).status,200);
    const after=await f.coordinator().unblob((await f.storage.get('actions')).ref);assert.equal(after.requestId,old.requestId);
    after.nextAt=0;await f.storage.put('actions',{ref:await f.coordinator().blob(after)});terminal=true;await f.alarm();
    assert.equal((await f.coordinator().unblob((await f.storage.get('actions')).ref)).state,'failed');
    const queries=f.calls.length;await f.alarm();assert.equal(f.calls.length,queries);assert.equal(f.calls.filter(c=>c.path==='/extract/enqueue'&&c.body.lines[0].action_only).length,1);
  }finally{f.cloud.close();}
});
test('unknown ASR queries retain identity and confirmed failures wait for controlled retry before resubmission',async()=>{
  const f=fixture();try {
    await f.claim();await f.invoke('piece',{piece:await f.piece()});
    let failure='processing_failed';
    f.modelIntercept(async(path,body)=>{
      if(path==='/asr/query'&&body.task_id!=='retried_safe_task')throw Object.assign(Error(failure),{code:failure});
      if(path==='/asr/submit'&&body.retryFailed)return {task_id:'retried_safe_task'};
      return null;
    });
    await f.alarm();let source=plain(await f.coordinator().source(await f.storage.get('head'))),job=source.jobs[0];
    assert.equal(job.state,'transcribing');assert(job.taskId);assert.equal(job.failureCode,'processing_failed');
    const originalTask=job.taskId;f.restart();await f.coordinator().putJob(await f.storage.get('head'),{...job,nextAt:0});failure='asr_failed';
    await f.alarm();source=plain(await f.coordinator().source(await f.storage.get('head')));job=source.jobs[0];
    assert.equal(job.state,'failed');assert.equal(job.taskId,originalTask);assert.equal(job.failureCode,'asr_failed');
    const calls=f.calls.length;await f.alarm();await f.alarm();assert.equal(f.calls.length,calls);
    assert.equal((await f.invoke('control',{state:'active',control_version:1,mutation_id:crypto.randomUUID(),retry:'failed',
      snapshot:{matter:source.matters[0],segments:source.segments,jobs:source.jobs,memory:[]}})).status,200);
    for(let i=0;i<4;i++)await f.alarm();
    assert.equal((await f.invoke('status')).body.jobs[0].state,'done');
    const submits=f.calls.filter(c=>c.path==='/asr/submit');assert.equal(submits.length,2);assert.equal(submits[1].body.retryFailed,true);
  }finally{f.cloud.close();}
});
test('an oversized control plan is rejected before ownership changes and a smaller edit can recover',async()=>{
  const f=fixture();try {
    await f.claim();for(let i=0;i<4;i++)await f.invoke('piece',{piece:await f.piece(i)});
    const head=await f.storage.get('head');
    for(const row of (await f.storage.list({prefix:'job:'})).values()) {
      const job=await f.coordinator().unblob(row.ref);await f.coordinator().putJob(head,{...job,state:'done',lines:[{line_id:row.index,text:'a'.repeat(3600000)}]});
    }
    const current=plain(await f.coordinator().source(head)),last=current.jobs.find(row=>row.index===3);
    const snapshot={matter:current.matters[0],segments:current.segments,jobs:[{...last,lines:[{line_id:3,text:'b'.repeat(6500000)}]}],memory:[]};
    const bad=await f.invoke('control',{state:'active',control_version:1,mutation_id:crypto.randomUUID(),snapshot});
    assert.equal(bad.status,400);assert.equal(bad.body.error,'background_material_capacity');
    assert.equal((await f.storage.get('head')).phase,'active');assert.equal((await f.storage.get('head')).control_version,0);
    snapshot.jobs[0].lines=[{line_id:3,text:'short correction'}];
    assert.equal((await f.invoke('control',{state:'active',control_version:1,mutation_id:crypto.randomUUID(),snapshot})).status,200);
    assert((await f.coordinator().source(await f.storage.get('head'))).jobs.every(row=>row.lines));
  }finally{f.cloud.close();}
});
test('an offline phone control preserves native pieces it has not received and respects explicit removals',async()=>{
  const f=fixture();try {
    await f.claim();await f.invoke('capture',{capture:f.captureFacts({closed:true,finish:true,frames:160000,ended_at:start+10000})});
    for(let i=0;i<2;i++)await f.invoke('piece',{piece:await f.piece(i)});
    for(let i=0;i<5;i++)await f.alarm();const snapshot=f.snapshot();snapshot.matter.rootUploadClient=client;
    assert.equal((await f.invoke('control',{state:'active',control_version:1,mutation_id:crypto.randomUUID(),snapshot})).status,200);
    for(let i=0;i<3;i++)await f.alarm();let status=(await f.invoke('status')).body;
    assert.equal(status.jobs.length,2);assert.equal(status.memory.sources,2);assert.equal(status.matter.captureComplete,true);
    assert.equal((await f.storage.list({prefix:'excluded:'})).size,0);
    assert.equal((await f.invoke('control',{state:'active',control_version:2,mutation_id:crypto.randomUUID(),snapshot,
      removed_ids:[`root:${capture}:0`,`root:${capture}:1`]})).status,200);
    await f.alarm();status=(await f.invoke('status')).body;assert.equal(status.jobs.length,0);assert.equal(status.memory.sources,0);
    assert.equal(f.cloud.sqlite.prepare('SELECT count(*) n FROM recording_memory_sources WHERE deleted=0').get().n,0);
  }finally{f.cloud.close();}
});
test('an explicitly moved piece is fenced even before its native delivery; later words get a fresh semantic root',async()=>{
  const f=fixture();try {
    await f.claim();const removed=`root:${capture}:0`;
    assert.equal((await f.invoke('control',{state:'active',control_version:1,mutation_id:crypto.randomUUID(),snapshot:f.snapshot(),
      removed_ids:[removed],removed_indices:{[removed]:0}})).status,200);
    await f.invoke('piece',{piece:await f.piece(1)});for(let i=0;i<3;i++)await f.alarm();
    const jobs=(await f.invoke('status')).body.jobs;assert.equal(jobs.length,1);assert.equal(jobs[0].state,'done');
    await f.invoke('piece',{piece:await f.piece(0)});await f.alarm();assert.equal((await f.invoke('status')).body.jobs.length,1);
    assert.equal((await f.coordinator().unblob(jobs[0].ref)).semanticStart,1);
  }finally{f.cloud.close();}
});
test('lost source publication receipt replays the same source revision after restart without charging again',async()=>{
  const f=fixture();try {
    await f.claim();await f.invoke('piece',{piece:await f.piece()});let lost=false;
    f.intercept(async(request,send)=>{const result=await send();if(!lost&&new URL(request.url).pathname==='/recording-memory/sync'){lost=true;throw Error('lost response');}return result;});
    await f.alarm();const first=f.cloud.sqlite.prepare('SELECT record_id FROM recording_memory_sources').get().record_id;
    f.restart();await f.alarm();await f.alarm();
    assert.equal(f.cloud.sqlite.prepare('SELECT count(*) n FROM recording_memory_sources').get().n,1);
    assert.equal(f.cloud.sqlite.prepare('SELECT record_id FROM recording_memory_sources').get().record_id,first);
    assert.equal(f.calls.filter(row=>row.path==='/asr/submit').length,1);
    assert.equal((await f.invoke('status')).body.memory.pending,0);
  }finally{f.cloud.close();}
});
test('deletion fences a model callback already in flight and native revocation is idempotent',async()=>{
  const f=fixture();try {
    await f.claim();await f.invoke('piece',{piece:await f.piece()});await f.alarm();
    let release,entered;const blocked=new Promise(resolve=>release=resolve),waiting=new Promise(resolve=>entered=resolve);
    f.modelIntercept(async path=>{if(path==='/extract/result'){entered();await blocked;}return null;});
    const running=f.alarm();await waiting;
    const mutation_id=crypto.randomUUID();assert.equal((await f.invoke('revoke',{mutation_id})).body.phase,'revoked');
    release();await running;f.restart();await f.alarm();
    assert.equal((await f.invoke('revoke',{mutation_id})).body.phase,'revoked');
    assert.equal(f.cloud.sqlite.prepare('SELECT count(*) n FROM recording_memory_sources WHERE deleted=0').get().n,0);
    assert.equal((await f.invoke('piece',{piece:await f.piece(1)})).status,409);
  }finally{f.cloud.close();}
});
test('tail closure arriving before a missing middle piece stays partial, then resumes one semantic event',async()=>{
  const f=fixture();try {
    await f.claim();await f.invoke('capture',{capture:f.captureFacts({closed:true,finish:true,frames:240000,ended_at:start+15000})});
    await f.invoke('piece',{piece:await f.piece(0)});await f.invoke('piece',{piece:await f.piece(2)});
    for(let i=0;i<5;i++)await f.alarm();
    assert.equal((await f.invoke('status')).body.memory.partial,true);
    await f.invoke('piece',{piece:await f.piece(1)});for(let i=0;i<6;i++)await f.alarm();
    const status=(await f.invoke('status')).body;assert(status.jobs.every(job=>job.state==='done'));assert.equal(status.memory.partial,false);
    const head=await f.storage.get('head'),source=await new RecordingCoordinator({storage:f.storage},{AUDIO:f.bucket},()=>{},async()=>f.runtime).source(head);
    assert.equal(f.runtime.projectedEvents(source).length,1);assert.equal(f.runtime.projectedEvents(source)[0].lineIds.length,3);
  }finally{f.cloud.close();}
});
test('claim survives a lost ownership receipt and adopts a confirmed v5 tombstone without resurrection',async()=>{
  const f=fixture();try {
    const snapshot=f.snapshot();snapshot.memory=[{id:'old/marker',recordingId:recording,jobId:'old',acknowledged:0,
      record:{id:'apt_recording_'+crypto.randomUUID(),revision:5,created:'2026-10-15T00:00:00.000Z',updated:'2026-10-15T01:00:00.000Z',title:'已移出记忆',text:'',partial:true,deleted:true}}];
    let lost=false;f.intercept(async(request,send)=>{const response=await send();if(!lost&&new URL(request.url).pathname==='/recording-memory/producer/claim'){lost=true;throw Error('lost claim');}return response;});
    assert.equal((await f.claim(snapshot)).status,400);f.restart();await f.alarm();
    assert.equal((await f.invoke('status')).body.phase,'active');
    assert.equal(f.cloud.sqlite.prepare('SELECT deleted FROM recording_memory_sources').get().deleted,1);
    assert.equal(f.calls.length,0);
  }finally{f.cloud.close();}
});
test('a whole 150-row transcript publishes atomically instead of advertising a complete 100-row prefix',async()=>{
  const f=fixture();try {
    const s=f.snapshot();s.matter.endedAt=start+600000;s.matter.captureComplete=true;
    const id='root:'+capture+':0',segment={id,matterId:recording,index:0,capturedAt:start,durationSec:600,sizeBytes:19200044,cloudEligible:true,stage:'recorded',attempts:0};
    const lines=f.runtime.parseASR({state:'done',result:[{utterances:Array.from({length:1200},(_,i)=>({text:'public '+i,start_time:i*400,end_time:i*400+200}))}]},segment,s.matter,600);
    s.segments=[segment];s.jobs=[{id,recordingId:recording,index:0,state:'done',lines,requestLines:f.runtime.freezeLines(lines),lineRevision:1,requestRevision:1,
      uploaded:true,remoteKey:'public-existing-audio',seconds:600,session:'stepx_'+client+'_'+recording,events:[],nextAt:0,attempts:0}];
    assert.equal((await f.claim(s)).status,200);await f.alarm();
    assert.equal(f.cloud.sqlite.prepare('SELECT count(*) n FROM recording_memory_sources WHERE deleted=0').get().n,150);
    assert.equal((await f.invoke('status')).body.memory.pending,0);
  }finally{f.cloud.close();}
});
test('privacy changes, excluded pieces and retiming replace the actual processing source before republishing',async()=>{
  for(const mode of ['private','remove','retime','unverified']) {
    const f=fixture();try {
      await f.claim();await f.invoke('piece',{piece:await f.piece()});await f.alarm();await f.alarm();
      const head=await f.storage.get('head'),s=plain(await new RecordingCoordinator({storage:f.storage},{AUDIO:f.bucket},()=>{},async()=>f.runtime).source(head));
      const snapshot={matter:s.matters[0],segments:s.segments,jobs:s.jobs,memory:[]};
      if(mode==='private')snapshot.segments[0].cloudEligible=false;
      if(mode==='remove'){snapshot.segments=[];snapshot.jobs=[];}
      if(mode==='retime'){snapshot.segments[0].capturedAt+=86400000;snapshot.jobs[0].lines=undefined;}
      if(mode==='unverified')snapshot.matter.recordingTimeUnverified=true;
      assert.equal((await f.invoke('control',{state:'active',control_version:1,mutation_id:crypto.randomUUID(),snapshot,
        ...(mode==='remove'?{removed_ids:s.segments.map(row=>row.id)}:{})})).status,200);
      await f.alarm();await f.alarm();
      if(mode==='retime') {
        const job=await new RecordingCoordinator({storage:f.storage},{AUDIO:f.bucket},()=>{},async()=>f.runtime).unblob((await f.storage.list({prefix:'job:'})).values().next().value.ref);
        assert.equal(job.lines[0].t_sec,86400);
      }else assert.equal(f.cloud.sqlite.prepare('SELECT count(*) n FROM recording_memory_sources WHERE deleted=0').get().n,0,mode);
      if(mode==='remove') {
        assert.equal((await f.invoke('piece',{piece:await f.piece()})).status,200);await f.alarm();
        assert.equal(f.cloud.sqlite.prepare('SELECT count(*) n FROM recording_memory_sources WHERE deleted=0').get().n,0);
      }
    }finally{f.cloud.close();}
  }
});
test('excluding a private predecessor starts a fresh semantic root and never borrows its summary',async()=>{
  const f=fixture();try {
    await f.claim();await f.invoke('piece',{piece:await f.piece(0)});await f.invoke('piece',{piece:await f.piece(1)});
    for(let i=0;i<4;i++)await f.alarm();
    const head=await f.storage.get('head'),s=plain(await new RecordingCoordinator({storage:f.storage},{AUDIO:f.bucket},()=>{},async()=>f.runtime).source(head));
    s.segments[0].cloudEligible=false;
    assert.equal((await f.invoke('control',{state:'active',control_version:1,mutation_id:crypto.randomUUID(),snapshot:{matter:s.matters[0],segments:s.segments,jobs:s.jobs,memory:[]}})).status,200);
    for(let i=0;i<4;i++)await f.alarm();
    const work=[...(await f.storage.list({prefix:'job:'})).values()],second=await f.bucket.get(work.find(job=>job.index===1).ref.key);
    const job=await second.json();assert.equal(job.state,'done');assert.equal(job.semanticStart,1);assert.equal(job.requestLines[0].stream_context,undefined);
    assert.equal((await f.invoke('status')).body.memory.partial,true);
  }finally{f.cloud.close();}
});
test('pending control and wakeup commit together; malformed controls cannot jam native deletion',async()=>{
  const f=fixture();try {
    await f.claim();await f.alarm();assert.equal(f.storage.alarm,null);
    assert.equal((await f.invoke('control',{state:'paused',control_version:1,mutation_id:crypto.randomUUID(),snapshot:f.snapshot()})).status,400);
    assert.equal((await f.storage.get('head')).phase,'active');
    const transaction=f.storage.transaction.bind(f.storage);let lost=false;
    f.storage.transaction=async fn=>{const result=await transaction(fn);if(!lost&&(await f.storage.get('head'))?.phase==='controlling'){lost=true;throw Error('committed response lost');}return result;};
    await f.invoke('control',{state:'active',control_version:1,mutation_id:crypto.randomUUID(),snapshot:f.snapshot()});
    assert.equal((await f.storage.get('head')).phase,'controlling');assert(f.storage.alarm);
    f.restart();await f.alarm();assert.equal((await f.storage.get('head')).phase,'active');
    assert.equal((await f.invoke('revoke',{mutation_id:crypto.randomUUID()})).body.phase,'revoked');
  }finally{f.cloud.close();}
});
