import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {stripTypeScriptTypes} from 'node:module';
import {IDBFactory} from 'fake-indexeddb';

const client='00000000-0000-4000-8000-000000000003';
const deferred=()=>{let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve};};
function setup(indexedDB=new IDBFactory(),revoked=new Set()) {
 const calls=[];let fail=false;
 const ctx={crypto,Blob,structuredClone,console,indexedDB,useSyncExternalStore:()=>{},
  RootRecordingClient:class {async revokeMatter(id){calls.push('forget');if(fail)throw Error('revocation not confirmed');revoked.add(id);return {};}}};
 vm.createContext(ctx);
 for(const [file,names] of [
  ['idb.ts',['idbGetAll','idbGet','idbPut','idbUpdate','idbDelete','idbCommitAudio','idbDeleteMatter','idbPrepareMatterDeletion','STORE_MATTERS','STORE_SEGMENTS','STORE_BLOBS','STORE_PROCESSING']],
  ['store.ts',['GrowthStore']]]) {
  const text=fs.readFileSync(new URL('../src/growth/'+file,import.meta.url),'utf8').replace(/^import[\s\S]*?from ['"][^'"]+['"]\s*\n/gm,'').replace(/export /g,'');
  vm.runInContext('(function(){'+stripTypeScriptTypes(text,{mode:'transform'})+'\n'+names.map(n=>`globalThis.${n}=${n};`).join('\n')+'})()',ctx);
 }
 return {c:ctx,store:new ctx.GrowthStore(),calls,fail:()=>fail=true};
}
test('a committed START marker with a delayed cache callback cannot bypass native deletion revocation',async()=>{
 const t=setup(),matter=await t.store.createMatter(),entered=deferred(),release=deferred(),real=t.c.idbUpdate;
 t.c.idbUpdate=async(...args)=>{const row=await real(...args);entered.resolve();await release.promise;return row;};
 const start=t.store.authorizeRootStart(matter.id,client,async()=>t.calls.push('start'));
 await entered.promise;const deleting=t.store.deleteMatter(matter.id);
 await new Promise(setImmediate);assert.ok(await t.c.idbGet('matters',matter.id));assert.deepEqual(t.calls,[]);
 release.resolve();await start;await deleting;assert.deepEqual(t.calls,['start','forget']);
 assert.equal(await t.c.idbGet('matters',matter.id),undefined);assert.equal(t.store.getMatter(matter.id),undefined);
 await assert.rejects(t.store.updateMatter(matter.id,{endedAt:1}));assert.equal(t.store.getMatter(matter.id),undefined);
 await assert.rejects(t.store.authorizeRootStart(matter.id,client,async()=>t.calls.push('late-start')));
 assert.equal(t.calls.includes('late-start'),false);
});
test('deletion consults durable ownership and cannot succeed before native forget acknowledgement',async()=>{
 const t=setup(),matter=await t.store.createMatter();
 await t.c.idbUpdate('matters',matter.id,row=>({...row,rootUploadClient:client}));
 assert.equal(t.store.getMatter(matter.id).rootUploadClient,undefined);t.fail();
 await assert.rejects(t.store.deleteMatter(matter.id),/revocation/);
 assert.ok(await t.c.idbGet('matters',matter.id));assert.ok(t.store.getMatter(matter.id));
 assert.equal(await t.c.idbGet('processing','__deleted_matter__:'+matter.id),undefined);
 await assert.rejects(t.store.authorizeRootStart(matter.id,client,async()=>{}),/删除/);
});
test('legacy SDK recordings remain deletable without a root controller',async()=>{
 for(const legacyRoot of [false,true]) {
  const t=setup(),matter=await t.store.createMatter();
  if(legacyRoot)await t.store.authorizeRootStart(matter.id,undefined,async()=>{});
  t.fail();await t.store.deleteMatter(matter.id);
  assert.equal(await t.c.idbGet('matters',matter.id),undefined);assert.deepEqual(t.calls,[]);
 }
});
test('cross-context deletion intent and START authorization share one durable ordering',async()=>{
 for(const startFirst of [false,true]) {
  const db=new IDBFactory(),revoked=new Set(),a=setup(db,revoked),b=setup(db,revoked),matter=await a.store.createMatter();
  await b.store.init();const entered=deferred(),release=deferred();
  if(startFirst) {
   const real=a.c.idbUpdate;a.c.idbUpdate=async(...args)=>{const row=await real(...args);entered.resolve();await release.promise;return row;};
   const starting=a.store.authorizeRootStart(matter.id,client,async()=>{if(revoked.has(matter.id))throw Error('root tombstone');a.calls.push('start');});
   await entered.promise;await b.store.deleteMatter(matter.id);release.resolve();await assert.rejects(starting,/tombstone/);
   assert.deepEqual(b.calls,['forget']);assert.deepEqual(a.calls,[]);
  } else {
   const real=a.c.idbPrepareMatterDeletion;a.c.idbPrepareMatterDeletion=async(...args)=>{const row=await real(...args);entered.resolve();await release.promise;return row;};
   const deleting=a.store.deleteMatter(matter.id);await entered.promise;
   await assert.rejects(b.store.authorizeRootStart(matter.id,client,async()=>b.calls.push('start')),/删除/);
   release.resolve();await deleting;assert.deepEqual(a.calls,[]);assert.deepEqual(b.calls,[]);
  }
  assert.equal(await a.c.idbGet('matters',matter.id),undefined);
 }
});
test('a delayed root audio commit cannot republish a segment after deletion completes',async()=>{
 const t=setup(),matter=await t.store.createMatter(),entered=deferred(),release=deferred(),real=t.c.idbCommitAudio;
 t.c.idbCommitAudio=async(...args)=>{const result=await real(...args);entered.resolve();await release.promise;return result;};
 const segment={id:'root-piece',matterId:matter.id,index:0,capturedAt:1,durationSec:1,sizeBytes:3,localUrl:'',stage:'recorded',attempts:0,rootUpload:{}};
 const commit=t.store.commitRootAudio(segment,new Blob(['pcm']),'a'.repeat(64));await entered.promise;
 const deleting=t.store.deleteMatter(matter.id);release.resolve();assert.equal(await commit,'saved');await deleting;
 assert.equal(t.store.getSnapshot().segments.length,0);assert.equal(await t.c.idbGet('segments',segment.id),undefined);
 assert.equal(await t.c.idbGet('blobs',segment.id),undefined);assert.deepEqual(t.calls,['forget']);
 assert.equal(await t.store.commitRootAudio(segment,new Blob(['pcm']),'a'.repeat(64)),'deleted');
 assert.equal(t.store.getSnapshot().segments.length,0);
});
