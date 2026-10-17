import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';
const root = new URL('../src/growth/', import.meta.url);
function load(files, extra = {}) {
  const ctx = { crypto, Blob, Uint8Array, ArrayBuffer, DataView, TextDecoder, structuredClone, console, setTimeout, clearTimeout,
    initBridge: async () => 'native', invokeNative: async () => ({}), ...extra }; vm.createContext(ctx);
  for (const [file, names] of files) {
    const source = fs.readFileSync(new URL(file, root), 'utf8').replace(/^import[\s\S]*?from ['"][^'"]+['"]\s*\n/gm, '').replace(/export /g, '');
    vm.runInContext(stripTypeScriptTypes(source, { mode: 'transform' }) + '\n' + names.map(n => `globalThis.${n}=${n};`).join('\n'), ctx, { filename: file });
  }
  return ctx;
}
const uuid = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const session = { captureId: uuid(1), matterId: uuid(2), indexBase: 0, chunkSeconds: 300, limitSeconds: 43200, state: 'stopped', frames: 16000, startedAt: 1791990000000, reason: 'requested' };
const piece = { captureId: uuid(1), matterId: uuid(2), index: 0, piece: 0, frames: 16000, frameOffset: 0, capturedAt: session.startedAt, size: 32044,
  sha256: 'a'.repeat(64), file: `apt-root-${uuid(1)}-0000.wav`, cloudEligible: true };
