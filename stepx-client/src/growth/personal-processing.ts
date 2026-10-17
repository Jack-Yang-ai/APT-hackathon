import { useSyncExternalStore } from 'react'
import { sourceTransaction, readSources, STORE_PROCESSING } from './idb'
import { growthStore } from './store'
import { growthProcessing } from './processing'
import { growthConnection, CloudFailure } from './connection'
import { recordingMaterial, type Sources } from './source-scope'
import { freezeLines } from './processing-data'
import { ACTION_PROTOCOL, currentEvaluation, currentEvaluations, parsePersonalActions } from './personal-action-data'
import type { ActionEvaluation, PersonalCandidate } from './personal-action-data'

interface PersonalSnapshot { ready:boolean; evaluations:ActionEvaluation[]; candidates:PersonalCandidate[]; error:string|null }
const EMPTY:PersonalSnapshot={ready:false,evaluations:[],candidates:[],error:null}
const defaults={read:readSources,transaction:sourceTransaction,connection:growthConnection}
class SourceChanged extends Error {}
export class PersonalProcessing {
  private snapshot=EMPTY
  private listeners=new Set<()=>void>()
  private busy=false
  private owner=crypto.randomUUID()
  private timer:ReturnType<typeof setInterval>|null=null
  private disposers:(()=>void)[]=[]
  private refreshRevision=0
  constructor(private deps=defaults) {}
  subscribe=(listener:()=>void)=>{this.listeners.add(listener);return()=>{this.listeners.delete(listener)}}
  getSnapshot=()=>this.snapshot
  private emit(patch:Partial<PersonalSnapshot>) { this.snapshot={...this.snapshot,...patch};this.listeners.forEach(listener=>listener()) }
  private publish(source:Sources) {
    const evaluations=(source.jobs.filter(row=>row.id.startsWith('__actions__:')) as unknown as ActionEvaluation[]).map(row=>{
      try {
        if(recordingMaterial(source,row.recordingId).stamp!==row.stamp || (row.state==='done'&&!currentEvaluation(source,row.recordingId)))throw new Error('stale')
        return row
      }catch{return {...row,state:'failed' as const,error:'来源或评估已变化，请重新识别个人行动'}}
    })
    const candidates=source.matters.flatMap(matter=>currentEvaluations(source,matter.id).flatMap(row=>row.candidates??[]))
    this.emit({ready:true,evaluations,candidates})
  }
  private sourcesChanged=()=>{
    this.emit({candidates:[]})
    void this.refresh().then(()=>this.kick()).catch(()=>this.emit({error:'个人行动来源暂时无法读取，请重试'}))
  }
  async refresh():Promise<void> { const revision=++this.refreshRevision,source=await this.deps.read();if(revision===this.refreshRevision)this.publish(source) }
  async init():Promise<void> {
    if (this.timer) return
    try { await this.refresh();this.emit({error:null}) }
    catch {this.emit({error:'个人行动记录未能读取，请保留 App 并重试'});return}
    this.disposers=[growthStore.subscribe(this.sourcesChanged),growthProcessing.subscribe(this.sourcesChanged),growthConnection.subscribe(this.sourcesChanged)]
    this.timer=setInterval(this.sourcesChanged,10000)
    void this.kick()
  }
  dispose() { if(this.timer)clearInterval(this.timer);this.timer=null;this.disposers.forEach(fn=>fn());this.disposers=[] }
  async recognize(recordingId:string):Promise<void> {
    if((await this.deps.read()).jobs.some(row=>row.id==='__background__:'+recordingId)) {
      await (await import('./background')).backgroundProcessing.retry(recordingId,'actions');await this.refresh();return
    }
    await this.queue(recordingId,true);await this.refresh();await this.kick()
  }
  private async queue(recordingId:string,explicit:boolean):Promise<void> {
    const requestId=crypto.randomUUID()
    await this.deps.transaction('readwrite',(source,put)=>{
      const matter=source.matters.find(row=>row.id===recordingId)
      if(source.jobs.some(row=>row.id==='__background__:'+recordingId))return
      if(!explicit && !matter?.personalActionsEnabled)return
      const old=source.jobs.find(row=>row.id===`__actions__:${recordingId}`) as unknown as ActionEvaluation|undefined
      const material=recordingMaterial(source,recordingId),lines=freezeLines(material.lines)
      const revision=source.jobs.filter(row=>row.recordingId===recordingId&&!row.id.startsWith('__')).reduce((sum,row)=>sum+(row.lineRevision??0),0)
      if (old && (!explicit || (['queued','running'].includes(old.state) && old.stamp===material.stamp))) return
      if(lines.length) lines[0]={...lines[0],action_protocol:ACTION_PROTOCOL,action_only:true,action_request:requestId,source_revision:revision}
      const session=material.session.slice(0,-36)+requestId
      if(new TextEncoder().encode(JSON.stringify({session,part:0,lines})).length>256*1024) throw new Error('整场原话超出当前识别容量，材料已保留')
      const evaluation:ActionEvaluation={id:`__actions__:${recordingId}`,recordingId,requestId,revision,stamp:material.stamp,
        session,lines,state:lines.length?'queued':'done',candidates:lines.length?undefined:[],nextAt:0}
      put(STORE_PROCESSING,evaluation)
    })
  }
  private async update(row:ActionEvaluation,claim=false):Promise<boolean> {
    return this.deps.transaction('readwrite',(source,put)=>{
      const current=source.jobs.find(job=>job.id===row.id) as unknown as ActionEvaluation|undefined
      if(source.jobs.some(job=>job.id==='__background__:'+row.recordingId))return false
      if(!current || current.requestId!==row.requestId || recordingMaterial(source,row.recordingId).stamp!==row.stamp) throw new SourceChanged('录音来源已变化，请重新识别')
      if(claim ? current.until!>Date.now() && current.owner!==this.owner : current.owner!==this.owner || current.until!<=Date.now()) return false
      put(STORE_PROCESSING,{...row,owner:this.owner,until:Date.now()+240000});return true
    })
  }
  private async call<T>(path:string,body:unknown,row:ActionEvaluation):Promise<T> {
    if(!this.deps.connection.isReady() || !await this.update(row)) throw new SourceChanged('识别已暂停，等待连接和当前来源')
    return this.deps.connection.request<T>(path,body)
  }
  async kick():Promise<void> {
    if(this.busy || !this.snapshot.ready || !this.deps.connection.isReady()
      || !this.deps.connection.getSnapshot().health?.extractionQueueConfigured)return
    this.busy=true
    try {
      let source=await this.deps.read()
      for(const matter of source.matters.filter(row=>row.personalActionsEnabled && row.endedAt!==null)) {
        try {await this.queue(matter.id,false)}catch{ /* Full material is not available yet. */ }
      }
      source=await this.deps.read();this.publish(source)
      for(const current of this.snapshot.evaluations) {
        if(!['queued','running'].includes(current.state) || current.nextAt>Date.now())continue
        const row=structuredClone(current)
        if(!await this.update(row,true))continue
        try {
          if(!row.ticket) {
            const receipt=await this.call<{ticket:string;state:string}>('/extract/enqueue',{session:row.session,part:0,lines:row.lines},row)
            if(!receipt.ticket?.startsWith(row.session+'-') || !['queued','done'].includes(receipt.state))throw new Error('个人行动回执无效')
            row.ticket=receipt.ticket;row.state='running';row.nextAt=0
            if(!await this.update(row))throw new SourceChanged('识别任务已转交')
          }
          const receipt=await this.call<{state:string;payload?:unknown}>('/extract/result',{ticket:row.ticket},row)
          if(['none','running'].includes(receipt.state))row.nextAt=Date.now()+15000
          else if(receipt.state==='done') {row.candidates=parsePersonalActions(receipt.payload,row);row.state='done';row.error=undefined}
          else throw new Error('个人行动回执状态无效')
        }catch(error) {
          if(error instanceof SourceChanged)throw error
          const code=error instanceof CloudFailure?error.code:''
          if(['offline','unknown_result','network_failed','connection_changed'].includes(code)) {row.nextAt=Date.now()+20000;row.error='等待核对原识别回执'}
          else {row.state='failed';row.error=error instanceof Error?error.message:'个人行动识别失败，请重新识别'}
        }
        if(!await this.update(row))throw new SourceChanged('识别任务已转交')
      }
      await this.refresh();this.emit({error:null})
    }catch(error) {await this.refresh().catch(()=>undefined);this.emit({error:error instanceof Error?error.message:'个人行动回执未保存，请重试'})}
    finally {this.busy=false}
  }
}
export const personalProcessing=new PersonalProcessing()
export function usePersonalActions() { return useSyncExternalStore(personalProcessing.subscribe,personalProcessing.getSnapshot,()=>EMPTY) }
