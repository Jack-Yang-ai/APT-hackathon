import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';
const root = new URL('../src/growth/', import.meta.url);
function load(file, names, extra = {}) {
  const ctx = { useSyncExternalStore: () => {}, structuredClone, console, ...extra }; vm.createContext(ctx);
  const source = fs.readFileSync(new URL(file, root), 'utf8').replace(/^import .*\n/gm, '').replace(/export /g, '');
  vm.runInContext(stripTypeScriptTypes(source, { mode: 'transform' }) + '\n' + names.map(name => `globalThis.${name}=${name};`).join('\n'), ctx);
  return ctx;
}
function fixture() {
  const rows = new Map(); let fail = false, count = 0;
  const deps = { read: async () => [...rows.values()].map(row => structuredClone(row)), id: () => `a-${++count}`,
    mutate: async (id, change) => { const row = change(structuredClone(rows.get(id))); if (fail) throw new Error('quota'); rows.set(id, structuredClone(row)); return row; } };
  const c = load('actions.ts', ['ActionsStore', 'actionStatus'], { idbGetAll: deps.read, idbUpdate: () => {}, STORE_ACTIONS: 'actions', newId: deps.id });
  return { rows, deps, store: new c.ActionsStore(deps), fresh: () => new c.ActionsStore(deps), status: c.actionStatus, fail: value => { fail = value; } };
}
test('failed persistence never displays a created or completed action; retries survive', async () => {
  const t = fixture(); await t.store.init(); t.fail(true);
  await assert.rejects(t.store.create({ title: 'public fixture' })); assert.equal(t.store.getSnapshot().actions.length, 0);
  t.fail(false); const a = await t.store.create({ title: 'public fixture' }); t.fail(true);
  await assert.rejects(t.store.setDone(a.id, true)); assert.equal(t.store.getSnapshot().actions[0].done, false);
  assert.equal(t.rows.get(a.id).done, false); t.fail(false); await t.store.setDone(a.id, true);
  const reopened = t.fresh(); await reopened.init(); assert.equal(reopened.getSnapshot().actions[0].done, true);
});
test('edit and completion read current persisted fields, retaining a concurrent change and source', async () => {
  const t = fixture(); const a = await t.store.create({ title: 'original', source: { recordingId: 'r', eventId: 'r:1' } });
  t.rows.set(a.id, { ...t.rows.get(a.id), title: 'changed elsewhere', dueAt: 1000 });
  await t.store.setDone(a.id, true); assert.equal(t.rows.get(a.id).title, 'changed elsewhere');
  const editing = t.store.edit(a.id, { title: 'edited', dueAt: null }), restoring = t.store.setDone(a.id, false);
  await Promise.all([editing, restoring]); assert.equal(t.rows.get(a.id).title, 'edited'); assert.equal(t.rows.get(a.id).done, false);
  assert.equal(t.rows.get(a.id).source.eventId, 'r:1');
});
test('queued input is frozen and rejected input does not write', async () => {
  const t = fixture(), input = { title: 'chosen action', source: { recordingId: 'r' } };
  const pending = t.store.create(input); input.title = 'later edit'; input.source.recordingId = 'other'; await pending;
  assert.equal([...t.rows.values()][0].title, 'chosen action'); assert.equal([...t.rows.values()][0].source.recordingId, 'r');
  for (const title of ['', ' ', 'x'.repeat(241)]) await assert.rejects(t.store.create({ title }));
  for (const dueAt of [NaN, Infinity, -1, '2026-10-14']) await assert.rejects(t.store.create({ title: 'valid', dueAt }));
  assert.equal(t.rows.size, 1);
});
test('an action removed while the UI was open cannot be revived by a stale completion', async () => {
  const t = fixture(), a = await t.store.create({ title: 'public fixture' }); t.rows.delete(a.id);
  await assert.rejects(t.store.setDone(a.id, true)); assert.equal(t.rows.size, 0);
});
test('corrupt stored action is reported rather than a false successful empty list', async () => {
  const t = fixture(); t.rows.set('bad', { id: 'bad', title: 'bad', done: 'false', createdAt: 1, updatedAt: 1 });
  await assert.rejects(t.store.init()); assert.equal(t.store.getSnapshot().ready, false); assert.ok(t.store.getSnapshot().error);
});
function database({ abort = false } = {}) {
  let disk = { id: 'a', title: 'latest title', done: false }, tx;
  const objectStore = { get: () => { const request = {}; queueMicrotask(() => { request.result = structuredClone(disk); request.onsuccess(); }); return request; },
    put: row => { queueMicrotask(() => { if (abort) { tx.error = Error('abort'); tx.onabort(); } else { disk = structuredClone(row); tx.oncomplete(); } }); return {}; } };
  const db = { transaction: () => { tx = { objectStore: () => objectStore, abort: () => queueMicrotask(() => tx.onabort()) }; return tx; } };
  const indexedDB = { open: () => { const request = {}; queueMicrotask(() => { request.result = db; request.onsuccess(); }); return request; } };
  const c = load('idb.ts', ['idbUpdate'], { indexedDB }); return { update: c.idbUpdate, disk: () => disk };
}
test('read-modify-write waits for transaction commit and abort preserves the stored action', async () => {
  const good = database(); const saved = await good.update('actions', 'a', row => ({ ...row, done: true }));
  assert.equal(saved.title, 'latest title'); assert.equal(good.disk().done, true);
  const failed = database({ abort: true }); await assert.rejects(failed.update('actions', 'a', row => ({ ...row, done: true })));
  assert.equal(failed.disk().done, false);
});
test('legacy booleans and candidate kinds project status without rewriting persisted records', async () => {
  const t = fixture(); const a = await t.store.create({ title: 'legacy' });
  const row = t.rows.get(a.id); delete row.phase; delete row.cancelled; t.rows.set(a.id, row);
  const before = structuredClone(row), reopened = t.fresh(); await reopened.init();
  assert.deepEqual(t.rows.get(a.id), before); assert.equal(t.status(reopened.getSnapshot().actions[0]), 'next');
  assert.equal(t.status({ ...before, kind: 'request' }), 'confirm'); assert.equal(t.status({ ...before, kind: 'follow_up' }), 'followup');
  assert.equal(t.status({ ...before, done: true }), 'done'); assert.equal(t.status({ ...before, cancelled: true }), 'cancelled');
});
test('phase, closed status and user edits survive remove restore and reopening', async () => {
  const t = fixture(), a = await t.store.create({ title: 'public', status: 'doing', nextStep: 'chosen step' });
  await t.store.setStatus(a.id, 'done'); await t.store.remove(a.id); await t.store.restore(a.id);
  const reopened = t.fresh(); await reopened.init(); let row = reopened.getSnapshot().actions[0];
  assert.equal(t.status(row), 'done'); assert.equal(row.phase, 'doing'); assert.equal(row.nextStep, 'chosen step');
  await reopened.setStatus(a.id, row.phase); row = reopened.getSnapshot().actions[0]; assert.equal(t.status(row), 'doing'); assert.equal(row.done, false); assert.equal(row.cancelled, false);
  await reopened.setStatus(a.id, 'cancelled'); assert.equal(t.status(reopened.getSnapshot().actions[0]), 'cancelled');
});
test('status and form fields commit together; rejected writes keep the previous status and content', async () => {
  const t = fixture(), a = await t.store.create({ title: 'before', status: 'followup', source: { recordingId: 'r' } });
  t.fail(true); await assert.rejects(t.store.edit(a.id, { title: 'after', status: 'done', nextStep: 'new step' }));
  assert.equal(t.rows.get(a.id).title, 'before'); assert.equal(t.status(t.store.getSnapshot().actions[0]), 'followup');
  await assert.rejects(t.store.setStatus(a.id, 'doing')); assert.equal(t.rows.get(a.id).phase, 'followup');
  t.fail(false); await t.store.edit(a.id, { title: 'after', status: 'done', nextStep: 'new step' });
  const row = t.store.getSnapshot().actions[0]; assert.equal(row.done, true); assert.equal(row.phase, 'followup'); assert.equal(row.source.recordingId, 'r');
  await t.store.setDone(a.id, false); assert.equal(t.status(t.store.getSnapshot().actions[0]), 'followup');
});
test('invalid or stale status changes cannot revive removed actions', async () => {
  const t = fixture(), a = await t.store.create({ title: 'kept', status: 'confirm' });
  await assert.rejects(t.store.create({ title: 'bad', status: 'unknown' })); await assert.rejects(t.store.setStatus(a.id, 'unknown'));
  await t.store.remove(a.id); await assert.rejects(t.store.setStatus(a.id, 'doing'));
  assert.equal(t.rows.size, 1); assert.ok(t.rows.get(a.id).removedAt); assert.equal(t.rows.get(a.id).phase, 'confirm');
});
