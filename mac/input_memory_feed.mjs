// Same state-change contract as Worker, with a byte-bound lazy page for Mac clients.
import { InputMemoryError } from './input_memory_agent.mjs';
function integer(raw,fallback,max=Number.MAX_SAFE_INTEGER) {
  if(raw===null) return fallback;
  if(!/^\d+$/.test(raw) || !Number.isSafeInteger(Number(raw)) || Number(raw)>max) throw new InputMemoryError('invalid_cursor');
  return Number(raw);
}
export function replicaChanges(replica,url) {
  const after=integer(url.searchParams.get('after'),0),limit=integer(url.searchParams.get('limit'),100,100),through=integer(url.searchParams.get('through'),null);
  if(limit<1) throw new InputMemoryError('invalid_limit');
  return replica.transaction(db=> {
    const maximum=db.prepare('SELECT COALESCE(MAX(seq),0) AS seq FROM input_memory_changes').get().seq;
    const watermark=through===null ? maximum : Math.min(through,maximum);
    if(after>watermark) throw new InputMemoryError('cursor_ahead',409);
    const records=[];let bytes=0,cursor=after;
    const rows=db.prepare(`SELECT c.seq,s.payload FROM input_memory_changes c JOIN input_memory_sources s
      ON s.device_id=c.device_id AND s.record_id=c.record_id WHERE c.seq>? AND c.seq<=? ORDER BY c.seq LIMIT ?`).iterate(after,watermark,limit+1);
    for(const row of rows) {
      const record={...JSON.parse(row.payload),event_seq:row.seq};
      const size=Buffer.byteLength(JSON.stringify(record))+1;
      // Always advance at least one admitted source. A single payload is bounded at ingestion.
      if(records.length && (records.length===limit || bytes+size>950000)) break;
      records.push(record);bytes+=size;cursor=row.seq;
    }
    if(!records.length) cursor=watermark;
    return {schema:'growth.input-memory.changes/1',records,cursor,watermark,has_more:cursor<watermark};
  });
}
