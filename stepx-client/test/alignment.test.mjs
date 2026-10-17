import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fixture, source, plain } from './fixture.mjs';
test('single-event context excludes other events in the same recording; fingerprint refuses changed text',async()=>{
  const f=fixture(),s=source();await f.seed(s);const event=f.c.projectedEvents(s).find(row=>row.id==='r:1'),ref=await f.c.eventRef(event);
  const background=f.c.eventBackground(await f.c.resolveEvent(await f.c.readSources(),ref));
  assert.ok(background.includes('send the plan'));assert.ok(!background.includes('separate public event'));assert.ok(!background.includes('Summary 1'));
  s.jobs[0].lines[0].text='changed';await f.c.idbPut('processing',s.jobs[0]);await assert.rejects(f.c.resolveEvent(await f.c.readSources(),ref));
});
test('three-piece continuation rejects deleted root, middle tombstone and inherited context changes',()=>{
  const f=fixture(),s=source();
  for(let index=1;index<3;index++){
    const prior=f.c.projectedEvents({...s,jobs:s.jobs.slice(0,index)})[0];
    s.jobs[index].requestLines[0].stream_context=f.c.previousContext(prior,s.matters[0].startedAt);
    s.jobs[index].events[0]={...s.jobs[index].events[0],id:'r:1',semanticId:1,title:'Event 0'};
  }
  assert.equal(f.c.projectedEvents(s).length,1);assert.equal(f.c.projectedEvents(s)[0].lineIds.length,3);
  for(const index of [0,1]){const deleted=structuredClone(s);deleted.segments.splice(index,1);assert.equal(f.c.projectedEvents(deleted).length,0)}
  const missing=structuredClone(s);missing.jobs.splice(1,1);missing.segments.splice(1,1);assert.equal(f.c.projectedEvents(missing).length,0);
  const changed=structuredClone(s);changed.jobs[1].requestLines[0].stream_context.summary='old private text';assert.equal(f.c.projectedEvents(changed).length,0);
});
test('wrong recording and changed owner/redaction/time cannot expand an event',()=>{
  const f=fixture();for(const change of [job=>job.events[0].recordingId='other',job=>job.lines[0].person_id='other',job=>job.lines[0].redacted=true,job=>job.lines[0].t_sec=0.5,job=>job.events[0].lineIds=[999]]) {
    const s=source();change(s.jobs[0]);assert.ok(!f.c.projectedEvents(s).some(row=>row.id==='r:1'));
  }
});
test('approved v1 normalization handles casefold/fullwidth and rejects empty punctuation quotes',()=>{
  const f=fixture();for(const [quote,text] of [['strasse','Straße'],['σσ','Σς'],['ＡＰＴ!','apt'],['hello world','Hello, world!'],['Ꭰ','ꭰ']])assert.equal(f.c.isVerbatim(quote,text),true);
  for(const quote of ['', '。',' ～ + ='])assert.equal(f.c.isVerbatim(quote,'source'),false);
});
test('protocol absence is unfinished; all responsibility/evidence/ownership errors are terminal',async()=>{
  const f=fixture();await f.seed(source());const e=await f.evaluation(),item={kind:'accepted',title:'plan',line_id:1,quote:'I will send the plan',evidence:[{line_id:1,quote:'I will send the plan'}],condition_text:'',deadline_text:'',collaborators_text:''};
  assert.throws(()=>f.c.parsePersonalActions({events:[]},e));assert.throws(()=>f.c.parsePersonalActions({terminal:true,error:'x'},e));
  for(const change of [x=>x.owner='me',x=>x.kind='pending',x=>x.quote='invented',x=>x.evidence=[{line_id:100001,quote:'separate public event'}],x=>x.evidence=[{line_id:999,quote:'invented'}],x=>delete x.condition_text]){
    const row=structuredClone(item);change(row);assert.throws(()=>f.c.parsePersonalActions({action_protocol:'personal-actions/v1',personal_actions:[row]},e));
  }
  assert.throws(()=>f.c.parsePersonalActions({action_protocol:'personal-actions/v1',personal_actions:[item,item]},e));
});
test('whole-record material rejects open, missing tail, unprocessed and oversized sources without truncation',()=>{
  const f=fixture();for(const change of [s=>s.matters[0].captureComplete=false,s=>s.matters[0].endedAt=null,s=>s.segments.splice(1,1),s=>s.jobs[2].state='failed',s=>s.jobs[0].lines=Array.from({length:2001},(_,i)=>({...s.jobs[0].lines[0],line_id:i+1}))]){const s=source();change(s);assert.throws(()=>f.c.recordingMaterial(s,'r'))}
});
test('adoption requires explicit ownership and current evaluation in the source/action transaction',async()=>{
  const f=fixture();await f.seed(source());const e=await f.evaluation(),candidate=e.candidates[0],store=new f.c.ActionsStore();await store.init();
  await assert.rejects(store.adopt(candidate,false,{title:candidate.title}));assert.equal((await f.c.idbGetAll('actions')).length,0);
  const row=await store.adopt(candidate,true,{title:'user edit',condition:'condition edit',deadline:'deadline edit',collaborators:'partner',nextStep:'next step'});
  assert.equal(row.source.eventId,'r:1');await store.setDone(row.id,true);await store.setCancelled(row.id,true);await store.remove(row.id);
  await assert.rejects(store.edit(row.id,{title:'stale edit'}));await assert.rejects(store.setDone(row.id,false));
  await store.restore(row.id);const saved=await f.c.idbGet('actions',row.id);
  assert.equal(saved.done,true);assert.equal(saved.cancelled,true);assert.equal(saved.title,'user edit');assert.equal(saved.nextStep,'next step');assert.equal(saved.removedAt,null);
});
test('ignore has only source identity; renamed candidates suppressed locally but another recording is independent',async()=>{
  const f=fixture();await f.seed(source());await f.seed(source('other'));const e=await f.evaluation(),candidate=e.candidates[0],store=new f.c.ActionsStore();await store.init();await store.ignore(candidate);
  const rows=await f.c.idbGetAll('actions');assert.deepEqual(Object.keys(rows[0]).sort(),['id','lineId','recordingId','removedAt','type']);
  const renamed={...candidate,title:'renamed by model'};assert.equal(f.c.candidateSuppressed(rows,renamed),true);assert.equal(f.c.candidateSuppressed(rows,{...renamed,recordingId:'other'}),false);
  await assert.rejects(store.adopt(candidate,true,{title:'renamed'}));const reopened=new f.c.ActionsStore();await reopened.init();assert.equal(reopened.getSnapshot().ignored.length,1);
  await reopened.restoreIgnored(rows[0].id);assert.equal(f.c.candidateSuppressed(await f.c.idbGetAll('actions'),candidate),false);
});
test('source deletion wins against stale adoption and cleans evaluations, preserving explicit actions and blobs of other sources',async()=>{
  for(const deletionFirst of [true,false]){
    const f=fixture();await f.seed(source());await f.seed(source('other'));const e=await f.evaluation(),store=new f.c.ActionsStore();await store.init();
    const manual=await store.create({title:'manual survives'});await f.c.idbPut('blobs',{id:'other-p0',blob:new Blob(['public'])});
    const one=deletionFirst?f.c.idbDeleteMatter('r'):Promise.resolve(await store.adopt(e.candidates[0],true,{title:'confirmed'}));
    const two=deletionFirst?store.adopt(e.candidates[0],true,{title:'confirmed'}):f.c.idbDeleteMatter('r');
    const results=await Promise.allSettled([one,two]);assert.equal(results[deletionFirst?1:0].status,deletionFirst?'rejected':'fulfilled');
    assert.equal(await f.c.idbGet('processing','__actions__:r'),undefined);assert.ok(await f.c.idbGet('actions',manual.id));assert.ok(await f.c.idbGet('blobs','other-p0'));
  }
});
test('source revision or replacement evaluation invalidates a pending confirmation',async()=>{
  const f=fixture();const s=source();await f.seed(s);const e=await f.evaluation(),store=new f.c.ActionsStore();await store.init();
  s.jobs[0].lines[0].text='modified';await f.c.idbPut('processing',s.jobs[0]);await assert.rejects(store.adopt(e.candidates[0],true,{title:'stale'}));assert.equal((await f.c.idbGetAll('actions')).length,0);
});
test('aborted source transaction cannot publish an adopted action',async()=>{
  const f=fixture();await f.seed(source());const e=await f.evaluation();
  await assert.rejects(f.c.sourceTransaction('readwrite',(source,put)=>{f.c.currentCandidate(source,e.candidates[0]);put('actions',{id:'abort'});throw Error('quota simulation')}));
  assert.equal((await f.c.idbGetAll('actions')).length,0);
});
test('old queue is not upgraded; action-only retry reuses frozen UUID/ticket and new explicit run changes only evaluation',async()=>{
  const f=fixture(),s=source();await f.seed(s);const old=plain(await f.c.idbGet('processing','r-p0')),runner=new f.c.PersonalProcessing();
  await runner.refresh();await runner.recognize('r');await new Promise(resolve=>setImmediate(resolve));
  let current=await f.c.idbGet('processing','__actions__:r');
  assert.deepEqual(plain(await f.c.idbGet('processing','r-p0')),old);assert.equal(current.lines[0].action_only,true);assert.equal(current.lines[0].action_protocol,'personal-actions/v1');
  const requestId=current.requestId;f.setCloud(async(path,body)=>path==='/extract/enqueue'?{state:'queued',ticket:body.session+'-0-'+'a'.repeat(16)}:{state:'running'});
  current.state='queued';current.nextAt=0;current.owner=undefined;current.until=0;await f.c.idbPut('processing',current);await runner.kick();
  current=await f.c.idbGet('processing','__actions__:r');assert.equal(current.requestId,requestId);assert.ok(current.ticket);const ticket=current.ticket;
  current.nextAt=0;await f.c.idbPut('processing',current);f.setCloud(async()=>({state:'done',payload:{terminal:true,error:'failed'}}));await runner.kick();
  current=await f.c.idbGet('processing','__actions__:r');assert.equal(current.state,'failed');assert.equal(current.ticket,ticket);
  const before=f.calls.length;await runner.kick();assert.equal(f.calls.length,before);
  await runner.recognize('r');await new Promise(resolve=>setImmediate(resolve));const next=await f.c.idbGet('processing','__actions__:r');assert.notEqual(next.requestId,requestId);assert.deepEqual(plain(await f.c.idbGet('processing','r-p0')),old);
});

