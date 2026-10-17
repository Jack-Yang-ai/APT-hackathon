import { invokeNative, onNativeEvent } from '@/shared/bridge'
import { growthStore } from './store'
import { enqueueUpload } from './upload'
import { getSegmentMinutes } from './recorder'
import { getClientId } from './client'
import { sha256 } from './audio'
import { growthConnection } from './connection'
import type { RecorderSnapshot } from './recorder'
import { RootRecordingClient, ROOT_JOURNAL_KEY, rootUuid } from './root-recording'
import type { RootStatus, RootSession } from './root-recording'
import { backgroundProcessing } from './background'

interface RootJournal { version: 1; matterId: string | null; captureId: string | null; stopping: 'pause' | 'finish' | null }
const empty = (): RootJournal => ({ version: 1, matterId: null, captureId: null, stopping: null })
const INITIAL: RecorderSnapshot = { state: 'busy', ready: false, matterId: null, elapsedSec: 0, segmentElapsedSec: 0,
  segmentLimitSec: 300, segmentCount: 0, permission: 'unknown', phase: 'initializing', error: null, notice: null, backgroundSupported: true }
const defaults = { store: growthStore, invoke: invokeNative, listen: onNativeEvent, upload: enqueueUpload,
  compressedAudioReady: () => growthConnection.getSnapshot().health?.audioFormats?.includes('m4a') === true,
  clientId: async () => {
    const value = getClientId(); if (rootUuid(value)) return value
    const h = await sha256(new TextEncoder().encode(value))
    return `${h.slice(0,8)}-${h.slice(8,12)}-${h.slice(12,16)}-${h.slice(16,20)}-${h.slice(20,32)}`
  },
  background:(id:string,status:RootStatus)=>backgroundProcessing.startConfig(id,status),
  now: () => Date.now(), id: () => crypto.randomUUID(), sleep: (ms: number) => new Promise(resolve => setTimeout(resolve, ms)) }

