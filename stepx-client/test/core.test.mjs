import { test } from 'node:test';
import assert from 'node:assert/strict';
import { StepXSubmissions } from '../../stepx-worker/src/index.js';
import fs from 'node:fs';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';
import { wavDuration } from '../../stepx-worker/src/index.js';
const root=new URL('../src/growth/',import.meta.url);
function load(files, extra={}) {
  const ctx={crypto,Blob,Uint8Array,ArrayBuffer,Float32Array,DataView,TextEncoder,structuredClone,console,
    useSyncExternalStore:()=>{},setInterval:()=>1,clearInterval:()=>{},...extra};vm.createContext(ctx);
  for(const [file,names] of files) {
    const source=fs.readFileSync(new URL(file,root),'utf8').replace(/^import .*\n/gm,'').replace(/export /g,'');
    vm.runInContext('(function(){'+stripTypeScriptTypes(source,{mode:'transform'})+'\n'+names.map(n=>`globalThis.${n}=${n};`).join('\n')+'})()',ctx,{filename:file});
  }
  return ctx;
}
const data=()=>{const c=load([['processing-data.ts',['parseASR','parseEvents','freezeLines','combinedEvents','SEMANTIC_RECIPE']]]);const original=c.parseASR;c.parseASR=(receipt,segment,recording,seconds=5)=>original(receipt,segment,recording,seconds);return c;};
const utterance=(text,start=0,end=1000)=>({text,start_time:start,end_time:end,speaker:{id:'speaker_0'}});
const recording={id:'rec-1',startedAt:1000000,endedAt:null,origin:'record'};
const segment=(index)=>({id:'piece-'+index,matterId:recording.id,index,capturedAt:recording.startedAt+index*5000,durationSec:5});

