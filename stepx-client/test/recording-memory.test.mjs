import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';
import { createHash } from 'node:crypto';
import { fixture, source, plain } from './fixture.mjs';

function setup() {
  const f = fixture();
  for (const [file, names] of [
    ['recording-memory-data.ts', ['projectRecordingMemory', 'canonicalRecording']],
    ['recording-memory.ts', ['RecordingMemorySync']],
  ]) {
    const text = fs.readFileSync(new URL('../src/growth/' + file, import.meta.url), 'utf8')
      .replace(/^import .*\n/gm, '').replace(/export /g, '');
    vm.runInContext('(function(){' + stripTypeScriptTypes(text, { mode: 'transform' })
      + '\n' + names.map(name => 'globalThis.' + name + '=' + name + ';').join('\n') + '})()', f.c);
  }
  let ready = true, handler = null;
  const sent = [];
  const connection = { subscribe: () => () => {}, isReady: () => ready, async request(path, body, timeout) {
    assert.equal(path, '/recording-memory/sync'); assert.equal(timeout, 15000);
    sent.push(structuredClone(body));
    if (handler) await handler(body);
    return { schema: 'apt.recording-memory.receipt/1', stale: [], conflicts: [],
      accepted: body.records.map(record => ({ id: record.id, revision: record.revision,
        fingerprint: createHash('sha256').update(JSON.stringify(f.c.canonicalRecording(record, body.device_id))).digest('hex') })) };
  } };
  const deps = { connection, transact: apply => f.c.sourceTransaction('readwrite', apply, ['recording_memory']) };
  return { ...f, sent, deps, runner: new f.c.RecordingMemorySync(deps),
    ready: value => { ready = value; }, handler: value => { handler = value; },
    rows: () => f.c.idbGetAll('recording_memory'),
    async memory() { return (await this.rows()).filter(row => row.record); } };
}
test('transcribed time-unverified recordings remain local and count as unavailable after restart', async () => {
  const f = setup(), data = source();
  data.matters[0].recordingTimeUnverified = true;
  await f.seed(data); await f.runner.kick();
  assert.equal(f.sent.length, 0); assert.equal(f.runner.getSnapshot().unavailable, 3);
  assert.equal((await f.c.readSources()).jobs[0].lines[0].text, data.jobs[0].lines[0].text);
  const reopened = new f.c.RecordingMemorySync(f.deps); await reopened.kick();
  assert.equal(reopened.getSnapshot().unavailable, 3);
  data.jobs[0].lines = []; data.jobs[1].lines = undefined;
  let unavailable = 0;
  assert.equal(f.c.projectRecordingMemory(data, () => { unavailable++; }).length, 0);
  assert.equal(unavailable, 1, '没有原话的材料不计为待同步缺失');
});
test('v4 data upgrades by adding only the replica store; two databases get independent stable identities', async () => {
  const a = setup(), b = setup();
  await new Promise((resolve, reject) => {
    const open = a.c.indexedDB.open('growth', 4);
    open.onupgradeneeded = () => {
      for (const name of ['matters', 'segments', 'blobs', 'processing', 'actions', 'topics', 'messages'])
        open.result.createObjectStore(name, { keyPath: 'id' });
    };
    open.onerror = () => reject(open.error);
    open.onsuccess = () => {
      const db = open.result, tx = db.transaction(['blobs', 'topics', 'actions'], 'readwrite');
      tx.objectStore('blobs').put({ id: 'old', blob: new Blob(['keep original']) });
      tx.objectStore('topics').put({ id: 'old', title: 'retained topic' });
      tx.objectStore('actions').put({ id: 'old', title: 'retained action', status: 'done' });
      tx.oncomplete = () => { db.close(); resolve(); };
    };
  });
  await a.seed(source()); await b.seed(source());
  await a.runner.kick(); await b.runner.kick();
  const namespace = a.sent[0].device_id;
  assert.notEqual(namespace, b.sent[0].device_id);
  assert.equal((await a.c.idbGet('topics', 'old')).title, 'retained topic');
  assert.equal((await a.c.idbGet('actions', 'old')).status, 'done');
  assert.equal(await (await a.c.idbGet('blobs', 'old')).blob.text(), 'keep original');
  const fresh = new a.c.RecordingMemorySync(a.deps); await fresh.kick();
  assert.equal(a.sent.length, 3); assert.equal((await a.rows()).find(row => row.id === '__identity__').namespace, namespace);
  assert.equal(fresh.getSnapshot().pending, 0); assert.equal(fresh.getSnapshot().acknowledged, 3);
});
test('canonical fingerprint agrees with the shared Worker shape, including normalized tombstones', () => {
  const f = setup(), record = { id: 'apt_recording_12345678-1234-1234-1234-123456789abc', revision: 2,
    created: '2026-10-14T00:00:00Z', updated: '2026-10-15T00:00:00Z', title: 'old', text: 'discard',
    partial: false, deleted: true };
  const canonical = f.c.canonicalRecording(record, '12345678-1234-1234-1234-123456789ABC');
  assert.equal(JSON.stringify(canonical), '{"device_id":"12345678-1234-1234-1234-123456789abc","id":"apt_recording_12345678-1234-1234-1234-123456789abc","revision":2,"created":"2026-10-14T00:00:00.000Z","updated":"2026-10-15T00:00:00.000Z","title":"已移出记忆","text":"","partial":false,"deleted":true}');
});
test('offline edits and deletion clear replica plaintext in the formal write transaction, retaining user data', async () => {
  const f = setup(); await f.seed(source()); await f.runner.kick(); f.ready(false);
  const before = await f.memory(), work = await f.c.idbGet('processing', 'r-p0');
  work.lines[0].text = 'new public text'; work.lineRevision = 1;
  await f.c.idbPut('processing', work);
  for (const row of await f.memory()) { assert.equal(row.record.text, ''); assert.equal(row.record.deleted, true); assert.equal(row.record.revision, 2); }
  assert.equal((await f.c.idbGet('processing', 'r-p0')).lines[0].text, 'new public text');
  await f.runner.kick(); const rebuilt = await f.memory();
  assert.equal(rebuilt.find(row => row.jobId === 'r-p0').record.revision, 3);
  assert.equal(rebuilt.find(row => row.jobId === 'r-p0').record.id, before.find(row => row.jobId === 'r-p0').record.id);
  assert.ok(rebuilt.find(row => row.jobId === 'r-p0').record.text.includes('new public text'));
  await f.c.idbDeleteMatter('r');
  assert.ok((await f.memory()).every(row => row.record.deleted && row.record.text === '' && row.record.revision === 4));
  f.ready(true); await f.runner.kick(); assert.equal(f.runner.getSnapshot().pending, 0);
  assert.ok(f.sent.at(-1).records.every(row => row.deleted && row.text === ''));
});
test('a late acknowledgement cannot acknowledge a deletion or resurrect its original sources', async () => {
  const f = setup(); await f.seed(source()); let once = true;
  f.handler(async () => { if (once) { once = false; await f.c.idbDeleteMatter('r'); } });
  await f.runner.kick();
  assert.equal(f.sent.length, 2);
  assert.ok(f.sent[0].records.every(row => !row.deleted));
  assert.ok(f.sent[1].records.every(row => row.deleted && row.revision === 2));
  assert.ok((await f.memory()).every(row => row.record.deleted && row.acknowledged === 2));
  assert.equal((await f.c.readSources()).matters.length, 0);
});
test('a failed second transcript preserves the first receipt and resumes with identical IDs and versions', async () => {
  const f = setup(); await f.seed(source()); let calls = 0;
  f.handler(async () => { if (++calls === 2) throw Error('offline fixture'); });
  await f.runner.kick(); assert.ok(f.runner.getSnapshot().error);
  const initial = await f.memory(); assert.equal(initial.filter(row => row.acknowledged === 1).length, 1);
  f.handler(null); await f.runner.kick();
  assert.equal(f.runner.getSnapshot().pending, 0);
  assert.deepEqual(plain((await f.memory()).map(row => row.record.id)), plain(initial.map(row => row.record.id)));
  assert.deepEqual(plain(f.sent[2]), plain(f.sent[1]));
});
test('malformed or mismatched receipt is never acknowledged', async () => {
  for (const accepted of [[], [{ id: 'wrong', revision: 1, fingerprint: 'a'.repeat(64) }]]) {
    const f = setup(); await f.seed(source());
    f.deps.connection.request = async () => ({ schema: 'apt.recording-memory.receipt/1', stale: [], conflicts: [], accepted });
    await f.runner.kick(); assert.ok(f.runner.getSnapshot().error);
    assert.equal((await f.memory()).filter(row => row.acknowledged).length, 0);
  }
});
test('a competing window cannot send while the durable owner holds the lease', async () => {
  const f = setup(); await f.seed(source()); const other = new f.c.RecordingMemorySync(f.deps);
  f.handler(async () => { const count = f.sent.length; await other.kick(); assert.equal(f.sent.length, count); });
  await f.runner.kick(); assert.equal(f.sent.length, 3); assert.equal(f.runner.getSnapshot().pending, 0);
});
test('twenty-batch budget leaves later work durable and the next opportunity drains it', async () => {
  const f = setup(), data = source(); data.segments = []; data.jobs = [];
  for (let index = 0; index < 21; index++) {
    const s = source(); const segment = { ...s.segments[0], id: 'p' + index, index };
    data.segments.push(segment); data.jobs.push({ ...s.jobs[0], id: segment.id, index, events: [] });
  }
  await f.seed(data); await f.runner.kick();
  assert.equal(f.sent.length, 20); assert.equal(f.runner.getSnapshot().pending, 1);
  await f.runner.kick(); assert.equal(f.sent.length, 21); assert.equal(f.runner.getSnapshot().pending, 0);
});
test('large historical tombstone sets drain without a live transcript being split', async () => {
  const f = setup();
  for (let index = 0; index < 2001; index++) await f.c.idbPut('recording_memory', {
    id: 'old' + index, recordingId: 'gone', jobId: 'gone', acknowledged: 0,
    record: { id: 'apt_recording_' + crypto.randomUUID(), revision: 2,
      created: '2026-10-14T00:00:00.000Z', updated: '2026-10-15T00:00:00.000Z',
      title: '已移出记忆', text: '', deleted: true, partial: false },
  });
  await f.runner.kick(); assert.deepEqual(f.sent.map(row => row.records.length), [1000, 1001]);
  assert.equal(f.runner.getSnapshot().pending, 0);
});
test('local diagnostics, uncertain ownership and redacted originals never enter exported text', () => {
  const f = setup(), data = source();
  data.segments[0].cloudEligible = false;
  data.jobs[1].lines[0].redacted = true; data.jobs[1].lines[0].text = 'private removed';
  const projected = f.c.projectRecordingMemory(data);
  assert.equal(projected.length, 1); assert.equal(projected[0].jobId, 'r-p2');
  assert.equal(projected[0].partial, true); assert.ok(!JSON.stringify(projected).includes('private removed'));
  data.matters[0].recordingTimeUnverified = true;
  assert.equal(f.c.projectRecordingMemory(data).length, 0);
});
test('Shanghai midnight splits sources and partial evidence never carries a full-event AI summary', () => {
  const f = setup(), data = source(); data.matters[0].startedAt = Date.parse('2026-10-14T15:59:59Z');
  data.segments = [data.segments[0]]; data.segments[0].capturedAt = data.matters[0].startedAt; data.segments[0].durationSec = 3;
  data.jobs = [data.jobs[0]];
  const job = data.jobs[0];
  job.lines = [job.lines[0], { ...job.lines[0], line_id: 2, text: 'next day public text', t_sec: 2, t_end_sec: 3 }];
  job.requestLines = structuredClone(job.lines);
  job.events[0] = { ...job.events[0], lineIds: [1, 2], startedAt: data.matters[0].startedAt,
    endedAt: data.matters[0].startedAt + 3000, summary: 'all two lines' };
  const projected = f.c.projectRecordingMemory(data);
  assert.equal(projected.length, 2);
  assert.equal(projected[0].created.slice(0, 19), '2026-10-14T15:59:59');
  assert.equal(projected[1].created.slice(0, 19), '2026-10-14T16:00:01');
  const bodies = projected.map(row => JSON.parse(row.text));
  assert.equal(bodies[0].events[0].semantic_id, bodies[1].events[0].semantic_id);
  assert.ok(bodies.every(row => !('ai_summary' in row.events[0])));
});
test('oversized single originals become explicit unavailable markers while formal text stays complete', () => {
  const f = setup(), data = source(); data.jobs[0].lines[0].text = 'x'.repeat(16000);
  const projected = f.c.projectRecordingMemory(data), row = projected.find(row => row.jobId === 'r-p0');
  assert.equal(row.partial, true); assert.ok(JSON.parse(row.text).unavailable);
  assert.equal(data.jobs[0].lines[0].text.length, 16000);
});
test('an aborted combined formal write rolls back both the source and its revocation', async () => {
  const f = setup(); await f.seed(source()); await f.runner.kick();
  await assert.rejects(f.c.sourceTransaction('readwrite', (_source, put) => {
    const job = source().jobs[0]; job.lines[0].text = 'must roll back'; put('processing', job);
    put('recording_memory', { id: 'bad', notCloneable() {} });
  }, ['recording_memory']));
  assert.equal((await f.c.idbGet('processing', 'r-p0')).lines[0].text, 'I will send the plan');
  assert.ok((await f.memory()).every(row => !row.record.deleted && row.record.revision === 1));
});
test('a continuation from local-only material cannot export that private semantic title', () => {
  const f = setup(), data = source();
  data.segments = data.segments.slice(0, 2); data.jobs = data.jobs.slice(0, 2);
  data.jobs[0].events[0].title = 'PRIVATE ROOT TITLE'; data.jobs[0].events[0].latestTitle = 'PRIVATE ROOT TITLE';
  const prior = f.c.projectedEvents(data).find(row => row.id === 'r:1');
  data.jobs[1].requestLines[0].stream_context = f.c.previousContext(prior, data.matters[0].startedAt);
  data.jobs[1].events[0] = { ...data.jobs[1].events[0], id: 'r:1', semanticId: 1, title: 'PRIVATE ROOT TITLE' };
  assert.equal(f.c.projectedEvents(data).length, 1);
  data.segments[0].cloudEligible = false;
  const exported = f.c.projectRecordingMemory(data);
  assert.equal(exported.length, 1); assert.equal(exported[0].jobId, 'r-p1');
  assert.ok(!JSON.stringify(exported).includes('PRIVATE ROOT TITLE'));
  assert.equal(JSON.parse(exported[0].text).events.length, 0);
});
test('a bad-date source cannot block other transcripts or an offline deletion tombstone', async () => {
  const f = setup(); await f.seed(source()); await f.runner.kick(); f.ready(false);
  await f.c.idbDeleteMatter('r'); const bad = source('bad');
  bad.matters[0].startedAt = NaN; await f.seed(bad); await f.seed(source('good'));
  f.ready(true); await f.runner.kick();
  assert.equal(f.runner.getSnapshot().error, null); assert.equal(f.runner.getSnapshot().unavailable, 3);
  assert.equal(f.runner.getSnapshot().pending, 0);
  assert.ok(f.sent.slice(3).some(batch => batch.records.every(row => row.deleted)));
  assert.ok(f.sent.slice(3).some(batch => batch.records.some(row => row.text.includes('good'))));
  assert.equal((await f.c.idbGet('processing', 'bad-p0')).lines[0].text, 'I will send the plan');
});
test('a line before its actual segment start cannot be presented as complete earlier evidence', () => {
  const f = setup(), data = source(); data.jobs[2].lines[0].t_sec = 0;
  const row = f.c.projectRecordingMemory(data).find(value => value.jobId === 'r-p2');
  assert.equal(row.partial, true); assert.ok(JSON.parse(row.text).unavailable);
});
test('same ID and revision with a wrong canonical fingerprint leaves its outbox pending', async () => {
  const f = setup(); await f.seed(source());
  f.deps.connection.request = async (_path, body) => ({ schema: 'apt.recording-memory.receipt/1', stale: [], conflicts: [],
    accepted: body.records.map(row => ({ id: row.id, revision: row.revision, fingerprint: 'a'.repeat(64) })) });
  await f.runner.kick(); assert.ok(f.runner.getSnapshot().error);
  assert.ok((await f.memory()).every(row => row.acknowledged === 0));
});
test('a skipped middle piece marks every remaining source in that recording partial', () => {
  const f = setup(), data = source(); data.segments[1].capturedAt = NaN;
  let unavailable = 0; const rows = f.c.projectRecordingMemory(data, () => { unavailable++; });
  assert.equal(unavailable, 1); assert.equal(rows.length, 2); assert.ok(rows.every(row => row.partial));
});
test('all formal write paths revoke old and new owners when an existing job changes ownership', async () => {
  for (const method of ['put', 'update', 'many', 'transaction']) {
    const f = setup(); await f.seed(source()); await f.runner.kick();
    const job = await f.c.idbGet('processing', 'r-p0'); job.recordingId = 'other';
    if (method === 'put') await f.c.idbPut('processing', job);
    if (method === 'update') await f.c.idbUpdate('processing', job.id, () => job);
    if (method === 'many') await f.c.idbPutMany([{ store: 'processing', value: job }]);
    if (method === 'transaction') await f.c.sourceTransaction('readwrite', (_source, put) => put('processing', job));
    assert.ok((await f.memory()).every(row => row.record.deleted && row.record.text === '' && row.record.revision > 1), method);
  }
});
test('a regrouped transcript sends old tombstones and its new live rows in one revision batch', async () => {
  const f = setup(), data = source(); data.segments = [data.segments[0]]; data.segments[0].durationSec = 20;
  data.jobs = [data.jobs[0]]; const job = data.jobs[0]; job.events = [];
  job.lines = Array.from({ length: 9 }, (_, index) => ({ ...job.lines[0], line_id: index + 1,
    text: 'public line ' + index, t_sec: index, t_end_sec: index + 1 }));
  await f.seed(data); await f.runner.kick(); assert.equal(f.sent[0].records.length, 2);
  const work = await f.c.idbGet('processing', job.id); work.lines.splice(0, 1); work.lineRevision = 1;
  await f.c.idbPut('processing', work); await f.runner.kick();
  assert.equal(f.sent.length, 2); const batch = f.sent[1];
  assert.ok(batch.records.some(row => row.deleted)); assert.ok(batch.records.some(row => !row.deleted));
  assert.equal(batch.records.length, 3);
});