/** Root owns microphone/time. WebView only reconciles and durably receives closed pieces. */
export class RootRecorder {
  private journal = empty()
  private snapshot = { ...INITIAL }
  private status: RootStatus | null = null
  private operations: Promise<void> = Promise.resolve()
  private initializing: Promise<void> | null = null
  private initialized = false
  private listeners = new Set<() => void>()
  private disposers: Array<() => void> = []
  private timer: ReturnType<typeof setInterval> | null = null
  private polling = false
  private stopping: Promise<void> | null = null
  private forgotten = new Set<string>()
  constructor(private readonly client = new RootRecordingClient(), private readonly deps = defaults) {}
  subscribe = (fn: () => void) => { this.listeners.add(fn); return () => { this.listeners.delete(fn) } }
  getSnapshot = (): RecorderSnapshot => this.snapshot
  private emit(patch: Partial<RecorderSnapshot>): void { this.snapshot = { ...this.snapshot, ...patch }; this.listeners.forEach(fn => fn()) }
  private run(action: () => Promise<void>): Promise<void> {
    const next = this.operations.then(action).catch(error => {
      this.emit({ state: 'recovering', phase: null, error: error instanceof Error ? error.message : '持续录音操作未确认，请保存重试' })
    })
    this.operations = next; return next
  }
  private async checkpoint(next: RootJournal): Promise<void> {
    await this.deps.invoke('setStorage', { key: ROOT_JOURNAL_KEY, data: JSON.stringify(next) })
    this.journal = next
  }
  initialize(): Promise<void> {
    if (this.initialized) return Promise.resolve()
    if (this.initializing) return this.initializing
    this.initializing = this.run(async () => {
      await this.deps.store.init()
      if (!this.deps.store.getSnapshot().storageOk) throw new Error('本机录音库未读取，请保留 App 并重试')
      const { data } = await this.deps.invoke('getStorage', { key: ROOT_JOURNAL_KEY })
      if (data) {
        const saved = typeof data === 'string' ? JSON.parse(data) : data as RootJournal
        if (saved.version !== 1 || saved.matterId !== null && !rootUuid(saved.matterId)
          || saved.captureId !== null && !rootUuid(saved.captureId) || ![null, 'pause', 'finish'].includes(saved.stopping))
          throw new Error('持续录音恢复记录未读取，请保留 App 并重试')
        this.journal = saved
      }
      this.emit({ ready: true })
      await this.refresh()
      this.initialized = true
      const changed = this.deps.store.subscribe?.(() => {
        if (this.status?.sessions.some(row => row.uploadClient && !row.uploadRevoked && !this.deps.store.getMatter(row.matterId)))
          void this.run(() => this.refresh())
      })
      if (changed) this.disposers.push(changed)
      const visible = () => { if (document.visibilityState === 'visible') void this.retryRecovery() }
      document.addEventListener('visibilitychange', visible); this.disposers.push(() => document.removeEventListener('visibilitychange', visible))
      this.disposers.push(await this.deps.listen('appShow', () => { void this.retryRecovery() }))
      // No appHide stop: the independent root stream owns locked/background capture.
      this.timer = setInterval(() => {
        if (this.polling || document.visibilityState === 'hidden') return
        this.polling = true
        void this.run(() => this.refresh()).finally(() => { this.polling = false })
      }, 2000)
    }).finally(() => { this.initializing = null })
    return this.initializing
  }
  private async readStatus(): Promise<RootStatus> {
    const status = await this.client.status()
    if (!status) throw new Error('持续录音服务未连接，请恢复手机录音服务')
    this.client.fresh(status); this.status = status; return status
  }
  private session(status: RootStatus): RootSession | undefined { return status.sessions.find(row => row.captureId === this.journal.captureId) }
  private complete(status: RootStatus, matterId: string): boolean {
    const closed = status.sessions.filter(row => row.matterId === matterId), pieces = this.deps.store.segmentsOf(matterId)
    return closed.length > 0 && closed.every(row => row.state === 'stopped' && row.frames !== undefined
      && Math.round(pieces.filter(piece => piece.id.startsWith(`root:${row.captureId}:`)).reduce((sum, piece) => sum + piece.durationSec * 16000, 0)) === row.frames)
  }
  private async receive(status: RootStatus): Promise<void> {
    for (const piece of [...status.pieces].sort((a, b) => a.capturedAt - b.capturedAt || a.index - b.index)) {
      if (this.stopping) break
      const blob = await this.client.audio(piece)
      const segment = { id: `root:${piece.captureId}:${piece.piece}`, matterId: piece.matterId, index: piece.index,
        capturedAt: piece.capturedAt, durationSec: piece.frames / 16000, sizeBytes: piece.size,
        localUrl: this.client.url(piece), stage: 'recorded' as const, attempts: 0, cloudEligible: piece.cloudEligible,
        ...(piece.audioFormat === 'm4a' ? { rootAudioFormat: 'm4a' as const } : {}),
        ...(piece.uploadClient ? { rootUpload: { captureId: piece.captureId, piece: piece.piece, sha256: piece.sha256, client: piece.uploadClient } } : {}) }
      const result = await this.deps.store.commitRootAudio(segment, blob, piece.sha256)
      if (result === 'missing') throw new Error('持续录音归属未读取，原件已保留，请保留 App 并重试')
      // A deletion tombstone is also durable evidence: acknowledge without resurrection.
      this.status = await this.client.command(this.status ?? status, 'ack', { captureId: piece.captureId,
        matterId: piece.matterId, piece: piece.piece, sha256: piece.sha256, disposition: result === 'deleted' ? 'deleted' : 'saved' })
      if (result === 'saved' && piece.cloudEligible) this.deps.upload(segment.id)
    }
  }
  private async refresh(): Promise<void> {
    let status = await this.readStatus()
    // Only an existing durable deletion tombstone can revoke a previously saved upload.
    for (const matterId of new Set(status.sessions.filter(row => row.uploadClient
      && !this.deps.store.getMatter(row.matterId)).map(row => row.matterId))) {
      const key = `${status.epoch}:${matterId}`
      if (!this.forgotten.has(key) && await this.deps.store.wasMatterDeleted?.(matterId)) {
        await this.client.revokeMatter(matterId)
        status = await this.readStatus(); this.forgotten.add(key)
      }
    }
    const running = status.sessions.filter(row => ['starting', 'recording', 'stopping'].includes(row.state))
    if (running.length > 1) throw new Error('持续录音状态冲突，请停止并重试')
    if (running[0] && this.journal.captureId !== running[0].captureId) {
      if (!this.deps.store.getMatter(running[0].matterId)) {
        await this.client.command(status, 'stop', { captureId: running[0].captureId })
        throw new Error('录音归属不存在，已请求停止；原件保留待核对')
      }
      await this.checkpoint({ version: 1, matterId: running[0].matterId, captureId: running[0].captureId, stopping: null })
    }
    await this.receive(status); status = this.status ?? status
    for (const matterId of new Set(status.sessions.map(row => row.matterId))) {
      const matter = this.deps.store.getMatter(matterId)
      if (matter?.rootFinalizing && matter.endedAt !== null && !matter.rootDeletionPending && this.complete(status, matterId))
        await this.deps.store.updateMatter(matterId, { captureComplete: true, rootFinalizing: false })
    }
    const current = this.session(status), matter = this.journal.matterId && this.deps.store.getMatter(this.journal.matterId)
    if (this.journal.matterId && !matter) {
      if (current && ['starting', 'recording', 'stopping'].includes(current.state)) {
        await this.client.command(status, 'stop', { captureId: current.captureId })
        throw new Error('记录已删除，正在停止采集')
      }
      await this.checkpoint(empty())
    }
    const active = current && ['starting', 'recording', 'stopping'].includes(current.state)
    if (!active && this.journal.stopping === 'finish') {
      if (this.journal.matterId && this.deps.store.getMatter(this.journal.matterId)) {
        const closed = status.sessions.filter(row => row.matterId === this.journal.matterId)
        const complete = this.complete(status, this.journal.matterId)
        const owner = this.deps.store.getMatter(this.journal.matterId)!
        await this.deps.store.updateMatter(this.journal.matterId, { endedAt: owner.endedAt ?? this.deps.now(), captureComplete: complete,
          rootFinalizing: !complete && closed.length > 0 && closed.every(row => row.state === 'stopped' && row.frames !== undefined) })
      }
      await this.checkpoint(empty())
    }
    const segments = this.journal.matterId ? this.deps.store.segmentsOf(this.journal.matterId) : []
    const old = segments.filter(row => !current || !row.id.startsWith(`root:${current.captureId}:`)).reduce((sum, row) => sum + row.durationSec, 0)
    const elapsed = old + (current?.frames ?? 0) / 16000
    const state = current?.state === 'recording' ? 'recording' : active ? 'busy' : this.journal.matterId ? 'paused' : 'idle'
    const interrupted = state === 'paused' && current?.state === 'failed'
    this.emit({ state: this.stopping ? 'busy' : state, matterId: this.journal.matterId, elapsedSec: current ? elapsed : segments.reduce((sum, row) => sum + row.durationSec, 0),
      segmentElapsedSec: current ? (current.frames ?? 0) / 16000 % current.chunkSeconds : 0,
      segmentLimitSec: current?.chunkSeconds ?? getSegmentMinutes() * 60, segmentCount: segments.length, ready: true,
      phase: current?.state === 'starting' ? 'starting' : current?.state === 'stopping' ? 'stopping' : null, error: null, interrupted,
      notice: interrupted ? '录音意外中断，已保存的录音仍在本机；可继续录音或结束保存'
        : status.validation ? '当前为真机验收模式，录音仅保存在本机' : current?.reason === 'limit' ? '已达本次12小时上限，保存后可继续' : null })
  }
  start(): Promise<void> {
    return (async () => {
      await this.initialize(); if (!this.initialized) return
      await this.run(async () => {
        await this.refresh()
        if (this.snapshot.state === 'recording' || this.snapshot.state === 'busy') return
        this.emit({ state: 'busy', phase: 'starting', error: null })
        const permission = await this.deps.invoke('requestPermission', { scope: 'record' })
        if (!permission.granted && permission.state !== 'notRequired') throw new Error('没有麦克风权限，无法开始持续录音')
        this.emit({ permission: 'granted' })
        if (!this.journal.matterId) {
          const matter = await this.deps.store.createMatter('record')
          if (!rootUuid(matter.id)) throw new Error('当前设备不支持安全录音身份')
          await this.checkpoint({ ...empty(), matterId: matter.id })
        }
        const startStatus = await this.readStatus()
        const captureId = this.deps.id(), pieces = this.deps.store.segmentsOf(this.journal.matterId!)
        const previous = startStatus.sessions.filter(row => row.matterId === this.journal.matterId)
        if (previous.some(row => row.frames === undefined || ['starting', 'recording', 'stopping'].includes(row.state)))
          throw new Error('上一段录音帧数尚未确认，请保存并重试')
        // Reserve slots for durable PCM too: its public AAC receipt can arrive after resume.
        const indexBase = Math.max(0, ...pieces.map(row => row.index + 1),
          ...previous.map(row => row.indexBase + Math.ceil(row.frames! / (row.chunkSeconds * 16000))))
        await this.checkpoint({ ...this.journal, captureId, stopping: null })
        const uploadClient = startStatus.uploads !== undefined && !startStatus.validation ? await this.deps.clientId() : undefined
        const background=uploadClient&&startStatus.backgroundVersion===1?await this.deps.background(this.journal.matterId!,startStatus):undefined
        await this.deps.store.authorizeRootStart(this.journal.matterId!,uploadClient,async () =>
          this.client.command(startStatus, 'start', { captureId, matterId: this.journal.matterId, indexBase,
            ...(!startStatus.validation && startStatus.audioFormats?.includes('m4a') && this.deps.compressedAudioReady?.() ? { audioFormat: 'm4a' } : {}),
            chunkSeconds: getSegmentMinutes() * 60, ...(uploadClient ? {uploadClient} : {}),...(background?{background}:{}) }))
        const deadline = this.deps.now() + 8000
        while (this.deps.now() < deadline) {
          await this.refresh()
          if (this.getSnapshot().state === 'recording') return
          if (this.session(this.status!)?.state === 'failed') throw new Error('持续录音启动失败，请检查麦克风与通知权限')
          await this.deps.sleep(250)
        }
        throw new Error('持续录音启动尚未确认，请保存重试')
      })
    })()
  }
  resume(): Promise<void> { return this.start() }
  private stop(intent: 'pause' | 'finish'): Promise<void> {
    if (this.stopping) return this.stopping
    this.stopping = (async () => {
      try {
        this.emit({ state: 'busy', phase: 'stopping', error: null })
        const status = await this.readStatus()
        const running = status.sessions.filter(row => ['starting', 'recording', 'stopping'].includes(row.state))
        if (running.length > 1) throw new Error('持续录音状态冲突，请恢复手机录音服务')
        const current = running[0] ?? this.session(status)
        // Stop the verified root capture before any IndexedDB or journal operation.
        const captureId = current?.captureId ?? this.journal.captureId
        if (captureId) await this.client.command(status, 'stop', { captureId,...(status.backgroundVersion===1?{finishMatter:intent==='finish'}:{}) })
        const deadline = this.deps.now() + 16000
        do {
          const next = await this.readStatus()
          const capture = current && next.sessions.find(row => row.captureId === current.captureId)
          if (!capture || !['starting', 'recording', 'stopping'].includes(capture.state)) break
          await this.deps.sleep(250)
        } while (this.deps.now() < deadline)
        const final = current && this.status?.sessions.find(row => row.captureId === current.captureId)
        if (final && ['starting', 'recording', 'stopping'].includes(final.state)) throw new Error('录音停止未确认，请保存重试；原文件仍在本机')
        const next = { ...this.journal, matterId: current?.matterId ?? this.journal.matterId,
          captureId: current?.captureId ?? this.journal.captureId, stopping: intent }
        this.journal = next
        try { await this.checkpoint(next) }
        catch { throw new Error('录音已停止，恢复记录尚未保存；原件保留，请保存重试') }
      } catch (error) {
        this.emit({ state: 'recovering', phase: null, error: error instanceof Error ? error.message : '录音停止尚未确认，请保存重试' })
        return
      } finally { this.stopping = null }
      // Receiving may fail independently; it never prevents microphone stop.
      await this.initialize()
      if (this.initialized) await this.run(async () => {
        await this.refresh()
        if (intent === 'pause') await this.checkpoint({ ...this.journal, stopping: null })
      })
    })()
    return this.stopping
  }
  pause(): Promise<void> { return this.stop('pause') }
  finish(): Promise<void> { return this.stop('finish') }
  retryRecovery(): Promise<void> { return (async () => { await this.initialize(); if (this.initialized) await this.run(() => this.refresh()) })() }
  dismissError(): void { if (this.snapshot.state !== 'recovering') this.emit({ error: null }) }
  dispose(): void { if (this.timer) clearInterval(this.timer); this.timer = null; this.disposers.forEach(fn => fn()); this.disposers = [] }
}