test('canonical WAV encodes actual PCM, correct size and saturation',()=>{
  const c=load([['audio.ts',['encodeWav']]]);
  const samples=new Float32Array(16000);samples[0]=2;samples[1]=-2;
  const bytes=c.encodeWav(samples,16000);assert.equal(wavDuration(bytes),1);
  const view=new DataView(bytes.buffer);assert.equal(view.getInt16(44,true),32767);assert.equal(view.getInt16(46,true),-32768);
  assert.throws(()=>c.encodeWav(new Float32Array([NaN]),16000));assert.throws(()=>c.encodeWav(samples,44100));
});
test('actual public WAV/AAC ASR replies remain readable with the original source frame limit',()=>{
 const c=data(),sample=JSON.parse(fs.readFileSync(new URL('./fixtures/aac-asr.json',import.meta.url),'utf8'));
 const texts=sample.cases.map(row=>{
  const lines=c.parseASR({state:'done',result:row.result},segment(0),recording,sample.sourceSeconds);
  assert.equal(lines.length,1);assert.ok(lines[0].t_end_sec<=sample.sourceSeconds);
  return lines.map(line=>line.text).join('');
 });assert.equal(texts[0],texts[1]);
});
test('native AAC bytes keep their own content key and never expand through the WAV converter',async()=>{
 const t=processor({count:1,empty:true}),capture='00000000-0000-4000-8000-000000000001',id=`root:${capture}:0`;
 const client='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
 t.pieces[0]={...t.pieces[0],id,durationSec:1,rootAudioFormat:'m4a',rootUpload:{captureId:capture,piece:0,sha256:'a'.repeat(64),client}};
 t.deps.toWav=async()=>{throw Error('AAC must not inflate');};
 t.deps.nativeUpload=async()=>({captureId:capture,piece:0,matterId:recording.id,sha256:'a'.repeat(64),frames:16000,key:t.rows.get(id).remoteKey,durationSec:1,state:'uploaded'});
 await t.runner.init();t.setReady(true);await t.runner.kick();
 assert.equal(t.rows.get(id).state,'done');assert.ok(t.rows.get(id).remoteKey.endsWith('.m4a'));
 assert.equal(t.calls.some(call=>call.path.startsWith('/upload')),false);
});
test('actual two-voice noisy ASR retains both speakers, alternating ownership, digits and source time',()=>{
 const c=data(),sample=JSON.parse(fs.readFileSync(new URL('./fixtures/aac-asr-dual.json',import.meta.url),'utf8'));
 const rows=sample.cases.map(row=>c.parseASR({state:'done',result:row.result},segment(0),recording,sample.sourceSeconds));
 for(const lines of rows) {
  assert.equal(lines.length,4);assert.equal(new Set(lines.map(line=>line.cluster_tag)).size,2);
  assert.equal(lines[0].cluster_tag,lines[2].cluster_tag);assert.equal(lines[1].cluster_tag,lines[3].cluster_tag);
  assert.notEqual(lines[0].cluster_tag,lines[1].cluster_tag);
  assert.ok(lines.every(line=>line.t_sec>=0&&line.t_end_sec<=sample.sourceSeconds));
 }
 const normalized=lines=>lines.map(line=>line.text).join('').replace(/\s/g,'');
 assert.equal(normalized(rows[0]),normalized(rows[1]));assert.match(normalized(rows[1]),/3600/);
});
test('ASR parses all blocks; empty terminal valid; malformed timing is never silence',()=>{
  const c=data();const lines=c.parseASR({state:'done',result:[{utterances:[utterance('first')]},{utterances:[utterance('second',1000,2000)]}]},segment(1),recording);
  assert.equal(lines.length,2);assert.equal(lines[0].line_id,100001);assert.equal(lines[0].t_sec,5);assert.equal(lines[1].t_end_sec,7);
  for(const result of [[],[{}],[{utterances:[]}]])assert.equal(c.parseASR({state:'done',result},segment(0),recording).length,0);
  for(const result of [[{utterances:[utterance('bad',1000,0)]}],[{raw:'unrecognized'}],[{utterances:[{text:'missing time'}]}]])assert.throws(()=>c.parseASR({state:'done',result},segment(0),recording));
});
test('semantic continuation is only accepted from frozen previous event and valid line evidence',()=>{
  const c=data(),lines=c.parseASR({state:'done',result:[{utterances:[utterance('source')]}]},segment(1),recording);
  const prev={event_id:1,title:'Original event',latest_title:'Current',summary:'Prior',tail:'Actual words',t_end_sec:1};
  const frozen=c.freezeLines(lines,prev);prev.title='changed';assert.equal(frozen[0].stream_context.title,'Original event');
  const job={recordingId:recording.id,requestLines:frozen};
  const payload={pipeline_version:'v3-semantic-continuity',events:[{title:'Continued',summary:'Real product',line_from:100001,line_to:100001,continuation_id:1}]};
  const events=c.parseEvents(payload,job,recording.startedAt);assert.equal(events[0].id,'rec-1:1');assert.equal(events[0].title,'Original event');
  assert.throws(()=>c.parseEvents({...payload,events:[{...payload.events[0],continuation_id:9}]},job,recording.startedAt));
  assert.throws(()=>c.parseEvents({...payload,events:[{...payload.events[0],line_to:999999}]},job,recording.startedAt));
  assert.throws(()=>c.parseEvents({...payload,pipeline_version:'old'},job,recording.startedAt));
});
function processor({count=2,empty=false,unknown=false,saveFailAfterSubmit=false}={}) {
  const rows=new Map(),calls=[],pieces=Array.from({length:count},(_,i)=>segment(i)), tickets=new Map();
  let ready=false,owner=null,failSave=false,sourceExists=true;
  class Failure extends Error { constructor(code){super(code);this.code=code;} }
  const connection={subscribe:()=>()=>{},isReady:()=>ready,getSnapshot:()=>({health:{asrConfigured:true,extractionQueueConfigured:true,semanticRecipe:'v3-semantic-continuity'}}),
    async request(path,body){ calls.push({path,body:structuredClone(body)});
      if(path.startsWith('/upload'))return {key:decodeURIComponent(path.split('key=')[1]),durationSec:1};
      if(path==='/asr/submit'){if(unknown)throw new Failure('asr_submission_unknown');if(saveFailAfterSubmit)failSave=true;return{task_id:'task-'+calls.length};}
      if(path==='/asr/query')return {state:'done',result:empty?[]:[{utterances:[utterance('public fixture')]}]};
      if(path==='/extract/enqueue'){const ticket=body.session+'-'+body.part+'-'+'a'.repeat(16);tickets.set(ticket,structuredClone(body));return{state:'queued',ticket};}
      if(path==='/extract/result'){const req=tickets.get(body.ticket),line=req.lines[0];return{state:'done',payload:{pipeline_version:'v3-semantic-continuity',...(line.action_protocol?{action_protocol:'personal-actions/v1',personal_actions:[]}:{}),events:[{title:'Test event',summary:'Validated fixture',line_from:line.line_id,line_to:line.line_id,...(line.stream_context?{continuation_id:line.stream_context.event_id}:{})}]}};}
      throw Error('unexpected');
    }};
  const store={subscribe:()=>()=>{},getSnapshot:()=>({ready:true,storageOk:true,segments:pieces}),getMatter:id=>sourceExists&&id===recording.id?recording:undefined,getAudio:async()=>new Blob(['synthetic source'])};
  const lease=async(actor,action,job)=>{if(failSave&&action==='put')throw Error('quota');if(action==='claim'){if(owner&&owner!==actor)return false;owner=actor;return true;}if(action==='release'){if(owner===actor)owner=null;return true;}if(owner!==actor)return false;if(action==='put')rows.set(job.id,structuredClone(job));return true;};
  const deps={connection,store,clientId:()=> 'fixture-client',read:async()=>[...rows.values()].map(row=>structuredClone(row)),lease,
    toWav:async()=>new Uint8Array(32044),hash:async()=> 'a'.repeat(64)};
  const ctx=load([['processing-data.ts',['parseASR','parseEvents','freezeLines','combinedEvents','SEMANTIC_RECIPE','retryProcessingJob']],['source-scope.ts',['projectedEvents','previousContext','fragmentMaterial','lineStamp']],['quote-normalize.ts',['normalizeQuote','isVerbatim']],['personal-action-data.ts',['ACTION_PROTOCOL','parsePersonalActions']],['processing.ts',['GrowthProcessing']]],{
    growthConnection:connection,growthStore:store,getClientId:deps.clientId,STORE_PROCESSING:'processing',idbGetAll:deps.read,processingLease:lease,toWav:deps.toWav,sha256:deps.hash,CloudFailure:Failure});
  return {runner:new ctx.GrowthProcessing(deps),fresh:()=>new ctx.GrowthProcessing(deps),rows,calls,setReady:v=>ready=v,
    pieces,deps,deleteSource:()=>{sourceExists=false;pieces.length=0;},markLocalOnly:()=>pieces.forEach(piece=>piece.cloudEligible=false),getAudio:fn=>store.getAudio=fn,clearDelay:()=>{for(const row of rows.values())row.nextAt=0;},loseLease:()=>owner='another-tab',failSave:v=>failSave=v,cloudFailure:code=>new Failure(code),connection};
}
test('native-owned audio waits without a second upload, then resumes ASR from its exact durable server receipt',async()=>{
  const t=processor({count:1,empty:true}),capture='00000000-0000-4000-8000-000000000001',id=`root:${capture}:0`;
  const client='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  t.pieces[0]={...t.pieces[0],id,durationSec:1,rootUpload:{captureId:capture,piece:0,sha256:'a'.repeat(64),client}};
  let native; t.deps.nativeUpload=async()=>native;
  await t.runner.init();t.setReady(true);await t.runner.kick();
  assert.equal(t.calls.length,0);assert.equal(t.rows.get(id).state,'pending');assert.equal(t.rows.get(id).attempts,0);
  const job=t.rows.get(id);native={captureId:capture,piece:0,matterId:recording.id,sha256:'a'.repeat(64),frames:16000,key:job.remoteKey,durationSec:1,state:'uploaded'};
  t.clearDelay();await t.runner.kick();assert.equal(t.rows.get(id).uploaded,true);assert.equal(t.rows.get(id).state,'done');
  assert.equal(t.calls.filter(row=>row.path.startsWith('/upload')).length,0);assert.equal(t.calls.filter(row=>row.path==='/asr/submit').length,1);
  await t.fresh().init();assert.equal(t.calls.filter(row=>row.path==='/asr/submit').length,1);
});
test('native receipt mismatches and a source deleted during polling cannot authorize ASR or another upload',async()=>{
  for(const deleted of [false,true]) {
    const t=processor({count:1}),capture='00000000-0000-4000-8000-000000000001',id=`root:${capture}:0`;
    t.pieces[0]={...t.pieces[0],id,durationSec:1,rootUpload:{captureId:capture,piece:0,sha256:'a'.repeat(64),client:'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'}};
    t.deps.nativeUpload=async()=>{if(deleted)t.deleteSource();return{captureId:capture,piece:0,matterId:recording.id,sha256:'a'.repeat(64),frames:16000,key:'wrong-object',durationSec:1,state:'uploaded'}};
    await t.runner.init();t.setReady(true);await t.runner.kick();assert.equal(t.calls.length,0);
    if(!deleted)assert.equal(t.rows.get(id).uploaded,undefined);
  }
});
test('native tail frames are checked from canonical bytes, including a nonexact duration round trip',async()=>{
 for(const frames of [512512,9600000]) {
  const t=processor({count:1,empty:true}),capture='00000000-0000-4000-8000-000000000001',id=`root:${capture}:0`;
  t.pieces[0]={...t.pieces[0],id,durationSec:frames/16000,rootUpload:{captureId:capture,piece:0,sha256:'a'.repeat(64),client:'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'}};
  t.deps.toWav=async()=>new Uint8Array(frames*2+44);
  t.deps.nativeUpload=async()=>({captureId:capture,piece:0,matterId:recording.id,sha256:'a'.repeat(64),frames,key:t.rows.get(id).remoteKey,durationSec:frames/16000,state:'uploaded'});
  await t.runner.init();t.setReady(true);await t.runner.kick();assert.equal(t.rows.get(id).state,'done');
  assert.equal(t.calls.some(row=>row.path.startsWith('/upload')),false);
 }
});
test('real pipeline order freezes previous event and related pieces show one semantic root',async()=>{
  const t=processor();await t.runner.init();t.setReady(true);await t.runner.kick();
  assert.equal(t.rows.get('piece-0').state,'done');assert.equal(t.rows.get('piece-1').state,'done');
  const enqueue=t.calls.filter(c=>c.path==='/extract/enqueue');assert.equal(enqueue.length,2);assert.equal(enqueue[0].body.lines[0].action_protocol,'personal-actions/v1');assert.equal(enqueue[0].body.lines[0].source_revision,1);assert.ok(enqueue[0].body.lines[0].action_request);assert.equal(t.rows.get('piece-0').personalEvaluation.state,'done');assert.equal(enqueue[0].body.lines[0].recipe,'v3-semantic-continuity');assert.equal(enqueue[1].body.lines[0].stream_context.event_id,1);
  assert.equal(t.runner.getSnapshot().events.length,1);assert.equal(t.runner.getSnapshot().events[0].lineIds.length,2);
  const paid=t.calls.filter(c=>c.path==='/asr/submit').length;await t.runner.kick();assert.equal(t.calls.filter(c=>c.path==='/asr/submit').length,paid);
});
test('empty transcription completes with preserved upload and no semantic/model request',async()=>{
  const t=processor({count:1,empty:true});await t.runner.init();t.setReady(true);await t.runner.kick();
  assert.equal(t.rows.get('piece-0').state,'done');assert.equal(t.rows.get('piece-0').uploaded,true);assert.equal(t.runner.getSnapshot().events.length,0);assert.equal(t.calls.some(c=>c.path==='/extract/enqueue'),false);
});
test('unknown paid submit remains waiting with stable key, not a terminal empty result',async()=>{
  const t=processor({count:1,unknown:true});await t.runner.init();t.setReady(true);await t.runner.kick();
  const row=t.rows.get('piece-0');assert.equal(row.state,'transcribing');assert.equal(row.uploaded,true);assert.ok(row.nextAt>Date.now());assert.equal(row.taskId,undefined);assert.equal(t.runner.getSnapshot().events.length,0);
});
test('expired unknown ASR becomes actionable and manual retry reuses audio without retaining paid consent',async()=>{
  const t=processor({count:1});await t.runner.init();
  const original=t.connection.request;let submit=0;
  t.connection.request=async(path,body)=>{
    if(path==='/asr/submit') {
      t.calls.push({path,body:structuredClone(body)});submit++;
      // Use the same CloudFailure class injected by the fixture.
      const error=t.cloudFailure(submit===1?'asr_submission_expired':'asr_submission_unknown');
      throw error;
    }
    return original(path,body);
  };
  t.setReady(true);await t.runner.kick();
  const before=t.rows.get('piece-0');assert.equal(before.state,'failed');assert.equal(before.failureCode,'asr_submission_expired');
  await t.runner.retryRecording(recording.id);
  const sent=t.calls.filter(call=>call.path==='/asr/submit');
  assert.equal(sent.length,2);assert.equal(sent[1].body.retryFailed,true);assert.equal(sent[1].body.key,sent[0].body.key);
  assert.match(sent[1].body.retryId,/^[0-9a-f-]{36}$/);
  assert.equal(t.rows.get('piece-0').state,'transcribing');assert.equal(t.rows.get('piece-0').retryFailed,false);
  t.clearDelay();await t.runner.kick();assert.equal(t.calls.filter(call=>call.path==='/asr/submit').at(-1).body.retryFailed,undefined);
  assert.equal(t.calls.filter(call=>call.path.startsWith('/upload')).length,1);
});
test('restoring a legacy pending retry never mints a paid authorization',async()=>{
  const t=processor({count:1,unknown:true});await t.runner.init();t.setReady(true);await t.runner.kick();
  const legacy=t.rows.get('piece-0');legacy.retryFailed=true;delete legacy.retryId;
  t.setReady(false);const restarted=t.fresh();await restarted.init();t.clearDelay();t.setReady(true);await restarted.kick();
  const submitted=t.calls.filter(call=>call.path==='/asr/submit').at(-1).body;
  assert.equal(submitted.retryFailed,undefined);assert.equal(submitted.retryId,undefined);
  assert.equal(t.rows.get('piece-0').retryFailed,false);
});
test('only another manual click creates a new authorization after consumed consent fails',async()=>{
  const t=processor({count:1});await t.runner.init();const original=t.connection.request;
  t.connection.request=async(path,body)=>{
    if(path==='/asr/submit'){t.calls.push({path,body:structuredClone(body)});throw t.cloudFailure('asr_retry_authorization_required');}
    return original(path,body);
  };
  t.setReady(true);await t.runner.kick();
  await t.runner.retryRecording(recording.id);
  const first=t.calls.filter(call=>call.path==='/asr/submit').at(-1).body.retryId;assert.ok(first);
  await t.runner.kick();assert.equal(t.calls.filter(call=>call.path==='/asr/submit').length,2);
  await t.runner.retryRecording(recording.id);
  const second=t.calls.filter(call=>call.path==='/asr/submit').at(-1).body.retryId;
  assert.ok(second);assert.notEqual(second,first);
});
test('manual recovery after a server receipt write failure replaces the consumed authorization',async()=>{
  const t=processor({count:1});await t.runner.init();const original=t.connection.request;
  t.connection.request=async(path,body)=>{
    if(path==='/asr/submit'){t.calls.push({path,body:structuredClone(body)});throw t.cloudFailure('submission_unavailable');}
    return original(path,body);
  };
  t.setReady(true);await t.runner.kick();await t.runner.retryRecording(recording.id);
  const first=t.calls.filter(call=>call.path==='/asr/submit').at(-1).body.retryId;assert.ok(first);
  await t.runner.retryRecording(recording.id);
  const second=t.calls.filter(call=>call.path==='/asr/submit').at(-1).body.retryId;
  assert.ok(second);assert.notEqual(second,first);
});
test('terminal ASR retry creates a new task but an ordinary query outage keeps the existing task',async()=>{
  for(const code of ['asr_failed','processing_failed']) {
    const t=processor({count:1,empty:true});await t.runner.init();const original=t.connection.request;
    let broken=true;
    t.connection.request=async(path,body)=>{
      if(path==='/asr/query' && broken)throw t.cloudFailure(code);
      return original(path,body);
    };
    t.setReady(true);await t.runner.kick();
    const first=structuredClone(t.rows.get('piece-0'));assert.equal(first.state,'failed');assert.ok(first.taskId);
    broken=false;await t.runner.retryRecording(recording.id);
    assert.equal(t.rows.get('piece-0').state,'done');
    const submits=t.calls.filter(call=>call.path==='/asr/submit');
    assert.equal(submits.length,code==='asr_failed'?2:1);
    if(code==='asr_failed') { assert.equal(submits[1].body.retryFailed,true);assert.equal(submits[1].body.key,submits[0].body.key);assert.notEqual(t.rows.get('piece-0').taskId,first.taskId); }
    else assert.equal(t.rows.get('piece-0').taskId,first.taskId);
    assert.equal(t.calls.filter(call=>call.path.startsWith('/upload')).length,1);
  }
});
test('failed local receipt write and restart after server expiry cannot repeat a paid retry',async()=>{
  const t=processor({count:1});await t.runner.init();const original=t.connection.request;
  const receiptRows=new Map([['receipt',{submittedAt:Date.now()-7*3600000,state:'unknown',supersedes:null}]]);
  const storage={get:async key=>structuredClone(receiptRows.get(key)),put:async(key,value)=>receiptRows.set(key,structuredClone(value))};
  const env={AUDIO:{head:async()=>({size:32044}),get:async()=>null},GROWTH_CLIENT_TOKEN:'synthetic-only'};
  let paid=0,failLocal=false;
  const fetcher=async()=>{paid++;throw Error('accepted but upstream receipt was lost');};
  let actor=new StepXSubmissions({storage},env,fetcher);
  t.connection.request=async(path,body)=>{
    if(path!=='/asr/submit')return original(path,body);
    const response=await actor.fetch(new Request('https://submission.internal/submit',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)}));
    const result=await response.json();
    if(failLocal)t.failSave(true);
    if(!response.ok)throw t.cloudFailure(result.reason==='asr_submission_expired'?'asr_submission_expired':result.error);
    return result;
  };
  t.setReady(true);await t.runner.kick();assert.equal(t.rows.get('piece-0').failureCode,'asr_submission_expired');
  failLocal=true;await t.runner.retryRecording(recording.id);
  assert.equal(paid,1);assert.equal(t.rows.get('piece-0').retryFailed,false);
  assert.match(t.runner.getSnapshot().error,/回执未保存/);
  t.failSave(false);failLocal=false;receiptRows.get('receipt').submittedAt=Date.now()-7*3600000;
  actor=new StepXSubmissions({storage},env,fetcher);
  t.setReady(false);const restarted=t.fresh();await restarted.init();t.setReady(true);t.clearDelay();await restarted.kick();
  assert.equal(paid,1,'重启不能继承已用过的一次付费授权');
  assert.equal(t.rows.get('piece-0').state,'failed');assert.equal(t.rows.get('piece-0').failureCode,'asr_submission_expired');
});
test('receipt storage failure stops work; restart resumes same immutable ASR submission key',async()=>{
  const t=processor({count:1,saveFailAfterSubmit:true});await t.runner.init();t.setReady(true);await t.runner.kick();
  assert.match(t.runner.getSnapshot().error,/回执未保存/);assert.equal(t.calls.some(c=>c.path==='/extract/enqueue'),false);const key=t.rows.get('piece-0').remoteKey;
  t.failSave(false);t.connection.request=async(path,body)=>{t.calls.push({path,body});if(path==='/asr/submit')return{task_id:'recovered'};if(path==='/asr/query')return{state:'done',result:[]};throw Error('unexpected');};
  t.setReady(false);const next=t.fresh();await next.init();t.setReady(true);t.clearDelay();await next.kick();assert.equal(t.rows.get('piece-0').state,'done');assert.equal(t.calls.filter(c=>c.path==='/asr/submit').at(-1).body.key,key);
});
test('an ASR callback after lease takeover cannot commit or start semantic work',async()=>{
  const t=processor({count:1});await t.runner.init();
  const original=t.connection.request;t.connection.request=async(path,body)=>{const result=await original(path,body);if(path==='/asr/query')t.loseLease();return result;};
  t.setReady(true);await t.runner.kick();assert.equal(t.rows.get('piece-0').taskId!==undefined,true);
  assert.equal(t.rows.get('piece-0').lines,undefined);assert.equal(t.calls.some(c=>c.path==='/extract/enqueue'),false);assert.equal(t.runner.getSnapshot().events.length,0);
});

