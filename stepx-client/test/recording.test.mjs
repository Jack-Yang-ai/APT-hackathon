import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';

const root = new URL('../src/growth/', import.meta.url);
function load(files, extra = {}) {
  const ctx = { crypto, Blob, Uint8Array, ArrayBuffer, URL, structuredClone, console,
    useSyncExternalStore: () => {}, ...extra };
  vm.createContext(ctx);
  for (const [file, names] of files) {
    const source = fs.readFileSync(new URL(file, root), 'utf8')
      .replace(/^import[\s\S]*?from ['"][^'"]+['"]\s*\n/gm, '').replace(/export /g, '');
    vm.runInContext(stripTypeScriptTypes(source, { mode: 'transform' }) + '\n' + names.map(name => `globalThis.${name}=${name};`).join('\n'), ctx, { filename: file });
  }
  return ctx;
}
class BridgeError extends Error { constructor(code, apiName, message) { super(message); this.code = code; this.apiName = apiName; } }
class RecordingAudioFailure extends Error {}
const noRecording = () => new BridgeError('unknown', 'stopRecordAudio', 'stopRecordAudio:fail not recording');
const fileAt = (time, duration = 1) => ({ tempFilePath: `https://studio-api.stepx.com/media/record_${time}.m4a`, duration, size: 16 });
function fixture() {
  const matters = new Map(), segments = new Map(), blobs = new Map(), events = new Map(), documentEvents = new Map(), ticks = new Map();
  let time = 1791960000000, sequence = 0, active = null, journal, readFail = false, commitFail = false, startReject = false, writeFail = () => false;
  let initWait = Promise.resolve(), storageOk = true;
  const calls = [], uploads = [], recovered = [], commits = [];
  const store = {
    async init() { await initWait; },
    getSnapshot: () => ({ ready: true, storageOk, matters: [...matters.values()], segments: [...segments.values()] }),
    getMatter: id => matters.get(id), segmentsOf: id => [...segments.values()].filter(row => row.matterId === id),
    async createMatter() { const row = { id: 'matter-' + ++sequence, startedAt: time, endedAt: null, origin: 'record' }; matters.set(row.id, row); return row; },
    async updateMatter(id, patch) { matters.set(id, { ...matters.get(id), ...patch }); },
    async deleteMatter(id) { matters.delete(id); },
    async commitCapturedAudio(row, blob) { if (commitFail) throw Error('synthetic quota'); commits.push(row.id); segments.set(row.id, structuredClone(row)); blobs.set(row.id, blob); },
    getAudio: async id => blobs.get(id),
  };
  const deps = {
    store, now: () => time, id: () => 'capture-' + ++sequence, isNative: () => true,
    async invoke(api, params) {
      calls.push({ api, params });
      if (api === 'requestPermission') return { granted: true };
      if (api === 'recordAudio') { if (active) throw new BridgeError('unknown', api, 'recordAudio:fail already recording'); active = fileAt(time); if (startReject) throw new BridgeError('unknown', api, 'recordAudio:fail ack lost'); return {}; }
      if (api === 'stopRecordAudio') { if (!active) throw noRecording(); const file = active; active = null; return file; }
      return {};
    },
    async listen(channel, fn) { events.set(channel, fn); return () => events.delete(channel); },
    async readJournal() { return journal ? structuredClone(journal) : ctx.emptyJournal(); },
    async writeJournal(next) { if (writeFail(next)) throw new Error('synthetic native storage failure'); journal = structuredClone(next); },
    async readAudio() { if (readFail) throw new RecordingAudioFailure('synthetic file read failure'); return new Blob([new Uint8Array(16)]); },
    async isSaved(file) { const row = [...segments.values()].find(row => row.localUrl === file.tempFilePath); return Boolean(row && blobs.get(row.id)?.size === file.size); },
    manifest: async () => [], recover: async file => { recovered.push(file); }, upload: id => uploads.push(id),
  };
  const ctx = load([['recording-journal.ts', ['emptyJournal', 'nativeFileName', 'nativeFileStartedAt', 'parseNativeAudio', 'parseJournal']], ['recorder.ts', ['Recorder']]], {
    growthStore: store, newId: deps.id, invokeNative: deps.invoke, onNativeEvent: deps.listen, nativeLog: { w: () => {} },
    getBridgeMode: () => 'native', storage: { get: () => 5, set: () => {} }, enqueueUpload: deps.upload,
    readRecordingJournal: deps.readJournal, writeRecordingJournal: deps.writeJournal, readNativeAudio: deps.readAudio,
    BridgeError, RecordingAudioFailure, readRecoveryManifest: deps.manifest, recoverNativeFile: deps.recover, savedNativeFile: () => undefined,
    document: { visibilityState: 'visible', addEventListener: (name, fn) => documentEvents.set(name, fn), removeEventListener: name => documentEvents.delete(name) },
    setInterval: fn => { const id = ++sequence; ticks.set(id, fn); return id; }, clearInterval: id => ticks.delete(id),
  });
  const runner = new ctx.Recorder(deps);
  return { ctx, deps, runner, calls, uploads, recovered, commits, matters, segments, blobs, documentEvents,
    fresh: () => { runner.dispose(); return new ctx.Recorder(deps); }, journal: () => structuredClone(journal), events,
    failRead: value => readFail = value, failCommit: value => commitFail = value, failWrite: fn => writeFail = fn, rejectStart: value => startReject = value,
    waitInit: promise => initWait = promise, storageOk: value => storageOk = value,
    advance: seconds => { time += seconds * 1000; }, emit: (name, payload) => events.get(name)?.(payload),
    autoStop: () => { const file = active; active = null; time += 1000; events.get('recordAudioStop')?.(file); return file; },
    tick: () => [...ticks.values()].forEach(fn => fn()),
  };
}
async function drain(runner) { for (let i = 0; i < 10; i++) { const current = runner.operations; await current; if (current === runner.operations) return; } throw Error('queue failed to settle'); }

