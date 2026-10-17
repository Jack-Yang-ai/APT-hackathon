// The Worker bundles the production parsers. No alternate semantic recipe lives here.
import { parseASR, parseEvents, freezeLines } from '../../stepx-client/src/growth/processing-data'
export { retryProcessingJob } from '../../stepx-client/src/growth/processing-data'
import type { ProcessingJob } from '../../stepx-client/src/growth/processing-data'
import { projectedEvents, previousContext, fragmentMaterial, recordingMaterial } from '../../stepx-client/src/growth/source-scope'
import type { Sources } from '../../stepx-client/src/growth/source-scope'
import { ACTION_PROTOCOL, parsePersonalActions } from '../../stepx-client/src/growth/personal-action-data'
import type { ActionEvaluation } from '../../stepx-client/src/growth/personal-action-data'
export { projectRecordingMemory, canonicalRecording } from '../../stepx-client/src/growth/recording-memory-data'
export { projectedEvents, recordingMaterial }
type Call = <T = Record<string, unknown>>(path: string, body: unknown) => Promise<T>
/** Every paid request identity and frozen input is durable before dispatch. */
export async function advance(source: Sources, job: ProcessingJob, call: Call, save: (job: ProcessingJob) => Promise<void>): Promise<void> {
  const recording=source.matters.find(row=>row.id===job.recordingId)!
  const segment=source.segments.find(row=>row.id===job.id)!
  if(!recording || !segment || !job.uploaded || !job.remoteKey || !job.session || !job.seconds)throw Error('invalid_background_source')
  if(job.lines===undefined) {
    if(!job.taskId) {
      const retryId=job.retryFailed===true?job.retryId:undefined
      if(job.retryFailed===true) {
        job.retryFailed=false
        await save(job)
      }
      const result=await call<{task_id:string}>('/asr/submit',{key:job.remoteKey,seconds:job.seconds,...(retryId?{retryFailed:true,retryId}:{})})
      if(!/^[a-zA-Z0-9_-]{1,160}$/.test(result.task_id??''))throw Error('invalid_asr_receipt')
      job.taskId=result.task_id;job.retryFailed=false;job.state='transcribing';await save(job)
    }
    const result=await call<{state:string}>('/asr/query',{task_id:job.taskId})
    if(result.state==='waiting'){job.nextAt=Date.now()+15000;await save(job);return}
    job.lines=parseASR(result,segment,recording,job.seconds)
    job.lineRevision=(job.lineRevision??0)+1
    job.state=job.lines.length?'extracting':'done';job.nextAt=0
    if(!job.lines.length)job.events=[]
    await save(job);return
  }
  const semanticStart=job.semanticStart??0
  if(source.segments.some(row=>row.matterId===recording.id && row.index>=semanticStart&&row.index<segment.index
    && !source.jobs.some(prior=>prior.id===row.id&&prior.state==='done')))return
  // A missing earlier transport piece cannot be filled by the next arrival.
  if(source.segments.filter(row=>row.matterId===recording.id&&row.index>=semanticStart&&row.index<=segment.index).length!==segment.index-semanticStart+1)return
  if(!job.requestLines) {
    const earlier=source.jobs.filter(row=>row.index>=semanticStart&&row.index<job.index&&row.state==='done')
    const event=projectedEvents({...source,jobs:earlier}).sort((a,b)=>b.endedAt-a.endedAt)[0]
    const material=fragmentMaterial(source,job.id),requestId=crypto.randomUUID()
    job.requestLines=freezeLines(job.lines,event?previousContext(event,recording.startedAt):undefined)
    job.requestRevision=job.lineRevision??0
    job.requestLines[0]={...job.requestLines[0],action_protocol:ACTION_PROTOCOL,action_request:requestId,source_revision:material.revision}
    job.personalEvaluation={id:`__fragment_actions__:${job.id}`,fragmentId:job.id,recordingId:job.recordingId,
      requestId,revision:material.revision,stamp:material.stamp,session:job.session,lines:structuredClone(job.lines),state:'queued',nextAt:0}
    await save(job)
  }
  if(!job.ticket) {
    const result=await call<{ticket:string;state:string}>('/extract/enqueue',{session:job.session,part:job.extractPart??job.index,lines:job.requestLines})
    if(!result.ticket?.startsWith(job.session+'-')||!['queued','done'].includes(result.state))throw Error('invalid_extraction_receipt')
    job.ticket=result.ticket;await save(job)
  }
  const result=await call<{state:string;payload?:unknown}>('/extract/result',{ticket:job.ticket})
  if(['running','none'].includes(result.state)){job.nextAt=Date.now()+15000;await save(job);return}
  if(result.state!=='done')throw Error('invalid_extraction_receipt')
  job.events=parseEvents(result.payload,job,recording.startedAt)
  if(job.requestLines?.[0]?.action_protocol===ACTION_PROTOCOL) {
    if(!job.personalEvaluation)throw Error('missing_frozen_actions')
    job.personalEvaluation.candidates=parsePersonalActions(result.payload,job.personalEvaluation);job.personalEvaluation.state='done'
  }
  job.state='done';job.nextAt=0;job.error=undefined;await save(job)
}
export async function wholeActions(source:Sources,prior:ActionEvaluation|undefined,call:Call,save:(row:ActionEvaluation)=>Promise<void>) {
  const matter=source.matters[0]
  if(!matter?.personalActionsEnabled||matter.endedAt===null||matter.captureComplete===false)return
  let material;try{material=recordingMaterial(source,matter.id)}catch{return}
  if(prior?.stamp===material.stamp&&['done','failed'].includes(prior.state))return
  let row=prior?.stamp===material.stamp?structuredClone(prior):undefined
  if(!row) {
    const requestId=crypto.randomUUID(),lines=freezeLines(material.lines)
    const revision=source.jobs.reduce((sum,job)=>sum+(job.lineRevision??0),0)
    if(lines.length)lines[0]={...lines[0],action_protocol:ACTION_PROTOCOL,action_only:true,action_request:requestId,source_revision:revision}
    row={id:`__actions__:${matter.id}`,recordingId:matter.id,requestId,revision,stamp:material.stamp,
      session:material.session.slice(0,-36)+requestId,lines,state:lines.length?'queued':'done',candidates:lines.length?undefined:[],nextAt:0}
    await save(row)
  }
  if(row.state==='done'||row.nextAt>Date.now())return
  try {
  if(!row.ticket) {
    const result=await call<{ticket:string;state:string}>('/extract/enqueue',{session:row.session,part:0,lines:row.lines})
    if(!result.ticket?.startsWith(row.session+'-')||!['queued','done'].includes(result.state))throw Error('invalid_extraction_receipt')
    row.ticket=result.ticket;row.state='running';await save(row)
  }
  const result=await call<{state:string;payload?:unknown}>('/extract/result',{ticket:row.ticket})
  if(['running','none'].includes(result.state))row.nextAt=Date.now()+15000
  else if(result.state==='done'){row.candidates=parsePersonalActions(result.payload,row);row.state='done';row.error=undefined}
  else throw Error('invalid_extraction_receipt')
  await save(row)
  }catch(error) {
    const failure=error as {code?:string;message?:string}
    if(failure.message==='recording_producer_fenced')throw error
    const retry=['offline','unknown_result','network_failed','asr_submission_unknown','upstream_unavailable','processing_failed'].includes(failure.code??failure.message??'')
    row={...row,state:retry?row.state:'failed',nextAt:Date.now()+30000,error:retry?'后台等待原识别回执':'整场个人行动识别未完成，可保留原话后重新识别'}
    await save(row)
  }
}