test('stored candidate corruption or altered frozen evaluation cannot become an accepted user action',async()=>{
  const f=fixture();await f.seed(source());const e=await f.evaluation();e.candidates[0].quote='invented source';await f.c.idbPut('processing',e);assert.equal(f.c.currentEvaluation(await f.c.readSources(),'r'),undefined);
  e.lines[0].text='forged frozen text';e.candidates[0].quote=e.lines[0].text;await f.c.idbPut('processing',e);assert.equal(f.c.currentEvaluation(await f.c.readSources(),'r'),undefined);
});

test('legacy frozen UUID tail ordering remains readable only while every source piece is valid',()=>{
  const f=fixture(),s=source();s.jobs[0].id=s.segments[0].id='z-root';s.jobs[1].id=s.segments[1].id='a-middle';
  for(let index=1;index<3;index++){const prior=f.c.projectedEvents({...s,jobs:s.jobs.slice(0,index)})[0];s.jobs[index].requestLines[0].stream_context=f.c.previousContext(prior,s.matters[0].startedAt);s.jobs[index].events[0]={...s.jobs[index].events[0],id:'r:1',semanticId:1,title:'Event 0'}}
  s.jobs[2].requestLines[0].stream_context.tail=s.jobs[1].lines[0].text+'\n'+s.jobs[0].lines[0].text;
  assert.equal(f.c.projectedEvents(s).length,1);s.segments.splice(1,1);assert.equal(f.c.projectedEvents(s).length,0);
});
test('changed queued or completed evaluation is shown as retryable failure and gets a fresh explicit UUID',async()=>{
  const f=fixture(),s=source();await f.seed(s);const old=await f.evaluation();old.state='queued';await f.c.idbPut('processing',old);s.jobs[0].lines[0].text='changed source';s.jobs[0].requestLines[0].text='changed source';await f.c.idbPut('processing',s.jobs[0]);
  const runner=new f.c.PersonalProcessing();await runner.refresh();assert.equal(runner.getSnapshot().evaluations[0].state,'failed');await runner.kick();assert.equal(f.calls.length,0);
  await runner.recognize('r');assert.notEqual((await f.c.idbGet('processing','__actions__:r')).requestId,old.requestId);
});
test('two actions from one responsibility line may both be explicitly saved; removal then suppresses the whole line',async()=>{
  const f=fixture();await f.seed(source());const e=await f.evaluation();e.candidates.push({...e.candidates[0],id:e.requestId+':1',title:'prepare report'});await f.c.idbPut('processing',e);
  const store=new f.c.ActionsStore();await store.init();const first=await store.adopt(e.candidates[0],true,{title:'first saved'});assert.equal(f.c.candidateSuppressed(await f.c.idbGetAll('actions'),e.candidates[1]),false);
  await store.adopt(e.candidates[1],true,{title:'second saved'});await store.remove(first.id);assert.equal(f.c.candidateSuppressed(await f.c.idbGetAll('actions'),{...e.candidates[1],title:'reworded third suggestion'}),true);
});

