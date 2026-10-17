import assert from 'node:assert/strict';
import worker from './src/index.js';
import { sync, changes, search } from './src/input_memory.js';

// The same SQLite adapter runs the Mac service and the Worker SQL contract checks.
import { InputMemoryReplica } from '../mac/input_memory_store.mjs';
function database() { return new InputMemoryReplica(':memory:').db; }

let assertions = 0;
const check = new Proxy(assert, {get(target, property) {
  const value = target[property];
  return typeof value === 'function' ? (...args) => { assertions++; return value(...args); } : value;
}});
const tests = [];
const test = (name, fn) => tests.push([name, fn]);
const device = 'aaaaaaaa-1111-2222-3333-123456789abc';
const otherDevice = 'bbbbbbbb-1111-2222-3333-123456789abc';
const id = (n = 1) => `local_input_00000000-1111-2222-3333-${String(n).padStart(12, '0')}`;
const record = (n = 1, overrides = {}) => ({id: id(n), revision: 1,
  created: '2026-10-13T10:00:00+08:00', updated: '2026-10-13T10:00:00+08:00',
  app: 'com.example.editor', text: '项目计划 alpha 粘贴 语音', pasted: ['粘贴'], voiced: ['语音'],
  partial: true, deleted: false, ...overrides});
const batch = (records = [record()], overrides = {}) => ({schema: 'growth.input-memory.batch/1', device_id: device, records, ...overrides});
const req = (path, value, headers = {}) => new Request('https://example.test' + path,
  {method: value === undefined ? 'GET' : 'POST', headers, ...(value === undefined ? {} : {body: JSON.stringify(value)})});
const send = async (db, records = [record()], extra = {}) => (await sync(db, req('/input-memory/sync', batch(records, extra)))).json();
const page = async (db, query = '') => (await changes(db, new URL('https://example.test/input-memory/changes?' + query))).json();
const find = async (db, input) => (await search(db, req('/input-memory/search', input))).json();

// Day digests are published replicas of a client's Days/ files: one per calendar day per device.
const dayId = (day = '2026-10-13') => `echo_day_${day}`;
const dayRecord = (day = '2026-10-13', overrides = {}) => ({id: dayId(day), revision: 1,
  created: `${day}T00:00:00+08:00`, updated: `${day}T21:00:00+08:00`,
  app: 'echo.day', text: '概要：整理了项目计划与排期。\n时段：\n- 09:00–11:00 排期：核对了项目计划。\n条目：\n- 待办：把项目排期表发给同事（原话：「明天我要把项目排期表发给同事确认。」）',
  pasted: [], voiced: [], partial: false, deleted: false, ...overrides});

