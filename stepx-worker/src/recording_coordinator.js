// Durable coordinator for delegated read projections. Phone formal content remains authoritative.
import { storedStepXSeconds } from '../../worker/src/stepx_audio.js';
const UUID=/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
const HASH=/^[0-9a-f]{64}$/;
const respond=(value,status=200)=>Response.json(value,{status,headers:{'Cache-Control':'no-store'}});
const fail=code=>{throw Error(code);};
const sha=async value=>[...new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value)))].map(v=>v.toString(16).padStart(2,'0')).join('');
const audioHash=async value=>[...new Uint8Array(await crypto.subtle.digest('SHA-256',value))].map(v=>v.toString(16).padStart(2,'0')).join('');
const same=(a,b)=>JSON.stringify(a)===JSON.stringify(b);
const clone=value=>structuredClone(value);
const stable=value=>JSON.stringify(value,(_key,item)=>item&&typeof item==='object'&&!Array.isArray(item)
  ?Object.fromEntries(Object.keys(item).sort().map(key=>[key,item[key]])):item);
function scope(input) {
  if(!UUID.test(input.device_id??'')||!UUID.test(input.recording_id??'')||!UUID.test(input.generation??''))fail('invalid_background_identity');
}
function validSnapshot(input,control=false) {
  const s=input.snapshot;
  if(!s||s.matter?.id!==input.recording_id||!Number.isSafeInteger(s.matter.startedAt)||!control&&s.matter.recordingTimeUnverified
    ||!Array.isArray(s.segments)||!Array.isArray(s.jobs)||!Array.isArray(s.memory)
    ||s.segments.length>2000||s.jobs.length>2000||s.memory.length>30000)fail('invalid_background_snapshot');
  if(s.segments.some(p=>p.matterId!==input.recording_id||!control&&p.cloudEligible===false||!Number.isSafeInteger(p.index)||p.index<0
    ||!Number.isSafeInteger(p.capturedAt)||!control&&p.capturedAt<s.matter.startedAt||!Number.isFinite(p.durationSec)||p.durationSec<=0||p.durationSec>601))fail('invalid_background_segments');
  if(new Set(s.segments.map(p=>p.id)).size!==s.segments.length||new Set(s.segments.map(p=>p.index)).size!==s.segments.length
    ||s.jobs.some(j=>j.recordingId!==input.recording_id||(!j.id.startsWith('__actions__:')&&!s.segments.some(p=>p.id===j.id&&p.index===j.index))))fail('invalid_background_jobs');
  if(s.memory.some(m=>m.recordingId!==input.recording_id||!m.record?.id))fail('invalid_background_memory');
  return s;
}
function verifiedPrefix(snapshot) {
  if(!snapshot.captures?.length)return 0;
  if(!Array.isArray(snapshot.captures)||snapshot.captures.length>1000)fail('invalid_background_prefix');
  let index=0;
  const seen=new Set();
  for(const c of [...snapshot.captures].sort((a,b)=>a.indexBase-b.indexBase)) {
    if(!UUID.test(c.captureId??'')||seen.has(c.captureId)||c.matterId!==snapshot.matter.id||c.state!=='stopped'
      ||c.uploadRevoked||!UUID.test(c.uploadClient??'')||c.indexBase!==index||!Number.isSafeInteger(c.frames)||c.frames<0
      ||!Number.isSafeInteger(c.startedAt)||c.startedAt<snapshot.matter.startedAt||![300,600].includes(c.chunkSeconds))fail('invalid_background_prefix');
    seen.add(c.captureId);
    const pieces=snapshot.segments.filter(p=>p.id.startsWith(`root:${c.captureId}:`)).sort((a,b)=>a.index-b.index);
    let frames=0;
    for(const [i,p] of pieces.entries()) {
      const j=snapshot.jobs.find(row=>row.id===p.id),r=p.rootUpload;
      const compact=p.rootAudioFormat==='m4a',format=compact?'m4a':'wav';
      const count=Math.round(p.durationSec*16000);
      if(p.id!==`root:${c.captureId}:${i}`||p.index!==index+i||r?.captureId!==c.captureId||r.piece!==i||r.client!==c.uploadClient
        ||!HASH.test(r.sha256??'')||!j?.uploaded||!j.remoteKey?.startsWith(`stepx/${c.uploadClient}/${snapshot.matter.id}/`)
        ||!j.remoteKey.endsWith(`-${r.sha256}.${format}`)||!Number.isSafeInteger(count)||Math.abs(p.durationSec*16000-count)>1e-6
        ||count!==Math.min(c.chunkSeconds*16000,c.frames-frames)
        ||(compact?c.audioFormat!=='m4a'||!Number.isSafeInteger(p.sizeBytes)||p.sizeBytes<46||p.sizeBytes>44+count*2
          :p.sizeBytes!==44+count*2)||p.capturedAt!==Math.floor(c.startedAt+frames*1000/16000))fail('invalid_background_prefix');
      frames+=count;
    }
    if(frames!==c.frames)fail('invalid_background_prefix');index+=pieces.length;
  }
  if(index!==snapshot.segments.length)fail('invalid_background_prefix');return index;
}
export class RecordingCoordinator {
  constructor(ctx,env,call,loadRuntime=()=>import('./recording_runtime.ts')) {
    this.storage=ctx.storage;this.env=env;this.call=call;this.loadRuntime=loadRuntime;this.running=false;
  }
  transition(apply) {
    const next=(this.transitioning??Promise.resolve()).catch(()=>undefined).then(apply);
    this.transitioning=next.catch(()=>undefined);return next;
  }
  async upstream(path,value) {
    if(!this.env.GROWTH_UPSTREAM||!this.env.RECORDING_PRODUCER_TOKEN)fail('background_not_configured');
    const response=await this.env.GROWTH_UPSTREAM.fetch(new Request('https://apt-backend.example'+path,{
      method:'POST',redirect:'manual',signal:AbortSignal.timeout(30000),headers:{'Content-Type':'application/json',
        'X-Growth-Token':this.env.GROWTH_CLIENT_TOKEN,'X-APT-Producer':this.env.RECORDING_PRODUCER_TOKEN},body:JSON.stringify(value)}));
    let result;try{result=await response.json();}catch{fail('background_upstream_unknown');}
    if(!response.ok)throw Object.assign(Error(result?.error??'background_upstream_unknown'),{code:result?.error,status:response.status});
    return result;
  }
  async blob(value) {
    const body=JSON.stringify(value),digest=await sha(body);
    if(new TextEncoder().encode(body).length>8*1024*1024)fail('background_artifact_capacity');
    const key=`stepx-background/artifacts/${digest}.json`;
    await this.env.AUDIO.put(key,body,{httpMetadata:{contentType:'application/json'}});
    return {key,sha256:digest};
  }
  async unblob(ref) {
    if(!ref||!HASH.test(ref.sha256??'')||ref.key!==`stepx-background/artifacts/${ref.sha256}.json`)fail('invalid_background_artifact');
    const object=await this.env.AUDIO.get(ref.key);
    if(!object||object.size>8*1024*1024)fail('background_artifact_missing');
    const body=await object.text();if(await sha(body)!==ref.sha256)fail('background_artifact_fingerprint');return JSON.parse(body);
  }
  async fence(expected,apply,wake=false) {
    return this.storage.transaction(async tx=>{
      const current=await tx.get('head');
      if(!current||current.generation!==expected.generation||current.control_version!==expected.control_version
        ||current.phase!=='active')fail('recording_producer_fenced');
      const result=await apply(tx,current);
      if(wake){const head=await tx.get('head');await tx.put('head',{...head,workVersion:(head.workVersion??0)+1});
        await this.storage.setAlarm(Date.now()+1000);}
      return result;
    });
  }
  async putJob(head,job) {
    const row=await this.jobRow(job);
    await this.fence(head,async tx=>{
      const jobs=await tx.list({prefix:'job:'});
      if([...jobs.values()].reduce((sum,j)=>sum+(j.id===job.id?0:j.bytes??0),row.bytes)>16*1024*1024)fail('background_material_capacity');
      await tx.put('job:'+job.id,row);
    });
  }
  async jobRow(job) {
    const body=JSON.stringify(job),bytes=new TextEncoder().encode(body).length,ref=await this.blob(job);
    return {id:job.id,index:job.index,state:job.state,nextAt:job.nextAt??0,bytes,ref,...(bytes<=65536?{data:job}:{})};
  }
  async modelCall(head,path,body) {
    await this.fence(head,()=>undefined);
    if(path==='/asr/submit') {
      const manifest=[...(await this.storage.list({prefix:'manifest:'})).values()].find(row=>row.key===body.key);
      if(manifest){const object=await this.env.AUDIO.head(body.key);
        if(object?.etag!==manifest.object_etag||object?.size!==(manifest.object_size??44+manifest.frames*2)
          ||storedStepXSeconds(object,body.key)!==manifest.frames/16000)fail('background_audio_changed');}
    }
    return this.call(path,body);
  }
  async source(head,cache=new Map()) {
    const [pieces,jobs]=await Promise.all([this.storage.list({prefix:'piece:'}),this.storage.list({prefix:'job:'})]);
    const hydrated=[];
    // Read in bounded groups; R2 artifacts keep the DO's per-value limit independent of transcript size.
    const refs=[...jobs.values()];
    if(refs.reduce((sum,row)=>sum+(row.bytes??0),0)>16*1024*1024)fail('background_material_capacity');
    for(let i=0;i<refs.length;i+=8)hydrated.push(...await Promise.all(refs.slice(i,i+8).map(async row=>{
      if(row.data)return clone(row.data);
      if(!cache.has(row.ref.sha256))cache.set(row.ref.sha256,await this.unblob(row.ref));return clone(cache.get(row.ref.sha256));
    })));
    return {matters:[clone(head.matter)],segments:[...pieces.values()].sort((a,b)=>a.index-b.index),jobs:hydrated};
  }
  async claim(input) {
    const snapshot=validSnapshot(input);
    const prefixIndex=verifiedPrefix(snapshot);
    if(!UUID.test(input.handoff_id??''))fail('invalid_background_handoff');
    const digest=await sha(stable(snapshot));
    const current=await this.storage.get('head');
    if(current) {
      if(current.generation!==input.generation||current.handoff_id!==input.handoff_id||current.snapshot_digest!==digest)fail('background_handoff_conflict');
    }else {
      // This record is immutable. A crash at any later step resumes the same snapshot.
      const ref=await this.blob(snapshot);
      await this.storage.transaction(async tx=>{
        if(await tx.get('head'))fail('background_handoff_conflict');
        await tx.put('head',{device_id:input.device_id,recording_id:input.recording_id,generation:input.generation,
          handoff_id:input.handoff_id,snapshot_digest:digest,control_version:0,phase:'claiming',matter:clone(snapshot.matter),
          phoneMatter:clone(snapshot.matter),phoneSegments:snapshot.segments.map(row=>row.id),snapshot:ref,prefixIndex});
        await this.storage.setAlarm(Date.now()+1000);
      });
    }
    await this.storage.setAlarm(Date.now()+1000);await this.resumeClaim();
    if(input.transport){const head=await this.storage.get('head');return {schema:'apt.background-claim/1',generation:head.generation,
      device_id:head.device_id,recording_id:head.recording_id,phase:head.phase,control_version:head.control_version};}
    return this.status(input);
  }
  resumeClaim() { return this.transition(()=>this.applyClaim()); }
  async applyClaim() {
    const head=await this.storage.get('head');if(head?.phase!=='claiming')return;
    const snapshot=await this.unblob(head.snapshot),runtime=await this.loadRuntime();
    const sources=await Promise.all(snapshot.memory.map(async row=>({id:row.record.id,revision:row.record.revision,tombstone:row.record.deleted,
      fingerprint:await sha(JSON.stringify(runtime.canonicalRecording(row.record,head.device_id)))})));
    const current=await this.upstream('/recording-memory/producer/status',head);
    const recovered=current.owner?.generation===head.generation&&current.owner?.handoff_id===head.handoff_id
      &&current.owner?.snapshot_digest===head.snapshot_digest;
    if(current.owner&&!recovered)fail('background_handoff_conflict');
    // A lost ownership receipt must not replay an ordinary phone write after the switch.
    for(let offset=0;!recovered&&offset<snapshot.memory.length;offset+=100) {
      const records=snapshot.memory.slice(offset,offset+100).map(row=>row.record);
      const receipt=await this.upstream('/recording-memory/sync',{schema:'apt.recording-memory.batch/1',device_id:head.device_id,records});
      if(receipt.stale?.length||receipt.conflicts?.length||receipt.accepted?.length!==records.length
        ||records.some(record=>!receipt.accepted.some(row=>row.id===record.id&&row.revision===record.revision
          &&row.fingerprint===sources.find(source=>source.id===record.id)?.fingerprint)))fail('background_handoff_sources_changed');
    }
    const owner=await this.upstream('/recording-memory/producer/claim',{...head,sources,snapshot:undefined,matter:undefined});
    if(owner.generation!==head.generation||owner.control_version!==0||owner.state!=='active')fail('background_handoff_receipt');
    // Seed under the durable claiming phase; repeatable after any crash, never after activation.
    for(const segment of snapshot.segments)await this.storage.put('piece:'+segment.id,segment);
    for(const job of snapshot.jobs) {
      const row=await this.jobRow(job);
      if(job.id.startsWith('__actions__:'))await this.storage.put('actions',{ref:row.ref});
      else await this.storage.put('job:'+job.id,row);
    }
    for(const row of snapshot.memory)await this.storage.put('memory:'+row.id,{...row,controlVersion:0,acknowledged:row.record.revision});
    await this.storage.transaction(async tx=>{
      const current=await tx.get('head');if(current.phase==='claiming'&&current.generation===head.generation)await tx.put('head',{...current,phase:'active'});
    });
  }
  async piece(input) {
    const head=await this.storage.get('head');if(!head||head.generation!==input.generation||head.phase!=='active')fail('recording_producer_fenced');
    const p=input.piece;
    if(!p||!UUID.test(p.capture_id??'')||!Number.isSafeInteger(p.piece)||p.piece<0||p.piece>999
      ||!Number.isSafeInteger(p.index_base)||p.index_base<0||!Number.isSafeInteger(p.frames)||p.frames<=0||p.frames>16000*601
      ||!Number.isSafeInteger(p.frame_offset)||p.frame_offset<0||!Number.isSafeInteger(p.captured_at)||p.captured_at<head.matter.startedAt
      ||!HASH.test(p.sha256??'')||!UUID.test(p.upload_client??''))fail('invalid_background_piece');
    const id=`root:${p.capture_id}:${p.piece}`,index=p.index_base+p.piece;
    const hash=await sha(id),pieceId=`${hash.slice(0,8)}-${hash.slice(8,12)}-${hash.slice(12,16)}-${hash.slice(16,20)}-${hash.slice(20,32)}`;
    const compact=typeof p.key==='string'&&p.key.endsWith('.m4a');
    const expectedKey=`stepx/${p.upload_client}/${head.recording_id}/${pieceId}-${p.sha256}.${compact?'m4a':'wav'}`;
    if(p.key!==expectedKey)fail('background_piece_key_mismatch');
    const object=await this.env.AUDIO.get(p.key);
    if(storedStepXSeconds(object,p.key)!==p.frames/16000)fail('background_piece_not_uploaded');
    if(await audioHash(await object.arrayBuffer())!==p.sha256)fail('background_audio_fingerprint_mismatch');
    const segment={id,matterId:head.recording_id,index,capturedAt:p.captured_at,durationSec:p.frames/16000,
      sizeBytes:object.size,stage:'recorded',attempts:0,cloudEligible:true,...(compact?{rootAudioFormat:'m4a'}:{}),
      rootUpload:{captureId:p.capture_id,piece:p.piece,sha256:p.sha256,client:p.upload_client}};
    const [exclusions,knownPieces]=await Promise.all([this.storage.list({prefix:'excluded:'}),this.storage.list({prefix:'piece:'})]);
    const breaks=[...exclusions.values()].map(row=>row.index).concat([...knownPieces.values()].filter(row=>row.cloudEligible===false).map(row=>row.index));
    const semanticStart=Math.max(-1,...breaks.filter(value=>value<index))+1;
    const jobRow=await this.jobRow({id,recordingId:head.recording_id,index,semanticStart,state:'transcribing',nextAt:0,attempts:0,
      remoteKey:p.key,session:`stepx_${p.upload_client}_${head.recording_id}`,seconds:p.frames/16000,uploaded:true});
    await this.fence(head,async tx=>{
      const prior=await tx.get('manifest:'+id);
      if(prior&&!Object.keys(p).every(k=>same(prior[k],p[k])))fail('background_piece_conflict');
      const pieces=await tx.list({prefix:'piece:'});
      if([...pieces.values()].some(row=>row.index===index&&row.id!==id))fail('background_piece_index_conflict');
      await tx.put('manifest:'+id,{...p,object_etag:object.etag,object_size:object.size});
      if(!await tx.get('excluded:'+id)) {
        if(!await tx.get('piece:'+id))await tx.put('piece:'+id,segment);
        if(!await tx.get('job:'+id)) {
          if(pieces.size>=2000||[...(await tx.list({prefix:'job:'})).values()].reduce((sum,j)=>sum+(j.bytes??0),jobRow.bytes)>16*1024*1024)
            fail('background_material_capacity');
          await tx.put('job:'+id,jobRow);
        }
      }
      const current=await tx.get('head');if(current.capacityError)await tx.put('head',{...current,capacityError:false,error:null});
    },true);
    await this.storage.setAlarm(Date.now()+1000);
    return {schema:'apt.background-piece/1',device_id:head.device_id,recording_id:head.recording_id,generation:head.generation,
      capture_id:p.capture_id,piece:p.piece,sha256:p.sha256,key:p.key,frames:p.frames};
  }
  async capture(input) {
    const head=await this.storage.get('head'),c=input.capture;
    if(!head||head.generation!==input.generation||head.phase!=='active')fail('recording_producer_fenced');
    if(!c||!UUID.test(c.capture_id??'')||!Number.isSafeInteger(c.index_base)||c.index_base<0||!Number.isSafeInteger(c.frames)||c.frames<0
      ||!Number.isSafeInteger(c.started_at)||c.started_at<head.matter.startedAt||!Number.isSafeInteger(c.chunk_frames)||c.chunk_frames<80000||c.chunk_frames>16000*600
      ||typeof c.closed!=='boolean'||typeof c.finish!=='boolean'||(c.finish&&(!c.closed||!Number.isSafeInteger(c.ended_at)||c.ended_at<c.started_at)))fail('invalid_background_capture');
    await this.fence(head,async(tx,current)=>{
      const prior=await tx.get('capture:'+c.capture_id);
      if(prior&&(!['index_base','started_at','chunk_frames'].every(k=>prior[k]===c[k])||prior.closed&&(!c.closed||prior.frames!==c.frames
        ||prior.finish&&(!c.finish||prior.ended_at!==c.ended_at))))fail('background_capture_conflict');
      await tx.put('capture:'+c.capture_id,c);
      if(!prior&&(!current.formalClose||current.phoneMatter?.endedAt===null))
        await tx.put('head',{...current,formalClose:false,matter:{...current.matter,endedAt:null,captureComplete:false}});},true);
    await this.storage.setAlarm(Date.now()+1000);
    return {schema:'apt.background-capture/1',capture_id:c.capture_id,frames:c.frames,closed:c.closed,finish:c.finish};
  }
  async closeMatter(head) {
    if(head.formalClose)return head;
    const captures=[...(await this.storage.list({prefix:'capture:'})).values()].sort((a,b)=>a.index_base-b.index_base);
    if(!captures.length||!captures.at(-1).finish)return head;
    const manifests=[...(await this.storage.list({prefix:'manifest:'})).values()];let index=head.prefixIndex??0;
    for(const capture of captures) {
      if(!capture.closed||capture.index_base!==index)return head;
      const pieces=manifests.filter(p=>p.capture_id===capture.capture_id).sort((a,b)=>a.piece-b.piece);
      let frames=0;
      for(const [i,p] of pieces.entries()) {
        if(p.piece!==i||p.index_base!==capture.index_base||p.frame_offset!==frames||p.captured_at!==Math.floor(capture.started_at+frames*1000/16000)
          ||p.frames!==Math.min(capture.chunk_frames,capture.frames-frames))return head;
        frames+=p.frames;
      }
      if(frames!==capture.frames)return head;index+=pieces.length;
    }
    const matter={...head.matter,endedAt:captures.at(-1).ended_at,captureComplete:true,rootFinalizing:false};
    return this.fence(head,async(tx,current)=>{
      if(current.workVersion!==head.workVersion)return current;
      const next={...current,matter};await tx.put('head',next);return next;
    });
  }
  async control(input) {
    const head=await this.storage.get('head');
    if(!head||head.generation!==input.generation||!UUID.test(input.mutation_id??'')||!Number.isSafeInteger(input.control_version)
      ||!['active','revoked'].includes(input.state))fail('invalid_background_control');
    const digest=await sha(stable(input));
    if(head.control_version===input.control_version) {
      if(head.control_digest!==digest)fail('background_control_conflict');
    }else {
      if(head.phase!=='active'||head.control_version!==input.control_version-1)fail('background_control_conflict');
      if(input.state!=='revoked')validSnapshot(input,true);
      const plan=input.state==='revoked'?undefined:await this.blob(await this.controlPlan(head,input));
      const ref=await this.blob(input);
      await this.fence(head,(tx,current)=>{
        if(current.workVersion!==head.workVersion)fail('background_control_conflict');
        return tx.put('head',{...current,phase:'controlling',control_version:input.control_version,
          control_digest:digest,control:ref,controlPlan:plan});
      },true);
    }
    await this.storage.setAlarm(Date.now()+1000);await this.resumeControl();return this.status(input);
  }
  async revoke(input) {
    if(!UUID.test(input.mutation_id??''))fail('invalid_background_revocation');
    await this.transition(async()=>{
      let head=await this.storage.get('head');if(!head||head.generation!==input.generation)fail('recording_producer_fenced');
      if(head.phase==='revoked')return;
      let status=await this.upstream('/recording-memory/producer/status',head);
      if(!status.owner){await this.applyClaim();head=await this.storage.get('head');status=await this.upstream('/recording-memory/producer/status',head);}
      if(status.owner?.generation!==head.generation)fail('recording_producer_fenced');
      if(status.owner.state==='revoked'){await this.storage.put('head',{...head,phase:'revoked',control_version:status.owner.control_version});return;}
      const control={...input,control_version:status.owner.control_version+1,state:'revoked'},ref=await this.blob(control);
      // Native deletion may supersede a failed edit; it never waits for model/artifact repair.
      const digest=await sha(stable(control));
      await this.storage.transaction(async tx=>{const current=await tx.get('head');
        await tx.put('head',{...current,phase:'controlling',control_version:control.control_version,
          control:ref,control_digest:digest,controlPlan:undefined,workVersion:(current.workVersion??0)+1});
        await this.storage.setAlarm(Date.now()+1000);});
      await this.applyControl();
    });
    const current=await this.storage.get('head');
    return {schema:'apt.background-revocation/1',device_id:current.device_id,recording_id:current.recording_id,
      generation:current.generation,control_version:current.control_version,phase:current.phase};
  }
  resumeControl() { return this.transition(()=>this.applyControl()); }
  async applyControl() {
    let head=await this.storage.get('head');if(head?.phase!=='controlling')return;
    const input=await this.unblob(head.control);
    let plan;
    if(input.state!=='revoked') {
      if(head.controlPlan)plan=await this.unblob(head.controlPlan);
      else {plan=await this.controlPlan(head,input);const ref=await this.blob(plan);
        head={...head,controlPlan:ref};await this.storage.put('head',head);}
    }
    const receipt=await this.upstream('/recording-memory/producer/control',{device_id:head.device_id,recording_id:head.recording_id,
      generation:head.generation,control_version:head.control_version,state:input.state,mutation_id:input.mutation_id});
    if(receipt.control_version!==head.control_version||receipt.state!==input.state)fail('background_control_receipt');
    // Future publications exceed even an upload whose receipt was lost before this control.
    const rows=await this.storage.list({prefix:'memory:'});
    for(const [key,row] of rows)if(row.controlVersion!==head.control_version)await this.storage.put(key,{...row,controlVersion:head.control_version,record:{...row.record,revision:row.record.revision+2,
      title:'已移出记忆',text:'',deleted:true,updated:new Date().toISOString()},acknowledged:0});
    if(input.state==='revoked'){await this.storage.put('head',{...head,phase:'revoked'});return;}
    for(const row of plan.archive)await this.storage.put('archive-job:'+row.id,row);
    for(const row of plan.excluded){await this.storage.put('excluded:'+row.id,{index:row.index,controlVersion:head.control_version});await this.storage.delete('piece:'+row.id);await this.storage.delete('job:'+row.id);}
    for(const segment of plan.segments){await this.storage.delete('excluded:'+segment.id);await this.storage.put('piece:'+segment.id,segment);}
    for(const row of plan.jobs)await this.storage.put('job:'+row.id,row);
    if(plan.resetActions)await this.storage.delete('actions');
    await this.storage.put('head',{...head,matter:plan.matter,phoneMatter:plan.phoneMatter,phoneSegments:plan.phoneSegments,formalClose:plan.formalClose,
      actionsRequested:head.actionsRequested||input.retry==='actions',capacityError:false,error:null,phase:'active'});
  }
  async controlPlan(head,input) {
    const snapshot=validSnapshot(input,true),old=await this.source(head);
    if(input.removed_ids!==undefined&&(!Array.isArray(input.removed_ids)||input.removed_ids.length>2000
      ||input.removed_ids.some(id=>typeof id!=='string'||id.length>200)))fail('invalid_background_removals');
    const known=new Set([...(head.phoneSegments??[]),...(input.removed_ids??[])]),phoneSelected=new Set(snapshot.segments.map(row=>row.id));
    // Absence on an offline phone is not removal of a native piece it has never received.
    const segments=[...snapshot.segments,...old.segments.filter(row=>!phoneSelected.has(row.id)&&!known.has(row.id))];
    if(segments.length>2000||new Set(segments.map(row=>row.index)).size!==segments.length)fail('background_piece_index_conflict');
    const selected=new Set(segments.map(row=>row.id));
    const exclusions=new Map(old.segments.filter(row=>!selected.has(row.id)).map(row=>[row.id,{id:row.id,index:row.index}]));
    for(const id of input.removed_ids??[])if(!selected.has(id)&&!exclusions.has(id)) {
      const index=input.removed_indices?.[id];if(!Number.isSafeInteger(index)||index<0||index>20000)fail('invalid_background_removals');
      exclusions.set(id,{id,index});
    }
    const oldMeta=[...(await this.storage.list({prefix:'job:'})).values()],archive=[];
    let changed=head.matter.startedAt!==snapshot.matter.startedAt?0:Infinity;
    const keys=['index','capturedAt','durationSec','sizeBytes','cloudEligible'];
    for(const before of old.segments) {
      const after=segments.find(row=>row.id===before.id);
      if(!after||keys.some(key=>before[key]!==after[key]))changed=Math.min(changed,before.index,after?.index??Infinity);
    }
    for(const job of snapshot.jobs.filter(row=>!row.id.startsWith('__'))) {
      const before=old.jobs.find(row=>row.id===job.id);
      if(job.lines!==undefined&&!same(before?.lines,job.lines))changed=Math.min(changed,job.index);
    }
    const breaks=[...(await this.storage.list({prefix:'excluded:'})).values()].map(row=>row.index)
      .concat([...exclusions.values()].map(row=>row.index),segments.filter(row=>row.cloudEligible===false).map(row=>row.index));
    const jobs=[],runtime=await this.loadRuntime();
    for(const segment of segments) {
      let prior=old.jobs.find(row=>row.id===segment.id);
      if(!prior){const saved=await this.storage.get('archive-job:'+segment.id);if(saved)prior=await this.unblob(saved.ref);}
      const formal=snapshot.jobs.find(row=>row.id===segment.id);
      if(!prior)prior=formal;if(!prior)continue;
      let next={...clone(prior),index:segment.index,semanticStart:Math.max(-1,...breaks.filter(value=>value<segment.index))+1},lines=formal?.lines===undefined?next.lines:clone(formal.lines);
      const original=old.segments.find(row=>row.id===segment.id);
      const delta=original?((segment.capturedAt-snapshot.matter.startedAt)-(original.capturedAt-head.matter.startedAt))/1000:0;
      if(delta&&(formal?.lines===undefined||same(prior.lines,formal.lines)))lines=lines?.map(line=>({...line,t_sec:line.t_sec+delta,t_end_sec:line.t_end_sec+delta}));
      if(segment.index>=changed&&lines!==undefined)next={...next,lines,lineRevision:Math.max(prior.lineRevision??0,formal?.lineRevision??0)+1,
        index:segment.index,state:lines.length?'extracting':'done',events:[],requestLines:undefined,requestRevision:undefined,
        personalEvaluation:undefined,ticket:undefined,nextAt:0,extractPart:(prior.extractPart??prior.index)+100000};
      if((next.extractPart??0)>999999)next={...next,state:'failed',error:'整理重试已达上限，原话仍已保留'};
      if(input.retry==='failed'&&next.state==='failed')next=runtime.retryProcessingJob(next);
      jobs.push(await this.jobRow(next));
    }
    for(const row of oldMeta)if(!selected.has(row.id))archive.push(row);
    if(jobs.reduce((sum,row)=>sum+row.bytes,0)>16*1024*1024)fail('background_material_capacity');
    // The phone can finish before asynchronous native preparation publishes the tail.
    // This temporary partial projection must not fence the native closed-frame proof.
    const lifecycleChanged=snapshot.matter.rootFinalizing!==true
      && ['endedAt','captureComplete'].some(key=>snapshot.matter[key]!==((head.phoneMatter??head.matter)[key]));
    const matter={...snapshot.matter,...(lifecycleChanged?{}:{endedAt:head.matter.endedAt,captureComplete:head.matter.captureComplete})};
    return {segments,jobs,archive,excluded:[...exclusions.values()],
      matter,phoneMatter:snapshot.matter,phoneSegments:snapshot.segments.map(row=>row.id),formalClose:head.formalClose||lifecycleChanged,
      resetActions:Number.isFinite(changed)||head.matter.personalActionsEnabled!==snapshot.matter.personalActionsEnabled
        ||input.retry==='actions'&&await this.actionsRetryable()};
  }
  async actionsRetryable() {
    const row=await this.storage.get('actions');if(!row)return false;
    return ['done','failed'].includes((await this.unblob(row.ref)).state);
  }
  async publish(head,source,runtime) {
    const desired=runtime.projectRecordingMemory(source),wanted=new Set(desired.map(row=>row.id));
    const existing=await this.storage.list({prefix:'memory:'}),now=new Date().toISOString();
    for(const value of desired) {
      const key='memory:'+value.id,prior=existing.get(key);
      if(prior&&!prior.record.deleted&&['created','title','text','partial'].every(k=>prior.record[k]===value[k]))continue;
      const row={id:value.id,recordingId:value.recordingId,jobId:value.jobId,acknowledged:0,controlVersion:head.control_version,
        record:{id:prior?.record.id??'apt_recording_'+crypto.randomUUID(),revision:(prior?.record.revision??0)+1,
          created:value.created,updated:new Date(Math.max(Date.parse(now),Date.parse(value.created))).toISOString(),
          title:value.title,text:value.text,partial:value.partial,deleted:false}};
      await this.fence(head,tx=>tx.put(key,row));existing.set(key,row);
    }
    for(const [key,row] of existing)if(!wanted.has(row.id)&&!row.record.deleted) {
      const next={...row,acknowledged:0,record:{...row.record,revision:row.record.revision+1,title:'已移出记忆',text:'',deleted:true,updated:now}};
      await this.fence(head,tx=>tx.put(key,next));existing.set(key,next);
    }
    const pending=[...existing.entries()].filter(([,row])=>row.acknowledged!==row.record.revision);
    // A transcript is indivisible, including its old tombstones and replacement rows.
    // Graveyards may drain first; live material is never cut into a falsely complete prefix.
    if(!pending.length)return;
    const first=pending.find(([,row])=>row.record.deleted)??pending[0];
    let batch=pending.filter(([,row])=>row.jobId===first[1].jobId);
    if(batch.every(([,row])=>row.record.deleted)) {
      const liveJobs=new Set(pending.filter(([,row])=>!row.record.deleted).map(([,row])=>row.jobId));
      batch=pending.filter(([,row])=>row.record.deleted&&!liveJobs.has(row.jobId)).slice(0,1000);
    }
    const bytes=batch.reduce((sum,[,row])=>sum+new TextEncoder().encode(JSON.stringify(row.record)).length+1,200);
    if(batch.length>2000||bytes>7*1024*1024)batch=batch.filter(([,row])=>row.record.deleted).slice(0,1000);
    if(!batch.length)fail('background_transcript_capacity');
    const records=batch.map(([,row])=>row.record);
    const receipt=await this.upstream('/recording-memory/sync',{schema:'apt.recording-memory.batch/1',device_id:head.device_id,records,
      producer:{recording_id:head.recording_id,generation:head.generation,control_version:head.control_version}});
    if(receipt.accepted?.length!==records.length||receipt.stale?.length||receipt.conflicts?.length)fail('background_publication_conflict');
    const hashes=await Promise.all(records.map(record=>sha(JSON.stringify(runtime.canonicalRecording(record,head.device_id)))));
    for(let i=0;i<batch.length;i++) {
      const [key,row]=batch[i];
      if(!receipt.accepted.some(saved=>saved.id===row.record.id&&saved.revision===row.record.revision&&saved.fingerprint===hashes[i]))fail('background_publication_receipt');
      await this.fence(head,async tx=>{const current=await tx.get(key);if(same(current?.record,row.record))await tx.put(key,{...current,acknowledged:row.record.revision});});
    }
  }
  async alarm() {
    if(this.running)return;this.running=true;
    // The next alarm exists before any network call. Isolate death is recoverable.
    await this.storage.setAlarm(Date.now()+60000);
    try {
      await this.resumeClaim();await this.resumeControl();
      let head=await this.storage.get('head');if(head?.phase!=='active')return;
      const runtime=await this.loadRuntime();head=await this.closeMatter(head);
      const cache=new Map();let source=await this.source(head,cache);
      const eligibleJobs=source.jobs.filter(job=>!source.matters[0].recordingTimeUnverified
        &&source.segments.some(piece=>piece.id===job.id&&piece.cloudEligible!==false));
      const readyJob=job=>!job.lines||source.segments.filter(p=>p.index>=(job.semanticStart??0)&&p.index<=job.index).length===job.index-(job.semanticStart??0)+1
          &&source.jobs.every(prior=>prior.index<(job.semanticStart??0)||prior.index>=job.index||prior.state==='done');
      const next=[...eligibleJobs].filter(job=>!job.id.startsWith('__')&&!['done','failed'].includes(job.state)&&job.nextAt<=Date.now())
        .sort((a,b)=>(a.lines===undefined?0:1)-(b.lines===undefined?0:1)||a.index-b.index)
        .find(readyJob);
      if(next) {
        try{await runtime.advance(source,clone(next),(path,body)=>this.modelCall(head,path,body),job=>this.putJob(head,job));}
        catch(error) {
          if(error.message==='recording_producer_fenced')return;
          const retry=['offline','unknown_result','network_failed','asr_submission_unknown','upstream_unavailable','processing_failed'].includes(error.code??error.message);
          const saved=await this.storage.get('job:'+next.id),latest=saved?await this.unblob(saved.ref):next;
          await this.putJob(head,{...latest,state:retry?latest.state:'failed',nextAt:Date.now()+30000,
            failureCode:error.code??'invalid_result',error:retry?'后台等待原处理回执':'后台处理未完成，原音频已保留'});
        }
        source=await this.source(head,cache);
      }
      await this.publish(head,source,runtime);
      const actions=await this.storage.get('actions');
      if(!source.matters[0].recordingTimeUnverified)await runtime.wholeActions(head.actionsRequested?
        {...source,matters:[{...source.matters[0],personalActionsEnabled:true}]}:source,actions?await this.unblob(actions.ref):undefined,(path,body)=>this.modelCall(head,path,body),async row=>{
        const ref=await this.blob(row);await this.fence(head,tx=>tx.put('actions',{ref}));
      });
      await this.fence(head,(tx,current)=>tx.put('head',{...current,lastSuccess:Date.now(),error:current.capacityError?current.error:null}));
      const pending=(await this.storage.list({prefix:'memory:'})),evaluation=await this.storage.get('actions');
      const actionPending=evaluation&&!['done','failed'].includes((await this.unblob(evaluation.ref)).state);
      await this.fence(head,async(tx,current)=>{
        if(current.workVersion!==head.workVersion)return;
        if(eligibleJobs.some(j=>!['done','failed'].includes(j.state)&&readyJob(j))||[...pending.values()].some(row=>row.acknowledged!==row.record.revision)
          ||actionPending)await this.storage.setAlarm(Date.now()+5000);
        else await this.storage.deleteAlarm();
      });
    }catch(error) {
      await this.storage.transaction(async tx=>{const head=await tx.get('head');
        if(head)await tx.put('head',{...head,error:'后台等待连接或核对持久回执',errorCode:String(error.code??error.message).slice(0,120)});});
    }finally{this.running=false;}
  }
  async status(input) {
    const head=await this.storage.get('head');if(!head||head.generation!==input.generation)fail('background_not_found');
    const jobs=[...(await this.storage.list({prefix:'job:'})).values()],memory=[...(await this.storage.list({prefix:'memory:'})).values()];
    return {schema:'apt.background-status/1',device_id:head.device_id,recording_id:head.recording_id,generation:head.generation,
      control_version:head.control_version,phase:head.phase,matter:head.matter,jobs:jobs.map(({data,...row})=>row),
      memory:{sources:memory.filter(row=>!row.record.deleted).length,pending:memory.filter(row=>row.record.revision!==row.acknowledged).length,
        partial:memory.some(row=>!row.record.deleted&&row.record.partial)},
      actions:await this.storage.get('actions')??null,lastSuccess:head.lastSuccess??null,error:head.error??null};
  }
  async fetch(request) {
    try {
      const input=await request.json();scope(input);const route=new URL(request.url).pathname;
      const stored=await this.storage.get('head');
      if(stored&&(stored.device_id!==input.device_id||stored.recording_id!==input.recording_id))fail('background_namespace_mismatch');
      if(route==='/claim')return respond(await this.claim(input));
      if(route==='/piece')return respond(await this.piece(input));
      if(route==='/capture')return respond(await this.capture(input));
      if(route==='/control')return respond(await this.control(input));
      if(route==='/revoke')return respond(await this.revoke(input));
      if(route==='/status')return respond(await this.status(input));
      if(route==='/artifact') {
        if(!stored||stored.generation!==input.generation||stored.phase!=='active'||stored.control_version!==input.control_version)fail('recording_producer_fenced');
        // A caller can read only this recording's current reference, never arbitrary R2.
        const job=input.job_id==='__actions__'?await this.storage.get('actions'):await this.storage.get('job:'+input.job_id);
        if(!job?.ref)fail('background_artifact_missing');
        return respond({schema:'apt.background-artifact/1',generation:stored.generation,control_version:stored.control_version,
          job:await this.unblob(job.ref)});
      }
      return respond({error:'not_found'},404);
    }catch(error){
      if(error.message==='background_material_capacity')await this.storage.transaction(async tx=>{
        const head=await tx.get('head');if(head?.phase==='active')await tx.put('head',{...head,capacityError:true,
          error:'这场录音的处理材料超出容量，原音频与已有结果已保留；请缩小处理范围后重试'});
      });
      return respond({error:error.message??'background_unavailable'},error.message?.includes('conflict')||error.message?.includes('fenced')?409:400);
    }
  }
}