test('streaming candidates are available during recording and whole-record calibration replaces only model candidates',async()=>{
  const f=fixture(),s=source();s.matters[0].endedAt=null;await f.seed(s);
  const job=s.jobs[0],material=f.c.fragmentMaterial(s,job.id),requestId=crypto.randomUUID();
  const evaluation={id:`__fragment_actions__:${job.id}`,fragmentId:job.id,recordingId:'r',requestId,revision:material.revision,stamp:material.stamp,session:job.session,lines:job.lines,state:'done',nextAt:0};
  evaluation.candidates=f.c.parsePersonalActions({action_protocol:'personal-actions/v1',personal_actions:[{kind:'accepted',title:'stream plan',line_id:1,quote:job.lines[0].text,evidence:[{line_id:1,quote:job.lines[0].text}],condition_text:'',deadline_text:'',collaborators_text:''}]},evaluation);
  job.personalEvaluation=evaluation;await f.c.idbPut('processing',job);let candidates=f.c.currentEvaluations(await f.c.readSources(),'r').flatMap(row=>row.candidates);assert.equal(candidates.length,1);assert.equal(candidates[0].provisional,true);
  const store=new f.c.ActionsStore();await store.init();const saved=await store.adopt(candidates[0],true,{title:'user owned edit'});
  s.matters[0].endedAt=103000;await f.c.idbPut('matters',s.matters[0]);const whole=await f.evaluation();whole.candidates=[];await f.c.idbPut('processing',whole);
  assert.deepEqual(plain(f.c.currentEvaluations(await f.c.readSources(),'r').flatMap(row=>row.candidates)),[]);assert.equal((await f.c.idbGet('actions',saved.id)).title,'user owned edit');
});
test('monotonic source revision rejects A to B to A with identical restored text',async()=>{
  const f=fixture(),s=source();s.jobs[0].lineRevision=1;await f.seed(s);const e=await f.evaluation(),store=new f.c.ActionsStore();await store.init();
  const original=s.jobs[0].lines[0].text;s.jobs[0].lines[0].text='B';s.jobs[0].lineRevision=2;await f.c.idbPut('processing',s.jobs[0]);s.jobs[0].lines[0].text=original;s.jobs[0].lineRevision=3;await f.c.idbPut('processing',s.jobs[0]);
  await assert.rejects(store.adopt(e.candidates[0],true,{title:'stale A'}));assert.equal((await f.c.idbGetAll('actions')).length,0);
});

