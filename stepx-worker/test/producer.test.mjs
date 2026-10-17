import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { RecordingMemoryReplica } from '../../mac/recording_memory.mjs';
import { handleRecordingMemory } from '../../worker/src/recording_memory.js';
import { fingerprint } from '../../worker/src/input_memory.js';
const device='11111111-1111-4111-8111-111111111111',recording='22222222-2222-4222-8222-222222222222';
const generation='33333333-3333-4333-8333-333333333333',handoff='44444444-4444-4444-8444-444444444444';
const id='apt_recording_55555555-5555-4555-8555-555555555555';
const record=(revision=1,extra={})=>({id,revision,created:'2026-10-15T00:00:00.000Z',updated:'2026-10-15T01:00:00.000Z',title:'public fixture',
  text:JSON.stringify({schema:'apt.recording-source/1',platform:'stepx',recording_id:recording,lines:[]}),partial:true,deleted:false,...extra});
const producer={recording_id:recording,generation,control_version:0};
function fixture() {
  const replica=new RecordingMemoryReplica(':memory:');replica.sqlite.exec(readFileSync(new URL('../../worker/migrations/0003_recording_producers.sql',import.meta.url),'utf8'));
  const env={INPUT_MEMORY:replica.db,RECORDING_PRODUCER_TOKEN:'server-only-fixture'};
  const call=async(path,input,trusted=false)=>{
    const request=new Request('https://fixture/recording-memory/'+path,{method:'POST',headers:{'Content-Type':'application/json',...(trusted?{'X-APT-Producer':env.RECORDING_PRODUCER_TOKEN}:{})},body:JSON.stringify(input)});
    const response=await handleRecordingMemory(request,env,new URL(request.url));return {status:response.status,body:await response.json()};
  };
  const put=(records,owner,trusted=!!owner)=>call('sync',{schema:'apt.recording-memory.batch/1',device_id:device,records,...(owner?{producer:owner}:{})},trusted);
  const claim=async(sources=[])=>call('producer/claim',{device_id:device,recording_id:recording,generation,handoff_id:handoff,snapshot_digest:'a'.repeat(64),sources},true);
  const control=(control_version,state='revoked',mutation_id=crypto.randomUUID())=>call('producer/control',{device_id:device,recording_id:recording,generation,control_version,state,mutation_id},true);
  return {replica,call,put,claim,control};
}
test('atomic handoff rejects late old writers including direct original API and new source IDs',async()=>{
  const f=fixture();try {
    assert.equal((await f.put([record()])).status,200);
    const source={id,revision:1,fingerprint:await fingerprint({device_id:device,...record()})};
    assert.equal((await f.claim([source])).status,200);assert.equal((await f.claim([source])).status,200);
    assert.equal((await f.put([record(2)])).status,409);
    assert.equal((await f.put([record(2,{id:'apt_recording_'+crypto.randomUUID()})])).status,409);
    assert.equal((await f.put([record(2)],producer,false)).status,400);
    assert.equal((await f.put([record(2)],producer)).body.accepted.length,1);
    assert.equal((await f.control(1)).status,200);
    assert.equal((await f.put([record(3)],producer)).status,409);
    assert.equal((await f.put([record(3,{id:'apt_recording_'+crypto.randomUUID()})],{...producer,control_version:1})).status,409);
    assert.equal(f.replica.sqlite.prepare('SELECT deleted FROM recording_memory_sources').get().deleted,1);
  }finally{f.replica.close();}
});
test('claim set equality refuses new, changed or missing sources and never partially owns',async()=>{
  const f=fixture();try {
    await f.put([record()]);assert.equal((await f.claim()).status,409);
    assert.equal(f.replica.sqlite.prepare('SELECT count(*) n FROM recording_memory_owners').get().n,0);
    const source={id,revision:1,fingerprint:await fingerprint({device_id:device,...record()})};
    await f.put([record(2)]);assert.equal((await f.claim([source])).status,409);
  }finally{f.replica.close();}
});
test('control receipt replays after timeout, prevents ABA and invalidates all published sources before ACK',async()=>{
  const f=fixture();try {
    await f.claim();await f.put([record(),record(1,{id:'apt_recording_'+crypto.randomUUID()})],producer);
    const mutation=crypto.randomUUID();assert.equal((await f.control(1,'active',mutation)).status,200);
    assert.equal((await f.control(1,'active',mutation)).status,200);assert.equal((await f.control(1,'active')).status,409);
    assert.equal(f.replica.sqlite.prepare('SELECT count(*) n FROM recording_memory_sources WHERE deleted=0').get().n,0);
    assert.equal((await f.put([record(3)],producer)).status,409);
    assert.equal((await f.put([record(3)],{...producer,control_version:1})).status,200);
    assert.equal((await f.control(2)).status,200);assert.equal((await f.control(3,'active')).status,409);
  }finally{f.replica.close();}
});
test('fresh opaque IDs, foreign claim supersets and failed replays cannot steal an owner',async()=>{
  const f=fixture();try {
    const foreign=record(1,{id:'apt_recording_'+crypto.randomUUID(),text:JSON.stringify({schema:'apt.recording-source/1',platform:'stepx',recording_id:'66666666-6666-4666-8666-666666666666',lines:[]})});
    const saved=await f.put([record(),foreign]);f.replica.sqlite.exec('DELETE FROM recording_memory_records');
    assert.equal((await f.claim(saved.body.accepted)).status,409);
    assert.equal(f.replica.sqlite.prepare('SELECT count(*) n FROM recording_memory_owners').get().n,0);
    assert.equal((await f.claim(saved.body.accepted.filter(row=>row.id===id))).status,200);
    assert.equal((await f.put([record(1,{id:'apt_recording_'+crypto.randomUUID(),text:'opaque'})])).status,409);
    const retry=await f.call('producer/claim',{device_id:device,recording_id:recording,generation,handoff_id:handoff,snapshot_digest:'b'.repeat(64),sources:saved.body.accepted.filter(row=>row.id===foreign.id)},true);
    assert.equal(retry.status,409);assert.equal(f.replica.sqlite.prepare('SELECT count(*) n FROM recording_memory_records WHERE record_id=?').get(foreign.id).n,0);
  }finally{f.replica.close();}
});
test('legacy unmapped source cannot change recording ownership through stale or higher revisions',async()=>{
  const f=fixture();try {
    await f.put([record(100)]);f.replica.sqlite.exec('DELETE FROM recording_memory_records');
    for(const revision of [1,101])assert.equal((await f.put([record(revision,{text:JSON.stringify({schema:'apt.recording-source/1',platform:'stepx',recording_id:'66666666-6666-4666-8666-666666666666'})})])).status,409);
    assert.equal(f.replica.sqlite.prepare('SELECT revision FROM recording_memory_sources').get().revision,100);
    assert.equal(f.replica.sqlite.prepare('SELECT count(*) n FROM recording_memory_records').get().n,0);
  }finally{f.replica.close();}
});
test('a stale duplicate control cannot downgrade a newer publication; changed retry semantics conflict',async()=>{
  const f=fixture();try {
    const p=await f.put([record()]);await f.claim(p.body.accepted);
    const mutation=crypto.randomUUID(),raw=f.replica.db.batch.bind(f.replica.db);let injected=false;
    f.replica.db.batch=async statements=>{
      if(!injected&&statements[0].sql.startsWith('UPDATE recording_memory_owners')) {
        injected=true;assert.equal((await f.control(1,'active',mutation)).status,200);
        assert.equal((await f.put([record(3)],{...producer,control_version:1})).status,200);
      }
      return raw(statements);
    };
    assert.equal((await f.control(1,'active',mutation)).status,200);
    assert.deepEqual({...f.replica.sqlite.prepare('SELECT revision,deleted FROM recording_memory_sources').get()},{revision:3,deleted:0});
    assert.equal((await f.control(1,'revoked',mutation)).status,409);
  }finally{f.replica.close();}
});
test('a publication between tombstone hashing and CAS is included in the final withdrawal',async()=>{
  const f=fixture();try {
    await f.claim();await f.put([record()],producer);const raw=f.replica.db.batch.bind(f.replica.db);let injected=false;
    f.replica.db.batch=async statements=>{if(!injected&&statements[0].sql.startsWith('UPDATE recording_memory_owners')) {
      injected=true;assert.equal((await f.put([record(9),record(1,{id:'apt_recording_'+crypto.randomUUID()})],producer)).status,200);
    }return raw(statements);};
    assert.equal((await f.control(1)).status,200);
    assert.equal(f.replica.sqlite.prepare('SELECT count(*) n FROM recording_memory_sources WHERE deleted=0').get().n,0);
    assert.equal(f.replica.sqlite.prepare('SELECT revision FROM recording_memory_sources WHERE record_id=?').get(id).revision,10);
  }finally{f.replica.close();}
});
