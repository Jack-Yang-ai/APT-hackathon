import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';
import { fixture,source,plain } from './fixture.mjs';
const id='22222222-2222-4222-8222-222222222222';
function setup() {
  const f=fixture();
  for(const [file,names] of [['background-data.ts',['BACKGROUND_PREFIX','backgroundOwner','backgroundMatterStamp']],['background.ts',['BackgroundProcessing']]]) {
    const text=fs.readFileSync(new URL('../src/growth/'+file,import.meta.url),'utf8').replace(/^import .*\n/gm,'').replace(/export /g,'');
    vm.runInContext('(function(){'+stripTypeScriptTypes(text,{mode:'transform'})+'\n'+names.map(name=>'globalThis.'+name+'='+name+';').join('')+'})()',f.c);
  }
  const s=source(id);for(const j of s.jobs){j.uploaded=true;j.remoteKey='public-key-'+j.id;}
  let handler=async()=>{throw Error('unexpected request')};const calls=[];
  const connection={subscribe:()=>()=>{},isReady:()=>true,getSnapshot:()=>({health:{backgroundConfigured:true}}),
    request:async(path,body)=>{calls.push({path,body:plain(body)});return handler(path,body);}};
  const runner=new f.c.BackgroundProcessing({connection,transaction:f.c.sourceTransaction,hash:f.c.fingerprint,store:{subscribe:()=>()=>{}}});
  const owner=async()=>f.c.backgroundOwner((await f.c.readSources()).jobs,id);
  const status=body=>({schema:'apt.background-status/1',device_id:body.device_id,recording_id:id,generation:body.generation,
    control_version:body.control_version??0,phase:'active',jobs:[],actions:null,lastSuccess:1,error:null});
  return {...f,s,calls,runner,owner,status,setHandler:fn=>handler=fn};
}
test('legacy prefix handoff keeps integral frames through duration conversion',async()=>{
  for(const fractional of [false,true]) {
    const f=setup(),capture=crypto.randomUUID(),client=crypto.randomUUID(),digest='a'.repeat(64),frames=1025024;
    f.s.matters[0].endedAt=null;
    const segment={...f.s.segments[0],id:`root:${capture}:0`,durationSec:(frames+(fractional?.01:0))/16000,sizeBytes:44+frames*2,
      rootUpload:{captureId:capture,piece:0,sha256:digest,client}};
    f.s.segments=[segment];f.s.jobs=[{...f.s.jobs[0],id:segment.id,uploaded:true,remoteKey:`stepx/${client}/${id}/${crypto.randomUUID()}-${digest}.wav`}];
    await f.seed(f.s);const status={sessions:[{captureId:capture,matterId:id,indexBase:0,chunkSeconds:300,limitSeconds:43200,state:'stopped',frames,startedAt:segment.capturedAt,uploadClient:client}]};
    if(fractional)await assert.rejects(f.runner.prepare(id,status));else assert.equal((await f.runner.prepare(id,status)).phase,'preparing');
  }
});
test('delegation is durable before network and preserves existing task identities on a lost claim response',async()=>{
  const f=setup();await f.seed(f.s);const first=await f.runner.prepare(id);
  const stored=await f.owner();assert.equal(stored.phase,'preparing');assert.equal(stored.generation,first.generation);assert.equal(f.calls.length,0);
  let lost=true;f.setHandler(async(path,body)=>{if(path==='/background/claim'&&lost){lost=false;throw Error('lost receipt');}return f.status(body);});
  await f.runner.kick();assert.equal((await f.owner()).phase,'preparing');
  await f.runner.kick();assert.equal((await f.owner()).phase,'active');
  const claims=f.calls.filter(row=>row.path==='/background/claim');assert.equal(claims.length,2);assert.deepEqual(claims[0].body,claims[1].body);
  assert.deepEqual(plain((await f.c.readSources()).jobs.filter(row=>!row.id.startsWith('__'))),plain(f.s.jobs));
});
test('a phone transcript edit during artifact retrieval wins in the same final transaction',async()=>{
  const f=setup();await f.seed(f.s);await f.runner.prepare(id);
  let release,entered;const blocked=new Promise(resolve=>release=resolve),waiting=new Promise(resolve=>entered=resolve);
  const artifact=structuredClone(f.s.jobs[0]);artifact.events[0].summary='remote updated summary';const digest=await f.c.fingerprint(JSON.stringify(artifact));
  f.setHandler(async(path,body)=>{
    if(path==='/background/claim')return f.status(body);
    if(path==='/background/status')return {...f.status(body),jobs:[{id:artifact.id,state:'done',ref:{sha256:digest}}]};
    if(path==='/background/artifact'){entered();await blocked;return {...f.status(body),job:artifact};}
    throw Error('unexpected');
  });
  const running=f.runner.kick();await waiting;
  await f.c.idbUpdate('processing',artifact.id,current=>({...current,lineRevision:9,lines:[{...current.lines[0],text:'user correction wins'}]}));
  release();await running;
  const current=await f.c.idbGet('processing',artifact.id);assert.equal(current.lines[0].text,'user correction wins');assert.notEqual(current.events[0].summary,artifact.events[0].summary);
  assert.equal((await f.owner()).dirty,true);
});
test('deletion and native revocation receipt survive a late artifact without resurrecting phone data',async()=>{
  const f=setup();await f.seed(f.s);await f.runner.prepare(id);
  let release,entered;const blocked=new Promise(resolve=>release=resolve),waiting=new Promise(resolve=>entered=resolve);
  const artifact=structuredClone(f.s.jobs[0]);artifact.error='new artifact';const digest=await f.c.fingerprint(JSON.stringify(artifact));let revoked=false;
  f.setHandler(async(path,body)=>{
    if(path==='/background/claim')return f.status(body);
    if(path==='/background/status')return revoked?{...f.status(body),phase:'revoked',control_version:4}:{...f.status(body),jobs:[{id:artifact.id,state:'done',ref:{sha256:digest}}]};
    if(path==='/background/artifact'){entered();await blocked;return {...f.status(body),job:artifact};}throw Error('unexpected');
  });
  const running=f.runner.kick();await waiting;await f.c.idbDeleteMatter(id);release();await running;
  assert.equal(await f.c.idbGet('matters',id),undefined);assert.equal(await f.c.idbGet('processing',artifact.id),undefined);assert.equal((await f.owner()).deleted,true);
  revoked=true;await f.runner.kick();assert.equal((await f.owner()).phase,'revoked');assert.equal((await f.owner()).controlVersion,4);
});
test('a control timeout keeps its immutable request; later edits are queued after its exact receipt',async()=>{
  const f=setup();await f.seed(f.s);await f.runner.prepare(id);f.setHandler(async(_path,body)=>f.status(body));await f.runner.kick();
  await f.c.idbUpdate('processing',f.s.jobs[0].id,current=>({...current,lineRevision:2,lines:[{...current.lines[0],text:'first user edit'}]}));
  let failed=true;f.setHandler(async(path,body)=>{if(path==='/background/control'&&failed){failed=false;throw Error('lost control receipt');}return f.status(body);});
  await f.runner.kick();const frozen=plain((await f.owner()).control);assert(frozen);
  await f.c.idbUpdate('processing',f.s.jobs[0].id,current=>({...current,lineRevision:3,lines:[{...current.lines[0],text:'second user edit'}]}));
  await f.runner.kick();assert.equal((await f.owner()).dirty,true);await f.runner.kick();
  const controls=f.calls.filter(row=>row.path==='/background/control');assert.equal(controls.length,3);assert.deepEqual(controls[0].body,controls[1].body);
  assert.equal(controls[2].body.control_version,2);assert.notEqual(controls[2].body.mutation_id,frozen.mutationId);
  assert.equal(controls[2].body.snapshot.jobs[0].lines[0].text,'second user edit');
});
test('multiple source moves retain explicit removals in one formal transaction',async()=>{
  const f=setup();await f.seed(f.s);await f.runner.prepare(id);
  const moved=f.s.segments.slice(0,2).map(row=>({...row,matterId:'another-recording'}));
  await f.c.idbPutMany(moved.map(value=>({store:'segments',value})));
  const owner=await f.owner();assert.deepEqual([...owner.removedIds].sort(),moved.map(row=>row.id).sort());
  assert.equal(owner.removedIndices[moved[0].id],0);assert.equal(owner.removedIndices[moved[1].id],1);assert.equal(owner.dirty,true);
});
test('a definitively rejected capacity control stays editable while an unknown control keeps its identity',async()=>{
  const f=setup();await f.seed(f.s);await f.runner.prepare(id);f.setHandler(async(_path,body)=>f.status(body));await f.runner.kick();
  await f.c.idbUpdate('processing',f.s.jobs[0].id,row=>({...row,error:'user edit'}));
  let rejected=true;f.setHandler(async(path,body)=>{if(path==='/background/control'&&rejected)throw Object.assign(Error('capacity'),{code:'background_material_capacity'});return f.status(body);});
  await f.runner.kick();const owner=await f.owner();assert.equal(owner.control,undefined);assert.equal(owner.blockedEpoch,owner.epoch);
  const calls=f.calls.length;await f.runner.kick();assert.equal(f.calls.length,calls);
  rejected=false;await f.c.idbUpdate('processing',f.s.jobs[0].id,row=>({...row,error:'smaller user edit'}));await f.runner.kick();
  assert.equal((await f.owner()).controlVersion,1);assert.equal((await f.owner()).dirty,false);
});