test('start waits for initialization; a failed read can retry without starting native capture', async () => {
  const t = fixture(); let release; t.waitInit(new Promise(resolve => release = resolve));
  const starting = t.runner.start(); await Promise.resolve(); assert.equal(t.calls.length, 0); assert.equal(t.matters.size, 0);
  t.storageOk(false); release(); await starting; assert.equal(t.runner.getSnapshot().state, 'recovering'); assert.equal(t.matters.size, 0);
  t.storageOk(true); await t.runner.start(); assert.equal(t.runner.getSnapshot().state, 'recording'); assert.ok(t.journal().capture);
});
test('native start accepted but acknowledgement rejected retains ownership and saves on finish', async () => {
  const t = fixture(); t.rejectStart(true); await t.runner.start();
  assert.equal(t.runner.getSnapshot().state, 'recovering'); assert.ok(t.journal().capture); assert.equal(t.journal().capture.acknowledgedAt, null);
  assert.equal(t.runner.getSnapshot().matterId, t.journal().matterId);
  t.advance(2); await t.runner.finish(); assert.equal(t.segments.size, 1); assert.equal(t.runner.getSnapshot().state, 'idle'); assert.equal(t.matters.values().next().value.endedAt > 0, true);
});
test('file read and atomic commit failures retain a durable pending receipt across a restart', async () => {
  for (const failing of ['failRead', 'failCommit']) {
    const t = fixture(); await t.runner.start(); t[failing](true); t.advance(2); await t.runner.pause();
    assert.equal(t.segments.size, 0); assert.ok(t.journal().pending); assert.equal(t.runner.getSnapshot().state, 'recovering');
    t[failing](false); const fresh = t.fresh(); await fresh.initialize(); assert.equal(t.segments.size, 1); assert.equal(fresh.getSnapshot().state, 'paused'); assert.equal(t.journal().pending, null);
  }
});
test('a failed checkpoint clear retains the pending receipt; reopening does not read or insert audio twice', async () => {
  const t = fixture(); await t.runner.start(); t.failWrite(next => next.capture === null && next.pending === null); await t.runner.pause();
  assert.equal(t.segments.size, 1); assert.equal(t.commits.length, 1); assert.ok(t.journal().pending);
  t.failWrite(() => false); t.failRead(true); const fresh = t.fresh(); await fresh.initialize();
  assert.equal(t.commits.length, 1); assert.equal(t.journal().pending, null); assert.equal(fresh.getSnapshot().elapsedSec, 1);
});
test('failure to journal a consumed native result still commits through healthy IndexedDB and survives restart', async () => {
  const t = fixture(); await t.runner.start(); t.failWrite(() => true); await t.runner.pause();
  assert.equal(t.segments.size, 1); assert.equal(t.runner.getSnapshot().state, 'recovering');
  t.failWrite(() => false); t.failRead(true); const fresh = t.fresh(); await fresh.initialize();
  assert.equal(t.segments.size, 1); assert.equal(t.journal().pending, null); assert.equal(t.commits.length, 1);
});
test('a checkpoint read failure cannot install an event writer that overwrites the unread owner', async () => {
  const t = fixture(); await t.runner.start(); const original = t.journal(), read = t.deps.readJournal;
  const fresh = t.fresh(); t.deps.readJournal = async () => { throw new Error('read failed'); };
  await fresh.initialize(); assert.equal(t.events.size, 0); t.emit('recordAudioStop', fileAt(1791950000000)); await drain(fresh);
  assert.deepEqual(t.journal(), original); t.deps.readJournal = read; await fresh.initialize(); assert.equal(t.segments.size, 1);
});
test('a failed first checkpoint closes and drops the new matter; retrying start leaves one open matter', async () => {
  const t = fixture(); t.failWrite(next => Boolean(next.matterId) && !next.capture && !next.pending); await t.runner.start();
  assert.equal(t.runner.getSnapshot().state, 'recovering'); assert.equal(t.matters.size, 0); assert.equal(t.journal()?.matterId ?? null, null);
  assert.equal(t.calls.some(call => call.api === 'recordAudio'), false);
  t.failWrite(() => false); await t.runner.start();
  assert.equal(t.runner.getSnapshot().state, 'recording'); assert.equal([...t.matters.values()].filter(row => row.endedAt === null).length, 1);
});
test('a partially installed listener set is torn down and fully reinstalled on retry', async () => {
  const t = fixture(), listen = t.deps.listen; let failHide = true;
  t.deps.listen = async (channel, fn) => { if (channel === 'appHide' && failHide) throw new Error('synthetic listen failure'); return listen(channel, fn); };
  await t.runner.initialize(); assert.equal(t.runner.getSnapshot().state, 'recovering'); assert.equal(t.events.size, 0);
  failHide = false; await t.runner.initialize();
  assert.deepEqual([...t.events.keys()].sort(), ['appHide', 'recordAudioStop']); assert.ok(t.documentEvents.has('visibilitychange'));
});
test('closing checkpoint failure retries without attaching future audio to an ended matter', async () => {
  const t = fixture(); await t.runner.start(); const oldId = t.journal().matterId;
  t.failWrite(next => next.matterId === null); await t.runner.finish(); assert.ok(t.matters.get(oldId).endedAt); assert.equal(t.runner.getSnapshot().state, 'recovering');
  t.failWrite(() => false); t.advance(2); await t.runner.start(); assert.notEqual(t.journal().matterId, oldId);
  assert.equal(t.runner.getSnapshot().state, 'recording'); assert.equal(t.matters.size, 2);
});
test('manual stop and duplicate auto events commit one segment and never pause a newer capture', async () => {
  const t = fixture(); await t.runner.start(); const file = t.autoStop(); await drain(t.runner);
  assert.equal(t.commits.length, 1); assert.equal(t.runner.getSnapshot().state, 'recording');
  const current = t.journal().capture.id; t.emit('recordAudioStop', file); await drain(t.runner);
  assert.equal(t.commits.length, 1); assert.equal(t.journal().capture.id, current); assert.equal(t.runner.getSnapshot().state, 'recording');
  await t.runner.pause(); t.emit('recordAudioStop', file); await drain(t.runner); assert.equal(t.runner.getSnapshot().state, 'paused');
});
test('foreign late files stay separate and cannot adopt the current capture owner', async () => {
  const t = fixture(); await t.runner.start(); const owner = t.journal().capture.id, foreign = fileAt(1791950000000);
  t.emit('recordAudioStop', foreign); await drain(t.runner);
  assert.equal(t.segments.size, 0); assert.equal(t.journal().capture.id, owner); assert.equal(t.runner.getSnapshot().state, 'recording');
  assert.equal(t.journal().orphans.length, 1); await t.runner.finish(); assert.equal(t.segments.size, 1); assert.equal(t.recovered.length, 1);
});
test('an orphan native receipt falls back to local recovery if native checkpoint storage fails', async () => {
  const t = fixture(); await t.runner.start(); t.failWrite(() => true); const foreign = fileAt(1791950000000);
  t.emit('recordAudioStop', foreign); await drain(t.runner); assert.equal(t.recovered.length, 1);
  assert.equal(t.recovered[0].tempFilePath, foreign.tempFilePath); assert.equal(t.runner.getSnapshot().state, 'recovering');
});
test('fallback collects an automatic native result when the event is lost', async () => {
  const t = fixture(); await t.runner.start(); t.advance(301); t.tick(); await drain(t.runner);
  assert.equal(t.commits.length, 1); assert.equal(t.runner.getSnapshot().state, 'recording'); assert.equal(t.journal().capture.index, 1);
});
test('background stops and saves before reporting paused, with an explicit foreground resume', async () => {
  const t = fixture(); await t.runner.start(); t.emit('appHide'); await drain(t.runner);
  assert.equal(t.runner.getSnapshot().state, 'paused'); assert.equal(t.segments.size, 1); assert.match(t.runner.getSnapshot().notice, /后台/);
  assert.equal(t.calls.filter(row => row.api === 'recordAudio').length, 1);
  t.advance(2); await t.runner.resume(); assert.equal(t.runner.getSnapshot().state, 'recording'); assert.equal(t.journal().capture.index, 1);
});
test('a lost native process preserves an unresolved tail and never invents a saved segment', async () => {
  const t = fixture(); await t.runner.start(); t.autoStop(); await drain(t.runner);
  // Simulate the replacement process having no active native capture.
  t.deps.invoke = async api => { if (api === 'stopRecordAudio') throw noRecording(); return {}; };
  const fresh = t.fresh(); await fresh.initialize(); assert.equal(t.journal().unresolved.length, 1); assert.equal(t.segments.size, 1);
  assert.equal(fresh.getSnapshot().state, 'paused'); assert.equal(t.matters.values().next().value.endedAt, null);
});
test('journal rejects corrupt timing, foreign owner, malformed pending metadata and unsafe file paths', () => {
  const t = fixture(), j = t.ctx.emptyJournal(); assert.equal(t.ctx.parseJournal(null).version, 1);
  for (const url of ['https://x/media/record_1791960000000.m4a?secret=x', 'https://x/media/../credentials', 'http://x/media/record_1791960000000.m4a']) assert.throws(() => t.ctx.nativeFileName(url));
  assert.throws(() => t.ctx.parseJournal({ ...j, capture: { id: 'x', matterId: 'wrong', index: 0, startedAt: 2, acknowledgedAt: 1, elapsedBefore: 0 } }));
  assert.throws(() => t.ctx.parseJournal({ ...j, pending: {} }));
  assert.throws(() => t.ctx.parseNativeAudio({ ...fileAt(1791960000000), size: NaN }));
});