test('closed recording never falls back to a provisional promise after later cancellation or failed whole calibration',async()=>{
  const f=fixture(),s=source();s.matters[0].endedAt=null;await f.seed(s);const job=s.jobs[0],material=f.c.fragmentMaterial(s,job.id),requestId=crypto.randomUUID();
  const evaluation={id:'fragment',fragmentId:job.id,recordingId:'r',requestId,revision:material.revision,stamp:material.stamp,session:job.session,lines:job.lines,state:'done',nextAt:0};
  evaluation.candidates=f.c.parsePersonalActions({action_protocol:'personal-actions/v1',personal_actions:[{kind:'accepted',title:'send plan',line_id:1,quote:job.lines[0].text,evidence:[{line_id:1,quote:job.lines[0].text}],condition_text:'',deadline_text:'',collaborators_text:''}]},evaluation);
  job.personalEvaluation=evaluation;await f.c.idbPut('processing',job);const candidate=f.c.currentEvaluations(await f.c.readSources(),'r')[0].candidates[0];
  s.jobs[2].lines[0].text='The plan has been cancelled';s.jobs[2].requestLines[0].text=s.jobs[2].lines[0].text;await f.c.idbPut('processing',s.jobs[2]);s.matters[0].endedAt=103000;await f.c.idbPut('matters',s.matters[0]);
  assert.equal(f.c.currentEvaluations(await f.c.readSources(),'r').length,0);const store=new f.c.ActionsStore();await store.init();await assert.rejects(store.adopt(candidate,true,{title:'stale promise'}));
  const whole=await f.evaluation();whole.state='failed';await f.c.idbPut('processing',whole);assert.equal(f.c.currentEvaluations(await f.c.readSources(),'r').length,0);
});

test('model changing only action kind cannot recreate an already completed user action',async()=>{
  const f=fixture();await f.seed(source());const e=await f.evaluation(),store=new f.c.ActionsStore();await store.init();const saved=await store.adopt(e.candidates[0],true,{title:'my edited title'});await store.setDone(saved.id,true);
  assert.equal(f.c.candidateSuppressed(await f.c.idbGetAll('actions'),{...e.candidates[0],kind:'follow_up'}),true);assert.equal((await f.c.idbGet('actions',saved.id)).done,true);
});
