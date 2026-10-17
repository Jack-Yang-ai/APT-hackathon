import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {m4aInfo,m4aSourceSeconds,storedStepXSeconds} from '../../worker/src/stepx_audio.js';
import {createBridge,StepXSubmissions} from '../src/index.js';
import worker from '../../worker/src/index.js';

const bytes=new Uint8Array(fs.readFileSync(new URL('./fixtures/aac-mono-16k.m4a',import.meta.url)));
const uuid='00000000-0000-4000-8000-000000000001',token='synthetic-compression-gate';
const hash=async data=>Buffer.from(await crypto.subtle.digest('SHA-256',data)).toString('hex');
const audioKey=async()=>`stepx/${uuid}/${uuid}/${uuid}-${await hash(bytes)}.m4a`;
test('real AAC-LC fixture validates 16k mono, source frames and bounded padding',()=>{
 const info=m4aInfo(bytes);assert.equal(info.sampleRate,16000);assert.equal(info.channels,1);
 assert.equal(m4aSourceSeconds(info,16000),1);
 for(const frames of [0,16000.5,30000,1])assert.throws(()=>m4aSourceSeconds(info,frames));
});
test('missing sample tables, renamed bytes, truncation, invalid offsets and wrong format are refused',()=>{
 for(const type of ['stts','stsc','stsz','stco']) {
  const changed=bytes.slice(),at=Buffer.from(changed).indexOf(type);assert.ok(at>=0);
  changed.set(new TextEncoder().encode('free'),at);assert.throws(()=>m4aInfo(changed),type);
 }
 for(const cut of [0,40,bytes.length-1])assert.throws(()=>m4aInfo(bytes.slice(0,cut)));
 const wrong=bytes.slice(),view=new DataView(wrong.buffer);
 const mp4a=Buffer.from(wrong).indexOf('mp4a');view.setUint16(mp4a+20,2);assert.throws(()=>m4aInfo(wrong));
 const offset=bytes.slice(),offsetView=new DataView(offset.buffer);
 offsetView.setUint32(Buffer.from(offset).indexOf('stco')+12,0);assert.throws(()=>m4aInfo(offset));
});
function harness() {
 const objects=new Map(),pending=[],provider=[];
 const AUDIO={
  async head(key){return objects.get(key)?.meta??null;},
  async put(key,data,options={}){
   if(options.onlyIf?.etagDoesNotMatch==='*'&&objects.has(key))return null;
   const encoded=typeof data==='string'?new TextEncoder().encode(data):data;
   const meta={key,size:encoded.byteLength,customMetadata:options.customMetadata};
   objects.set(key,{data:encoded.slice(),meta});return meta;
  },
  async get(key){const row=objects.get(key);if(!row)return null;return {...row.meta,json:async()=>JSON.parse(new TextDecoder().decode(row.data))};},
 };
 const rootEnv={AUDIO,CLIENT_TOKEN:token,STEPFUN_API_KEY:'synthetic-provider-key'};
 const env={AUDIO,GROWTH_CLIENT_TOKEN:token,GROWTH_UPSTREAM:{fetch:req=>worker.fetch(req,rootEnv,{waitUntil:p=>pending.push(p)})}};
 const storage=new Map();const submissions=new StepXSubmissions({storage:{get:async key=>structuredClone(storage.get(key)),put:async(key,value)=>storage.set(key,structuredClone(value))}},env);
 env.SUBMISSIONS={idFromName:value=>value,get:()=>submissions};
 const bridge=createBridge();
 const call=(path,body)=>bridge.fetch(new Request('https://apt-backend.example/stepx'+path,{method:'POST',headers:{'X-Growth-Token':token,'Content-Type':body instanceof Uint8Array?'audio/mp4':'application/json'},body:body instanceof Uint8Array?body:JSON.stringify(body)}),env);
 return {AUDIO,objects,pending,provider,env,rootEnv,call};
}
test('same bytes cannot change source time on retries, including concurrent conditional creation',async()=>{
 const h=harness(),key=await audioKey(),frames=[16000,15900];
 const results=await Promise.all(frames.map(count=>h.call('/upload?key='+key+'&frames='+count,bytes)));
 assert.deepEqual(results.map(r=>r.status).sort(),[200,409]);
 const winner=frames[results.findIndex(r=>r.status===200)],loser=frames.find(count=>count!==winner);
 assert.equal(storedStepXSeconds(await h.AUDIO.head(key),key),winner/16000);
 assert.equal((await h.call('/upload?key='+key+'&frames='+winner,bytes)).status,200);
 assert.equal((await h.call('/upload?key='+key+'&frames='+loser,bytes)).status,409);
 assert.equal(storedStepXSeconds(await h.AUDIO.head(key),key),winner/16000);
});
test('compressed ASR uses the existing provider, claims and accounting, preserving format and deduplication',async()=>{
 const h=harness(),key=await audioKey(),previous=globalThis.fetch;
 globalThis.fetch=async(url,init)=>{assert.equal(url,'https://api.stepfun.com/v1/audio/asr/file/submit');h.provider.push(JSON.parse(init.body));return Response.json({task_id:'compression-test-task'});};
 try {
  assert.equal((await h.call('/upload?key='+key+'&frames=16000',bytes)).status,200);
  for(let n=0;n<2;n++){
   const result=await h.call('/asr/submit',{key,seconds:1});assert.equal(result.status,200);assert.equal((await result.json()).task_id,'compression-test-task');
  }
  await Promise.all(h.pending);assert.equal(h.provider.length,1);
  assert.equal(h.provider[0].audio.format,'m4a');assert.equal(h.provider[0].audio.codec,undefined);
  assert.equal(h.provider[0].request.model_name,'stepaudio-2.5-asr');assert.equal(h.provider[0].request.enable_speaker_info,true);
  const usage=[...h.objects.keys()].filter(key=>key.startsWith('usage/'));assert.equal(usage.length,1);
  // The generic route cannot erase the StepX validator's immutable metadata.
  const direct=await worker.fetch(new Request('https://apt-backend.example/upload?key='+key,{method:'POST',headers:{'X-Growth-Token':token},body:bytes}),h.rootEnv,{waitUntil:()=>{}});
  assert.equal(direct.status,400);assert.equal(storedStepXSeconds(await h.AUDIO.head(key),key),1);
 } finally {globalThis.fetch=previous;}
});
test('unvalidated objects and fingerprint mismatches never submit ASR',async()=>{
 const h=harness(),key=await audioKey();
 const bad=bytes.slice();bad[0]=0;bad[1]=0;bad[2]=0;bad[3]=8;
 assert.equal((await h.call('/upload?key='+key+'&frames=16000',bad)).status,400);
 h.objects.set(key,{data:bytes,meta:{size:bytes.length}});
 assert.equal((await h.call('/asr/submit',{key,seconds:1})).status,409);
});
