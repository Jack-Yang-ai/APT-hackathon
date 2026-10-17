import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fixture,source,plain } from './fixture.mjs';
const turn=(id,role,text,extra={})=>({id,topicId:'main',role,text,createdAt:100,status:'sent',...extra});
test('event chat uses only this event and its bound history, while preserving manual topics',async()=>{
  const f=fixture();await f.seed(source());const events=f.c.projectedEvents(await f.c.readSources()),a=await f.c.eventRef(events.find(row=>row.id==='r:1')),b=await f.c.eventRef(events.find(row=>row.id==='r:100001'));
  await f.c.idbPut('messages',turn('unrelated','assistant','general private history'));
  await f.c.idbPut('messages',turn('event-b','assistant','other event answer',{sourceRefs:[b]}));
  await f.c.idbPut('messages',turn('event-a','assistant','related answer',{sourceRefs:[a]}));
  await f.c.idbPut('topics',{id:'manual',title:'manual topic',createdAt:1,updatedAt:1});
  const store=new f.c.AskStore();await store.init();await store.send('public question',undefined,a);
  const request=f.calls[0];assert.equal(request.background.includes('separate public event'),false);assert.deepEqual(plain(request.history),[{role:'assistant',text:'related answer'}]);
  const user=(await f.c.idbGetAll('messages')).find(row=>row.text==='public question');assert.equal(user.background,undefined);assert.equal(user.requestHistory,undefined);assert.deepEqual(plain(user.eventRef),plain(a));
  assert.ok(store.getSnapshot().topics.some(row=>row.id==='manual'));assert.equal(store.getSnapshot().currentTopicId,'main');
});
test('deleted draft source refuses sending before model call; saved user questions remain intact',async()=>{
  const f=fixture();await f.seed(source());const ref=await f.c.eventRef(f.c.projectedEvents(await f.c.readSources()).find(row=>row.id==='r:1')),store=new f.c.AskStore();await store.init();await f.c.idbDeleteMatter('r');
  await assert.rejects(store.send('question to keep',undefined,ref));assert.equal(f.calls.length,0);assert.equal((await f.c.idbGetAll('messages')).length,0);
});
test('source deleted during model call cannot commit a late assistant reply; retry never resends old background',async()=>{
  const f=fixture();await f.seed(source());const ref=await f.c.eventRef(f.c.projectedEvents(await f.c.readSources()).find(row=>row.id==='r:1')),store=new f.c.AskStore();await store.init();
  let release,entered;const start=new Promise(resolve=>entered=resolve);f.setReply(async()=>{entered();await new Promise(resolve=>release=resolve);return{status:'ok',text:'late private answer'}});
  const sending=store.send('kept question',undefined,ref);await start;await f.c.idbDeleteMatter('r');release();await sending;
  let rows=await f.c.idbGetAll('messages');assert.equal(rows.length,1);assert.equal(rows[0].text,'kept question');assert.equal(rows[0].role,'user');
  await store.retry(rows[0].id);rows=await f.c.idbGetAll('messages');assert.equal(rows.length,1);assert.equal(rows[0].status,'failed');assert.equal(f.calls.length,1);
});
test('source-dependent old replies hidden on reopen and excluded from general chat history',async()=>{
  const f=fixture();await f.seed(source());const ref=await f.c.eventRef(f.c.projectedEvents(await f.c.readSources()).find(row=>row.id==='r:1'));
  await f.c.idbPut('messages',turn('a','user','my question',{eventRef:ref}));await f.c.idbPut('messages',turn('b','assistant','private source answer',{replyTo:'a',sourceRefs:[ref]}));
  await f.c.idbDeleteMatter('r');const store=new f.c.AskStore();await store.init();assert.equal(store.getSnapshot().messages.some(row=>row.text==='private source answer'),false);
  assert.ok(store.getSnapshot().messages.some(row=>row.text==='my question'));await store.send('new general question');assert.deepEqual(plain(f.calls[0].history),[]);
});
test('legacy whole-record background and its reply/history are quarantined, while manual text survives',async()=>{
  const f=fixture();await f.c.idbPut('messages',turn('old','user','old question',{status:'failed',background:'这次录音：old private text',requestHistory:[{role:'assistant',text:'private frozen history'}]}));
  await f.c.idbPut('messages',turn('old-reply','assistant','old private answer',{replyTo:'old'}));await f.c.idbPut('messages',turn('manual','user','manual question'));
  const store=new f.c.AskStore();await store.init();assert.equal(store.getSnapshot().messages.some(row=>row.text==='old private answer'),false);await store.retry('old');assert.equal(f.calls.length,0);
  await store.send('another question');assert.deepEqual(plain(f.calls[0].history),[{role:'user',text:'manual question'}]);
});
test('general answer dependent on valid historical event is hidden when that source is later deleted',async()=>{
  const f=fixture();await f.seed(source());const ref=await f.c.eventRef(f.c.projectedEvents(await f.c.readSources()).find(row=>row.id==='r:1'));
  await f.c.idbPut('messages',turn('event','assistant','bound history',{sourceRefs:[ref]}));const store=new f.c.AskStore();await store.init();await store.send('general followup');
  const reply=(await f.c.idbGetAll('messages')).find(row=>row.text==='synthetic answer');assert.equal(reply.sourceRefs[0].fingerprint,ref.fingerprint);
  await f.c.idbDeleteMatter('r');const reopened=new f.c.AskStore();await reopened.init();assert.equal(reopened.getSnapshot().messages.some(row=>row.text==='synthetic answer'),false);
});

test('legacy source dependency propagates through downstream frozen histories and assistant replies',async()=>{
  const f=fixture();await f.c.idbPut('messages',turn('u1','user','first question',{background:'这次录音：private'}));
  await f.c.idbPut('messages',turn('a1','assistant','first private answer',{replyTo:'u1'}));
  await f.c.idbPut('messages',turn('u2','user','second handwritten question',{requestHistory:[{role:'assistant',text:'first private answer'}]}));
  await f.c.idbPut('messages',turn('a2','assistant','downstream private answer',{replyTo:'u2'}));
  const store=new f.c.AskStore();await store.init();assert.equal(store.getSnapshot().messages.some(row=>row.text==='downstream private answer'),false);
  assert.ok(store.getSnapshot().messages.some(row=>row.text==='second handwritten question'));
  await store.send('new question');assert.deepEqual(plain(f.calls[0].history),[]);
});
