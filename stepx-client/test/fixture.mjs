import fs from 'node:fs';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';
import { IDBFactory } from 'fake-indexeddb';
export function fixture() {
  let seq=0;const calls=[];let reply=async()=>({status:'ok',text:'synthetic answer'}),cloud=async()=>{throw Error('unexpected request')};
  const subscribe=()=>()=>{};
  const connection={subscribe,isReady:()=>true,getSnapshot:()=>({health:{extractionQueueConfigured:true}}),request:(...args)=>{calls.push(args);return cloud(...args)}};
  const ctx={crypto,Blob,TextEncoder,structuredClone,console,indexedDB:new IDBFactory(),useSyncExternalStore:()=>{},setInterval:()=>1,clearInterval:()=>{},newId:()=>`id-${++seq}`,
    growthStore:{subscribe},growthProcessing:{subscribe},growthConnection:connection,CloudFailure:class CloudFailure extends Error {constructor(code){super(code);this.code=code}},
    chatService:{reply:request=>{calls.push(request);return reply(request)}}};vm.createContext(ctx);
  const files=[['processing-data.ts',['freezeLines','parseEvents','SEMANTIC_RECIPE']],['source-scope.ts',['projectedEvents','previousContext','lineStamp','eventStamp','fingerprint','eventRef','resolveEvent','eventBackground','recordingMaterial','fragmentMaterial']],
    ['quote-normalize.ts',['normalizeQuote','isVerbatim']],['personal-action-data.ts',['ACTION_PROTOCOL','parsePersonalActions','currentCandidate','currentEvaluation','currentEvaluations','candidateSuppressed','ignoredId']],
    ['idb.ts',['idbGetAll','idbGet','idbPut','idbUpdate','idbDeleteMatter','sourceTransaction','readSources','idbPutMany','STORE_ACTIONS','STORE_PROCESSING','STORE_TOPICS','STORE_MESSAGES','STORE_RECORDING_MEMORY']],
    ['actions.ts',['ActionsStore','actionOrigin','actionPhase','actionStatus']],['personal-processing.ts',['PersonalProcessing']],['../ask/types.ts',['DEFAULT_TOPIC_TITLE']],['../ask/store.ts',['AskStore','MAIN_TOPIC_ID']]];
  for(const [file,names] of files) {
    const source=fs.readFileSync(new URL('../src/growth/'+file,import.meta.url),'utf8').replace(/^import .*\n/gm,'').replace(/export /g,'');
    vm.runInContext('(function(){'+stripTypeScriptTypes(source,{mode:'transform'})+'\n'+names.map(name=>`globalThis.${name}=${name};`).join('\n')+'})()',ctx,{filename:file});
  }
  return {c:ctx,calls,setReply:fn=>reply=fn,setCloud:fn=>cloud=fn,
    async seed(source){for(const row of source.matters)await ctx.idbPut('matters',row);for(const row of source.segments)await ctx.idbPut('segments',row);for(const row of source.jobs)await ctx.idbPut('processing',row)},
    async evaluation(recordingId='r') {
      const material=ctx.recordingMaterial(await ctx.readSources(),recordingId),requestId=crypto.randomUUID();
      const row={id:`__actions__:${recordingId}`,recordingId,requestId,revision:1,stamp:material.stamp,session:material.session,lines:material.lines,state:'done',nextAt:0};
      row.candidates=ctx.parsePersonalActions({action_protocol:'personal-actions/v1',personal_actions:[{kind:'accepted',title:'send plan',line_id:row.lines[0].line_id,quote:row.lines[0].text,evidence:[{line_id:row.lines[0].line_id,quote:row.lines[0].text}],condition_text:'after approval',deadline_text:'Friday',collaborators_text:'team'}]},row);
      await ctx.idbPut('processing',row);return row;
    }};
}
export function source(recordingId='r') {
  const uuid='12345678-1234-1234-1234-123456789abc',start=100000;
  const matters=[{id:recordingId,startedAt:start,endedAt:start+3000,origin:'record',title:null,progress:null}];
  const segments=Array.from({length:3},(_,index)=>({id:`${recordingId}-p${index}`,matterId:recordingId,index,capturedAt:start+index*1000,durationSec:1,sizeBytes:32044,stage:'recorded',localUrl:'',attempts:0}));
  const jobs=segments.map(segment=>{const line={line_id:segment.index*100000+1,text:segment.index?'separate public event':'I will send the plan',cluster_tag:null,t_sec:segment.index,t_end_sec:segment.index+1,is_gap:false};return {id:segment.id,recordingId,index:segment.index,state:'done',lines:[line],requestLines:[{...line,recipe:'v3-semantic-continuity',streaming:true}],session:`stepx_${uuid}_${uuid}`,nextAt:0,attempts:0,events:[{id:`${recordingId}:${line.line_id}`,semanticId:line.line_id,recordingId,title:`Event ${segment.index}`,latestTitle:`Event ${segment.index}`,summary:`Summary ${segment.index}`,lineIds:[line.line_id],startedAt:start+segment.index*1000,endedAt:start+(segment.index+1)*1000}]}});
  return {matters,segments,jobs};
}
export const plain=value=>JSON.parse(JSON.stringify(value));
