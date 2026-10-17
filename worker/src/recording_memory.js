// Read-only projections from the phone's formal content library. Never an authority writer.
import { body, fingerprint, integer, stamp } from './input_memory.js';

const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ID=/^apt_recording_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const reply=(value,status=200)=>Response.json(value,{status,headers:{'Cache-Control':'no-store'}});
export function normalizeRecording(record,device) {
  if(!UUID.test(device ?? '') || !record || !ID.test(record.id ?? '') || !Number.isSafeInteger(record.revision) || record.revision<1 ||
      typeof record.deleted!=='boolean' || typeof record.partial!=='boolean' || typeof record.title!=='string' || !record.title.trim() || record.title.length>300 ||
      typeof record.text!=='string' || record.text.length>16000 || (!record.deleted && !record.text.trim()))throw new Error('invalid_recording_source');
  const created=stamp(record.created),updated=stamp(record.updated);
  if(updated<created)throw new Error('invalid_timestamp_order');
  return {device_id:device.toLowerCase(),id:record.id.toLowerCase(),revision:record.revision,created,updated,
    title:record.deleted ? '已移出记忆' : record.title,text:record.deleted ? '' : record.text,partial:record.partial,deleted:record.deleted};
}
export async function syncRecordings(db,request,producerAuthorized=false) {
  const {sourceFence,sourceScope}=await import('./recording_producer.js');
  let records,producer,scopes;
  try {
    const input=await body(request,8*1024*1024);
    if(input.schema!=='apt.recording-memory.batch/1' || !UUID.test(input.device_id ?? '') || !Array.isArray(input.records) || input.records.length<1 || input.records.length>2000)throw new Error('invalid_recording_batch');
    records=input.records.map(r=>normalizeRecording(r,input.device_id));
    if(new Set(records.map(r=>r.id)).size!==records.length)throw new Error('duplicate_recording_source');
    producer=input.producer;
    if(producer && (!producerAuthorized || !UUID.test(producer.recording_id??'') || !UUID.test(producer.generation??'')
      || !Number.isSafeInteger(producer.control_version) || producer.control_version<0))throw new Error('invalid_recording_producer');
    scopes=records.map(r=>({id:r.id,revision:r.revision,deleted:r.deleted,recording_id:sourceScope(r) ?? producer?.recording_id ?? null}));
    if(producer && scopes.some(s=>s.recording_id!==producer.recording_id))throw new Error('recording_producer_scope_mismatch');
  }catch(e){return reply({error:e.message},e.message==='payload_too_large' ? 413 : 400);}
  const prepared=await Promise.all(records.map(async record=>({record,hash:await fingerprint(record)})));
  scopes=scopes.map((scope,index)=>({...scope,fingerprint:prepared[index].hash}));
  const received=new Date().toISOString();
  // JSON rowsets keep a whole transcript atomic without spending one D1 query per source.
  // Every bound rowset stays below D1's 2 MB value limit; even the 8 MiB request uses < 50 queries.
  const chunks=[];let chunk=[],size=2;
  for(const {record,hash} of prepared) {
    const value={...record,fingerprint:hash},bytes=new TextEncoder().encode(JSON.stringify(value)).length+1;
    if(size+bytes>1500000 && chunk.length){chunks.push(chunk);chunk=[];size=2;}
    chunk.push(value);size+=bytes;
  }
  if(chunk.length)chunks.push(chunk);
  const fence=sourceFence(records[0].device_id,scopes,producer);
  const statements=chunks.map(rows=>db.prepare(`
    INSERT INTO recording_memory_sources(device_id,record_id,revision,payload,fingerprint,text,created,deleted,received_at)
    SELECT json_extract(value,'$.device_id'),json_extract(value,'$.id'),json_extract(value,'$.revision'),
      json_remove(value,'$.fingerprint'),json_extract(value,'$.fingerprint'),json_extract(value,'$.text'),
      json_extract(value,'$.created'),json_extract(value,'$.deleted'),? FROM json_each(?) WHERE ${fence.sql}
    ON CONFLICT(device_id,record_id) DO UPDATE SET
      revision=excluded.revision,payload=excluded.payload,fingerprint=excluded.fingerprint,text=excluded.text,
      created=excluded.created,deleted=excluded.deleted,received_at=excluded.received_at
    WHERE excluded.revision>recording_memory_sources.revision
  `).bind(received,JSON.stringify(rows),...fence.args));
  statements.push(db.prepare(`INSERT INTO recording_memory_records(device_id,record_id,recording_id)
    SELECT ?,json_extract(value,'$.id'),json_extract(value,'$.recording_id') FROM json_each(?)
    WHERE json_extract(value,'$.recording_id') IS NOT NULL AND ${fence.sql}
    AND EXISTS (SELECT 1 FROM recording_memory_sources saved WHERE saved.device_id=?
      AND saved.record_id=json_extract(value,'$.id') AND saved.revision=json_extract(value,'$.revision')
      AND saved.fingerprint=json_extract(value,'$.fingerprint'))
    ON CONFLICT(device_id,record_id) DO NOTHING`).bind(records[0].device_id,JSON.stringify(scopes),...fence.args,records[0].device_id));
  if(producer)statements.push(db.prepare(`UPDATE recording_memory_owners SET publication_version=publication_version+1
    WHERE device_id=? AND recording_id=? AND generation=? AND control_version=? AND state='active' AND ${fence.sql}`)
    .bind(records[0].device_id,producer.recording_id,producer.generation,producer.control_version,...fence.args));
  statements.push(db.prepare(`SELECT ${fence.sql} AS allowed`).bind(...fence.args));
  // The receipt read is in the same transaction, including no-op/idempotent replays.
  statements.push(db.prepare(`SELECT s.record_id,s.revision,s.fingerprint FROM recording_memory_sources s
    JOIN json_each(?) wanted ON s.record_id=wanted.value WHERE s.device_id=?`).bind(JSON.stringify(records.map(r=>r.id)),records[0].device_id));
  const results=await db.batch(statements);
  if(!results.at(-2).results[0].allowed)return reply({error:'recording_producer_fenced'},409);
  const savedRows=new Map(results.at(-1).results.map(r=>[r.record_id,r]));
  const accepted=[],stale=[],conflicts=[];
  for(const {record:r,hash} of prepared) {
    const saved=savedRows.get(r.id),ref={id:r.id,revision:r.revision};
    if(saved?.revision===r.revision && saved.fingerprint===hash)accepted.push({...ref,fingerprint:hash});
    else if((saved?.revision ?? 0)>r.revision)stale.push(ref);
    else conflicts.push(ref);
  }
  return reply({schema:'apt.recording-memory.receipt/1',accepted,stale,conflicts});
}
export async function recordingChanges(db,url) {
  let after,limit,through;
  try {
    after=integer(url.searchParams.get('after'),0);limit=integer(url.searchParams.get('limit'),10,10);
    through=integer(url.searchParams.get('through'),null);if(limit<1)throw new Error('invalid_limit');
  }catch(e){return reply({error:e.message},400);}
  // Both reads share a transaction. Later pages reject a changed boundary instead of joining future payloads to an old watermark.
  const page=await db.batch([
    db.prepare('SELECT COALESCE(MAX(seq),0) AS seq FROM recording_memory_changes'),
    db.prepare(`SELECT c.seq,s.payload FROM recording_memory_changes c JOIN recording_memory_sources s
      ON s.device_id=c.device_id AND s.record_id=c.record_id WHERE c.seq>? AND c.seq<=COALESCE(?,(SELECT COALESCE(MAX(seq),0) FROM recording_memory_changes)) ORDER BY c.seq LIMIT ?`).bind(after,through,limit),
  ]);
  const maximum=Number(page[0].results[0].seq);
  if(through!=null && through!==maximum)return reply({error:'recording_watermark_changed'},409);
  const watermark=maximum;
  if(after>watermark)return reply({error:'cursor_ahead'},409);
  const results=page[1].results;
  const cursor=results.length ? results.at(-1).seq : watermark;
  return reply({schema:'apt.recording-memory.changes/1',records:results.map(r=>({...JSON.parse(r.payload),event_seq:r.seq})),cursor,watermark,has_more:cursor<watermark});
}
export async function handleRecordingMemory(request,env,url) {
  if(!env.INPUT_MEMORY)return reply({error:'recording_memory_not_configured'},503);
  try {
    if(url.pathname.startsWith('/recording-memory/producer/') && request.method==='POST')return await (await import('./recording_producer.js')).handleProducer(request,env,url);
    if(url.pathname==='/recording-memory/sync' && request.method==='POST')return await syncRecordings(env.INPUT_MEMORY,request,await (await import('./recording_producer.js')).producerAllowed(request,env));
    if(url.pathname==='/recording-memory/changes' && request.method==='GET')return await recordingChanges(env.INPUT_MEMORY,url);
    return reply({error:'method_or_path_not_allowed'},405);
  }catch{return reply({error:'recording_memory_storage_failed'},500);}
}
