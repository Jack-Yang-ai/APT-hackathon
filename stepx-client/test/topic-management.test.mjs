import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fixture } from './fixture.mjs';
const topic = { id: 'public-topic', title: '合成话题', createdAt: 1, updatedAt: 1 };
const message = { id: 'public-message', topicId: topic.id, role: 'user', text: '合成问题', createdAt: 1, status: 'sent' };
async function opened() { const f = fixture(); await f.c.idbPut('topics', topic); await f.c.idbPut('messages', message); const store = new f.c.AskStore(); await store.init(); return { ...f, store }; }
test('topic rename and reversible archive preserve messages and survive reopening without model calls', async () => {
  const f = await opened(); await f.store.renameTopic(topic.id, '改名后的话题'); f.store.selectTopic(topic.id); await f.store.archiveTopic(topic.id, true);
  assert.equal(f.store.getSnapshot().currentTopicId, 'main');
  const reopened = new f.c.AskStore(); await reopened.init(); const saved = reopened.getSnapshot().topics.find(row => row.id === topic.id);
  assert.equal(saved.title, '改名后的话题'); assert.equal(saved.archived, true); assert.equal(reopened.messagesOf(topic.id)[0].text, message.text);
  await reopened.archiveTopic(topic.id, false); assert.equal((await f.c.idbGet('topics', topic.id)).archived, false); assert.equal(f.calls.length, 0);
});
test('main chat is protected and named empty topics remain drafts until their first explicit send', async () => {
  const f = await opened(); const before = (await f.c.idbGetAll('topics')).length;
  await assert.rejects(f.store.renameTopic('main', 'name')); await assert.rejects(f.store.archiveTopic('main', true));
  await assert.rejects(f.store.renameTopic(topic.id, '')); await assert.rejects(f.store.renameTopic(topic.id, '很'.repeat(13)));
  f.store.startNewTopic('准备演示'); assert.equal(f.store.currentTopic().title, '准备演示'); assert.equal((await f.c.idbGetAll('topics')).length, before); assert.equal(f.calls.length, 0);
  await f.store.send('明确发送'); assert.equal(f.store.currentTopic().title, '准备演示'); assert.equal((await f.c.idbGetAll('topics')).length, before + 1);
});
test('topic write failure never changes the visible title or archive state', async () => {
  const f = await opened(), update = f.c.idbUpdate; f.c.idbUpdate = async () => { throw Error('synthetic quota'); };
  await assert.rejects(f.store.renameTopic(topic.id, '未保存')); await assert.rejects(f.store.archiveTopic(topic.id, true));
  assert.equal(f.store.getTopic(topic.id).title, topic.title); assert.equal(f.store.getTopic(topic.id).archived, undefined);
  assert.equal((await f.c.idbGet('topics', topic.id)).title, topic.title); f.c.idbUpdate = update;
});
test('send and retry cannot race a pending topic mutation, and active requests block archive', async () => {
  const f = await opened(), update = f.c.idbUpdate; let release, entered;
  const started = new Promise(resolve => entered = resolve);
  f.c.idbUpdate = async (...args) => { entered(); await new Promise(resolve => release = resolve); return update(...args); };
  const renaming = f.store.renameTopic(topic.id, '保存中的话题'); await started;
  await assert.rejects(f.store.send('保留问题')); await assert.rejects(f.store.retry(message.id)); assert.equal(f.calls.length, 0);
  release(); await renaming; f.c.idbUpdate = update;
  let releaseReply, begin; const beginReply = new Promise(resolve => begin = resolve);
  f.setReply(async () => { begin(); await new Promise(resolve => releaseReply = resolve); return { status: 'ok', text: '合成回答' }; });
  const sending = f.store.send('正在发送的问题'); await beginReply; await assert.rejects(f.store.archiveTopic(topic.id, true));
  releaseReply(); await sending; assert.equal(f.store.getTopic(topic.id).archived, undefined);
});
for (const mutation of ['rename', 'archive']) test(`stale chat instances preserve another page's ${mutation} at first send and delayed reply`, async () => {
  const f = await opened(), other = new f.c.AskStore(); await other.init(); f.store.selectTopic(topic.id);
  const change = async (value) => mutation === 'rename'
    ? other.renameTopic(topic.id, value) : other.archiveTopic(topic.id, value);
  const check = async (value) => {
    const row = await f.c.idbGet('topics', topic.id);
    assert.equal(mutation === 'rename' ? row.title : row.archived, value);
  };
  // A's snapshot predates B's committed change; even the initial user-message write must merge.
  await change(mutation === 'rename' ? '发送前的改名' : true);
  let release, entered; const started = new Promise(resolve => entered = resolve);
  f.setReply(async () => { entered(); await new Promise(resolve => release = resolve); return { status: 'ok', text: '合成迟到回复' }; });
  const sending = f.store.send('合成并发问题'); await started;
  await check(mutation === 'rename' ? '发送前的改名' : true);
  // B commits again while A waits for the provider, outside A's in-memory busy guard.
  await change(mutation === 'rename' ? '回复前的改名' : false);
  release(); await sending; await check(mutation === 'rename' ? '回复前的改名' : false);
  const reopened = new f.c.AskStore(); await reopened.init();
  assert.equal(mutation === 'rename' ? reopened.getTopic(topic.id).title : reopened.getTopic(topic.id).archived,
    mutation === 'rename' ? '回复前的改名' : false);
  assert.equal(reopened.messagesOf(topic.id).filter(row => row.text === '合成并发问题' || row.text === '合成迟到回复').length, 2);
  assert.equal(f.calls.length, 1);
});