test('empty first ASR container cannot hide a second container or unsupported text',()=>{
  const c=data();assert.equal(c.parseASR({state:'done',result:[{utterances:[],sentences:[utterance('must survive')]}]},segment(0),recording).length,1);
  assert.throws(()=>c.parseASR({state:'done',result:[{utterances:[],text:'not silence'}]},segment(0),recording));
});
test('only the first ordered event may continue the supplied previous event',()=>{
  const c=data(),lines=c.parseASR({state:'done',result:[{utterances:[utterance('a'),utterance('b',1000,2000)]}]},segment(1),recording);
  const frozen=c.freezeLines(lines,{event_id:1,title:'prior',latest_title:'prior',summary:'prior',tail:'prior',t_end_sec:1});
  const one={title:'new',summary:'valid',line_from:100001,line_to:100001},two={title:'continued',summary:'valid',line_from:100002,line_to:100002,continuation_id:1};
  assert.throws(()=>c.parseEvents({pipeline_version:'v3-semantic-continuity',events:[one,two]},{recordingId:'rec-1',requestLines:frozen},recording.startedAt));
  assert.throws(()=>c.parseEvents({pipeline_version:'v3-semantic-continuity',events:[{...one,summary:' '}]},{recordingId:'rec-1',requestLines:frozen},recording.startedAt));
});
test('deleted source cannot be revived by an in-flight transcription callback',async()=>{
  const t=processor({count:1});await t.runner.init();const original=t.connection.request;
  t.connection.request=async(path,body)=>{const result=await original(path,body);if(path==='/asr/query')t.deleteSource();return result;};
  t.setReady(true);await t.runner.kick();assert.equal(t.rows.get('piece-0').lines,undefined);assert.equal(t.calls.some(c=>c.path==='/extract/enqueue'),false);
});
test('explicit retry of an invalid semantic product uses a new queue identity and the same frozen evidence',async()=>{
  const t=processor({count:1});await t.runner.init();const original=t.connection.request;let invalid=true;
  t.connection.request=async(path,body)=>{const result=await original(path,body);if(path==='/extract/result'&&invalid)result.payload.events[0].line_to=999;return result;};
  t.setReady(true);await t.runner.kick();assert.equal(t.rows.get('piece-0').state,'failed');assert.equal(t.rows.get('piece-0').failureCode,'invalid_result');
  invalid=false;await t.runner.retryRecording(recording.id);assert.equal(t.rows.get('piece-0').state,'done');
  const queued=t.calls.filter(c=>c.path==='/extract/enqueue');assert.equal(queued.length,2);assert.notEqual(queued[0].body.part,queued[1].body.part);assert.deepEqual(queued[0].body.lines,queued[1].body.lines);
});

