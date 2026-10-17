import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';

function fixture() {
  const rows = new Map(); let fails = false;
  const storage = { getItem: k => rows.get(k) ?? null, setItem: (k, v) => { if (fails) throw Error('quota'); rows.set(k, v); } };
  const context = { useSyncExternalStore: () => {}, window: { localStorage: storage } };
  vm.createContext(context);
  const source = fs.readFileSync(new URL('../src/growth/composer.ts', import.meta.url), 'utf8')
    .replace(/^import .*\n/gm, '').replace(/export /g, '');
  vm.runInContext(stripTypeScriptTypes(source, { mode: 'transform' }) + '\nglobalThis.ComposerStore=ComposerStore;', context);
  return { store: new context.ComposerStore(() => storage), reopen: () => new context.ComposerStore(() => storage), rows, fail: v => { fails = v; } };
}
test('main inputs share the same persisted draft; manual topics and unnamed draft remain separate', () => {
  const f = fixture(); f.store.update('main', { text: 'main text', background: 'chosen source' });
  f.store.update('topic-1', { text: 'topic text' }); f.store.update('__new__', { text: 'unsent new topic' });
  assert.equal(f.store.get('main'), f.store.get('main'));
  const restored = f.reopen(); assert.equal(restored.get('main').background, 'chosen source');
  assert.equal(restored.get('topic-1').text, 'topic text'); assert.equal(restored.get('__new__').text, 'unsent new topic');
});
test('late submission cannot clear a newer edit, removed background or a different conversation', () => {
  const f = fixture(); const sent = f.store.update('main', { text: 'first', background: 'source' });
  f.store.update('main', { text: 'later', background: undefined }); f.store.update('topic-1', { text: 'other' });
  assert.equal(f.store.clearIfRevision('main', sent.revision), false);
  assert.equal(f.store.get('main').text, 'later'); assert.equal(f.store.get('main').background, undefined);
  assert.equal(f.store.get('topic-1').text, 'other');
});
test('clear after committed send clears only the captured draft and survives reopening', () => {
  const f = fixture(); const sent = f.store.update('main', { text: 'first', background: 'source' });
  f.store.update('topic-1', { text: 'other' }); assert.equal(f.store.clearIfRevision('main', sent.revision), true);
  assert.equal(f.reopen().get('main').text, ''); assert.equal(f.reopen().get('main').background, undefined);
  assert.equal(f.store.get('topic-1').text, 'other');
});
test('quota failure retains input visibly and failed draft clearing never pretends success', () => {
  const f = fixture(); f.fail(true); const draft = f.store.update('main', { text: 'keep input' });
  assert.equal(draft.text, 'keep input'); assert.ok(draft.error);
  assert.equal(f.store.clearIfRevision('main', draft.revision), false); assert.equal(f.store.get('main').text, 'keep input');
  f.fail(false); f.store.update('main', { text: 'recovered' }); assert.equal(f.reopen().get('main').text, 'recovered');
});
test('corrupt restored draft is visible and does not erase other drafts or modify raw data', () => {
  const f = fixture(); f.rows.set('growth.ask.draft.v1:main', '{broken');
  f.store.update('topic-1', { text: 'safe' }); assert.ok(f.store.get('main').error);
  assert.equal(f.rows.get('growth.ask.draft.v1:main'), '{broken'); assert.equal(f.reopen().get('topic-1').text, 'safe');
});
test('immutable snapshots prevent accidental edits without revision changes or persistence', () => {
  const f = fixture(); const saved = f.store.update('main', { text: 'frozen' });
  assert.throws(() => { saved.text = 'mutated'; }); assert.equal(f.store.get('main').text, 'frozen');
});
test('shared submit lock survives navigation and cannot block a different topic', () => {
  const f = fixture(); f.store.update('main', { text: 'main input' }); f.store.update('topic-1', { text: 'other' });
  const captured = f.store.acquire('main'); assert.ok(captured); assert.equal(f.store.get('main').busy, true);
  assert.equal(f.store.acquire('main'), undefined); assert.ok(f.store.acquire('topic-1'));
  f.store.update('main', { text: 'new edit during pending' });
  assert.equal(f.store.clearIfRevision('main', captured.revision), false); f.store.release('main');
  assert.equal(f.store.get('main').busy, false); assert.equal(f.store.get('main').text, 'new edit during pending');
  assert.equal(f.reopen().get('main').busy, false); assert.equal(f.store.get('topic-1').busy, true);
});
test('submission error is shared after navigation without overwriting newer text or unlocking early', () => {
  const f = fixture(); f.store.update('main', { text: 'first' }); f.store.acquire('main');
  f.store.update('main', { text: 'new text', background: 'new context' });
  f.store.reportError('main', '刚才的消息未能保存');
  assert.equal(f.store.get('main').text, 'new text'); assert.equal(f.store.get('main').background, 'new context');
  assert.equal(f.store.get('main').busy, true); assert.equal(f.store.get('main').error, '刚才的消息未能保存');
  f.store.release('main'); assert.equal(f.store.get('main').busy, false); assert.ok(f.store.get('main').error);
});
test('continue-ask attaches fresh context while preserving unsent text and other topics across reopen', () => {
  const f = fixture(), ref = { eventId: 'public:event', recordingId: 'public', fingerprint: 'a'.repeat(64) };
  f.store.update('main', { text: '尚未发送的手写问题', background: '旧背景' });
  f.store.update('topic-1', { text: '手动话题草稿' });
  f.store.attach('main', { question: '继续问的建议问题', eventRef: ref });
  assert.equal(f.store.get('main').text, '尚未发送的手写问题');
  assert.equal(f.store.get('main').eventRef.fingerprint, ref.fingerprint); assert.equal(f.store.get('main').background, undefined);
  assert.equal(f.reopen().get('main').text, '尚未发送的手写问题'); assert.equal(f.reopen().get('topic-1').text, '手动话题草稿');
});
test('empty continue-ask prefills without sending and prevents a late submission from clearing the new context', () => {
  const f = fixture(), ref = { eventId: 'public:event', recordingId: 'public', fingerprint: 'b'.repeat(64) };
  f.store.update('main', { text: ' ' }); const before = f.store.get('main');
  const attached = f.store.attach('main', { question: '继续聊这个事件', eventRef: ref });
  assert.equal(attached.text, '继续聊这个事件'); assert.equal(attached.busy, false);
  assert.equal(f.store.clearIfRevision('main', before.revision), false); assert.equal(f.reopen().get('main').text, attached.text);
});
