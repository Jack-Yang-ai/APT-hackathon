// Bridge the existing cloud source feed into the Mac replica, without a phone.
import { createHash } from 'node:crypto';
import { normalize } from '../worker/src/input_memory.js';
import { InputMemoryError } from './input_memory_agent.mjs';

const validSeq = value => Number.isSafeInteger(value) && value >= 0;
export class InputMemoryPuller {
  constructor(replica, { origin, token, fetcher = fetch, maxPages = 20, budgetMs = 20000, protocol = {} }) {
    this.namespace=protocol.namespace ?? 'input_memory';
    if(!['input_memory','recording_memory'].includes(this.namespace))throw new Error('invalid_source_domain');
    this.schema=protocol.schema ?? 'growth.input-memory.changes/1';
    this.path=protocol.path ?? '/input-memory/changes';
    this.normalize=protocol.normalize ?? normalize;
    const parsed = new URL(origin);
    if (parsed.protocol !== 'https:' || parsed.username || parsed.password || parsed.search || parsed.hash || !['','/'].includes(parsed.pathname)) throw new Error('upstream_requires_https_origin');
    if (typeof token !== 'string' || !token.trim()) throw new Error('upstream_token_required');
    if (!Number.isInteger(maxPages) || maxPages < 1 || maxPages > 20) throw new Error('invalid_upstream_page_budget');
    if (!Number.isInteger(budgetMs) || budgetMs<1 || budgetMs>20000) throw new Error('invalid_upstream_time_budget');
    this.replica=replica; this.origin=parsed.origin; this.token=token; this.fetcher=fetcher; this.maxPages=maxPages; this.budgetMs=budgetMs; this.running=null; this.generation=0; this.lastRun=null;
    this.lastAttempt=null; this.lastSuccess=null; this.lastError=null; this.lastResult=null;
  }
  fail() { throw new InputMemoryError(this.namespace+'_upstream_invalid',503); }
  status() {
    const saved=this.replica.sqlite.prepare(`SELECT cursor,updated_at FROM ${this.namespace}_upstreams WHERE origin=?`).get(this.origin);
    const ready=this.lastSuccess !== null && this.lastError === null && Date.now()-Date.parse(this.lastSuccess)<=180000;
    return {mode:'upstream',origin:this.origin,state:this.running ? 'refreshing' : this.lastError ? (this.lastError==='input_memory_upstream_backlog' ? 'backlog' : 'offline') : ready ? 'ready' : 'starting',
      ready,cursor:saved?.cursor ?? 0,cursor_updated_at:saved?.updated_at ?? null,watermark:this.lastResult?.watermark ?? null,
      last_attempt_at:this.lastAttempt,last_success_at:this.lastSuccess,last_error:this.lastError};
  }
  bounded(promise, deadline) {
    return new Promise((done, fail) => {
      const timer=setTimeout(()=>fail(new InputMemoryError('input_memory_upstream_backlog',503)),Math.max(0,deadline-Date.now()));
      promise.then(value=> {clearTimeout(timer);done(value);},error=> {clearTimeout(timer);fail(error);});
    });
  }
  begin(deadline) {
    if(this.running) return this.running;
    this.generation++;
    this.lastAttempt=new Date().toISOString();
    const run=this.drain(deadline).then(result=> {this.lastSuccess=new Date().toISOString();this.lastError=null;this.lastResult=result;return result;})
      .catch(error=> {const safe=error instanceof InputMemoryError ? error : new InputMemoryError('input_memory_upstream_unavailable',503);this.lastError=safe.message;throw safe;})
      .finally(()=> {if(this.running===run) this.running=null;});
    this.running=run; this.lastRun=run;return run;
  }
  refresh({fresh=false}={}) {
    const deadline=Date.now()+this.budgetMs,boundary=this.generation;
    if(fresh && this.running) {
      return this.bounded(this.running,deadline).then(()=> {
        // A drain begun after this call can satisfy it; a pre-existing watermark cannot.
        return this.bounded(this.generation>boundary ? this.lastRun : this.begin(deadline),deadline);
      });
    }
    return this.bounded(this.running ?? this.begin(deadline),deadline);
  }
  async drain(deadline) {
    let after=this.replica.sqlite.prepare(`SELECT cursor FROM ${this.namespace}_upstreams WHERE origin=?`).get(this.origin)?.cursor ?? 0;
    let watermark,changed=0;
    for (let page=0;page<this.maxPages;page++) {
      const url=new URL(this.path,this.origin);url.searchParams.set('after',String(after));url.searchParams.set('limit','10');
      if (watermark !== undefined) url.searchParams.set('through',String(watermark));
      const remaining=deadline-Date.now();if(remaining<=0) throw new InputMemoryError('input_memory_upstream_backlog',503);
      const response=await this.fetcher(url,{headers:{'X-Growth-Token':this.token},redirect:'error',signal:AbortSignal.timeout(Math.min(10000,remaining))});
      if (!response.ok) throw new InputMemoryError('input_memory_upstream_unavailable',503);
      // Ten admitted records are bounded by the one-MiB ingestion budget each.
      if (Number(response.headers.get('content-length'))>12*1024*1024) this.fail();
      let bytes=0;const blocks=[];
      for await (const block of response.body) {bytes+=block.byteLength;if(bytes>12*1024*1024) this.fail();blocks.push(Buffer.from(block));}
      let value;try {value=JSON.parse(Buffer.concat(blocks).toString('utf8'));} catch {this.fail();}
      if (!value || value.schema !== this.schema || !Array.isArray(value.records) || value.records.length>10 ||
          !validSeq(value.cursor) || !validSeq(value.watermark) || value.cursor<after || value.cursor>value.watermark ||
          typeof value.has_more !== 'boolean' || (watermark !== undefined && watermark !== value.watermark)) this.fail();
      watermark=value.watermark;
      let seq=after;
      const prepared=value.records.map(row=> {
        if (!validSeq(row.event_seq) || row.event_seq<=seq || row.event_seq>watermark || typeof row.device_id !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(row.device_id)) this.fail();
        seq=row.event_seq;
        let record;try {record=this.normalize(row,row.device_id);} catch {this.fail();}
        return {record,payload:JSON.stringify(record),fingerprint:createHash('sha256').update(JSON.stringify(record)).digest('hex')};
      });
      if ((prepared.length && value.cursor !== seq) || (!prepared.length && (value.has_more || value.cursor !== watermark)) || (value.has_more && value.cursor<=after) || (!value.has_more && value.cursor !== watermark)) this.fail();
      if(Date.now()>=deadline) throw new InputMemoryError('input_memory_upstream_backlog',503);
      // Source updates, their local events and the upstream cursor commit together.
      this.replica.transaction(db=> {
        const current=db.prepare(`SELECT cursor FROM ${this.namespace}_upstreams WHERE origin=?`).get(this.origin)?.cursor ?? 0;
        if(current !== after) throw new InputMemoryError('input_memory_upstream_cursor_changed',503);
        const received=new Date().toISOString();
        for (const {record:r,payload,fingerprint} of prepared) {
          db.prepare(`INSERT INTO ${this.namespace}_sources(device_id,record_id,revision,payload,fingerprint,text,created,deleted,received_at)
            VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(device_id,record_id) DO UPDATE SET
            revision=excluded.revision,payload=excluded.payload,fingerprint=excluded.fingerprint,text=excluded.text,
            created=excluded.created,deleted=excluded.deleted,received_at=excluded.received_at
            WHERE excluded.revision>${this.namespace}_sources.revision`).run(r.device_id,r.id,r.revision,payload,fingerprint,r.text,r.created,+r.deleted,received);
          const saved=db.prepare(`SELECT revision,fingerprint FROM ${this.namespace}_sources WHERE device_id=? AND record_id=?`).get(r.device_id,r.id);
          if (saved.revision === r.revision && saved.fingerprint !== fingerprint) throw new InputMemoryError('input_memory_upstream_conflict',503);
        }
        db.prepare(`INSERT INTO ${this.namespace}_upstreams(origin,cursor,updated_at) VALUES(?,?,?) ON CONFLICT(origin) DO UPDATE SET cursor=excluded.cursor,updated_at=excluded.updated_at`).run(this.origin,value.cursor,received);
      });
      changed+=prepared.length;after=value.cursor;
      if (!value.has_more) return {cursor:after,watermark,changed,complete:true};
    }
    throw new InputMemoryError('input_memory_upstream_backlog',503);
  }
}