test('store initialization cannot overwrite a concurrently requested new record; read failure retries', async () => {
  let release, fail = true, writes = 0;
  const waiting = new Promise(resolve => release = resolve), rows = [{ id: 'old', startedAt: 1, endedAt: null, origin: 'record' }];
  const c = load([['store.ts', ['GrowthStore']]], { STORE_MATTERS: 'matters', STORE_SEGMENTS: 'segments', STORE_BLOBS: 'blobs',
    async idbGetAll(name) { await waiting; if (fail) throw Error('read failed'); return name === 'matters' ? rows : []; },
    idbPut: async () => { writes++; }, idbPutMany: async () => {}, idbGet: async () => undefined, idbDelete: async () => {} });
  const store = new c.GrowthStore(), creating = store.createMatter(); await Promise.resolve(); assert.equal(writes, 0); release();
  await assert.rejects(creating); assert.equal(writes, 0); fail = false; const matter = await store.createMatter();
  assert.equal(store.getSnapshot().matters.length, 2); assert.equal(store.getMatter('old').endedAt, null); assert.equal(store.getMatter(matter.id).id, matter.id);
});

test('first checkpoint read waits for bridge initialization instead of treating unknown mode as empty', async () => {
  let ready = false, reads = 0;
  const c = load([['recording-journal.ts', ['readRecordingJournal', 'emptyJournal']]], {
    initBridge: async () => { ready = true; return 'native'; },
    invokeNative: async () => { assert.equal(ready, true); reads++; return { data: null }; },
  });
  assert.equal((await c.readRecordingJournal()).version, 1); assert.equal(reads, 1);
});
test('native file reading validates origin, exact bytes and container header; failures stay retryable', async () => {
  let response, fetches = 0;
  const url = fileAt(1791960000000), bytes = new Uint8Array(16); bytes.set(new TextEncoder().encode('ftyp'), 4);
  const c = load([['recording-journal.ts', ['nativeFileName']], ['recording-audio.ts', ['readNativeAudio', 'localNativeURL']]], {
    nativeLog: { w: () => {} }, location: { origin: 'https://studio-api.stepx.com' }, AbortController, setTimeout, clearTimeout,
    fetch: async () => { fetches++; return response; },
  });
  response = { ok: true, url: url.tempFilePath, blob: async () => new Blob([bytes]) };
  const virtual = { ...url, tempFilePath: url.tempFilePath.replace('studio-api.stepx.com', 'appassets.t-stepos.com') };
  assert.equal(c.localNativeURL(virtual), virtual.tempFilePath);
  assert.equal((await c.readNativeAudio(url)).size, 16);
  response = { ...response, blob: async () => new Blob(['html error']) }; await assert.rejects(c.readNativeAudio(url));
  response = { ...response, ok: false, status: 404 }; await assert.rejects(c.readNativeAudio(url));
  const before = fetches; await assert.rejects(c.readNativeAudio({ ...url, tempFilePath: url.tempFilePath.replace('studio-api.stepx.com', 'untrusted.example') })); assert.equal(fetches, before);
});
test('equal-content native files keep distinct identities; repaired legacy audio cannot auto-upload', async () => {
  const segments = [], matters = new Map(), blobs = new Map();
  const store = { getSnapshot: () => ({ segments }), getAudio: async id => blobs.get(id),
    commitRecoveredAudio: async (matter, segment, blob) => { matters.set(matter.id, matter); segments.push(segment); blobs.set(segment.id, blob); },
    commitCapturedAudio: async (segment, blob) => { const i = segments.findIndex(row => row.id === segment.id); segments[i] = segment; blobs.set(segment.id, blob); } };
  const c = load([['recording-journal.ts', ['nativeFileName', 'nativeFileStartedAt']], ['recording-recovery.ts', ['recoverNativeFile']]], {
    growthStore: store, sha256: async () => 'a'.repeat(64), readNativeAudio: async () => new Blob([new Uint8Array(16)]),
  });
  const one = fileAt(1791960000000), two = fileAt(1791960001000);
  await c.recoverNativeFile(one); await c.recoverNativeFile(two); assert.equal(matters.size, 2); assert.equal(segments.length, 2); assert.notEqual(segments[0].id, segments[1].id);
  assert.equal(segments.every(row => row.cloudEligible === false), true);
  blobs.delete(segments[0].id); segments[0].cloudEligible = true; await c.recoverNativeFile(one);
  assert.equal(segments.length, 2); assert.equal(segments[0].cloudEligible, false); assert.equal(blobs.get(segments[0].id).size, 16);
});

