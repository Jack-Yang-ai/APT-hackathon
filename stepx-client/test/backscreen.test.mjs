import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';
const id = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const status = () => ({ version: 1, runtime: '1.0.0', epoch: id(1), updatedAt: Date.now(),
  hardware: { supported: true, logicalWidth: 17, logicalHeight: 23, state: 1, brightness: 32, rotation: 0, enabled: true },
  mode: 'off', overrideActive: false, glyph: 'mic', minutes: 0, lastCommand: {}, error: null });
const flush = () => new Promise(resolve => setImmediate(resolve));
function fixture(extra = {}) {
  const ctx = { crypto, AbortController, structuredClone, fetch: async () => ({ ok: true, status: 200, text: async () => JSON.stringify(status()) }),
    initBridge: async () => 'native', invokeNative: async () => ({}), console,
    setTimeout: (fn, ms) => setTimeout(fn, ms === 250 ? 1 : ms === 5000 ? 40 : ms), clearTimeout, ...extra };
  vm.createContext(ctx);
  const code = fs.readFileSync(new URL('../src/growth/backscreen.ts', import.meta.url), 'utf8')
    .replace(/^import .*\n/gm, '').replace(/export /g, '');
  vm.runInContext(stripTypeScriptTypes(code, { mode: 'transform' }) + '\nglobalThis.api = { parseBackStatus, BackScreenStore, backScreenPixels, backScreenUploads };', ctx);
  return { ctx, ...ctx.api, store: new ctx.api.BackScreenStore() };
}
test('rear status rejects incompatible hardware, stale epochs and untyped command receipts', () => {
  const { parseBackStatus } = fixture(), s = status();
  assert.equal(parseBackStatus(s).hardware.logicalWidth, 17);
  for (const patch of [{ version: 2 }, { epoch: '../wrong' }, { updatedAt: Date.now() - 9000 }, { updatedAt: Date.now() + 6000 },
    { mode: 'arbitrary' }, { overrideActive: 1 }, { minutes: 721 }, { glyph: 'user-path' }, { runtime: '1.0.2', glyph: 'apt' }, { runtime: '1.0.2', glyph: 'done' }, { runtime: {} },
    { lastCommand: { id: id(2), ok: 'true' } }, { lastCommand: { id: '../wrong', ok: true } },
    { hardware: { ...s.hardware, logicalWidth: 18 } }, { hardware: { ...s.hardware, brightness: -1 } }])
    assert.throws(() => parseBackStatus({ ...s, ...patch }));
});
test('desktop preview never writes a hardware command or invents a connected rear screen', async () => {
  let writes = 0; const { store } = fixture({ initBridge: async () => 'mock', invokeNative: async () => { writes++; } });
  await store.initialize(); await store.command('recording');
  assert.equal(writes, 0); assert.equal(store.getSnapshot().status, null); assert.match(store.getSnapshot().error, /电脑预览/);
});
test('production commands cannot display a test, logo, completion mark or caller-selected pattern', async () => {
  let writes = 0; const { store } = fixture({ invokeNative: async () => { writes++; } });
  await store.refresh();
  for (const action of ['test', 'apt', 'done', 'arbitrary']) {
    await store.command(action); assert.equal(writes, 0); assert.match(store.getSnapshot().error, /无法识别/);
  }
});
test('minute preview keeps the microphone fixed and rejects invalid durations', () => {
  const { backScreenPixels } = fixture();
  for (const minute of [0, 1, 9, 10, 59, 60, 99, 100, 720]) {
    const pixels = backScreenPixels(minute);
    assert.equal(pixels.length, 391); assert.equal(pixels[2 * 17 + 7], true);
    assert.ok(pixels.every(pixel => typeof pixel === 'boolean'));
    assert.deepEqual(pixels.slice(0, 17 * 17), backScreenPixels(0).slice(0, 17 * 17));
  }
  assert.notDeepEqual(backScreenPixels(9), backScreenPixels(10));
  for (const value of [-1, 721, 1.5, NaN, Infinity]) assert.throws(() => backScreenPixels(value));
});
test('legacy logo and completion status remain readable for the priority STOP channel only', async () => {
  for (const glyph of ['apt', 'done']) {
    const writes = [], legacy = { ...status(), runtime: '1.0.1', glyph, mode: 'test', overrideActive: true }
    const { store, parseBackStatus } = fixture({ fetch: async () => ({ ok: true, status: 200, text: async () => JSON.stringify(legacy) }),
      invokeNative: async (_, value) => { writes.push(JSON.parse(value.data)) } })
    assert.equal(parseBackStatus(legacy).glyph, glyph)
    await store.refresh(); assert.equal(store.getSnapshot().canStop, true)
    store.read = async () => ({ ...legacy, mode: 'off', overrideActive: false, lastCommand: { id: writes.at(-1).commandId, ok: true } })
    await store.command('stop'); assert.deepEqual(writes.map(row => row.action), ['stop']); assert.match(store.getSnapshot().notice, /已停止/)
  }
});
test('upload counts require the exact persisted job acknowledgement, not a key or semantic result', () => {
  const { backScreenUploads } = fixture()
  const segments = [0, 1, 2, 3, 4].map(index => ({ id: id(index + 20), matterId: id(10), index, cloudEligible: index !== 4 }))
  const job = (index, patch) => ({ id: segments[index].id, recordingId: id(10), index, state: 'failed', nextAt: 0, attempts: 0, ...patch })
  const jobs = [job(0, { uploaded: true, remoteKey: 'verified-0' }), job(1, { remoteKey: 'preallocated' }),
    job(2, { state: 'done', remoteKey: 'unconfirmed' }), job(3, { uploaded: true, remoteKey: 'foreign', recordingId: id(11) })]
  assert.equal(JSON.stringify(backScreenUploads(segments, jobs)), JSON.stringify({ saved: 5, uploaded: 1, pending: 3 }))
  assert.equal(backScreenUploads(segments, [job(0, { uploaded: true })]).uploaded, 0)
  assert.equal(backScreenUploads(segments, [job(0, { uploaded: true, remoteKey: 'wrong-index', index: 9 })]).uploaded, 0)
});
test('rear status timeout covers a stalled response body', async () => {
  const { store } = fixture({ fetch: async () => ({ status: 200, ok: true, text: () => new Promise(() => {}) }) });
  await store.refresh(); assert.match(store.getSnapshot().error, /超时/); assert.equal(store.getSnapshot().status, null);
});
test('STOP bypasses a stuck enable read; the superseded enable can never dispatch', async () => {
  const writes = []; let release;
  const { store } = fixture({ invokeNative: async (_, value) => { writes.push(JSON.parse(value.data)); } });
  await store.refresh();
  let reads = 0; store.read = async () => ++reads === 1 ? new Promise(resolve => { release = resolve; })
    : { ...status(), lastCommand: { id: writes.at(-1).commandId, ok: true } };
  const enable = store.command('recording'); await flush();
  await store.command('stop'); release(status()); await enable;
  assert.deepEqual(writes.map(row => row.action), ['stop']); assert.equal(store.getSnapshot().busy, false);
  assert.match(store.getSnapshot().notice, /已停止/);
});
test('STOP supersedes an uncertain native write and old callbacks cannot overwrite its receipt', async () => {
  const writes = []; let release;
  const { store } = fixture({ invokeNative: async (_, value) => {
    const row = JSON.parse(value.data); writes.push(row);
    if (row.action === 'recording') return new Promise(resolve => { release = resolve; });
  } });
  await store.refresh(); store.read = async () => ({ ...status(), lastCommand: writes.length ? { id: writes.at(-1).commandId, ok: true } : {} });
  const enable = store.command('recording'); await flush(); await store.command('stop'); release({}); await enable;
  assert.deepEqual(writes.map(row => row.action), ['recording', 'stop']);
  assert.ok(writes[1].createdAt > writes[0].createdAt); assert.match(store.getSnapshot().notice, /已停止/);
});
test('old refresh completion cannot roll back a newer mode or overwrite a command', async () => {
  const { store } = fixture(); let old, recent;
  store.read = () => new Promise(resolve => { if (!old) old = resolve; else recent = resolve; });
  const first = store.refresh(); await flush(); const second = store.refresh(); await flush();
  recent(status()); await second; old({ ...status(), mode: 'recording' }); await first;
  assert.equal(store.getSnapshot().status.mode, 'off');
});
test('failed refresh keeps only the last stop epoch; STOP dispatch never waits for another failed status read', async () => {
  const writes = []; const { store } = fixture({ invokeNative: async (_, value) => { writes.push(JSON.parse(value.data)); } });
  await store.refresh(); store.read = async () => { throw Error('offline'); }; await store.refresh();
  assert.equal(store.getSnapshot().status, null); assert.equal(store.getSnapshot().canStop, true);
  await store.command('stop'); assert.deepEqual(writes.map(row => row.action), ['stop']);
  assert.equal(writes[0].epoch, id(1)); assert.equal(store.getSnapshot().notice, null); assert.ok(store.getSnapshot().error);
});
test('STOP uses the fresh service epoch even when an accepted enable never returns its receipt', async () => {
  const writes = []; let mode = 'off', release, entered;
  const ackEntered = new Promise(resolve => { entered = resolve; });
  const epoch = id(9), current = () => ({ ...status(), epoch, mode, overrideActive: mode !== 'off',
    lastCommand: writes.length ? { id: writes.at(-1).commandId, ok: true } : {} });
  const { store } = fixture({ invokeNative: async (_, value) => {
    const command = JSON.parse(value.data); writes.push(command);
    assert.equal(command.epoch, epoch);
    mode = command.action === 'stop' ? 'off' : 'recording';
  } });
  await store.refresh(); assert.equal(store.getSnapshot().status.epoch, id(1));
  let reads = 0;
  store.read = async () => {
    if (++reads === 2) {
      const oldReceipt = current(); entered();
      return new Promise(resolve => { release = () => resolve(oldReceipt); });
    }
    return current();
  };
  const enable = store.command('recording'); await ackEntered;
  await store.command('stop'); release(); await enable;
  assert.deepEqual(writes.map(row => [row.action, row.epoch]), [['recording', epoch], ['stop', epoch]]);
  assert.equal(mode, 'off'); assert.equal(store.getSnapshot().status.epoch, epoch);
  assert.equal(store.getSnapshot().status.mode, 'off'); assert.match(store.getSnapshot().notice, /已停止/);
});
test('epoch changes and refused or ineffective receipts stay errors after refresh', async () => {
  for (const kind of ['epoch', 'refused', 'ineffective']) {
    let command; const { store } = fixture({ invokeNative: async (_, value) => { command = JSON.parse(value.data); } });
    await store.refresh();
    store.read = async () => ({ ...status(), epoch: kind === 'epoch' && command ? id(9) : id(1),
      lastCommand: command ? { id: command.commandId, ok: kind !== 'refused' } : {}, error: kind === 'refused' ? '背屏操作未完成' : null });
    await store.command('recording'); assert.equal(store.getSnapshot().notice, null); assert.ok(store.getSnapshot().error);
    const error = store.getSnapshot().error; await store.refresh(); assert.equal(store.getSnapshot().error, error);
  }
});
test('backscreen is a valid private return route and external URLs stay excluded', () => {
  const source = fs.readFileSync(new URL('../src/ui/returnTo.ts', import.meta.url), 'utf8').replace(/export /g, '');
  const context = {}; vm.createContext(context); vm.runInContext(stripTypeScriptTypes(source) + '\nglobalThis.api={isBusinessPath,rememberBusinessPath,getReturnTo};', context);
  context.api.rememberBusinessPath('/me/backscreen'); assert.equal(context.api.getReturnTo(), '/me/backscreen');
  for (const path of ['https://example.org', '//example.org', '/ask', '/me/backscreen/../../outside']) assert.equal(context.api.isBusinessPath(path), false);
});