// Route auth is tested through Worker.fetch, not by assuming the helper is protected.
test('all input-memory routes reject absent or wrong auth before storage', async () => {
  for (const [path, value] of [['/input-memory/sync', batch()], ['/input-memory/search', {query:'计划'}], ['/input-memory/changes', undefined]]) {
    for (const token of [undefined, 'wrong']) {
      const headers = token ? {'X-Growth-Token': token} : {};
      const response = await worker.fetch(req(path, value, headers), {CLIENT_TOKEN:'secret'}, {});
      check.equal(response.status, 401); check.equal((await response.json()).error, 'unauthorized');
    }
  }
  check.equal((await worker.fetch(req('/input-memory/changes', undefined, {'X-Growth-Token':'secret'}), {}, {})).status, 401);
});
test('authorized routes require configured storage and restrict methods/paths', async () => {
  const headers = {'X-Growth-Token':'secret'};
  check.equal((await worker.fetch(req('/input-memory/changes', undefined, headers), {CLIENT_TOKEN:'secret'}, {})).status, 503);
  const db = database(), env = {CLIENT_TOKEN:'secret', INPUT_MEMORY:db};
  for (const path of ['/input-memory/sync', '/input-memory/search', '/input-memory/not-found']) {
    check.equal((await worker.fetch(req(path, undefined, headers), env, {})).status, 405);
  }
  const response = await worker.fetch(req('/input-memory/sync', batch(), headers), env, {});
  check.equal(response.status, 200); check.equal(response.headers.get('Cache-Control'), 'no-store');
  check.equal((await response.json()).accepted.length, 1);
  check.equal((await worker.fetch(req('/input-memory/changes', undefined, headers), env, {})).status, 200);
});
test('invalid schema, device, batch size and duplicated identity never write', async () => {
  const db = database();
  for (const value of [null, [], {}, batch([], {}), batch(Array.from({length:51}, (_,i)=>record(i))),
    batch([record(), record()]), batch(undefined, {schema:'other/1'}), batch(undefined, {device_id:'evil'}),
    batch(undefined, {device_id:42}), batch(undefined, {device_id:[device]}), batch(undefined, {records:'not an array'})]) {
    check.equal((await sync(db, req('/input-memory/sync', value))).status, 400);
  }
  check.equal(db.sqlite.prepare('SELECT COUNT(*) AS n FROM input_memory_sources').get().n, 0);
});
test('raw malformed JSON and missing body are rejected', async () => {
  const db = database();
  check.equal((await sync(db, new Request('https://x', {method:'POST',body:'{'}))).status, 400);
  check.equal((await sync(db, new Request('https://x', {method:'POST'}))).status, 400);
});
test('actual UTF-8 payload and declared length both enforce one MiB limit', async () => {
  const db = database();
  check.equal((await sync(db, req('/input-memory/sync', batch(), {'Content-Length':'1048577'}))).status, 413);
  check.equal((await sync(db, new Request('https://x', {method:'POST', body:'汉'.repeat(400000)}))).status, 413);
  check.equal(db.sqlite.prepare('SELECT COUNT(*) AS n FROM input_memory_sources').get().n, 0);
});
test('source admission rejects other source types, bad revisions, metadata and provenance', async () => {
  const db = database();
  const invalid = [{id:[id()]}, {id:'echo_day_20261031'}, {id:'local_input_not-uuid'}, {revision:0}, {revision:-1},
    {revision:1.5}, {revision:Number.MAX_SAFE_INTEGER+1}, {deleted:0}, {partial:'true'}, {app:''},
    {app:'x'.repeat(257)}, {text:42}, {text:'x'.repeat(8193)}, {text:'  ',pasted:[],voiced:[]},
    {pasted:['does not occur']}, {voiced:['does not occur']}, {pasted:'not array'}, {voiced:Array(129).fill('语音')},
    {created:'yesterday'}, {updated:'2026-10-12T10:00:00Z'}, {created:'2026-13-01T00:00:00Z'}];
  for (const patch of invalid) check.equal((await sync(db, req('/input-memory/sync', batch([record(1, patch)])))).status, 400);
  check.equal(db.sqlite.prepare('SELECT COUNT(*) AS n FROM input_memory_changes').get().n, 0);
});
test('mixed valid/invalid batch is rejected atomically', async () => {
  const db = database();
  check.equal((await sync(db, req('/input-memory/sync', batch([record(1),record(2,{revision:0})])))).status, 400);
  check.equal(db.sqlite.prepare('SELECT COUNT(*) AS n FROM input_memory_sources').get().n, 0);
});
test('day digests sync, replicate through changes and keep their own larger text bound', async () => {
  const db = database();
  const receipt = await send(db, [dayRecord()]);
  check.deepEqual(receipt.accepted, [{id: dayId(), revision: 1}]);
  const first = await page(db);
  check.equal(first.records[0].id, dayId());
  check.equal(first.records[0].text.includes('项目计划'), true);
  // A UTC timestamp whose Beijing day matches the id is normalized in, not rejected.
  check.equal((await send(db, [dayRecord('2026-10-14', {created:'2026-10-13T16:00:00Z', updated:'2026-10-13T16:00:00Z'})])).accepted.length, 1);
  // 20000 chars is a real digest shape and must pass; drafts keep the 8192 bound.
  check.equal((await send(db, [dayRecord('2026-10-15', {text:'整理正文'.repeat(5000)})])).accepted.length, 1);
  check.equal((await sync(db, req('/input-memory/sync', batch([dayRecord('2026-10-16', {text:'整理正文'.repeat(16385)})])))).status, 400);
  check.equal((await sync(db, req('/input-memory/sync', batch([record(1, {text:'x'.repeat(8193), pasted:[], voiced:[]})])))).status, 400);
});
test('day digests reject draft-shaped provenance, partial flags and mismatched days', async () => {
  const db = database();
  for (const patch of [{pasted:['项目']}, {voiced:['排期']}, {partial:true},
    {created:'2026-10-12T00:00:00+08:00', updated:'2026-10-12T21:00:00+08:00'},
    {app:''}, {text:'   '}, {id: dayId('2026-10-13'), created:'2026-02-30T00:00:00+08:00'}])
    check.equal((await sync(db, req('/input-memory/sync', batch([dayRecord('2026-10-13', patch)])))).status, 400);
  check.equal((await sync(db, req('/input-memory/sync', batch([dayRecord('2026-02-30')])))).status, 400);
  check.equal(db.sqlite.prepare('SELECT COUNT(*) AS n FROM input_memory_sources').get().n, 0);
});
test('day tombstones erase text, replicate and stale revisions never resurrect', async () => {
  const db = database();
  await send(db, [dayRecord()]);
  check.equal((await send(db, [dayRecord(undefined, {revision:2, deleted:true, text:''})])).accepted.length, 1);
  const saved = db.sqlite.prepare('SELECT text, deleted FROM input_memory_sources WHERE record_id=?').get(dayId());
  check.equal(saved.text, ''); check.equal(saved.deleted, 1);
  const next = await page(db, 'limit=1&after=1');
  check.equal(next.records[0].deleted, true); check.equal(next.records[0].text, '');
  check.equal((await send(db, [dayRecord()])).stale.length, 1);
  check.equal((await send(db, [dayRecord(undefined, {revision:3, text:'重写后的整理正文'})])).accepted.length, 1);
  const restored = await page(db, 'after=2');
  check.equal(restored.records[0].revision, 3); check.equal(restored.records[0].deleted, false);
});
test('search stays a draft-only index and never returns day digests', async () => {
  const db = database();
  await send(db, [record(1), dayRecord()]);
  const hits = await find(db, {query:'项目计划'});
  check.equal(hits.records.length, 1); check.equal(hits.records[0].id, id(1));
  check.equal((await find(db, {query:'排期'})).records.length, 0);
});
test('one batch carries drafts and day digests side by side', async () => {
  const db = database();
  const receipt = await send(db, [record(1), dayRecord()]);
  check.equal(receipt.accepted.length, 2);
  const p = await page(db, 'limit=2');
  check.equal(p.records.filter(r => r.id.startsWith('echo_day_')).length, 1);
  check.equal(p.records.filter(r => r.id.startsWith('local_input_')).length, 1);
});
test('D1 batch adapter really rolls back failing SQL and triggers', async () => {
  const db = database();
  await check.rejects(()=>db.batch([db.prepare('INSERT INTO input_memory_changes(device_id,record_id) VALUES(?,?)').bind(device,id()), db.prepare('INSERT INTO does_not_exist VALUES(?)').bind(1)]));
  check.equal(db.sqlite.prepare('SELECT COUNT(*) AS n FROM input_memory_changes').get().n, 0);
});
test('initial sync persists canonical timestamps and provenance', async () => {
  const db = database();
  const receipt = await send(db, [record(1,{pasted:['粘贴','粘贴']})]);
  check.deepEqual(receipt.accepted, [{id:id(), revision:1}]);
  const p = await page(db);
  check.equal(p.records[0].created, '2026-10-13T02:00:00.000Z');
  check.deepEqual(p.records[0].pasted, ['粘贴']); check.equal(p.records[0].device_id, device);
  check.equal(p.records[0].partial, true); check.equal(p.watermark, 1); check.equal(p.has_more, false);
});
test('same revision with equivalent canonical spans and timezone is idempotent', async () => {
  const db = database();
  await send(db, [record(1,{pasted:['粘贴','粘贴']})]);
  const receipt = await send(db, [record(1,{created:'2026-10-13T02:00:00Z', updated:'2026-10-13T02:00:00Z'})]);
  check.equal(receipt.accepted.length, 1); check.equal((await page(db)).watermark, 1);
});
test('same-version conflict cannot replace content', async () => {
  const db = database(); await send(db);
  const receipt = await send(db, [record(1,{text:'不同正文',pasted:[],voiced:[]})]);
  check.equal(receipt.conflicts.length, 1); check.equal(receipt.accepted.length,0);
  check.equal((await page(db)).records[0].text, record().text); check.equal((await page(db)).watermark,1);
});
test('mixed receipt acknowledges only committed items and reports conflict/stale independently', async () => {
  const db=database(); await send(db,[record(1),record(2,{revision:5})]);
  const response=await sync(db,req('/input-memory/sync',batch([
    record(1,{text:'conflicting alpha',pasted:[],voiced:[]}),record(2,{revision:4}),record(3)
  ])));
  check.equal(response.status,200);
  const receipt=await response.json();
  check.deepEqual(receipt.accepted,[{id:id(3),revision:1}]);
  check.deepEqual(receipt.conflicts,[{id:id(1),revision:1}]);
  check.deepEqual(receipt.stale,[{id:id(2),revision:4,current_revision:5}]);
  const rows=db.sqlite.prepare('SELECT record_id,revision,payload FROM input_memory_sources ORDER BY record_id').all();
  check.equal(rows.length,3); check.equal(JSON.parse(rows[0].payload).text,record().text);
  check.equal(rows[1].revision,5); check.equal(rows[2].revision,1);
});
test('higher revisions win and lower revisions report current version', async () => {
  const db = database(); await send(db);
  check.equal((await send(db,[record(1,{revision:3,text:'new alpha',pasted:[],voiced:[]})])).accepted.length,1);
  const receipt = await send(db,[record(1,{revision:2})]);
  check.equal(receipt.stale[0].current_revision,3); check.equal(receipt.accepted.length,0);
  check.equal((await find(db,{query:'alpha'})).records[0].text,'new alpha');
});
test('same record on separate devices has independent identity', async () => {
  const db = database(); await send(db); await send(db,[record()],{device_id:otherDevice});
  check.equal((await find(db,{query:'alpha'})).records.length,2);
});
test('delete erases all text/provenance, stops search, and stale input never resurrects', async () => {
  const db = database(); await send(db);
  check.equal((await send(db,[record(1,{revision:2,deleted:true})])).accepted.length,1);
  const saved = db.sqlite.prepare('SELECT * FROM input_memory_sources').get();
  check.equal(saved.text,''); check.equal(saved.deleted,1); check.equal(saved.payload.includes('粘贴'),false);
  check.equal(saved.payload.includes('语音'),false); check.equal(saved.payload.includes('alpha'),false);
  check.deepEqual(JSON.parse(saved.payload).pasted,[]); check.deepEqual(JSON.parse(saved.payload).voiced,[]);
  check.equal((await find(db,{query:'alpha'})).records.length,0);
  check.equal((await send(db,[record()])).stale.length,1);
  const p = await page(db); check.equal(p.records.every(r=>r.deleted && !r.text),true);
});
test('case variants cannot split a source identity or bypass its tombstone', async () => {
  const db=database();
  const upperID='local_input_AAAAAAAA-1111-2222-3333-123456789ABC';
  const lowerID=upperID.toLowerCase();
  await send(db,[record(1,{id:lowerID})]);
  await send(db,[record(1,{id:upperID,revision:2,deleted:true})],{device_id:device.toUpperCase()});
  check.equal(db.sqlite.prepare('SELECT COUNT(*) AS n FROM input_memory_sources').get().n,1);
  check.equal((await find(db,{query:'alpha'})).records.length,0);
  check.equal((await send(db,[record(1,{id:lowerID})])).stale.length,1);
  check.equal((await sync(db,req('/input-memory/sync',batch([record(1,{id:lowerID}),record(1,{id:upperID})])))).status,400);
});
test('restore requires a higher version than tombstone', async () => {
  const db = database(); await send(db,[record(1,{revision:2,deleted:true})]);
  check.equal((await send(db,[record(1,{revision:2})])).conflicts.length,1);
  check.equal((await send(db,[record(1,{revision:3})])).accepted.length,1);
  check.equal((await find(db,{query:'alpha'})).records[0].revision,3);
  await send(db,[record(1,{revision:2,deleted:true})]);
  check.equal((await find(db,{query:'alpha'})).records[0].deleted,false);
});
test('successful commit receipt remains accepted if competing higher write lands before reply', async () => {
  const db = database();
  db.afterBatch = ()=>send(db,[record(1,{revision:2,deleted:true})]);
  const receipt = await send(db);
  check.deepEqual(receipt.accepted,[{id:id(),revision:1}]);
  check.equal(db.sqlite.prepare('SELECT revision FROM input_memory_sources').get().revision,2);
});
test('parallel revision submissions leave monotonic maximum', async () => {
  const db = database();
  await Promise.all([5,1,7,3,6,2,4].map(revision=>send(db,[record(1,{revision})])));
  check.equal(db.sqlite.prepare('SELECT revision FROM input_memory_sources').get().revision,7);
  const receipt = await send(db,[record(1,{revision:6})]); check.equal(receipt.stale[0].current_revision,7);
});
test('fixed watermark pagination excludes subsequently inserted change events', async () => {
  const db = database(); await send(db,[record(1),record(2),record(3)]);
  const first = await page(db,'limit=1'); check.equal(first.has_more,true); check.equal(first.watermark,3);
  await send(db,[record(4)]);
  const second = await page(db,`limit=1&after=${first.cursor}&through=${first.watermark}`);
  check.equal(second.records[0].id,id(2)); check.equal(second.watermark,3);
  const third = await page(db,`limit=1&after=${second.cursor}&through=${first.watermark}`);
  check.equal(third.records[0].id,id(3)); check.equal(third.has_more,false); check.equal(third.cursor,3);
  const next = await page(db,'after=3'); check.equal(next.records[0].id,id(4)); check.equal(next.cursor,4);
});
test('old event pages return current tombstones without retaining historical full text', async () => {
  const db = database(); await send(db,[record(1),record(2)]);
  const first = await page(db,'limit=1');
  await send(db,[record(2,{revision:2,deleted:true})]);
  const next = await page(db,`after=${first.cursor}&through=${first.watermark}&limit=1`);
  check.equal(next.watermark,2); check.equal(next.records[0].event_seq,2);
  check.equal(next.records[0].revision,2); check.equal(next.records[0].deleted,true);
  check.equal(next.records[0].text,''); check.equal(next.has_more,false);
  const following=await page(db,'after=2'); check.equal(following.records[0].event_seq,3);
  check.equal(following.records[0].deleted,true);
});
test('empty changes has zero watermark and cursor-ahead fails', async () => {
  const db = database(); const p=await page(db);
  check.deepEqual(p.records,[]); check.equal(p.cursor,0); check.equal(p.watermark,0); check.equal(p.has_more,false);
  check.equal((await changes(db,new URL('https://x?after=1'))).status,409);
});
test('pagination rejects injection, negatives, unsafe numbers and invalid limits', async () => {
  const db = database();
  for (const query of ['after=-1','after=1.2','after=9007199254740992','after=1%20OR%201=1','through=no','limit=0','limit=101','limit=-2'])
    check.equal((await changes(db,new URL('https://x?'+query))).status,400);
});
test('search returns Chinese bigram and English hits, bounded and explicitly truncated', async () => {
  const db=database(); await send(db,[record(1),record(2),record(3),record(4,{text:'无关记录',pasted:[],voiced:[]})]);
  const result=await find(db,{query:'项目计划',limit:2});
  check.equal(result.records.length,2); check.equal(result.truncated,true); check.equal(result.scope,'synced_input_memory_only');
  check.equal(result.records.every(r=>r.text.includes('计划')),true); check.match(result.warning,/不证明/);
  check.equal((await find(db,{query:'ALPHA',limit:30})).records.length,3);
  check.equal((await find(db,{query:'missingword'})).records.length,0);
});
test('search never interpolates user text into SQL', async () => {
  const db=database(); await send(db,[record(1,{text:'onlyneedle',pasted:[],voiced:[]})]);
  check.equal((await find(db,{query:"' OR 1=1; DROP TABLE input_memory_sources; --"})).records.length,0);
  check.equal(db.sqlite.prepare('SELECT COUNT(*) AS n FROM input_memory_sources').get().n,1);
});
test('search caps max records, enforces query size and date range', async () => {
  const db=database(); await send(db,Array.from({length:40},(_,i)=>record(i+1)));
  check.equal((await find(db,{query:'alpha',limit:10000})).records.length,30);
  check.equal((await find(db,{query:'alpha',limit:0})).records.length,1);
  for(const input of [null,{}, {query:''},{query:' '},{query:42},{query:'x'.repeat(1001)},
    {query:'alpha',from:'today'}, {query:'alpha',from:['2026-10-13']},{query:'alpha',from:'2026-13-01'}, {query:'alpha',from:'2026-10-14',to:'2026-10-13'}])
    check.equal((await search(db,req('/input-memory/search',input))).status,400);
});
test('search Beijing date window includes midnight and excludes adjacent days', async () => {
  const db=database();
  const dates=['2026-10-12T23:59:59+08:00','2026-10-13T00:00:00+08:00','2026-10-13T07:59:59+08:00','2026-10-13T23:59:59+08:00','2026-10-14T00:00:00+08:00'];
  await send(db,dates.map((created,i)=>record(i+1,{created,updated:created})));
  const result=await find(db,{query:'alpha',from:'2026-10-13',to:'2026-10-13'});
  check.deepEqual(result.records.map(r=>r.id).sort(),[id(2),id(3),id(4)]);
});
test('calendar-invalid timestamps and dates are rejected instead of silently normalized', async () => {
  const db=database();
  for(const created of ['2026-02-30T10:00:00Z','2026-02-29T10:00:00Z','2026-04-31T10:00:00Z'])
    check.equal((await sync(db,req('/input-memory/sync',batch([record(1,{created,updated:created})])))).status,400);
  for(const from of ['2026-02-30','2026-02-29','2026-04-31'])
    check.equal((await search(db,req('/input-memory/search',{query:'alpha',from}))).status,400);
  check.equal((await sync(db,req('/input-memory/sync',batch([record(1,{created:'2024-02-29T10:00:00Z',updated:'2024-02-29T10:00:00Z'})])))).status,200);
});
test('storage errors are generic, do not disclose SQL or input text', async () => {
  const env={CLIENT_TOKEN:'secret',INPUT_MEMORY:{prepare(){throw new Error('secret SQL');}}};
  const response=await worker.fetch(req('/input-memory/changes',undefined,{'X-Growth-Token':'secret'}),env,{});
  check.equal(response.status,500); check.deepEqual(await response.json(),{error:'input_memory_storage_failed'});
});
let passed=0,failed=0;
for(const [name,fn] of tests) {
  try { await fn(); passed++; console.log('✅',name); }
  catch(error) { failed++; console.error('🔴',name,'\n',error.stack); }
}
console.log(`Input-memory SQLite: ${passed} passed, ${failed} failed; ${assertions} executed assertions`);
process.exitCode=failed?1:0;
