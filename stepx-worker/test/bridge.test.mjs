import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createBridge as bridgeFactory, StepXSubmissions, wavDuration, STREAM_RECIPE } from '../src/index.js';

function createBridge(fetcher) {
  const bridge = bridgeFactory(fetcher), objects = new Map();
  return { fetch(request, env) {
    const bound = { ...env, SUBMISSIONS: {
      idFromName: name => name,
      get(name) {
        if (!objects.has(name)) {
          const rows = new Map();
          objects.set(name, new StepXSubmissions({ storage: {
            get: async key => structuredClone(rows.get(key)),
            put: async (key, value) => { rows.set(key, structuredClone(value)); },
          } }, env, fetcher));
        }
        return objects.get(name);
      },
    } };
    return bridge.fetch(request, bound);
  } };
}
const TOKEN = 'isolated-fake-test-token';
const env = { GROWTH_CLIENT_TOKEN: TOKEN, STEPX_SRC_SHA: 'test-fingerprint', AUDIO: {
  head: async() => ({size: 44 + 32000 * 5}), get: async() => null,
} };
const uuid = '12345678-1234-1234-1234-123456789abc';
const session = `stepx_${uuid}_${uuid}`;
function request(path, body, options = {}) {
  return new Request('https://apt-backend.example/stepx' + path, {
    method: options.method ?? (body === undefined ? 'GET' : 'POST'),
    headers: { 'X-Growth-Token': TOKEN, 'Content-Type': 'application/json', ...options.headers },
    ...(body === undefined ? {} : { body: typeof body === 'object' && !(body instanceof Uint8Array) ? JSON.stringify(body) : body }),
  });
}
function fixture(seconds = 1) {
  const wav = new Uint8Array(44 + seconds * 32000), view = new DataView(wav.buffer);
  const text = (offset, value) => [...value].forEach((c, i) => { wav[offset + i] = c.charCodeAt(0); });
  text(0, 'RIFF'); text(8, 'WAVE'); text(12, 'fmt '); text(36, 'data');
  for (const [offset, value] of [[4, wav.length - 8], [16,16], [24,16000], [28,32000], [40,wav.length - 44]]) view.setUint32(offset,value,true);
  for (const [offset,value] of [[20,1], [22,1], [32,2], [34,16]]) view.setUint16(offset,value,true);
  return wav;
}
const hash = async bytes => [...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(b=>b.toString(16).padStart(2,'0')).join('');

test('all business calls require existing gate; unknown and original routes unavailable', async () => {
  let calls=0; const bridge=createBridge(async()=>{calls++;return Response.json({});});
  for(const path of ['/health','/chat','/upload','/asr/query','/extract/result','/recording-memory/sync']) {
    const response=await bridge.fetch(request(path,undefined,{headers:{'X-Growth-Token':''}}),env);
    assert.equal(response.status,401);
  }
  assert.equal((await bridge.fetch(request('/health'),{})).status,503);
  assert.equal((await bridge.fetch(new Request('https://apt-backend.example/version'),env)).status,404);
  assert.equal((await bridge.fetch(request('/session/purge'),env)).status,404);
  assert.equal(calls,0);
});
test('preflight is harmless and does not open a paid request', async()=>{
  let calls=0; const bridge=createBridge(async()=>{calls++;return Response.json({});});
  const response=await bridge.fetch(request('/chat',undefined,{method:'OPTIONS',headers:{'X-Growth-Token':''}}),env);
  assert.equal(response.status,204); assert.equal(response.headers.get('Access-Control-Allow-Origin'),'*');
  assert.equal(response.headers.has('Access-Control-Allow-Credentials'),false); assert.equal(calls,0);
});
test('health only reports configured flags and safe fingerprint', async()=>{
  const bridge=createBridge(async(url, init)=>{
    assert.equal(url,'https://apt-backend.example/health'); assert.equal(init.headers['X-Growth-Token'],TOKEN);
    assert.equal(init.redirect,'manual'); return Response.json({tokenOK:true,hasLLMKey:true,hasKey:true,hasBucket:true});
  });
  assert.deepEqual(await (await bridge.fetch(request('/health'),env)).json(),{
    ok:true,chatConfigured:true,asrConfigured:true,extractionQueueConfigured:true,semanticRecipe:STREAM_RECIPE,backgroundConfigured:false,source:'test-fingerprint',audioFormats:['wav'],
  });
  const denied=createBridge(async()=>Response.json({tokenOK:false}));
  assert.equal((await denied.fetch(request('/health'),env)).status,502);
});
test('chat fixes scene ask and strips model/usage; empty answers fail', async()=>{
  const bridge=createBridge(async(url,init)=>{
    assert.equal(url,'https://apt-backend.example/extract');
    assert.deepEqual(JSON.parse(init.body),{scene:'ask',messages:[{role:'user',content:'public fixture'}]});
    return Response.json({content:'actual mock reply',model:'existing-router',usage:{}});
  });
  assert.deepEqual(await (await bridge.fetch(request('/chat',{messages:[{role:'user',content:'public fixture'}]}),env)).json(),{text:'actual mock reply'});
  assert.equal((await bridge.fetch(request('/chat',{messages:[],provider:'anything'}),env)).status,400);
  const empty=createBridge(async()=>Response.json({content:' '}));
  assert.equal((await empty.fetch(request('/chat',{messages:[{role:'user',content:'q'}]}),env)).status,400);
});
test('message roles, fields, sizes and content type fail before model call', async()=>{
  let calls=0; const bridge=createBridge(async()=>{calls++;return Response.json({content:'bad'});});
  for(const body of [{messages:[{role:'tool',content:'x'}]},{messages:[{role:'user',content:'x',model:'other'}]},
    {messages:[{role:'user',content:'x'.repeat(32001)}]},{messages:[]},{messages:[null]}]) {
    assert.equal((await bridge.fetch(request('/chat',body),env)).status,400);
  }
  assert.equal((await bridge.fetch(request('/chat','not json'),env)).status,400);
  assert.equal((await bridge.fetch(request('/chat',{messages:[]},{headers:{'Content-Type':'text/plain'}}),env)).status,415);
  assert.equal(calls,0);
});
test('WAV parser rejects renamed AAC, invalid headers, stereo, other rates and wrong sizes',()=>{
  assert.equal(wavDuration(fixture()),1);
  assert.throws(()=>wavDuration(new Uint8Array([1,2,3])));
  for(const [offset,value,size] of [[0,0,4],[22,2,2],[24,44100,4],[34,32,2],[40,999,4]]) {
    const wav=fixture(),view=new DataView(wav.buffer); view[size===2?'setUint16':'setUint32'](offset,value,true);
    assert.throws(()=>wavDuration(wav));
  }
  assert.throws(()=>wavDuration(fixture(0))); assert.throws(()=>wavDuration(fixture(602)));
});
test('upload namespace and content fingerprint preserve original app objects', async()=>{
  const wav=fixture(),audioKey=`stepx/${uuid}/${uuid}/${uuid}-${await hash(wav)}.wav`;
  let calls=0; const bridge=createBridge(async(url,init)=>{calls++;assert.ok(url.includes(encodeURIComponent(audioKey)));assert.equal(init.headers['Content-Type'],'audio/wav');return Response.json({key:audioKey});});
  const response=await bridge.fetch(request('/upload?key='+encodeURIComponent(audioKey),wav),env);
  assert.equal(response.status,200);assert.deepEqual(await response.json(),{key:audioKey,durationSec:1});
  assert.equal((await bridge.fetch(request('/upload?key=native/original.wav',wav),env)).status,400);
  const badKey=audioKey.replace(/[0-9a-f]{64}(?=\.wav$)/,'0'.repeat(64));
  assert.equal((await bridge.fetch(request('/upload?key='+encodeURIComponent(badKey),wav),env)).status,400);
  assert.equal(calls,1);
});
test('ASR and extraction accept only precise StepX requests', async()=>{
  const calls=[];const ticket=session+'-0-'+'a'.repeat(16);
  const bridge=createBridge(async(url,init)=>{
    calls.push({url,body:JSON.parse(init.body)});
    if(url.endsWith('/asr/submit'))return Response.json({task_id:'safe-task'});
    if(url.endsWith('/asr/query'))return Response.json({status:'RUNNING'});
    if(url.endsWith('/extract/enqueue'))return Response.json({state:'queued',ticket});
    return Response.json({state:'running'});
  });
  const audioKey=`stepx/${uuid}/${uuid}/${uuid}-${'a'.repeat(64)}.wav`;
  assert.equal((await bridge.fetch(request('/asr/submit',{key:audioKey,seconds:5.2}),env)).status,200);
  assert.equal(calls[0].body.seconds,5, 'billing duration comes from actual uploaded WAV byte length');
  assert.equal((await bridge.fetch(request('/asr/submit',{key:audioKey,seconds:999}),env)).status,400);
  assert.equal((await bridge.fetch(request('/asr/query',{task_id:'safe-task'}),env)).status,200);
  assert.equal((await bridge.fetch(request('/asr/query',{task_id:'../native'}),env)).status,400);
  assert.equal((await bridge.fetch(request('/extract/enqueue',{session,part:0,lines:[{line_id:1,text:'public fixture',cluster_tag:null,t_sec:0,is_gap:false,recipe:STREAM_RECIPE,streaming:true}]}),env)).status,200);
  assert.equal((await bridge.fetch(request('/extract/enqueue',{session:'native-session',part:0,lines:[]}),env)).status,400);
  assert.equal((await bridge.fetch(request('/extract/result',{ticket:session+'-0-'+'a'.repeat(16)}),env)).status,200);
  assert.equal((await bridge.fetch(request('/extract/result',{ticket:'native-0-123456789abcdef0'}),env)).status,400);
});
test('network failures and upstream provider errors do not expose raw body or credential', async()=>{
  const bridge=createBridge(async()=>new Response('private provider error '+TOKEN,{status:500}));
  const response=await bridge.fetch(request('/chat',{messages:[{role:'user',content:'q'}]}),env);
  assert.equal(response.status,502); assert.equal((await response.text()).includes(TOKEN),false);
  const network=createBridge(async()=>{throw Error('url '+TOKEN);});
  assert.equal((await network.fetch(request('/health'),env)).status,502);
});
test('ASR query preserves confirmed terminal failure while unknown upstream failures remain retryable',async()=>{
  for(const [status,error,expected] of [[502,'asr failed','asr_failed'],[502,'query failed','processing_failed'],[401,'asr failed','processing_failed']]) {
    const bridge=createBridge(async()=>Response.json({error,detail:'private provider body '+TOKEN},{status}));
    const response=await bridge.fetch(request('/asr/query',{task_id:'safe-task'}),env);
    assert.equal(response.status,status);assert.deepEqual(await response.json(),{error:expected});
  }
  let cancelled=false;
  const oversized=new ReadableStream({start(controller){controller.enqueue(new Uint8Array(256*1024+1));},cancel(){cancelled=true;}});
  for(const body of ['not JSON',new Uint8Array([0x7b,0x22,0xff]),oversized]) {
    let queries=0;
    const bridge=createBridge(async(url)=>{assert(url.endsWith('/asr/query'));queries++;return new Response(body,{status:502,headers:{'Content-Type':'application/json'}});});
    const response=await bridge.fetch(request('/asr/query',{task_id:'safe-task'}),env);
    assert.equal(response.status,502);assert.deepEqual(await response.json(),{error:'processing_failed'});assert.equal(queries,1);
  }
  assert.equal(cancelled,true);
});
test('200 failure products and malformed receipts never pass through as successful results', async()=>{
  for(const receipt of [
    {state:'done',body:JSON.stringify({error:'private',raw:TOKEN})},
    {state:'done',body:'not JSON '+TOKEN},
    {state:'done',body:JSON.stringify({events:[],raw:TOKEN})},
    {state:'error',detail:TOKEN},
  ]) {
    const bridge=createBridge(async()=>Response.json(receipt));
    const response=await bridge.fetch(request('/extract/result',{ticket:session+'-0-'+'a'.repeat(16)}),env);
    assert.equal(response.status,502);assert.equal((await response.text()).includes(TOKEN),false);
  }
  const failed=createBridge(async()=>Response.json({task_id:'safe-task',error:TOKEN}));
  assert.equal((await failed.fetch(request('/asr/submit',{key:`stepx/${uuid}/${uuid}/${uuid}-${'a'.repeat(64)}.wav`,seconds:1}),env)).status,409);
  const empty=createBridge(async()=>Response.json({}));
  assert.equal((await empty.fetch(request('/asr/query',{task_id:'safe-task'}),env)).status,502);
});
test('existing semantic pipeline version is mandatory and completed empty events remain a valid result', async()=>{
  let calls=0;const bridge=createBridge(async()=>{calls++;return Response.json({state:'done',body:JSON.stringify({pipeline_version:STREAM_RECIPE,events:[],one_liner:'No semantic events'})});});
  const result=await bridge.fetch(request('/extract/result',{ticket:session+'-0-'+'a'.repeat(16)}),env);
  assert.equal(result.status,200);assert.deepEqual((await result.json()).payload.events,[]);
  const bad=await bridge.fetch(request('/extract/enqueue',{session,part:0,lines:[{line_id:1,text:'x',cluster_tag:null,t_sec:0,is_gap:false,recipe:'old',streaming:true}]}),env);
  assert.equal(bad.status,400);assert.equal(calls,1);
});
test('ASR receipt survives completion; only explicit retry permits failed work to resubmit', async()=>{
  let calls=0;let failed=false;
  const bridge=createBridge(async()=>{calls++;return Response.json({task_id:'new-task'});});
  const withReceipt={...env,AUDIO:{
    head:async()=>({size:44+32000}),
    get:async path=>({json:async()=>path.startsWith('asr/claim/')
      ? {task_id:'prior-task',submitted_at:new Date().toISOString()}
      : {verdict:failed?'failed':'done',body:JSON.stringify({duration:1,result:[{}]})}}),
  }};
  const body={key:`stepx/${uuid}/${uuid}/${uuid}-${'a'.repeat(64)}.wav`,seconds:600};
  const completed=await bridge.fetch(request('/asr/submit',body),withReceipt);
  assert.deepEqual(await completed.json(),{task_id:'prior-task'});assert.equal(calls,0);
  failed=true;assert.equal((await bridge.fetch(request('/asr/submit',body),withReceipt)).status,502);
  assert.equal((await bridge.fetch(request('/asr/submit',{...body,retryFailed:true,retryId:uuid}),withReceipt)).status,200);
  assert.equal(calls,1);
});

test('completed empty transcription follows the native terminal contract', async()=>{
  for (const receipt of [{duration:4.48,result:[]}, {status:'COMPLETED',result:[]}]) {
    const bridge=createBridge(async()=>Response.json(receipt));
    const result=await (await bridge.fetch(request('/asr/query',{task_id:'safe-task'}),env)).json();
    assert.equal(result.state,'done');assert.deepEqual(result.result,[]);
  }
  const bridge=createBridge(async()=>Response.json({result:[]}));
  assert.equal((await (await bridge.fetch(request('/asr/query',{task_id:'safe-task'}),env)).json()).state,'done');
});
test('terminal ASR query failures retain retry codes while ordinary outages retain the task', async()=>{
  for (const [body, status, expected] of [
    [{error:'asr failed',detail:'private upstream detail'},502,'asr_failed'],
    [{error:'asr_cached_result_invalid'},502,'asr_cached_result_invalid'],
    [{error:'query failed',body:'temporary outage'},502,'processing_failed'],
    [{error:'asr failed'},401,'processing_failed'],
  ]) {
    const bridge=createBridge(async()=>Response.json(body,{status}));
    const response=await bridge.fetch(request('/asr/query',{task_id:'safe-task'}),env);
    assert.equal(response.status,status===401?401:502);
    assert.deepEqual(await response.json(),{error:expected});
  }
});
test('expired unknown receipts require explicit retry and protect the new attempt after restart', async()=>{
  const body={key:`stepx/${uuid}/${uuid}/${uuid}-${'a'.repeat(64)}.wav`,seconds:1};
  const rows=new Map([['receipt',{submittedAt:Date.now()-7*3600000,state:'unknown',supersedes:null}]]);
  const storage={get:async k=>structuredClone(rows.get(k)),put:async(k,v)=>rows.set(k,structuredClone(v))};
  let calls=0;const fetcher=async()=>{calls++;throw Error('lost upstream result');};
  const actor=()=>new StepXSubmissions({storage},env,fetcher);
  for(let i=0;i<2;i++) {
    const response=await actor().fetch(request('/asr/submit',body));
    assert.equal(response.status,409);assert.deepEqual(await response.json(),{error:'asr_failed',reason:'asr_submission_expired'});
  }
  assert.equal(calls,0);
  const retry=await actor().fetch(request('/asr/submit',{...body,retryFailed:true,retryId:uuid}));
  assert.deepEqual(await retry.json(),{error:'asr_submission_unknown'});assert.equal(calls,1);
  const replay=await actor().fetch(request('/asr/submit',{...body,retryFailed:true,retryId:uuid}));
  assert.deepEqual(await replay.json(),{error:'asr_submission_unknown'});assert.equal(calls,1);
});
test('concurrent initial ASR submissions are serialized and paid only once', async()=>{
  let calls=0;
  const bridge=createBridge(async()=>{ calls++; await new Promise(resolve=>setTimeout(resolve,15)); return Response.json({task_id:'one-task'}); });
  const body={key:`stepx/${uuid}/${uuid}/${uuid}-${'a'.repeat(64)}.wav`,seconds:1};
  const responses=await Promise.all([bridge.fetch(request('/asr/submit',body),env),bridge.fetch(request('/asr/submit',body),env)]);
  assert.equal(calls,1);
  for(const response of responses)assert.deepEqual(await response.json(),{task_id:'one-task'});
});
test('legacy boolean cannot authorize paid recovery at any expiry after actor restart', async()=>{
  const body={key:`stepx/${uuid}/${uuid}/${uuid}-${'a'.repeat(64)}.wav`,seconds:1,retryFailed:true};
  const rows=new Map([['receipt',{submittedAt:Date.now()-7*3600000,state:'unknown',supersedes:null}]]);
  const storage={get:async k=>structuredClone(rows.get(k)),put:async(k,v)=>rows.set(k,structuredClone(v))};
  let paid=0;const fetcher=async()=>{paid++;throw Error('paid but no receipt');};
  const call=()=>new StepXSubmissions({storage},env,fetcher).fetch(request('/asr/submit',body));
  const first=await call();assert.deepEqual(await first.json(),{error:'asr_retry_authorization_required'});assert.equal(paid,0);
  for(let i=0;i<3;i++) {
    rows.get('receipt').submittedAt=Date.now()-7*3600000;
    const response=await call();assert.equal(response.status,409);
    assert.deepEqual(await response.json(),{error:'asr_retry_authorization_required'});
    assert.equal(paid,0,'a legacy boolean cannot distinguish a new confirmation from replay');
  }
});
test('identified retry consent is single-use across expiry; a new user consent can recover', async()=>{
  const body={key:`stepx/${uuid}/${uuid}/${uuid}-${'a'.repeat(64)}.wav`,seconds:1,retryFailed:true};
  const rows=new Map([['receipt',{submittedAt:Date.now()-7*3600000,state:'unknown',supersedes:null}]]);
  const storage={get:async k=>structuredClone(rows.get(k)),put:async(k,v)=>rows.set(k,structuredClone(v))};
  let paid=0;const fetcher=async()=>{paid++;throw Error('paid but no receipt');};
  const call=retryId=>new StepXSubmissions({storage},env,fetcher).fetch(request('/asr/submit',{...body,retryId}));
  const first=uuid,second='22345678-1234-1234-1234-123456789abc';
  await call(first);assert.equal(paid,1);
  rows.get('receipt').submittedAt=Date.now()-7*3600000;
  await call(first);assert.equal(paid,1);
  await call(second);assert.equal(paid,2);
  rows.get('receipt').submittedAt=Date.now()-7*3600000;
  await call(first);await call(second);assert.equal(paid,2);
});
test('retry authorization and receipt must both persist before a paid call', async()=>{
  const body={key:`stepx/${uuid}/${uuid}/${uuid}-${'a'.repeat(64)}.wav`,seconds:1,retryFailed:true,retryId:uuid};
  for(const failAt of ['retry:'+uuid,'receipt']) {
    const rows=new Map([['receipt',{submittedAt:Date.now()-7*3600000,state:'unknown',supersedes:null}]]);
    let fail=true,paid=0;
    const storage={get:async k=>structuredClone(rows.get(k)),put:async(k,v)=>{if(fail&&k===failAt)throw Error('disk');rows.set(k,structuredClone(v));}};
    const fetcher=async()=>{paid++;throw Error('paid but unknown');};
    const call=()=>new StepXSubmissions({storage},env,fetcher).fetch(request('/asr/submit',body));
    assert.equal((await call()).status,502);assert.equal(paid,0);
    fail=false;const retried=await call();
    assert.equal(paid,failAt==='receipt'?0:1);
    if(failAt==='receipt')assert.deepEqual(await retried.json(),{error:'asr_retry_authorization_required'});
  }
});
test('retry identities are strict and legacy clients still recover existing task receipts', async()=>{
  const body={key:`stepx/${uuid}/${uuid}/${uuid}-${'a'.repeat(64)}.wav`,seconds:1};
  let paid=0;const bridge=createBridge(async()=>{paid++;return Response.json({task_id:'kept-task'});});
  for(const change of [{retryFailed:true,retryId:'bad'},{retryFailed:true,retryId:uuid.toUpperCase()},{retryId:uuid},{retryFailed:'true',retryId:uuid}]) {
    assert.equal((await bridge.fetch(request('/asr/submit',{...body,...change}),env)).status,400);
  }
  assert.equal(paid,0);
  assert.deepEqual(await(await bridge.fetch(request('/asr/submit',body),env)).json(),{task_id:'kept-task'});
  assert.deepEqual(await(await bridge.fetch(request('/asr/submit',{...body,retryFailed:true}),env)).json(),{task_id:'kept-task'});
  assert.equal(paid,1);
});
test('provider result unknown survives actor restart and explicit retry cannot charge before expiry', async()=>{
  const rows=new Map(), storage={get:async k=>structuredClone(rows.get(k)),put:async(k,v)=>{rows.set(k,structuredClone(v));}};
  let calls=0;const fetcher=async()=>{calls++;throw Error('lost response');};
  const body={key:`stepx/${uuid}/${uuid}/${uuid}-${'a'.repeat(64)}.wav`,seconds:1};
  const actor=new StepXSubmissions({storage},env,fetcher);
  assert.equal((await actor.fetch(request('/asr/submit',body))).status,409);
  const restarted=new StepXSubmissions({storage},env,fetcher);
  assert.equal((await restarted.fetch(request('/asr/submit',{...body,retryFailed:true}))).status,409);
  assert.equal(calls,1);
});
test('persist failure before provider call costs nothing',async()=>{
  let calls=0;const actor=new StepXSubmissions({storage:{get:async()=>undefined,put:async()=>{throw Error('disk');}}},env,async()=>{calls++;return Response.json({task_id:'bad'});});
  const body={key:`stepx/${uuid}/${uuid}/${uuid}-${'a'.repeat(64)}.wav`,seconds:1};
  assert.equal((await actor.fetch(request('/asr/submit',body))).status,502);assert.equal(calls,0);
});
test('explicit pending status wins over partial or empty ASR material',async()=>{
  for(const receipt of [{status:'RUNNING',duration:0,result:[]},{status:'PROCESSING',result:[{}]}]) {
    const bridge=createBridge(async()=>Response.json(receipt));
    assert.equal((await (await bridge.fetch(request('/asr/query',{task_id:'safe-task'}),env)).json()).state,'waiting');
  }
});
test('old failed R2 claim cannot override the latest durable attempt',async()=>{
  const body={key:`stepx/${uuid}/${uuid}/${uuid}-${'a'.repeat(64)}.wav`,seconds:1,retryFailed:true,retryId:uuid};
  const stale={...env,AUDIO:{head:env.AUDIO.head,get:async p=> p.endsWith('new-task.json') ? null : ({json:async()=>p.startsWith('asr/claim/')
    ? {task_id:'old-task',submitted_at:new Date(Date.now()-1000).toISOString()}
    : {verdict:'failed'}})}};
  for(const unknown of [false,true]) {
    const rows=new Map(),storage={get:async k=>rows.get(k),put:async(k,v)=>rows.set(k,v)};
    let calls=0,queries=0;const fetcher=async url=>{
      if(url.endsWith('/asr/query')) { queries++;return Response.json({status:'RUNNING'}); }
      calls++;if(unknown)throw Error('timeout');return Response.json({task_id:'new-task'});
    };
    const actor=new StepXSubmissions({storage},stale,fetcher);
    const first=await actor.fetch(request('/asr/submit',body));
    const restarted=new StepXSubmissions({storage},stale,fetcher);
    const second=await restarted.fetch(request('/asr/submit',body));
    assert.equal(first.status,unknown?409:200);assert.equal(second.status,unknown?409:200);assert.equal(calls,1);
    assert.equal(queries,0,'等待 collector 缓存终态，不扩大旧客户端自动重放的付费窗口');
    if(!unknown)assert.deepEqual(await second.json(),{task_id:'new-task'});
  }
});

test('a corrupt done cache is explicit failure and can recover only after expiry',async()=>{
  let calls=0;const rows=new Map();
  const storage={get:async k=>rows.get(k),put:async(k,v)=>rows.set(k,v)};
  const bound={...env,AUDIO:{head:env.AUDIO.head,get:async p=>({json:async()=>p.startsWith('asr/claim/')
    ?{task_id:'old-task',submitted_at:new Date().toISOString()}
    :{verdict:'done',body:JSON.stringify({status:'RUNNING',duration:0,result:[]})}})}};
  const actor=new StepXSubmissions({storage},bound,async()=>{calls++;return Response.json({task_id:'new-task'});});
  const body={key:`stepx/${uuid}/${uuid}/${uuid}-${'a'.repeat(64)}.wav`,seconds:1,retryFailed:true};
  const response=await actor.fetch(request('/asr/submit',body));assert.equal(response.status,502);
  assert.deepEqual(await response.json(),{error:'asr_cached_result_invalid'});assert.equal(calls,0);
});

test('personal action-only headers are strict, first-line only, preserving the exact frozen request',async()=>{
  let forwarded,calls=0;const bridge=createBridge(async(url,init)=>{calls++;forwarded=JSON.parse(init.body);return Response.json({state:'queued',ticket:session+'-0-'+'a'.repeat(16)})});
  const line={line_id:1,text:'public fixture',cluster_tag:null,t_sec:0,t_end_sec:1,is_gap:false,recipe:STREAM_RECIPE,streaming:true,action_protocol:'personal-actions/v1',action_request:uuid,source_revision:1,action_only:true};
  const body={session,part:0,lines:[line]};assert.equal((await bridge.fetch(request('/extract/enqueue',body),env)).status,200);assert.deepEqual(forwarded,body);
  for(const change of [x=>x.action_protocol='other',x=>x.action_request='bad',x=>x.source_revision=-1,x=>x.source_revision=1.2,x=>x.action_only='true',x=>x.owner='me',x=>x.stream_context={event_id:1,title:'old',summary:'old',tail:'old',t_end_sec:1}]){
    const changed=structuredClone(line);change(changed);assert.equal((await bridge.fetch(request('/extract/enqueue',{session,part:0,lines:[changed]}),env)).status,400);
  }
  assert.equal((await bridge.fetch(request('/extract/enqueue',{session,part:0,lines:[line,{...line,line_id:2}]}),env)).status,400);assert.equal(calls,1);
});
test('action-only and mixed results retain personal actions; terminal errors stay terminal and sanitized',async()=>{
  const ticket=session+'-0-'+'a'.repeat(16);
  for(const payload of [{pipeline_version:STREAM_RECIPE,action_protocol:'personal-actions/v1',personal_actions:[]},{pipeline_version:STREAM_RECIPE,events:[],action_protocol:'personal-actions/v1',personal_actions:[]}]){
    const bridge=createBridge(async()=>Response.json({state:'done',body:JSON.stringify(payload)}));assert.deepEqual(await(await bridge.fetch(request('/extract/result',{ticket}),env)).json(),{state:'done',payload});
  }
  const terminal=createBridge(async()=>Response.json({state:'done',body:JSON.stringify({terminal:true,error:'private stack and token'})}));
  const result=await(await terminal.fetch(request('/extract/result',{ticket}),env)).json();assert.equal(result.payload.terminal,true);assert.equal(JSON.stringify(result).includes('private'),false);
  for(const payload of [{pipeline_version:STREAM_RECIPE,action_protocol:'personal-actions/v1'},{pipeline_version:STREAM_RECIPE,events:[],action_protocol:'other',personal_actions:[]},{pipeline_version:STREAM_RECIPE,personal_actions:[]}]){
    const bridge=createBridge(async()=>Response.json({state:'done',body:JSON.stringify(payload)}));assert.equal((await bridge.fetch(request('/extract/result',{ticket}),env)).status,502);
  }
});