test('audio and metadata transaction publishes only after commit and rolls back a failed second write', async () => {
  for (const abort of [false, true]) {
    const disk = new Map(); let transactionNames, completed = false;
    const db = { transaction(names) {
      transactionNames = [...names]; const staged = [], tx = { abort() { queueMicrotask(() => tx.onabort()); } };
      tx.objectStore = name => ({ getAll() {
        const request = {}; queueMicrotask(() => { request.result = []; request.onsuccess?.(); }); return request;
      }, get() {
        const request = {}; queueMicrotask(() => { request.result = undefined; request.onsuccess?.(); }); return request;
      }, put(value) {
        if (abort && name === 'segments') throw Error('synthetic metadata failure');
        staged.push([name + ':' + value.id, value]);
        if (staged.length === 2) queueMicrotask(() => { for (const row of staged) disk.set(...row); completed = true; tx.oncomplete(); });
        return {};
      } }); return tx;
    } };
    const c = load([['idb.ts', ['idbPutMany']]], { indexedDB: { open() { const request = {}; queueMicrotask(() => { request.result = db; request.onsuccess(); }); return request; } } });
    const pending = c.idbPutMany([{ store: 'blobs', value: { id: 'piece', blob: new Blob(['synthetic']) } }, { store: 'segments', value: { id: 'piece', matterId: 'record' } }]);
    assert.equal(disk.size, 0);
    if (abort) { await assert.rejects(pending); assert.equal(disk.size, 0); assert.equal(completed, false); }
    else { await pending; assert.equal(disk.size, 2); assert.equal(completed, true); }
    assert.deepEqual(transactionNames, ['blobs', 'segments', 'recording_memory', 'processing']);
  }
});
