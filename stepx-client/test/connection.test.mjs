import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import {stripTypeScriptTypes} from 'node:module';
import {test} from 'node:test';
const original=fs.readFileSync(new URL('../src/growth/connection.ts',import.meta.url),'utf8');
function setup({native=true,fail='',bodyTimeout=false, invalidToken='',online=true,responseBody=null}={}) {
 let credential='',throwOp=fail,calls=0;
 const health={ok:true,chatConfigured:true,asrConfigured:true,extractionQueueConfigured:true,semanticRecipe:'v3-semantic-continuity',source:'fixture'};
 const session=new Map();
 const ctx={Blob,Uint8Array,ArrayBuffer,URL,AbortController,setTimeout,clearTimeout,navigator:{onLine:online},useSyncExternalStore:()=>{},
   initBridge:async()=>native?'native':'mock',
   invokeNative:async(op,params)=>{ if(op===throwOp)throw Error('private storage error');if(op==='getStorage')return{data:credential};if(op==='setStorage')credential=params.data;if(op==='removeStorage')credential='';return{};},
   sessionStorage:{getItem:k=>session.get(k),setItem:(k,v)=>session.set(k,v),removeItem:k=>session.delete(k)},
   fetch:async(url,init)=>{calls++;return{ok:!responseBody&&init.headers['X-Growth-Token']!==invalidToken,status:401,json:()=>bodyTimeout?new Promise((r,j)=>init.signal.addEventListener('abort',()=>j(Error('aborted')))):Promise.resolve(responseBody??(init.headers['X-Growth-Token']===invalidToken?{error:'unauthorized'}:health))}}};
 vm.createContext(ctx);
 vm.runInContext(stripTypeScriptTypes(original.replace(/^import .*\n/gm,'').replace(/export /g,''),{mode:'transform'})+'\nglobalThis.Connection=GrowthConnection;',ctx);
 return{connection:new ctx.Connection(),fresh:()=>new ctx.Connection(),setFail:op=>throwOp=op,stored:()=>credential,calls:()=>calls,session};
}
test('a stale WebView offline flag cannot veto a successful bounded server response',async()=>{
 const t=setup({online:false});await t.connection.connect('isolated-public-fake-token');
 assert.equal(t.connection.isReady(),true);assert.equal(t.calls(),1);
});
test('failed native credential clearing remains visible and can be retried',async()=>{
 const a=setup();await a.connection.connect('isolated-public-fake-token');assert.equal(a.connection.isReady(),true);
 a.setFail('removeStorage');await assert.rejects(a.connection.disconnect(),/凭据存储失败/);assert.equal(a.connection.isReady(),false);assert.equal(a.connection.getSnapshot().hasCredential,true);assert.ok(a.stored());
 a.setFail('');await a.connection.disconnect();assert.equal(a.stored(),'');const fresh=a.fresh();await fresh.init();assert.equal(fresh.isReady(),false);
});

test('native writes never silently fall back to web storage',async()=>{
 const b=setup({fail:'setStorage'});await assert.rejects(b.connection.connect('isolated-public-fake-token'),/凭据存储失败/);assert.equal(b.connection.isReady(),false);assert.equal(b.session.size,0);
});

test('native credential read can retry after storage recovery',async()=>{
 const c=setup({fail:'getStorage'});await c.connection.init();assert.match(c.connection.getSnapshot().error,/凭据存储失败/);c.setFail('');await c.connection.init();assert.equal(c.connection.isReady(),false);
});

test('browser preview keeps credential only in tab session',async()=>{
 const d=setup({native:false});await d.connection.connect('isolated-public-fake-token');assert.equal(d.stored(),'');assert.equal(d.session.size,1);await d.connection.disconnect();assert.equal(d.session.size,0);
});

test('normalized URL cannot escape the StepX route',async()=>{
 const e=setup();await e.connection.connect('isolated-public-fake-token');await assert.rejects(e.connection.request('/../extract',{}),error=>error.code==='invalid_path');assert.equal(e.calls(),1);
});

test('body timeout preserves unknown paid result',async()=>{
 const f=setup({bodyTimeout:true});await assert.rejects(f.connection.fetchJson('/chat',{},'fake-token',5),error=>error.code==='unknown_result');
});
test('compatible terminal error reports expiry to new clients and ignores unrelated reason fields',async()=>{
 for(const body of [{error:'asr_failed',reason:'asr_submission_expired'}, {error:'processing_failed',reason:'asr_submission_expired'}]) {
  const f=setup({responseBody:body});
  await assert.rejects(f.connection.fetchJson('/asr/submit',{},'fake-token'),error=>error.code===(body.error==='asr_failed'?'asr_submission_expired':'processing_failed'));
 }
});

test('disconnect clears prior credential even if a later connection fails',async()=>{
 const race=setup({invalidToken:'invalid-new-fake-token'});await race.connection.connect('old-isolated-fake-token');
 const results=await Promise.allSettled([race.connection.disconnect(),race.connection.connect('invalid-new-fake-token')]);
 assert.equal(results[0].status,'fulfilled');assert.equal(results[1].status,'rejected');assert.equal(race.stored(),'');const restarted=race.fresh();await restarted.init();assert.equal(restarted.isReady(),false);
});
