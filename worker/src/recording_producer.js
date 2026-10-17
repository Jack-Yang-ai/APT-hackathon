import { body, fingerprint } from './input_memory.js';
const UUID=/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
const ID=/^apt_recording_[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
const HASH=/^[0-9a-f]{64}$/;
const reply=(value,status=200)=>Response.json(value,{status,headers:{'Cache-Control':'no-store'}});
export async function producerAllowed(request,env) {
  const given=request.headers.get('X-APT-Producer'),expected=env.RECORDING_PRODUCER_TOKEN;
  if(!given||!expected)return false;
  const digest=async s=>new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(s)));
  const [a,b]=await Promise.all([digest(given),digest(expected)]);let difference=0;
  for(let i=0;i<a.length;i++)difference|=a[i]^b[i];return difference===0;
}
export function sourceScope(record) {
  if(record.deleted)return null;
  let value;try{value=JSON.parse(record.text);}catch{return null;}
  if(value?.schema!=='apt.recording-source/1'||value.platform!=='stepx')return null;
  if(!UUID.test(value.recording_id??''))throw Error('invalid_stepx_recording_scope');
  return value.recording_id;
}
/** Repeated in every mutation statement, inside D1's single batch transaction.
 * Mapping survives tombstones, so empty text and fresh source IDs cannot evade it. */
export function sourceFence(device,scopes,producer) {
  const existingScope=`CASE WHEN json_valid(current.text) THEN CASE WHEN json_extract(current.text,'$.schema')='apt.recording-source/1'
    AND json_extract(current.text,'$.platform')='stepx' THEN json_extract(current.text,'$.recording_id') END END`;
  return {sql:`NOT EXISTS (
    SELECT 1 FROM json_each(?) incoming
    LEFT JOIN recording_memory_records mapped ON mapped.device_id=? AND mapped.record_id=json_extract(incoming.value,'$.id')
    LEFT JOIN recording_memory_sources current ON current.device_id=? AND current.record_id=json_extract(incoming.value,'$.id')
    LEFT JOIN recording_memory_owners owner ON owner.device_id=?
      AND owner.recording_id=COALESCE(mapped.recording_id,${existingScope},json_extract(incoming.value,'$.recording_id'))
    WHERE (COALESCE(mapped.recording_id,${existingScope}) IS NOT NULL AND json_extract(incoming.value,'$.recording_id') IS NOT NULL
      AND COALESCE(mapped.recording_id,${existingScope})<>json_extract(incoming.value,'$.recording_id'))
    OR (owner.recording_id IS NOT NULL AND NOT (owner.state='active' AND owner.generation=COALESCE(?,'')
      AND owner.control_version=COALESCE(?,-1) AND owner.recording_id=COALESCE(?,'')))
    OR (? IS NOT NULL AND owner.recording_id IS NULL)
    OR (mapped.record_id IS NULL AND json_extract(incoming.value,'$.recording_id') IS NULL
      AND COALESCE(json_extract(incoming.value,'$.deleted'),0)=0
      AND EXISTS (SELECT 1 FROM recording_memory_owners namespace WHERE namespace.device_id=?))
    OR (? IS NOT NULL AND (SELECT COUNT(*) FROM recording_memory_records r WHERE r.device_id=? AND r.recording_id=?)
      +(SELECT COUNT(*) FROM json_each(?) candidate WHERE NOT EXISTS (SELECT 1 FROM recording_memory_records r
        WHERE r.device_id=? AND r.record_id=json_extract(candidate.value,'$.id')))>30000)
  )`,args:[JSON.stringify(scopes),device,device,device,producer?.generation??null,producer?.control_version??null,
    producer?.recording_id??null,producer?.recording_id??null,device,producer?.recording_id??null,device,
    producer?.recording_id??null,JSON.stringify(scopes),device]};
}
function identity(input) {
  if(!UUID.test(input.device_id??'')||!UUID.test(input.recording_id??'')||!UUID.test(input.generation??''))throw Error('invalid_producer_identity');
  return [input.device_id,input.recording_id,input.generation];
}
const scopeSQL=`(m.recording_id=? OR (m.recording_id IS NULL AND json_valid(s.text)
  AND json_extract(s.text,'$.schema')='apt.recording-source/1' AND json_extract(s.text,'$.platform')='stepx'
  AND json_extract(s.text,'$.recording_id')=?))`;