const status = () => ({ version: 1, runtime: '1.0.0', epoch: uuid(3), updatedAt: Date.now(), validation: false, lastCommand: {}, sessions: [structuredClone(session)], pieces: [] });
const parser = () => load([['root-recording.ts', ['parseRootStatus', 'validateRootWav', 'RootRecordingClient']]], { sha256: async () => 'a'.repeat(64), AbortController });
test('native deletion requires durable root acknowledgement; offline or refused deletion retains its revocation', async () => {
  for (const mode of ['success','offline','refused','native-failure','cleanup-failure']) {
    const calls=[],pending=new Map(),key=`growth.root.capture.deleted.${uuid(2)}`;
    const c=load([['root-recording.ts',['RootRecordingClient']]],{sha256:async()=>'',AbortController,
      invokeNative:async(action,args)=>{calls.push(action);if(mode==='native-failure'&&action==='setStorage')throw Error('native-write');
        if(action==='setStorage')pending.set(args.key,args.data);
        if(action==='removeStorage'){if(mode==='cleanup-failure')throw Error('cleanup');pending.delete(args.key);}return {};}});
    const client=new c.RootRecordingClient();client.status=async()=>mode==='offline'?null:{...status(),uploads:[]};
    client.command=async(_s,action)=>{calls.push(action);assert.equal(pending.get(key),'deleted');if(mode==='refused')throw Error('refused');};
    if(['success','cleanup-failure'].includes(mode))await client.revokeMatter(uuid(2));
    else await assert.rejects(client.revokeMatter(uuid(2)));
    assert.equal(pending.has(key),['offline','refused','cleanup-failure'].includes(mode));
    assert.deepEqual(calls,mode==='native-failure'?['setStorage']:mode==='offline'?['setStorage']:
      mode==='refused'?['setStorage','forget']:['setStorage','forget','removeStorage']);
  }
});
test('root receipts reject foreign owner, index, path, length, duplicate and diagnostic upload', () => {
  const c = parser(), s = status(); s.pieces = [piece]; assert.equal(c.parseRootStatus(s).pieces.length, 1);
  for (const patch of [{ matterId: uuid(9) }, { index: 3 }, { frameOffset: 1 }, { size: 32045 }, { file: '../x.wav' }, { frames: 0 }, { sha256: 'bad' }])
    assert.throws(() => c.parseRootStatus({ ...s, pieces: [{ ...piece, ...patch }] }));
  assert.throws(() => c.parseRootStatus({ ...s, pieces: [piece, piece] }));
  assert.throws(() => c.parseRootStatus({ ...s, validation: true }));
});
test('canonical root WAV keeps exact PCM; malformed headers and wrong frames are rejected', async () => {
  const c = load([['audio.ts', ['encodeWav', 'toWav']], ['root-recording.ts', ['validateRootWav']]], { sha256: async () => '' });
  const bytes = c.encodeWav(new Float32Array(16000).fill(.25), 16000); c.validateRootWav(bytes, 16000);
  assert.deepEqual(await c.toWav(new Blob([bytes])), bytes);
  assert.throws(() => c.validateRootWav(bytes.slice(0, -1), 16000));
  assert.throws(() => c.validateRootWav(bytes, 15999));
  const corrupt = bytes.slice(); corrupt[24] = 1; assert.throws(() => c.validateRootWav(corrupt, 16000));
});
test('stale runtime and changed epoch never become successful commands', async () => {
  const c = parser(), client = new c.RootRecordingClient(), s = status();
  assert.throws(() => client.fresh({ ...s, updatedAt: Date.now() - 9000 }));
  client.status = async () => ({ ...s, epoch: uuid(8) });
  await assert.rejects(client.command(s, 'start', {}), /重启/);
});
function fixture({ state = 'stopped', commitResult = 'saved', commitFail = false, ackFail = false, minutes = 5, background = false, compactRoot = false, compactBackend = false, validation = false } = {}) {
  let now = Date.now(), journal, s = status(), sequence = 10, commits = 0;
  s.sessions[0].state = state; s.updatedAt = now; s.validation=validation;
  if (background) { s.sessions[0].uploadClient = uuid(3); s.uploads=[]; }
  if (compactRoot) s.audioFormats=['wav','m4a'];
  if (state === 'failed') s.sessions[0].reason = 'controller-lost';
  const matter = { id: uuid(2), startedAt: session.startedAt, endedAt: null, origin: 'record' }, rows = new Map([[matter.id, matter]]), segments = new Map(), calls = [], events = new Map(), uploads = [];
  journal = { version: 1, matterId: matter.id, captureId: uuid(1), stopping: null };
  const store = { init: async () => {}, getSnapshot: () => ({ storageOk: true }), getMatter: id => rows.get(id), segmentsOf: id => [...segments.values()].filter(row => row.matterId === id),
    async createMatter() { const row = { ...matter, id: uuid(++sequence) }; rows.set(row.id, row); return row; },
    async updateMatter(id, patch) { rows.set(id, { ...rows.get(id), ...patch }); },
    async authorizeRootStart(id,client,start) { rows.set(id,{...rows.get(id),rootUploadClient:client});return start(); },
    async commitRootAudio(row) { commits++; if (commitFail) throw Error('quota'); if (commitResult === 'saved') segments.set(row.id, row); return commitResult; } };
  const client = { revokeMatter: async matterId => { calls.push({ action:'forget', fields:{matterId} }); s.sessions.forEach(row => { if(row.matterId===matterId)row.uploadRevoked=true; }); }, status: async () => structuredClone(s), fresh: v => { if (now - v.updatedAt > 8000) throw Error('offline'); }, audio: async () => new Blob([new Uint8Array(32044)]), url: p => 'https://appassets.t-stepos.com/media/' + p.file,
    async command(_, action, fields) { calls.push({ action, fields }); if (action === 'ack') { if (ackFail) throw Error('ack unknown'); s.pieces = []; }
      if (action === 'stop') { const row=s.sessions.find(row=>row.captureId===fields.captureId);if(row&&['starting','recording','stopping'].includes(row.state))row.state='stopped'; }
      if (action === 'start') s.sessions.push({...structuredClone(session),...fields,frames:0,state:'recording'});
      return structuredClone(s); } };
  const deps = { store, clientId: async () => uuid(3), invoke: async (api, p) => { if (api === 'getStorage') return { data: JSON.stringify(journal) }; if (api === 'setStorage') journal = JSON.parse(p.data); if (api === 'requestPermission') return { granted: true }; return {}; },
    compressedAudioReady:()=>compactBackend,
    listen: async (name, fn) => { events.set(name, fn); return () => events.delete(name); }, upload: id => uploads.push(id), now: () => now, id: () => uuid(++sequence), sleep: async ms => { now += ms; s.updatedAt = now; } };
  const c = load([['root-recording.ts', ['rootUuid']], ['root-recorder.ts', ['RootRecorder']]], { growthStore: store, enqueueUpload: deps.upload, onNativeEvent: deps.listen,
    getSegmentMinutes: () => minutes, RootRecordingClient: function () {}, ROOT_JOURNAL_KEY: 'journal', document: { visibilityState: 'visible', addEventListener: () => {}, removeEventListener: () => {} }, setInterval: () => 1, clearInterval: () => {} });
  const runner = new c.RootRecorder(client, deps);
  return { runner, client, deps, rows, segments, calls, uploads, events, setPieces: (pieces=[piece]) => s.pieces = structuredClone(pieces), commits: () => commits,
    fresh: () => new c.RootRecorder(client, deps), journal: () => journal, failCommit: value => commitFail = value, failAck: value => ackFail = value,
    setState: value => { s.sessions[0].state = value; s.sessions[0].reason = value === 'failed' ? 'controller-lost' : null; },
    deleteOwner: () => rows.clear(), deleted: () => store.wasMatterDeleted = async () => true,
    stale: () => s.updatedAt = now - 10000 };
}
test('new recording negotiates compact audio only when root and actual backend both advertise it',async()=>{
 for(const compactRoot of [false,true])for(const compactBackend of [false,true]) {
  const t=fixture({background:true,compactRoot,compactBackend});await t.runner.start();
  assert.equal(t.calls.find(row=>row.action==='start').fields.audioFormat,compactRoot&&compactBackend?'m4a':undefined);
 }
});
test('validation capture remains local WAV even if an incorrect capability advertises AAC',async()=>{
  const t=fixture({compactRoot:true,compactBackend:true,validation:true});await t.runner.start();
  const start=t.calls.find(row=>row.action==='start');assert.equal(start.fields.audioFormat,undefined);
  assert.equal(start.fields.uploadClient,undefined);
});
test('compressed root receipts retain source frames and reject undeclared formats or changed hashes',()=>{
 const c=parser(),s=status();s.audioFormats=['wav','m4a'];s.sessions[0].audioFormat='m4a';
 const compact={...piece,audioFormat:'m4a',size:4000,file:piece.file.replace('.wav','.m4a')};
 s.pieces=[compact];assert.equal(c.parseRootStatus(s).pieces[0].frames,16000);
 assert.throws(()=>c.parseRootStatus({...s,sessions:[{...s.sessions[0],audioFormat:undefined}]}));
 assert.throws(()=>c.parseRootStatus({...s,pieces:[{...compact,audioFormat:'mp3'}]}));
 assert.throws(()=>c.parseRootStatus({...s,audioFormats:['wav','wav']}));
});
test('native server receipts require exact owner, finite frames/time, unique pieces and a real success timestamp', () => {
  const c = parser(), s = status(); s.sessions[0].uploadClient = uuid(3);
  const upload = { captureId: uuid(1), matterId: uuid(2), piece: 0, frames: 16000, sha256: 'a'.repeat(64),
    key: `stepx/${uuid(3)}/${uuid(2)}/${uuid(4)}-${'a'.repeat(64)}.wav`, durationSec: 1, state: 'uploaded', uploadedAt: Date.now() };
  s.uploads = [upload]; assert.equal(c.parseRootStatus(s).uploads[0].state, 'uploaded');
  for (const patch of [{ matterId: uuid(7) }, { frames: 16000.5 }, { durationSec: 'NaN' }, { durationSec: NaN },
    { uploadedAt: '1' }, { key: 'https://other.invalid/audio.wav' }, { state: 'done' }])
    assert.throws(() => c.parseRootStatus({ ...s, uploads: [{ ...upload, ...patch }] }));
  assert.throws(() => c.parseRootStatus({ ...s, validation: true }));
  assert.throws(() => c.parseRootStatus({ ...s, uploads: [upload,upload] }));
});
test('missing native ownership cannot downgrade a new piece to the legacy uploader', () => {
  const c=parser(),s=status();s.sessions[0].uploadClient=uuid(3);s.pieces=[{...piece,uploadClient:uuid(3)}];
  assert.equal(c.parseRootStatus(s).pieces[0].uploadClient,uuid(3));
  for(const client of [undefined,uuid(9)])assert.throws(()=>c.parseRootStatus({...s,pieces:[{...piece,uploadClient:client}]}));
  const old=status();old.pieces=[piece];assert.equal(c.parseRootStatus(old).pieces[0].uploadClient,undefined);
});
test('10-minute root START persists upload ownership and passes the stable cloud client', async () => {
  const t = fixture({ minutes: 10, background:true }); await t.runner.start();
  const start = t.calls.find(row => row.action === 'start');
  assert.equal(start.fields.chunkSeconds, 600); assert.equal(start.fields.uploadClient, uuid(3));
  assert.equal(t.rows.get(uuid(2)).rootUploadClient, uuid(3));
});
test('starting on an older root keeps its legacy upload ownership and needs no new client identity', async () => {
  const t=fixture();t.deps.clientId=async()=>{throw Error('new upload identity must not be requested');};
  await t.runner.start();const start=t.calls.find(row=>row.action==='start');assert.ok(start);
  assert.equal(start.fields.uploadClient,undefined);assert.equal(t.rows.get(start.fields.matterId).rootUploadClient,undefined);
});
test('saved, duplicate and deleted ACKs retain distinct upload dispositions', async () => {
  for (const [commitResult,disposition] of [['saved','saved'],['duplicate','saved'],['deleted','deleted']]) {
    const t=fixture({commitResult});t.setPieces();await t.runner.initialize();
    assert.equal(t.calls.find(row=>row.action==='ack').fields.disposition,disposition);
  }
});
test('a durable deletion revokes a saved native upload; a missing owner alone cannot revoke it', async () => {
  for (const deleted of [false,true]) {
    const t=fixture({background:true});await t.runner.initialize();t.deleteOwner();if(deleted)t.deleted();
    await t.runner.retryRecovery();assert.equal(t.calls.some(row=>row.action==='forget'),deleted);
    await t.runner.retryRecovery();assert.equal(t.calls.filter(row=>row.action==='forget').length,deleted?1:0);
  }
});
test('unexpected root interruption remains visible and distinct from user pause, clearing only on actual live status', async () => {
  const t = fixture({ state: 'failed' }); t.setPieces(); await t.runner.initialize();
  const failed = t.runner.getSnapshot();
  assert.equal(failed.state, 'paused'); assert.equal(failed.interrupted, true);
  assert.match(failed.notice, /中断/); assert.equal(failed.matterId, uuid(2));
  assert.equal(t.segments.size, 1); assert.equal(t.rows.get(uuid(2)).endedAt, null);
  t.setState('recording'); await t.runner.retryRecovery();
  assert.equal(t.runner.getSnapshot().state, 'recording'); assert.equal(t.runner.getSnapshot().interrupted, false);
  const paused = fixture(); await paused.runner.initialize(); assert.equal(paused.runner.getSnapshot().interrupted, false);
});
test('cold reopening adopts the same live root session, without another start or appHide stop', async () => {
  const t = fixture({ state: 'recording' }); await t.runner.initialize();
  assert.equal(t.runner.getSnapshot().state, 'recording'); assert.equal(t.runner.getSnapshot().elapsedSec, 1);
  assert.equal(t.calls.length, 0); assert.equal(t.events.has('appHide'), false);
  const fresh = t.fresh(); await fresh.initialize(); assert.equal(fresh.getSnapshot().matterId, uuid(2)); assert.equal(t.calls.length, 0);
});
test('Blob commit failure cannot ACK; retry after reopening receives the original piece', async () => {
  const t = fixture({ commitFail: true }); t.setPieces(); await t.runner.initialize();
  assert.equal(t.runner.getSnapshot().state, 'recovering'); assert.equal(t.calls.length, 0);
  t.failCommit(false); await t.fresh().initialize(); assert.equal(t.segments.size, 1); assert.equal(t.calls[0].action, 'ack');
});
test('lost ACK retries delivery without another segment or cloud submission', async () => {
  const t = fixture({ ackFail: true, commitResult: 'duplicate' }); t.setPieces(); await t.runner.initialize();
  assert.equal(t.runner.getSnapshot().state, 'recovering'); t.failAck(false); await t.fresh().initialize();
  assert.equal(t.calls.filter(x => x.action === 'ack').length, 2); assert.equal(t.uploads.length, 0);
});
test('durably deleted owner is ACKed without resurrecting; missing owner retains original', async () => {
  const deleted = fixture({ commitResult: 'deleted' }); deleted.setPieces(); await deleted.runner.initialize(); assert.equal(deleted.segments.size, 0); assert.equal(deleted.calls[0].action, 'ack');
  const missing = fixture({ commitResult: 'missing' }); missing.setPieces(); await missing.runner.initialize(); assert.equal(missing.calls.length, 0); assert.equal(missing.runner.getSnapshot().state, 'recovering');
});
test('pause preserves owner and tail; finish durably ends it; stale status never claims recording', async () => {
  const t = fixture({ state: 'recording' }); await t.runner.initialize(); t.setPieces(); await t.runner.pause();
  assert.equal(t.runner.getSnapshot().state, 'paused'); assert.equal(t.rows.get(uuid(2)).endedAt, null); assert.equal(t.segments.size, 1);
  await t.runner.finish(); assert.equal(t.runner.getSnapshot().state, 'idle'); assert.ok(t.rows.get(uuid(2)).endedAt); assert.equal(t.rows.get(uuid(2)).captureComplete,true);
  const stale = fixture({ state: 'recording' }); stale.stale(); await stale.runner.initialize(); assert.equal(stale.runner.getSnapshot().state, 'recovering');
});
test('removing the live owner requests stop rather than reconstructing the deleted record', async () => {
  const t = fixture({ state: 'recording' }); await t.runner.initialize(); t.deleteOwner(); await t.runner.retryRecovery();
  assert.equal(t.calls[0].action, 'stop'); assert.equal(t.rows.size, 0);
});
test('journal write and IndexedDB initialization failures cannot prevent microphone stop', async () => {
  for (const failing of ['journal', 'idb']) {
    const t = fixture({ state: 'recording' });
    if (failing === 'journal') {
      await t.runner.initialize(); const invoke = t.deps.invoke;
      t.deps.invoke = async (api, params) => { if (api === 'setStorage') throw Error('quota'); return invoke(api, params); };
    } else t.deps.store.getSnapshot = () => ({ storageOk: false });
    await t.runner.finish();
    assert.equal(t.calls[0].action, 'stop'); assert.equal((await t.client.status()).sessions[0].state, 'stopped');
    assert.equal(t.runner.getSnapshot().state, 'recovering');
  }
});
test('response body is included in the read deadline even when headers succeeded', async () => {
  const c = load([['root-recording.ts', ['RootRecordingClient']]], { sha256: async () => 'a'.repeat(64), AbortController,
    fetch: async () => ({ status: 200, ok: true, headers: { get: () => null }, arrayBuffer: () => new Promise(() => {}) }),
    setTimeout: fn => { queueMicrotask(fn); return 1; }, clearTimeout: () => {} });
  await assert.rejects(new c.RootRecordingClient().audio(piece), /超时/);
});

