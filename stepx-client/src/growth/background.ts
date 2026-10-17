import { useSyncExternalStore } from 'react'
import { growthConnection } from './connection'
import { growthStore } from './store'
import { sourceTransaction, STORE_PROCESSING, STORE_RECORDING_MEMORY } from './idb'
import { fingerprint, recordingMaterial } from './source-scope'
import { BACKGROUND_PREFIX, backgroundOwner, backgroundMatterStamp } from './background-data'
import type { BackgroundOwner, BackgroundSnapshot } from './background-data'
import type { ProcessingJob } from './processing-data'
import type { MemoryRow } from './recording-memory-data'
import type { ActionEvaluation } from './personal-action-data'
import type { RootStatus } from './root-recording'
const UUID=/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/
interface RemoteStatus {
  schema:string;device_id:string;recording_id:string;generation:string;control_version:number
  phase:string;jobs:Array<{id:string;state:string;ref:{sha256:string}}>;
  actions:{ref:{sha256:string}}|null;lastSuccess:number|null;error:string|null
  memory?:{sources:number;pending:number;partial:boolean}
}
const EMPTY={ready:false,running:false,recordings:0,preparing:0,done:0,total:0,failed:0,sources:0,pending:0,controls:0,error:null as string|null}
const defaults={connection:growthConnection,transaction:sourceTransaction,hash:fingerprint,store:growthStore}
/** This client receives artifacts and sends durable user controls; it does not schedule models. */
export class BackgroundProcessing {
  private busy=false
  private timer:ReturnType<typeof setInterval>|null=null
  private disposers:Array<()=>void>=[]
  private view={...EMPTY}
  private listeners=new Set<()=>void>()
  constructor(private deps=defaults) {}
  subscribe=(listener:()=>void)=>{this.listeners.add(listener);return()=>{this.listeners.delete(listener)}}
  getSnapshot=()=>this.view
  private async publish():Promise<void> {
    const owners=await this.transaction(s=>s.jobs.filter(row=>row.id.startsWith(BACKGROUND_PREFIX)) as unknown as BackgroundOwner[])
    const active=owners.filter(row=>row.phase!=='revoked')
    this.view={ready:true,running:this.busy,recordings:active.length,preparing:active.filter(row=>row.phase==='preparing').length,
      done:active.reduce((sum,row)=>sum+(row.remoteDone??0),0),total:active.reduce((sum,row)=>sum+(row.remoteTotal??0),0),
      failed:active.reduce((sum,row)=>sum+(row.remoteFailed??0),0),sources:active.reduce((sum,row)=>sum+(row.remoteSources??0),0),
      pending:active.reduce((sum,row)=>sum+(row.remotePending??0),0),controls:owners.filter(row=>row.dirty||row.control).length,
      error:owners.find(row=>row.error)?.error??null};this.listeners.forEach(fn=>fn())
  }
  init():void {
    if(this.timer)return
    this.timer=setInterval(()=>{void this.kick()},10000)
    this.disposers=[this.deps.connection.subscribe(()=>{void this.kick()}),this.deps.store.subscribe(()=>{void this.kick()})]
    void this.kick()
  }
  dispose():void {if(this.timer)clearInterval(this.timer);this.timer=null;this.disposers.forEach(fn=>fn());this.disposers=[]}
  private identity(owner:BackgroundOwner) {return {device_id:owner.namespace,recording_id:owner.recordingId,generation:owner.generation}}
  private transaction<T>(apply:Parameters<typeof sourceTransaction<T>>[1]):Promise<T> {
    return this.deps.transaction('readwrite',apply,[STORE_RECORDING_MEMORY],true)
  }
  private snapshot(source:Parameters<Parameters<typeof sourceTransaction>[1]>[0],id:string):BackgroundSnapshot {
    const matter=source.matters.find(row=>row.id===id)
    if(!matter)throw Error('录音已删除，后台接管已停止')
    return {matter:structuredClone(matter),segments:source.segments.filter(row=>row.matterId===id),
      jobs:source.jobs.filter(row=>row.recordingId===id&&(!row.id.startsWith('__')||row.id.startsWith('__actions__:'))),
      memory:(source.rows[STORE_RECORDING_MEMORY] as MemoryRow[]).filter(row=>row.recordingId===id&&row.record)}
  }
  async prepare(recordingId:string,status?:RootStatus):Promise<BackgroundOwner> {
    return this.transaction((source,put)=>{
      const prior=backgroundOwner(source.jobs,recordingId);if(prior)return prior
      const snapshot=this.snapshot(source,recordingId)
      if(snapshot.segments.length&&snapshot.matter.endedAt===null) {
        const captures=status?.sessions.filter(row=>row.matterId===recordingId)
        if(!captures?.length||captures.some(row=>row.state!=='stopped'||row.frames===undefined||row.startedAt===undefined||row.uploadRevoked))
          throw Error('旧录音的暂停收尾尚未核验，请先恢复录音状态；原件已保留')
        snapshot.captures=captures.map(({captureId,matterId,indexBase,chunkSeconds,limitSeconds,state,frames,startedAt,reason,uploadClient,audioFormat})=>
          ({captureId,matterId,indexBase,chunkSeconds,limitSeconds,state,frames,startedAt,reason,uploadClient,...(audioFormat?{audioFormat}:{})}))
        let index=0
        for(const capture of [...captures].sort((a,b)=>a.indexBase-b.indexBase)) {
          const pieces=snapshot.segments.filter(p=>p.id.startsWith(`root:${capture.captureId}:`)).sort((a,b)=>a.index-b.index)
          let frames=0
          if(capture.indexBase!==index||!capture.uploadClient||![300,600].includes(capture.chunkSeconds))throw Error('旧录音的分片身份尚未完整核验')
          for(const [i,piece] of pieces.entries()) {
            const upload=piece.rootUpload,job=snapshot.jobs.find(row=>row.id===piece.id)
            const count=Math.round(piece.durationSec*16000)
            if(piece.index!==index+i||piece.id!==`root:${capture.captureId}:${i}`||upload?.captureId!==capture.captureId
              ||upload.piece!==i||upload.client!==capture.uploadClient||!job?.uploaded||!job.remoteKey?.endsWith(`-${upload.sha256}.${piece.rootAudioFormat==='m4a'?'m4a':'wav'}`)
              ||!Number.isSafeInteger(count)||Math.abs(piece.durationSec*16000-count)>1e-6
              ||count!==Math.min(capture.chunkSeconds*16000,capture.frames!-frames)
              ||piece.capturedAt!==Math.floor(capture.startedAt!+frames*1000/16000))throw Error('旧录音的分片回执尚未完整核验')
            frames+=count
          }
          if(frames!==capture.frames)throw Error('旧录音尾片尚未完整保存，后台交接已保留原队列')
          index+=pieces.length
        }
        if(index!==snapshot.segments.length)throw Error('旧录音包含待核材料，后台交接已保留原队列')
      }
      const bytes=new TextEncoder().encode(JSON.stringify(snapshot)).length
      if(snapshot.segments.length>2000||snapshot.jobs.length>2000||snapshot.memory.length>30000||bytes>8*1024*1024-2048
        ||snapshot.jobs.some(job=>new TextEncoder().encode(JSON.stringify(job)).length>8*1024*1024-128))
        throw Error('这场录音超出本次后台交接容量，仍保留现有处理队列及原件')
      if(!UUID.test(recordingId)||snapshot.matter.recordingTimeUnverified||snapshot.segments.some(row=>row.cloudEligible===false)
        ||snapshot.segments.some(row=>!source.jobs.some(job=>job.id===row.id&&job.uploaded&&job.remoteKey)))throw Error('等待已有录音上传回执后再交给后台；原音频仍在本机')
      let identity=source.rows[STORE_RECORDING_MEMORY].find(row=>(row as {id:string}).id==='__identity__') as {id:string;namespace:string}|undefined
      if(!identity){identity={id:'__identity__',namespace:crypto.randomUUID()};put(STORE_RECORDING_MEMORY,identity)}
      if(!UUID.test(identity.namespace))throw Error('本机记忆身份未能核验，请保留数据重试')
      const owner:BackgroundOwner={id:BACKGROUND_PREFIX+recordingId,recordingId,namespace:identity.namespace,generation:crypto.randomUUID(),
        handoffId:crypto.randomUUID(),phase:'preparing',controlVersion:0,epoch:0,dirty:false,snapshot,jobStamps:{},matterStamp:backgroundMatterStamp(snapshot.matter)}
      put(STORE_PROCESSING,owner)
      for(const row of snapshot.memory)put(STORE_RECORDING_MEMORY,{...row,delegated:true})
      return owner
    })
  }
  /** New empty captures can be authorized offline. The root delivers this same claim on reconnect. */
  async startConfig(recordingId:string,status?:RootStatus):Promise<object> {
    const owner=await this.prepare(recordingId,status)
    if(owner.deleted||owner.phase==='revoked')throw Error('该录音已撤回，不能继续后台采集')
    if(owner.phase==='preparing'&&owner.snapshot.segments.length)await this.advance(owner)
    const claim=owner.snapshot.segments.length?undefined:{...this.identity(owner),handoff_id:owner.handoffId,snapshot:owner.snapshot}
    return {namespace:owner.namespace,generation:owner.generation,handoffId:owner.handoffId,...(claim?{claim}:{})}
  }
  async retry(recordingId:string,kind:'failed'|'actions'):Promise<void> {
    await this.update(recordingId,current=>({...current,dirty:true,epoch:current.epoch+1,retry:kind}));await this.kick()
  }
  private async update(id:string,apply:(owner:BackgroundOwner)=>BackgroundOwner):Promise<void> {
    await this.transaction((source,put)=>{const owner=backgroundOwner(source.jobs,id);if(owner)put(STORE_PROCESSING,apply(owner))})
  }
  private async advance(owner:BackgroundOwner):Promise<void> {
    const identity=this.identity(owner)
    if(owner.phase==='preparing') {
      const reply=await this.deps.connection.request<RemoteStatus>('/background/claim',{...identity,handoff_id:owner.handoffId,snapshot:owner.snapshot},90000)
      if(owner.deleted&&reply.generation===owner.generation&&reply.phase==='revoked') {
        await this.update(owner.recordingId,current=>({...current,phase:'revoked',controlVersion:reply.control_version,dirty:false,control:undefined}));return
      }
      if(reply.generation!==owner.generation||reply.phase!=='active'||reply.control_version!==0)throw Error('后台交接回执尚未确认，原件已保留')
      const stamps=Object.fromEntries(await Promise.all(owner.snapshot.jobs.map(async row=>[row.id,await this.deps.hash(JSON.stringify(row))])))
      await this.update(owner.recordingId,current=>current.generation===owner.generation&&current.phase==='preparing'
        ?{...current,phase:'active',jobStamps:stamps}:current)
      owner=(await this.transaction(source=>backgroundOwner(source.jobs,owner.recordingId)))!
    }
    if(owner.phase==='revoked')return
    if(owner.blockedEpoch===owner.epoch&&!owner.deleted)return
    if(owner.deleted) {
      const remote=await this.deps.connection.request<RemoteStatus>('/background/status',identity)
      if(remote.generation===owner.generation&&remote.phase==='revoked'&&remote.control_version>=owner.controlVersion) {
        await this.update(owner.recordingId,current=>({...current,phase:'revoked',controlVersion:remote.control_version,dirty:false,control:undefined}));return
      }
    }
    if(owner.dirty&&!owner.control) {
      const request=await this.transaction((source,put)=>{
        const current=backgroundOwner(source.jobs,owner.recordingId)!
        if(!current.dirty||current.control)return current
        const snapshot=current.deleted?current.snapshot:this.snapshot(source,current.recordingId)
        const control={version:current.controlVersion+1,mutationId:crypto.randomUUID(),epoch:current.epoch,snapshot,deleted:!!current.deleted,
          retry:current.retry,removedIds:current.removedIds??[],removedIndices:current.removedIndices??{}}
        const next={...current,control};put(STORE_PROCESSING,next);return next
      });owner=request
    }
    if(owner.control) {
      const control=owner.control
      let reply:RemoteStatus
      try {reply=await this.deps.connection.request<RemoteStatus>('/background/control',{...identity,control_version:control.version,
        mutation_id:control.mutationId,state:control.deleted?'revoked':'active',...(control.deleted?{}:{snapshot:control.snapshot,
          removed_ids:control.removedIds??[],removed_indices:control.removedIndices??{}}),...(control.retry?{retry:control.retry}:{})},90000)}
      catch(error) {
        if((error as {code?:string}).code!=='background_material_capacity')throw error
        const remote=await this.deps.connection.request<RemoteStatus>('/background/status',identity)
        if(remote.generation!==owner.generation||remote.phase!=='active'||remote.control_version!==owner.controlVersion)throw error
        await this.update(owner.recordingId,current=>current.control?.mutationId===control.mutationId?
          {...current,control:undefined,blockedEpoch:control.epoch,error:'这场录音的处理材料超出容量，原件已保留；缩小修改范围后可重试'}:current)
        return
      }
      if(reply.control_version!==control.version||reply.generation!==owner.generation||reply.phase!==(control.deleted?'revoked':'active'))throw Error('修改尚未由后台确认，请保持待同步记录')
      const stamps=Object.fromEntries(await Promise.all(control.snapshot.jobs.map(async row=>[row.id,await this.deps.hash(JSON.stringify(row))])))
      await this.update(owner.recordingId,current=>current.generation===owner.generation&&current.control?.mutationId===control.mutationId
        ?{...current,control:undefined,controlVersion:control.version,phase:control.deleted?'revoked':'active',dirty:current.epoch!==control.epoch,
          retry:current.epoch===control.epoch?undefined:current.retry,removedIds:(current.removedIds??[]).filter(id=>!control.removedIds?.includes(id)),
          removedIndices:Object.fromEntries(Object.entries(current.removedIndices??{}).filter(([id])=>!control.removedIds?.includes(id))),
          jobStamps:stamps,matterStamp:backgroundMatterStamp(control.snapshot.matter)}:current)
      return
    }
    const status=await this.deps.connection.request<RemoteStatus>('/background/status',identity)
    if(status.generation!==owner.generation||status.control_version!==owner.controlVersion||status.phase!=='active')throw Error('后台版本已变化，等待核对')
    for(const remote of status.jobs) {
      const before=await this.transaction(source=>({owner:backgroundOwner(source.jobs,owner.recordingId),
        job:source.jobs.find(row=>row.id===remote.id),segment:source.segments.find(row=>row.id===remote.id&&row.matterId===owner.recordingId),
        matter:source.matters.find(row=>row.id===owner.recordingId)}))
      if(!before.owner||before.owner.dirty||before.owner.control||before.owner.epoch!==owner.epoch||!before.matter||!before.segment)continue
      const stamp=before.job?await this.deps.hash(JSON.stringify(before.job)):undefined
      if(stamp!==before.owner.jobStamps[remote.id]) {
        // Old tabs and late callbacks also cross this check; preserve the phone's formal edit.
        await this.update(owner.recordingId,current=>({...current,dirty:true,epoch:current.epoch+1}));break
      }
      if(stamp===remote.ref.sha256)continue
      const reply=await this.deps.connection.request<{generation:string;control_version:number;job:ProcessingJob}>('/background/artifact',{
        ...identity,control_version:owner.controlVersion,job_id:remote.id})
      if(reply.generation!==owner.generation||reply.control_version!==owner.controlVersion||reply.job.id!==remote.id
        ||reply.job.recordingId!==owner.recordingId||reply.job.index!==before.segment.index)throw Error('后台产物出处不一致，请保留录音核对')
      const nextStamp=await this.deps.hash(JSON.stringify(reply.job))
      if(nextStamp!==remote.ref.sha256)throw Error('后台产物指纹不一致')
      await this.transaction((source,put)=>{
        const current=backgroundOwner(source.jobs,owner.recordingId),job=source.jobs.find(row=>row.id===remote.id)
        if(!current||current.generation!==owner.generation||current.controlVersion!==owner.controlVersion||current.epoch!==owner.epoch||current.dirty
          ||current.deleted||current.control||!source.matters.some(row=>row.id===owner.recordingId)
          ||JSON.stringify(job)!==JSON.stringify(before.job)
          ||JSON.stringify(source.segments.find(row=>row.id===remote.id))!==JSON.stringify(before.segment))return
        put(STORE_PROCESSING,reply.job);put(STORE_PROCESSING,{...current,jobStamps:{...current.jobStamps,[remote.id]:nextStamp}})
      })
    }
    if(status.actions) {
      const reply=await this.deps.connection.request<{generation:string;control_version:number;job:ActionEvaluation}>('/background/artifact',{
        ...identity,control_version:owner.controlVersion,job_id:'__actions__'})
      if(reply.generation!==owner.generation||reply.control_version!==owner.controlVersion
        ||await this.deps.hash(JSON.stringify(reply.job))!==status.actions.ref.sha256)throw Error('后台个人行动产物未能核验')
      await this.transaction((source,put)=>{
        const current=backgroundOwner(source.jobs,owner.recordingId)
        if(!current||current.dirty||current.control||current.epoch!==owner.epoch||current.controlVersion!==owner.controlVersion||current.deleted)return
        try{if(recordingMaterial(source,owner.recordingId).stamp!==reply.job.stamp)return}catch{return}
        put(STORE_PROCESSING,reply.job)
      })
    }
    await this.update(owner.recordingId,current=>({...current,remoteDone:status.jobs.filter(job=>job.state==='done').length,
      remoteTotal:status.jobs.length,remoteFailed:status.jobs.filter(job=>job.state==='failed').length,
      remoteSources:status.memory?.sources??0,remotePending:status.memory?.pending??0,lastSuccess:status.lastSuccess??undefined,error:status.error??undefined}))
  }
  async kick():Promise<void> {
    if(this.busy)return
    if(!this.deps.connection.isReady()||!this.deps.connection.getSnapshot().health?.backgroundConfigured){await this.publish();return}
    this.busy=true
    try {
      const source=await this.transaction(s=>s)
      for(const matter of source.matters.filter(row=>!row.recordingTimeUnverified&&row.endedAt!==null&&row.captureComplete!==false&&!backgroundOwner(source.jobs,row.id)
        &&source.segments.some(piece=>piece.matterId===row.id&&piece.id.startsWith('root:')))) {
        try{await this.prepare(matter.id)}catch{/* Unuploaded legacy material keeps its existing queue. */}
      }
      const owners=await this.transaction(s=>s.jobs.filter(row=>row.id.startsWith(BACKGROUND_PREFIX)) as unknown as BackgroundOwner[])
      for(const owner of owners)try{await this.advance(owner)}catch{
        await this.update(owner.recordingId,current=>({...current,error:'后台尚未确认，原材料及待同步修改已保留'}))
      }
    }finally{this.busy=false;await this.publish()}
  }
}
export const backgroundProcessing=new BackgroundProcessing()
export const useBackgroundProcessing=()=>useSyncExternalStore(backgroundProcessing.subscribe,backgroundProcessing.getSnapshot,()=>EMPTY)