test('nested ASR containers survive and error/text-only products never freeze empty',()=>{
  const c=data();assert.equal(c.parseASR({state:'done',result:[{utterances:[],data:{sentences:[utterance('nested source')]}}]},segment(0),recording).length,1);
  for(const block of [{utterances:[],error:'failed'},{utterances:[],transcript:'speech'},{utterances:[],data:{transcription:'speech'}}])assert.throws(()=>c.parseASR({state:'done',result:[block]},segment(0),recording));
});
test('transcript evidence is constrained to actual WAV duration with a bounded tail tolerance',()=>{
  const c=data();assert.throws(()=>c.parseASR({state:'done',result:[{utterances:[utterance('outside source',10000,11000)]}]},segment(0),recording,1));
  const lines=c.parseASR({state:'done',result:[{utterances:[utterance('tail',0,1200)]}]},segment(0),recording,1);assert.equal(lines[0].t_end_sec,1);
});
test('real vendor padded utterance is recovered only by complete bounded word alignment',()=>{
  const c=data(),row={text:'public test',start_time:13,end_time:15992,words:[{text:'public ',end_time:500},{text:'test',start_time:500,end_time:1000}]};
  const result=c.parseASR({state:'done',result:[{utterances:[row]}]},segment(0),recording,1);assert.equal(result[0].t_end_sec,1);
  assert.throws(()=>c.parseASR({state:'done',result:[{utterances:[{...row,words:[{text:'public ',end_time:500}]}]}]},segment(0),recording,1));
  assert.throws(()=>c.parseASR({state:'done',result:[{utterances:[{...row,words:[{text:'public test',end_time:11000}]}]}]},segment(0),recording,1));
});
test('malformed containers and failed empty utterances never become valid silence',()=>{
  const c=data();for(const block of [{utterances:[],sentences:'unsupported speech'},{utterances:[{text:'',error:'failed'}]}])assert.throws(()=>c.parseASR({state:'done',result:[block]},segment(0),recording));
});


test('local-only recovered audio cannot create or advance cloud jobs, including an existing receipt',async()=>{
  for(const existing of [false,true]){
    const t=processor({count:1});t.markLocalOnly();
    if(existing)t.rows.set('piece-0',{id:'piece-0',recordingId:recording.id,index:0,state:'pending',nextAt:0,attempts:0});
    await t.runner.init();t.setReady(true);await t.runner.kick();assert.equal(t.calls.length,0);assert.equal(t.rows.size,existing?1:0);
  }
});
test('local recovery during an in-flight audio read blocks the next upload and paid request',async()=>{
  const t=processor({count:1});await t.runner.init();let release,entered;const started=new Promise(resolve=>entered=resolve);
  t.getAudio(async()=>{entered();await new Promise(resolve=>release=resolve);return new Blob(['recovered local fixture']);});
  t.setReady(true);const running=t.runner.kick();await started;t.markLocalOnly();release();await running;assert.equal(t.calls.length,0);
  assert.equal(t.rows.get('piece-0').uploaded,undefined);
});