// Minimal asynchronous IDB platform fixture: serial read/write transactions, rollback,
// request callbacks and oncomplete. The production transaction code is executed unchanged.
function database() {
  const tables = new Map(['matters', 'segments', 'blobs', 'processing', 'recording_memory'].map(name => [name, new Map()])); const queue = []; let active = false;
  const next = () => { if (active || !queue.length) return; active = true; queue.shift()(); };
  const db = { transaction(names) {
    const operations = []; let working, aborted = false, running = false;
    const tx = { error: null, abort() { aborted = true; }, objectStore(name) {
      return Object.fromEntries(['get', 'getAll', 'put', 'delete'].map(action => [action, value => {
        const request = {}; operations.push(() => {
          const table = working.get(name);
          if (action === 'get') request.result = structuredClone(table.get(value));
          if (action === 'getAll') request.result = structuredClone([...table.values()]);
          if (action === 'put') { table.set(value.id, structuredClone(value)); request.result = value.id; }
          if (action === 'delete') table.delete(value);
          request.onsuccess?.();
        }); return request;
      }]));
    } };
    queue.push(() => { working = new Map([...tables].map(([k, v]) => [k, new Map(v)])); running = true; drain(); });
    function drain() { queueMicrotask(() => {
      if (aborted) { tx.onabort?.(); active = false; next(); return; }
      if (operations.length) { operations.shift()(); drain(); return; }
      if (running) { for (const [k, v] of working) tables.set(k, v); tx.oncomplete?.(); active = false; next(); }
    }); }
    queueMicrotask(next); return tx;
  } };
  return { tables, indexedDB: { open() { const request = {}; queueMicrotask(() => { request.result = db; request.onsuccess(); }); return request; } } };
}
test('actual IDB receive/delete transactions serialize both orders and tombstone rejects late delivery', async () => {
  for (const deleteFirst of [false, true]) {
    const fixture = database(); fixture.tables.get('matters').set('m', { id: 'm' });
    const c = load([['idb.ts', ['idbCommitAudio', 'idbDeleteMatter']]], fixture);
    const receive = () => c.idbCommitAudio({ id: 's', matterId: 'm' }, new Blob(['synthetic']), { id: '__root_receipt__:s', sha256: 'x' });
    const operations = deleteFirst ? [c.idbDeleteMatter('m'), receive()] : [receive(), c.idbDeleteMatter('m')]; await Promise.all(operations);
    assert.equal(fixture.tables.get('matters').size, 0); assert.equal(fixture.tables.get('segments').size, 0); assert.equal(fixture.tables.get('blobs').size, 0);
    assert.equal(await receive(), 'deleted'); assert.ok(fixture.tables.get('processing').get('__deleted_matter__:m'));
  }
});