async function claim(db,input) {
  const [device,recording,generation]=identity(input);
  if(!UUID.test(input.handoff_id??'')||!HASH.test(input.snapshot_digest??'')||!Array.isArray(input.sources)||input.sources.length>30000)throw Error('invalid_producer_handoff');
  const sources=input.sources;
  if(new Set(sources.map(s=>s.id)).size!==sources.length||sources.some(s=>!ID.test(s.id??'')||!Number.isSafeInteger(s.revision)||s.revision<1||!HASH.test(s.fingerprint??'')))throw Error('invalid_handoff_sources');
  // Unique IDs + equal cardinality + every exact member proves set equality.
  // Chunked rowsets avoid a 2MB D1 value and quadratic JSON membership scans.
  const chunks=[];let chunk=[],size=2;
  for(const source of sources){const bytes=new TextEncoder().encode(JSON.stringify(source)).length+1;
    if(size+bytes>1500000&&chunk.length){chunks.push(JSON.stringify(chunk));chunk=[];size=2;}
    chunk.push(source);size+=bytes;}
  if(chunk.length)chunks.push(JSON.stringify(chunk));
  const membership=`NOT EXISTS (SELECT 1 FROM json_each(?) x WHERE NOT EXISTS
    (SELECT 1 FROM recording_memory_sources s LEFT JOIN recording_memory_records m
      ON m.device_id=s.device_id AND m.record_id=s.record_id
      WHERE s.device_id=? AND s.record_id=json_extract(x.value,'$.id')
      AND s.revision=json_extract(x.value,'$.revision') AND s.fingerprint=json_extract(x.value,'$.fingerprint')
      AND (${scopeSQL} OR (m.recording_id IS NULL AND s.deleted=1 AND json_extract(x.value,'$.tombstone')=1))))`;
  const guard=`(SELECT COUNT(*) FROM recording_memory_sources s LEFT JOIN recording_memory_records m
    ON m.device_id=s.device_id AND m.record_id=s.record_id WHERE s.device_id=? AND ${scopeSQL})`
    +chunks.map(()=>`+(SELECT COUNT(*) FROM json_each(?) x JOIN recording_memory_sources s ON s.device_id=? AND s.record_id=json_extract(x.value,'$.id')
      LEFT JOIN recording_memory_records m ON m.device_id=s.device_id AND m.record_id=s.record_id
      WHERE m.recording_id IS NULL AND s.deleted=1 AND json_extract(x.value,'$.tombstone')=1)`).join('')+'=?'
    +chunks.map(()=>` AND ${membership}`).join('');
  const sourcesDigest=await fingerprint([...sources].sort((a,b)=>a.id.localeCompare(b.id)));
  const args=[device,recording,recording,...chunks.flatMap(encoded=>[encoded,device]),sources.length,
    ...chunks.flatMap(encoded=>[encoded,device,recording,recording])];
  const statements=[
    db.prepare(`INSERT INTO recording_memory_owners(device_id,recording_id,generation,control_version,state,handoff_id,snapshot_digest,sources_digest)
      SELECT ?,?,?,0,'active',?,?,? WHERE ${guard} ON CONFLICT(device_id,recording_id) DO NOTHING`)
      .bind(device,recording,generation,input.handoff_id,input.snapshot_digest,sourcesDigest,...args),
  ];
  for(const encoded of chunks)statements.push(db.prepare(`INSERT INTO recording_memory_records(device_id,record_id,recording_id)
      SELECT ?,json_extract(x.value,'$.id'),? FROM json_each(?) x WHERE EXISTS
      (SELECT 1 FROM recording_memory_owners WHERE device_id=? AND recording_id=? AND generation=? AND handoff_id=?
        AND snapshot_digest=? AND sources_digest=?) AND ${guard}
      ON CONFLICT(device_id,record_id) DO NOTHING`).bind(device,recording,encoded,device,recording,generation,input.handoff_id,input.snapshot_digest,sourcesDigest,...args));
  statements.push(db.prepare('SELECT * FROM recording_memory_owners WHERE device_id=? AND recording_id=?').bind(device,recording));
  const result=await db.batch(statements);
  const owner=result.at(-1).results[0];
  if(!owner||owner.generation!==generation||owner.handoff_id!==input.handoff_id||owner.snapshot_digest!==input.snapshot_digest||owner.sources_digest!==sourcesDigest)return reply({error:'recording_handoff_conflict'},409);
  return reply({schema:'apt.recording-producer/1',...owner});
}
async function control(db,input) {
  const [device,recording,generation]=identity(input);
  if(!UUID.test(input.mutation_id??'')||!Number.isSafeInteger(input.control_version)||input.control_version<1
    ||!['active','revoked'].includes(input.state))throw Error('invalid_producer_control');
  // Read only small canonical identities. CAS on fingerprints protects the gap while hashing.
  for(let attempt=0;attempt<3;attempt++) {
    const page=await db.batch([
      db.prepare('SELECT * FROM recording_memory_owners WHERE device_id=? AND recording_id=?').bind(device,recording),
      db.prepare(`SELECT s.record_id,s.revision,s.created,s.fingerprint FROM recording_memory_sources s
        JOIN recording_memory_records m ON m.device_id=s.device_id AND m.record_id=s.record_id
        WHERE m.device_id=? AND m.recording_id=?`).bind(device,recording),
    ]);
    const owner=page[0].results[0],rows=page[1].results;
    if(owner?.generation!==generation)return reply({error:'recording_producer_fenced'},409);
    if(owner.control_version===input.control_version && owner.mutation_id===input.mutation_id && owner.state===input.state)return reply({schema:'apt.recording-producer/1',...owner});
    if(owner.state==='revoked'||owner.control_version!==input.control_version-1)return reply({error:'recording_control_conflict'},409);
    const now=new Date().toISOString(),tombstones=await Promise.all(rows.map(async s=>{
      if(s.revision>=Number.MAX_SAFE_INTEGER)throw Error('source_revision_exhausted');
      const record={device_id:device,id:s.record_id,revision:s.revision+1,created:s.created,
        updated:new Date(Math.max(Date.parse(now),Date.parse(s.created))).toISOString(),title:'已移出记忆',text:'',partial:true,deleted:true};
      return {...record,fingerprint:await fingerprint(record)};
    }));
    const guard=`device_id=? AND recording_id=? AND generation=? AND state='active' AND control_version=?
      AND publication_version=?`;
    const nonce=crypto.randomUUID();
    const statements=[db.prepare(`UPDATE recording_memory_owners SET control_version=?,state=?,mutation_id=?,apply_nonce=? WHERE ${guard}`)
      .bind(input.control_version,input.state,input.mutation_id,nonce,device,recording,generation,owner.control_version,owner.publication_version)];
    for(let offset=0;offset<tombstones.length;offset+=1000)statements.push(db.prepare(`
      INSERT INTO recording_memory_sources(device_id,record_id,revision,payload,fingerprint,text,created,deleted,received_at)
      SELECT json_extract(value,'$.device_id'),json_extract(value,'$.id'),json_extract(value,'$.revision'),json_remove(value,'$.fingerprint'),
        json_extract(value,'$.fingerprint'),'',''||json_extract(value,'$.created'),1,? FROM json_each(?) WHERE EXISTS
      (SELECT 1 FROM recording_memory_owners WHERE device_id=? AND recording_id=? AND generation=? AND control_version=? AND mutation_id=? AND apply_nonce=?)
      ON CONFLICT(device_id,record_id) DO UPDATE SET revision=excluded.revision,payload=excluded.payload,fingerprint=excluded.fingerprint,
        text='',deleted=1,received_at=excluded.received_at WHERE excluded.revision>recording_memory_sources.revision`)
      .bind(now,JSON.stringify(tombstones.slice(offset,offset+1000)),device,recording,generation,input.control_version,input.mutation_id,nonce));
    statements.push(db.prepare('SELECT * FROM recording_memory_owners WHERE device_id=? AND recording_id=?').bind(device,recording));
    const result=await db.batch(statements),saved=result.at(-1).results[0];
    if(saved?.control_version===input.control_version && saved.mutation_id===input.mutation_id && saved.state===input.state)return reply({schema:'apt.recording-producer/1',...saved});
  }
  return reply({error:'recording_control_changed'},409);
}
export async function handleProducer(request,env,url) {
  if(!await producerAllowed(request,env))return reply({error:'producer_unauthorized'},403);
  let input;try{input=await body(request,8*1024*1024);
    if(url.pathname==='/recording-memory/producer/claim')return await claim(env.INPUT_MEMORY,input);
    if(url.pathname==='/recording-memory/producer/control')return await control(env.INPUT_MEMORY,input);
    if(url.pathname==='/recording-memory/producer/status') {
      const [device,recording]=identity(input);
      const r=await env.INPUT_MEMORY.prepare('SELECT * FROM recording_memory_owners WHERE device_id=? AND recording_id=?').bind(device,recording).all();
      return reply({schema:'apt.recording-producer/1',owner:r.results[0]??null});
    }
    return reply({error:'unknown_producer_route'},404);
  }catch(e){return reply({error:e.message},400);}
}
