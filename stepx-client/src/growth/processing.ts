import { useSyncExternalStore } from 'react'
import { growthConnection, CloudFailure } from './connection'
import { growthStore } from './store'
import { getClientId } from './client'
import { STORE_PROCESSING, idbGetAll, processingLease } from './idb'
import { toWav, sha256 } from './audio'
import { parseASR, parseEvents, freezeLines, SEMANTIC_RECIPE, retryProcessingJob } from './processing-data'
import type { ProcessingJob, PreviousContext, UnderstoodEvent } from './processing-data'
import type { Segment, Matter } from './types'
import { projectedEvents, previousContext, fragmentMaterial } from './source-scope'
import { ACTION_PROTOCOL, parsePersonalActions } from './personal-action-data'
import { RootRecordingClient } from './root-recording'

export interface ProcessingSnapshot { ready: boolean; running: boolean; error: string | null; jobs: ProcessingJob[]; events: UnderstoodEvent[] }
const EMPTY: ProcessingSnapshot = { ready: false, running: false, error: null, jobs: [], events: [] }
class LeaseLost extends Error {}
class StorageFailure extends Error {}
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
async function identity(value: string): Promise<string> {
  if (uuid.test(value)) return value
  const hash = await sha256(new TextEncoder().encode(value))
  return `${hash.slice(0,8)}-${hash.slice(8,12)}-${hash.slice(12,16)}-${hash.slice(16,20)}-${hash.slice(20,32)}`
}
export const PROCESSING_LABEL: Record<ProcessingJob['state'], string> = {
  pending: '待上传', uploading: '上传中', transcribing: '等待转写', extracting: '正在按事整理', done: '已整理', failed: '处理未完成',
}
const defaults = {
  connection: growthConnection, store: growthStore, clientId: getClientId,
  read: () => idbGetAll<ProcessingJob>(STORE_PROCESSING), lease: processingLease, toWav, hash: sha256,
  nativeUpload: (captureId: string, piece: number) => new RootRecordingClient().uploadReceipt(captureId,piece),
  retryBackground:async(id:string)=>(await import('./background')).backgroundProcessing.retry(id,'failed'),
}
/** Transport receipts are local; semantic decisions always come from the existing recipe. */
export class GrowthProcessing {
  private snapshot: ProcessingSnapshot = EMPTY
  private listeners = new Set<() => void>()
  private busy = false
  private initialized = false
  private owner = crypto.randomUUID()
  private lost = false
  private timer: ReturnType<typeof setInterval> | null = null
  private initPromise: Promise<void> | null = null
  constructor(private readonly deps = defaults) {}
  subscribe = (listener: () => void) => { this.listeners.add(listener); return () => { this.listeners.delete(listener) } }
  getSnapshot = (): ProcessingSnapshot => this.snapshot
  private emit(patch: Partial<ProcessingSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch }
    this.listeners.forEach(listener => listener())
  }
  private sources(jobs: ProcessingJob[]) {
    return { jobs,segments:this.deps.store.getSnapshot().segments,
      matters:[...new Set(jobs.map(job=>job.recordingId))].flatMap(id=>{ const row=this.deps.store.getMatter(id); return row?[row]:[] }) }
  }
  private publish(jobs: ProcessingJob[]): void { this.emit({ jobs, events: projectedEvents(this.sources(jobs)) }) }
  init(): Promise<void> {
    if (this.initPromise) return this.initPromise
    this.initPromise = (async () => {
      try {
        this.publish((await this.deps.read()).filter(job => !job.id.startsWith('__')))
        this.emit({ ready: true, error: null })
        if (!this.initialized) {
          this.initialized = true
          this.deps.connection.subscribe(() => { void this.kick() })
          this.deps.store.subscribe(() => { this.publish(this.snapshot.jobs); void this.kick() })
          this.timer = setInterval(() => { void this.kick() }, 10000)
        }
        void this.kick()
      } catch { this.emit({ ready: false, error: '处理记录未能读取，请检查本机存储后重试' }); this.initPromise = null }
    })()
    return this.initPromise
  }
  dispose(): void { if (this.timer) clearInterval(this.timer); this.timer = null }
  async retryStorage(): Promise<void> { this.initPromise = null; this.emit({ error: null }); await this.init() }
  private async guard(): Promise<void> {
    if (this.lost || !this.deps.connection.isReady()) throw new LeaseLost()
    let accepted: boolean
    try { accepted = await this.deps.lease(this.owner, 'renew') } catch { throw new StorageFailure() }
    if (!accepted) { this.lost = true; throw new LeaseLost() }
  }
  private async save(job: ProcessingJob): Promise<void> {
    if((await this.deps.read()).some(row=>row.id==='__background__:'+job.recordingId))throw new LeaseLost()
    if (this.lost || !this.deps.connection.isReady() || !this.deps.store.getMatter(job.recordingId)
      || !this.deps.store.getSnapshot().segments.some(segment => segment.id === job.id && segment.matterId === job.recordingId && segment.cloudEligible !== false)) throw new LeaseLost()
    let accepted: boolean
    try { accepted = await this.deps.lease(this.owner, 'put', job) } catch { throw new StorageFailure() }
    if (!accepted) { this.lost = true; throw new LeaseLost() }
    this.publish([...this.snapshot.jobs.filter(row => row.id !== job.id), structuredClone(job)])
  }
  private async call<T>(path: string, body: unknown, job: ProcessingJob): Promise<T> {
    await this.guard()
    if((await this.deps.read()).some(row=>row.id==='__background__:'+job.recordingId))throw new LeaseLost()
    if (!this.deps.store.getSnapshot().segments.some(segment => segment.id === job.id && segment.matterId === job.recordingId && segment.cloudEligible !== false)) throw new LeaseLost()
    return this.deps.connection.request<T>(path, body)
  }
  async kick(): Promise<void> {
    if (this.busy || !this.snapshot.ready || this.snapshot.error || !this.deps.store.getSnapshot().ready
      || !this.deps.store.getSnapshot().storageOk || !this.deps.connection.isReady()) return
    const health = this.deps.connection.getSnapshot().health
    if (!health?.asrConfigured || !health.extractionQueueConfigured || health.semanticRecipe !== SEMANTIC_RECIPE) return
    this.busy = true; let held = false
    let heartbeat: ReturnType<typeof setInterval> | null = null
    try {
      held = await this.deps.lease(this.owner, 'claim'); if (!held) return
      this.lost = false; this.emit({ running: true })
      heartbeat = setInterval(() => { void this.guard().catch(error => { this.lost = true; if (error instanceof StorageFailure) this.emit({ error: '处理回执未保存，请检查本机存储后重试' }) }) }, 20000)
      const all=await this.deps.read(),delegated=new Set(all.filter(row=>row.id.startsWith('__background__:')).map(row=>row.recordingId))
      this.publish(all.filter(job => !job.id.startsWith('__')))
      const segments = this.deps.store.getSnapshot().segments.filter(segment => segment.cloudEligible !== false&&!delegated.has(segment.matterId)).sort((a,b)=>a.index-b.index)
      for (const segment of segments) {
        if (!this.deps.store.getMatter(segment.matterId)) continue
        const prior = this.snapshot.jobs.find(job => job.id === segment.id)
        if (!prior) await this.save({ id: segment.id, recordingId: segment.matterId, index: segment.index,
          state: 'pending', nextAt: 0, attempts: 0 })
      }
      // Upload/ASR may run ahead. Only semantic extraction waits for earlier pieces.
      for (const segment of segments) {
        const job = this.snapshot.jobs.find(row => row.id === segment.id)
        const recording = this.deps.store.getMatter(segment.matterId)
        if (!job || !recording || job.state === 'done' || job.state === 'failed' || job.nextAt > Date.now()) continue
        if (job.lines?.length && this.snapshot.jobs.some(row => row.recordingId === job.recordingId && row.index < job.index && row.state !== 'done')) continue
        await this.advance(structuredClone(job), segment, recording)
      }
    } catch (error) {
      if (!(error instanceof LeaseLost)) this.emit({ error: '处理回执未保存，请检查本机存储后重试；原音频已保留' })
    } finally {
      if (heartbeat) clearInterval(heartbeat)
      if (held) await this.deps.lease(this.owner, 'release').catch(() => undefined)
      this.busy = false; this.emit({ running: false })
    }
  }
  private previous(job: ProcessingJob, recording: Matter): PreviousContext | undefined {
    const earlier = this.snapshot.jobs.filter(row => row.recordingId === job.recordingId && row.index < job.index && row.state === 'done')
    const events = projectedEvents(this.sources(earlier)).sort((a,b)=>b.endedAt-a.endedAt), event = events[0]
    if (!event) return undefined
    return previousContext(event,recording.startedAt)
  }
  private async advance(job: ProcessingJob, segment: Segment, recording: Matter): Promise<void> {
    try {
      if (!job.uploaded) {
        job.state = 'uploading'; job.error = undefined; await this.save(job)
        const blob = await this.deps.store.getAudio(job.id)
        if (!blob?.size) throw new Error('本机音频缺失，请保留记录并检查存储')
        const format = segment.rootAudioFormat === 'm4a' ? 'm4a' : 'wav'
        const wav = format === 'm4a' ? new Uint8Array(await blob.arrayBuffer()) : await this.deps.toWav(blob)
        const fingerprint = await this.deps.hash(wav)
        const [client, session, piece] = await Promise.all([identity(this.deps.clientId()), identity(job.recordingId), identity(job.id)])
        const key = `stepx/${client}/${session}/${piece}-${fingerprint}.${format}`
        if (job.remoteKey && job.remoteKey !== key) throw new Error('转换结果变化，原音频已保留，需核对后再上传')
        job.remoteKey = key; job.session = `stepx_${client}_${session}`; job.seconds = format === 'm4a' ? segment.durationSec : (wav.byteLength - 44) / 32000
        await this.save(job)
        let receipt: { key: string; durationSec: number }
        if (segment.rootUpload) {
          const owner = segment.rootUpload
          if (owner.client !== client || owner.sha256 !== fingerprint || job.id !== `root:${owner.captureId}:${owner.piece}`)
            throw new Error('后台上传来源已变化，原音频已保留，请核对后重试')
          let native
          try { native = await this.deps.nativeUpload(owner.captureId,owner.piece) } catch { /* Keep waiting for the durable native server receipt. */ }
          if (!native || native.state !== 'uploaded') {
            job.state = 'pending'; job.nextAt = Date.now() + 10000
            job.error = native?.state === 'waiting-connection' ? '请连接云代理，后台将继续上传'
              : native?.state === 'cancelled' ? '后台上传已撤销，请保留原录音核对' : '等待后台上传回执，原录音已保留'
            await this.save(job); return
          }
          if (native.captureId !== owner.captureId || native.piece !== owner.piece || native.matterId !== job.recordingId
            || native.sha256 !== fingerprint || native.key !== key || native.frames !== Math.round(job.seconds * 16000))
            throw new Error('后台上传回执不匹配，原音频已保留，请核对后重试')
          receipt = native
        } else receipt = await this.call<{ key: string; durationSec: number }>('/upload?key=' + encodeURIComponent(key)
          + (format === 'm4a' ? '&frames=' + Math.round(job.seconds * 16000) : ''), format === 'm4a' ? new Blob([wav.slice().buffer], {type: 'audio/mp4'}) : wav, job)
        if (receipt.key !== key || Math.abs(receipt.durationSec - job.seconds) > 0.001) throw new Error('上传回执不完整，可以重试')
        job.uploaded = true; job.state = 'transcribing'; job.nextAt = 0; await this.save(job)
      }
      if (job.lines === undefined) {
        if (!job.taskId) {
          const retryFailed = job.retryFailed === true && typeof job.retryId === 'string'
          if (job.retryFailed === true) {
            // Consume consent durably before dispatch: a crash or a failed receipt
            // write must not authorize another paid attempt after server expiry.
            job.retryFailed = false
            await this.save(job)
          }
          const receipt = await this.call<{ task_id: string }>('/asr/submit', { key: job.remoteKey, seconds: job.seconds,
            ...(retryFailed ? { retryFailed: true, retryId: job.retryId } : {}) }, job)
          if (typeof receipt.task_id !== 'string' || !/^[a-zA-Z0-9_-]{1,160}$/.test(receipt.task_id)) throw new Error('转写回执不完整，可以重试核对')
          job.taskId = receipt.task_id; job.retryFailed = false; job.error = undefined; await this.save(job)
        }
        const receipt = await this.call<{ state: string }>('/asr/query', { task_id: job.taskId }, job)
        if (receipt.state === 'waiting') { job.nextAt = Date.now() + 15000; await this.save(job); return }
        job.lines = parseASR(receipt, segment, recording, job.seconds!)
        job.lineRevision=(job.lineRevision??0)+1
        if (!job.lines.length) { job.state = 'done'; job.events = []; job.error = undefined; await this.save(job); return }
        job.state = 'extracting'; job.nextAt = 0; await this.save(job)
      }
      if (this.snapshot.jobs.some(row => row.recordingId === job.recordingId && row.index < job.index && row.state !== 'done')) return
      if (!job.ticket) {
        if (!job.requestLines) {
          const material=fragmentMaterial(this.sources([...this.snapshot.jobs.filter(row=>row.id!==job.id),job]),job.id)
          const requestId=crypto.randomUUID()
          job.requestLines = freezeLines(job.lines, this.previous(job, recording))
          job.requestRevision=job.lineRevision??0
          job.requestLines[0]={...job.requestLines[0],action_protocol:ACTION_PROTOCOL,action_request:requestId,source_revision:material.revision}
          job.personalEvaluation={id:`__fragment_actions__:${job.id}`,fragmentId:job.id,recordingId:job.recordingId,
            requestId,revision:material.revision,stamp:material.stamp,session:job.session!,lines:structuredClone(job.lines),state:'queued',nextAt:0}
          await this.save(job)
        }
        const receipt = await this.call<{ ticket: string; state: string }>('/extract/enqueue', { session: job.session, part: job.extractPart ?? job.index, lines: job.requestLines }, job)
        if (typeof receipt.ticket !== 'string' || !receipt.ticket.startsWith(job.session + '-') || !['queued','done'].includes(receipt.state)) throw new Error('整理回执不完整，可以重试核对')
        job.ticket = receipt.ticket; job.nextAt = Date.now() + 5000; await this.save(job)
      }
      const result = await this.call<{ state: string; payload?: unknown }>('/extract/result', { ticket: job.ticket }, job)
      if (['running','none'].includes(result.state)) { job.nextAt = Date.now() + 15000; await this.save(job); return }
      if (result.state !== 'done') throw new Error('整理状态无法识别')
      job.events = parseEvents(result.payload, job, recording.startedAt)
      if(job.requestLines?.[0]?.action_protocol===ACTION_PROTOCOL) {
        if(!job.personalEvaluation)throw new Error('个人行动冻结来源缺失，请保留原话并重试')
        job.personalEvaluation.candidates=parsePersonalActions(result.payload,job.personalEvaluation)
        job.personalEvaluation.state='done'
      }
      job.state = 'done'; job.error = undefined; job.nextAt = 0; await this.save(job)
    } catch (error) {
      if (error instanceof LeaseLost || error instanceof StorageFailure) throw error
      const code = error instanceof CloudFailure ? error.code : 'invalid_result'
      if (['offline','unknown_result','network_failed','asr_submission_unknown','connection_changed'].includes(code)) {
        // A user's retry authorizes one attempt, not automatic paid retries after expiry.
        job.retryFailed = false
        job.nextAt = Date.now() + 20000
        if (!job.uploaded) job.state = 'pending'
        job.error = error instanceof Error ? error.message : '稍后会核对处理回执'
      } else {
        job.state = 'failed'; job.attempts++; job.failureCode = code
        job.error = error instanceof Error ? error.message : '处理未完成，可重试；原音频已保留'
      }
      await this.save(job)
    }
  }
  async retryRecording(recordingId: string): Promise<void> {
    if (this.busy) return
    if((await this.deps.read()).some(row=>row.id==='__background__:'+recordingId)) {await this.deps.retryBackground(recordingId);return}
    this.busy = true; let held = false
    try {
      held = await this.deps.lease(this.owner, 'claim'); if (!held) return
      this.lost = false
      this.publish((await this.deps.read()).filter(job => !job.id.startsWith('__')))
      for (const current of this.snapshot.jobs.filter(row=>row.recordingId===recordingId && row.state==='failed')) {
        await this.save(retryProcessingJob(current))
      }
    } finally {
      if (held) await this.deps.lease(this.owner, 'release').catch(()=>undefined)
      this.busy = false
    }
    await this.kick()
  }
}
export const growthProcessing = new GrowthProcessing()
export function useGrowthProcessing(): ProcessingSnapshot {
  return useSyncExternalStore(growthProcessing.subscribe, growthProcessing.getSnapshot, () => EMPTY)
}