test('closed root session without its tail receipt is preserved but cannot claim complete material',async()=>{
  const t=fixture({state:'recording'});await t.runner.initialize();await t.runner.finish();
  assert.equal(t.runner.getSnapshot().state,'idle');assert.ok(t.rows.get(uuid(2)).endedAt);assert.equal(t.rows.get(uuid(2)).captureComplete,false);
});
test('a late prepared tail completes a finished matter after restart without changing its end time',async()=>{
  const t=fixture({state:'recording'});await t.runner.initialize();await t.runner.finish();
  const endedAt=t.rows.get(uuid(2)).endedAt;assert.equal(t.rows.get(uuid(2)).rootFinalizing,true);
  t.runner.dispose();t.setPieces();const restored=t.fresh();await restored.initialize();
  assert.equal(t.rows.get(uuid(2)).captureComplete,true);assert.equal(t.rows.get(uuid(2)).rootFinalizing,false);
  assert.equal(t.rows.get(uuid(2)).endedAt,endedAt);assert.equal(t.segments.size,1);
});
test('pause then immediate resume reserves the unpublished native tail index',async()=>{
  const t=fixture({state:'recording'});await t.runner.initialize();await t.runner.pause();
  assert.equal(t.segments.size,0);await t.runner.resume();
  const start=t.calls.find(row=>row.action==='start');assert.equal(start.fields.indexBase,1);
  t.setPieces();await t.runner.retryRecovery();assert.equal([...t.segments.values()][0].index,0);
  assert.equal(t.runner.getSnapshot().state,'recording');
});
test('failed captures and deleted owners cannot be completed by late prepared pieces',async()=>{
  const failed=fixture({state:'failed'});await failed.runner.initialize();await failed.runner.finish();
  failed.setPieces();await failed.runner.retryRecovery();assert.equal(failed.rows.get(uuid(2)).captureComplete,false);
  assert.equal(failed.rows.get(uuid(2)).rootFinalizing,false);
  const deleted=fixture({state:'recording',commitResult:'deleted'});await deleted.runner.initialize();await deleted.runner.finish();
  deleted.deleteOwner();deleted.setPieces();await deleted.runner.retryRecovery();assert.equal(deleted.rows.size,0);
});
