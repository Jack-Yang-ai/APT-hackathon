import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fixture, source } from './fixture.mjs';

test('adopted whole-session action resolves its UUID evaluation and loses evidence when the source changes', async () => {
  const f = fixture(); await f.seed(source()); const evaluation = await f.evaluation(), candidate = evaluation.candidates[0];
  const store = new f.c.ActionsStore(), action = await store.adopt(candidate, true, { title: 'my edited title' });
  assert.notEqual(evaluation.id, candidate.evaluationId);
  let origin = f.c.actionOrigin(action, await f.c.readSources()); assert.equal(origin.warning, null); assert.equal(origin.event.id, 'r:1'); assert.equal(origin.quote, candidate.quote);
  const job = await f.c.idbGet('processing', 'r-p0'); job.lineRevision = 2; job.requestRevision = 2; await f.c.idbPut('processing', job);
  origin = f.c.actionOrigin(action, await f.c.readSources()); assert.ok(origin.warning); assert.equal(origin.quote, undefined); assert.equal(origin.event, undefined);
  assert.equal((await f.c.idbGet('actions', action.id)).title, 'my edited title');
});
test('adopted open-session fragment action resolves the request UUID, then deletion removes its displayed quote', async () => {
  const f = fixture(), s = source(); s.matters[0].endedAt = null; await f.seed(s);
  const material = f.c.fragmentMaterial(await f.c.readSources(), 'r-p0');
  const row = { id: '__fragment_actions__:r-p0', recordingId: 'r', requestId: crypto.randomUUID(), revision: 1, stamp: material.stamp, session: s.jobs[0].session, lines: s.jobs[0].lines, state: 'done', nextAt: 0, fragmentId: 'r-p0' };
  row.candidates = f.c.parsePersonalActions({ action_protocol: 'personal-actions/v1', personal_actions: [{ kind: 'accepted', title: 'send plan', line_id: row.lines[0].line_id, quote: row.lines[0].text, evidence: [{ line_id: row.lines[0].line_id, quote: row.lines[0].text }], condition_text: '', deadline_text: '', collaborators_text: '' }] }, row);
  await f.c.idbPut('processing', { ...s.jobs[0], personalEvaluation: row });
  const store = new f.c.ActionsStore(), action = await store.adopt(row.candidates[0], true, { title: 'retained action' });
  assert.equal(f.c.actionOrigin(action, await f.c.readSources()).warning, null);
  await f.c.idbDeleteMatter('r'); const origin = f.c.actionOrigin(action, await f.c.readSources()); assert.ok(origin.warning); assert.equal(origin.quote, undefined); assert.equal(origin.event, undefined);
  assert.equal((await f.c.idbGet('actions', action.id)).title, 'retained action');
});
test('closed legacy request and follow-up restore their real phase instead of becoming next-step actions', async () => {
  for (const [kind, expected] of [['request', 'confirm'], ['follow_up', 'followup']]) {
    const f = fixture(), row = { id: kind, title: 'legacy fixture', kind, done: true, createdAt: 1, updatedAt: 1, dueAt: null };
    await f.c.idbPut('actions', row); const store = new f.c.ActionsStore(); await store.init();
    await store.setStatus(row.id, f.c.actionPhase(store.getSnapshot().actions[0]));
    assert.equal(f.c.actionStatus(store.getSnapshot().actions[0]), expected);
    await store.setStatus(row.id, 'cancelled'); assert.equal(store.getSnapshot().actions[0].phase, expected);
    await store.setStatus(row.id, f.c.actionPhase(store.getSnapshot().actions[0])); assert.equal(f.c.actionStatus(store.getSnapshot().actions[0]), expected);
  }
});
