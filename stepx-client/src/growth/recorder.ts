/** Native capture ownership is journaled before recording; audio and metadata commit together. */
import { useSyncExternalStore } from 'react'
import { BridgeError, getBridgeMode, invokeNative, onNativeEvent, nativeLog } from '@/shared/bridge'
import { storage } from '@/shared/lib/storage'
import { growthStore, newId } from './store'
import { enqueueUpload } from './upload'
import { emptyJournal, nativeFileName, nativeFileStartedAt, parseNativeAudio, readRecordingJournal, writeRecordingJournal } from './recording-journal'
import type { Capture, NativeAudioFile, RecordingJournal } from './recording-journal'
import { readNativeAudio, RecordingAudioFailure } from './recording-audio'
import { readRecoveryManifest, recoverNativeFile, savedNativeFile } from './recording-recovery'

export type RecorderState = 'idle' | 'recording' | 'paused' | 'busy' | 'recovering'
export type SegmentMinutes = 5 | 10
export function getSegmentMinutes(): SegmentMinutes { return storage.get<SegmentMinutes>('growth.segmentMinutes', 5) === 10 ? 10 : 5 }
export function setSegmentMinutes(value: SegmentMinutes): void { storage.set('growth.segmentMinutes', value) }
export interface RecorderSnapshot {
  backgroundSupported?: boolean
  interrupted?: boolean
  state: RecorderState; ready: boolean; matterId: string | null; elapsedSec: number; segmentElapsedSec: number
  segmentLimitSec: number; segmentCount: number; permission: 'unknown' | 'granted' | 'denied'
  phase: 'initializing' | 'starting' | 'stopping' | 'reading' | 'saving' | null; error: string | null; notice: string | null
}
const INITIAL: RecorderSnapshot = { state: 'busy', ready: false, matterId: null, elapsedSec: 0, segmentElapsedSec: 0,
  segmentLimitSec: 300, segmentCount: 0, permission: 'unknown', phase: 'initializing', error: null, notice: null }
const defaults = {
  store: growthStore, invoke: invokeNative, listen: onNativeEvent, upload: enqueueUpload,
  readJournal: readRecordingJournal, writeJournal: writeRecordingJournal, readAudio: readNativeAudio,
  manifest: readRecoveryManifest, recover: recoverNativeFile,
  async isSaved(file: NativeAudioFile): Promise<boolean> {
    const segment = savedNativeFile(file)
    return Boolean(segment && (await growthStore.getAudio(segment.id))?.size === file.size)
  },
  isNative: () => getBridgeMode() === 'native', now: () => Date.now(), id: newId,
}
function noNativeRecording(error: unknown): boolean {
  // Exact failure text verified in this container's AudioRecorder.stop implementation.
  return error instanceof BridgeError && /^stopRecordAudio:\s*fail\s+not recording$/i.test(error.message.trim())
}
class CheckpointFailure extends Error {
  constructor() { super('录音恢复记录未能保存，请点保存重试；已存音频和原文件保留在本机') }
}
export class Recorder {
  private deps: typeof defaults
  private snapshot: RecorderSnapshot = { ...INITIAL }
  private journal: RecordingJournal = emptyJournal()
  private initialized = false
  private initializing: Promise<void> | null = null
  private operations: Promise<void> = Promise.resolve()
  private continuous = false
  private stopIntent: 'pause' | 'finish' | null = null
  private startRequested = false
  private startVersion = 0
  private ticker: ReturnType<typeof setInterval> | null = null
  private disposers: Array<() => void> = []
  private listeners = new Set<() => void>()
  constructor(deps = defaults) { this.deps = deps }
  subscribe = (listener: () => void) => { this.listeners.add(listener); return () => { this.listeners.delete(listener) } }
  getSnapshot = (): RecorderSnapshot => this.snapshot
  private emit(patch: Partial<RecorderSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch }; this.listeners.forEach(listener => listener())
  }
  private run(action: () => Promise<void>): Promise<void> {
    const next = this.operations.then(action).catch(error => {
      this.continuous = false; this.stopTicker()
      nativeLog.w('growth/recorder', 'recording operation incomplete', {
        phase: this.snapshot.phase, code: error instanceof BridgeError ? error.code : 'local-operation',
      })
      const message = error instanceof RecordingAudioFailure || error instanceof CheckpointFailure ? error.message
        : this.snapshot.phase === 'starting' ? '麦克风启动未确认，请保存重试后再开始'
        : this.snapshot.phase === 'stopping' ? '录音停止未确认，请点保存重试；原文件保留在本机'
        : this.snapshot.phase === 'reading' ? '录音文件读取未完成，请点保存重试；原文件保留在本机'
        : this.snapshot.phase === 'saving' ? '录音未能存入本机记录，请点保存重试；原文件保留在本机'
        : '录音恢复未完成，请点保存重试；请保留 App 和本机数据'
      this.sync('recovering', { phase: null, error: message })
    })
    this.operations = next
    return next
  }
  private async checkpoint(next: RecordingJournal, retainResultOnFailure = false): Promise<void> {
    // Never discard retry state in memory before the durable write succeeds.
    try { await this.deps.writeJournal(structuredClone(next)) }
    catch (error) {
      // A native stop receipt is consumed once. Keep it for an in-process retry
      // even if both storage systems are failing; the original file is untouched.
      if (retainResultOnFailure) this.journal = next
      throw new CheckpointFailure()
    }
    this.journal = next
  }
  private sync(state: RecorderState, patch: Partial<RecorderSnapshot> = {}): void {
    this.emit({ state, matterId: this.journal.matterId, elapsedSec: this.journal.elapsedSec,
      segmentElapsedSec: 0, segmentCount: this.journal.matterId ? this.deps.store.segmentsOf(this.journal.matterId).length : 0,
      phase: null, ...patch })
  }
  initialize(): Promise<void> {
    if (this.initialized) return Promise.resolve()
    if (this.initializing) return this.initializing
    this.initializing = this.run(async () => {
      this.emit({ state: 'busy', phase: 'initializing', error: null })
      await this.deps.store.init()
      const store = this.deps.store.getSnapshot()
      if (!store.ready || !store.storageOk) throw new Error('本机记录未能读取，请点重试读取后再录音')
      this.journal = await this.deps.readJournal()
      if (this.journal.matterId && !this.deps.store.getMatter(this.journal.matterId))
        throw new Error('上次录音的归属未能读取，请保留 App 并重试')
      // Do not subscribe writers while getStorage is still uncertain: a late
      // native event must never overwrite a checkpoint that we failed to read.
      await this.attachEvents()
      this.initialized = true
      this.emit({ ready: true })
      if (this.deps.isNative()) {
        await this.savePending()
        if (this.journal.capture || store.matters.length) await this.settleNative()
        const hint = this.journal.orphans[0]?.tempFilePath ?? store.segments.find(segment => segment.nativeFileName)?.localUrl
        for (const file of await this.deps.manifest(hint)) await this.rememberOrphan(file)
        await this.recoverOrphans()
        await this.reconcileClosed()
      }
      this.sync(this.journal.matterId ? 'paused' : 'idle', { error: null })
    }).finally(() => { this.initializing = null })
    return this.initializing
  }
  private async attachEvents(): Promise<void> {
    if (this.disposers.length) return
    // All-or-nothing: a partial set would make the next retry skip the rest.
    try { await this.installEvents() }
    catch (error) { this.disposers.forEach(dispose => dispose()); this.disposers = []; throw error }
  }
  private async installEvents(): Promise<void> {
    this.disposers.push(await this.deps.listen('recordAudioStop', payload => {
      const owner = this.journal.capture
      void this.run(async () => {
        const file = parseNativeAudio(payload)
        const accepted = await this.acceptFile(file, owner)
        // A duplicate or a late foreign callback must not pause a newer capture.
        if (!accepted) return
        if (this.continuous && !this.journal.capture && !this.journal.pending) await this.beginSegment()
        else if (this.stopIntent === 'finish') await this.closeRecording()
        else this.sync(this.journal.matterId ? 'paused' : 'idle')
      })
    }))
    this.disposers.push(await this.deps.listen('appHide', () => { void this.pause(true) }))
    const visible = () => {
      if (document.visibilityState === 'hidden') void this.pause(true)
      else if (this.snapshot.state === 'recovering') void this.retryRecovery()
    }
    document.addEventListener('visibilitychange', visible)
    this.disposers.push(() => document.removeEventListener('visibilitychange', visible))
  }
  start(): Promise<void> {
    if (this.startRequested || this.snapshot.state === 'recording' || this.snapshot.state === 'busy' && this.snapshot.ready) return Promise.resolve()
    this.startRequested = true
    const version = ++this.startVersion
    return (async () => {
      await this.initialize()
      if (!this.initialized || version !== this.startVersion) return
      this.continuous = true; this.stopIntent = null
      await this.run(async () => {
        this.emit({ state: 'busy', phase: 'starting', error: null, notice: null })
        await this.savePending()
        const permission = await this.deps.invoke('requestPermission', { scope: 'record' })
        if (!(permission.granted || permission.state === 'notRequired')) {
          this.continuous = false
          this.sync(this.journal.matterId ? 'paused' : 'idle', { permission: 'denied', error: '没有麦克风权限，无法开始录音' })
          return
        }
        this.emit({ permission: 'granted' })
        await this.settleNative(); await this.recoverOrphans(); await this.reconcileClosed()
        if (!this.continuous) return
        if (!this.journal.matterId) {
          const matter = await this.deps.store.createMatter('record')
          try { await this.checkpoint({ ...this.journal, matterId: matter.id, elapsedSec: 0, nextIndex: 0 }) }
          catch (error) {
            // No journal owns this empty row, so recovery could never close it.
            // Close it durably first, then drop it; a retry creates a fresh one.
            await this.deps.store.updateMatter(matter.id, { endedAt: this.deps.now() }).catch(() => undefined)
            await this.deps.store.deleteMatter(matter.id).catch(() => undefined)
            throw error
          }
        }
        await this.beginSegment()
      })
    })().finally(() => { this.startRequested = false })
  }
  resume(): Promise<void> { return this.start() }
  pause(background = false): Promise<void> {
    this.continuous = false; this.stopIntent = 'pause'; this.startVersion++
    if (!this.initialized || (!this.journal.capture && !this.journal.pending && !this.journal.matterId)) return Promise.resolve()
    return this.run(async () => {
      this.emit({ state: 'busy', phase: 'stopping' })
      await this.savePending(); await this.settleNative()
      await this.releaseKeepAwake()
      this.sync(this.journal.matterId ? 'paused' : 'idle', { error: null,
        notice: background && this.journal.matterId ? '切到后台已保存并暂停，回到 App 可以继续录音' : null })
    })
  }
  finish(): Promise<void> {
    this.continuous = false; this.stopIntent = 'finish'; this.startVersion++
    return (async () => {
      await this.initialize()
      if (!this.initialized) return
      await this.run(async () => {
        this.emit({ state: 'busy', phase: 'stopping' })
        await this.savePending(); await this.settleNative(); await this.recoverOrphans(); await this.closeRecording()
      })
    })()
  }
  retryRecovery(): Promise<void> {
    return (async () => {
      await this.initialize(); if (!this.initialized) return
      await this.run(async () => {
        await this.savePending(); await this.settleNative(); await this.recoverOrphans(); await this.reconcileClosed()
        this.sync(this.journal.matterId ? 'paused' : 'idle', { error: null })
      })
    })()
  }
  dismissError(): void { if (!this.journal.capture && !this.journal.pending) this.emit({ error: null }) }
  private async beginSegment(): Promise<void> {
    if (!this.continuous || this.journal.capture || this.journal.pending || !this.journal.matterId) return
    const capture: Capture = { id: this.deps.id(), matterId: this.journal.matterId, index: this.journal.nextIndex,
      startedAt: this.deps.now(), acknowledgedAt: null, elapsedBefore: this.journal.elapsedSec }
    await this.checkpoint({ ...this.journal, capture })
    this.emit({ state: 'busy', phase: 'starting' })
    const limit = getSegmentMinutes() * 60
    await this.deps.invoke('recordAudio', { duration: limit * 1000, format: 'aac', sampleRate: 16000, numberOfChannels: 1, encodeBitRate: 96000 })
    const acknowledged = { ...capture, acknowledgedAt: this.deps.now() }
    await this.checkpoint({ ...this.journal, capture: acknowledged })
    this.sync(this.continuous ? 'recording' : 'busy', { phase: this.continuous ? null : 'stopping', segmentLimitSec: limit, error: null })
    await this.deps.invoke('setKeepScreenOn', { keepScreenOn: true }).catch(() => undefined)
    this.startTicker(acknowledged, limit)
  }
  private owns(file: NativeAudioFile, capture: Capture): boolean {
    const time = nativeFileStartedAt(file.tempFilePath)
    // The native implementation generates this filename between start() and its ack.
    // Legacy files with no journal are never assigned by their timestamp.
    return time >= capture.startedAt && time <= (capture.acknowledgedAt ?? this.deps.now())
  }
  private async stopFile(): Promise<NativeAudioFile | null> {
    try { return parseNativeAudio(await this.deps.invoke('stopRecordAudio')) }
    catch (error) { if (noNativeRecording(error)) return null; throw error }
  }
  private async settleNative(): Promise<void> {
    this.stopTicker()
    const capture = this.journal.capture
    let file = await this.stopFile()
    if (file) {
      await this.acceptFile(file, capture)
      // Native may first return an old pending result. Drain it before declaring
      // the current capture absent or allowing another native start.
      if (capture && this.journal.capture?.id === capture.id) {
        file = await this.stopFile()
        if (file) await this.acceptFile(file, capture)
        if (file && this.journal.capture?.id === capture.id) throw new Error('native-stop-unconfirmed')
      }
    }
    if (!file && capture && this.journal.capture?.id === capture.id) {
      const committed = this.deps.store.getSnapshot().segments.find(row => row.id === capture.id && row.matterId === capture.matterId)
      if (committed) {
        const receipt = parseNativeAudio({ tempFilePath: committed.localUrl, duration: committed.durationSec, size: committed.sizeBytes })
        if (await this.deps.isSaved(receipt)) {
          await this.checkpoint({ ...this.journal, pending: { capture, segment: committed, file: receipt } }, true)
          await this.savePending()
          return
        }
      }
      // The old native process may have died before returning its file. Preserve
      // ownership for later recovery, and never fabricate an end time or a segment.
      await this.checkpoint({ ...this.journal, capture: null,
        nextIndex: Math.max(this.journal.nextIndex, capture.index + 1),
        unresolved: this.journal.unresolved.some(row => row.id === capture.id) ? this.journal.unresolved : [...this.journal.unresolved, capture] })
      this.emit({ notice: '上次采集中断；已保存的分段仍在，未确认尾段保留待恢复' })
    }
  }
  private async acceptFile(file: NativeAudioFile, owner: Capture | null): Promise<boolean> {
    if (this.journal.pending && nativeFileName(this.journal.pending.file.tempFilePath) === nativeFileName(file.tempFilePath)) {
      await this.savePending(); return true
    }
    if (await this.deps.isSaved(file)) return false
    if (!owner || owner.id !== this.journal.capture?.id || !this.owns(file, owner)) {
      await this.rememberOrphan(file)
      return false
    }
    this.stopTicker()
    const pending = { capture: owner, file, segment: { id: owner.id, matterId: owner.matterId,
      index: owner.index, capturedAt: nativeFileStartedAt(file.tempFilePath), durationSec: file.duration,
      sizeBytes: file.size, localUrl: file.tempFilePath, nativeFileName: nativeFileName(file.tempFilePath), stage: 'recorded' as const, attempts: 0 } }
    try { await this.checkpoint({ ...this.journal, pending }, true) }
    catch { /* Save the consumed receipt through healthy IndexedDB as a second durable path. */ }
    await this.savePending()
    return true
  }
  private async savePending(): Promise<void> {
    const pending = this.journal.pending
    if (!pending) return
    this.emit({ state: 'busy', phase: 'saving' })
    try { await this.checkpoint(this.journal) }
    catch { nativeLog.w('growth/recorder', 'checkpoint write incomplete; trying local audio commit', { stage: 'checkpoint' }) }
    const existing = this.deps.store.getSnapshot().segments.find(segment => segment.id === pending.segment.id)
    if (!existing || !(await this.deps.isSaved(pending.file))) {
      this.emit({ phase: 'reading' })
      const blob = await this.deps.readAudio(pending.file)
      this.emit({ phase: 'saving' })
      await this.deps.store.commitCapturedAudio(pending.segment, blob)
    }
    await this.checkpoint({ ...this.journal, elapsedSec: pending.capture.elapsedBefore + pending.segment.durationSec,
      nextIndex: Math.max(this.journal.nextIndex, pending.capture.index + 1), capture: null, pending: null })
    this.deps.upload(pending.segment.id)
    this.sync('paused', { error: null })
  }
  private async rememberOrphan(file: NativeAudioFile): Promise<void> {
    if (await this.deps.isSaved(file)) return
    if (this.journal.orphans.some(row => nativeFileName(row.tempFilePath) === nativeFileName(file.tempFilePath))) return
    try { await this.checkpoint({ ...this.journal, orphans: [...this.journal.orphans, file] }, true) }
    catch (error) {
      // A legacy result has no durable capture ID to rediscover it by. Preserve
      // its file and metadata through IndexedDB even if native storage fails.
      await this.deps.recover(file)
      throw error
    }
  }
  private async recoverOrphans(): Promise<void> {
    for (const file of [...this.journal.orphans]) {
      await this.deps.recover(file)
      await this.checkpoint({ ...this.journal,
        orphans: this.journal.orphans.filter(row => nativeFileName(row.tempFilePath) !== nativeFileName(file.tempFilePath)) })
    }
  }
  private async closeRecording(): Promise<void> {
    if (this.journal.capture || this.journal.pending) throw new Error('录音尚未保存完成，请点保存重试')
    if (this.journal.matterId) await this.deps.store.updateMatter(this.journal.matterId, { endedAt: this.deps.now(),captureComplete:true })
    await this.checkpoint({ ...this.journal, matterId: null, elapsedSec: 0, nextIndex: 0 })
    await this.releaseKeepAwake()
    this.stopIntent = null
    this.sync('idle', { error: null })
  }
  private async reconcileClosed(): Promise<void> {
    if (this.journal.matterId && !this.journal.capture && !this.journal.pending
      && this.deps.store.getMatter(this.journal.matterId)?.endedAt != null) {
      await this.checkpoint({ ...this.journal, matterId: null, elapsedSec: 0, nextIndex: 0 })
    }
  }
  private startTicker(capture: Capture, limit: number): void {
    this.stopTicker()
    this.ticker = setInterval(() => {
      if (this.journal.capture?.id !== capture.id) return
      const seconds = Math.max(0, Math.floor((this.deps.now() - capture.startedAt) / 1000))
      this.emit({ segmentElapsedSec: seconds, elapsedSec: capture.elapsedBefore + seconds })
      // Also collect the native pending result if an automatic event was lost.
      if (seconds >= limit) {
        this.stopTicker()
        void this.run(async () => {
          if (this.journal.capture?.id !== capture.id) return
          await this.settleNative()
          if (this.continuous) await this.beginSegment()
          else this.sync(this.journal.matterId ? 'paused' : 'idle')
        })
      }
    }, 1000)
  }
  private stopTicker(): void { if (this.ticker !== null) clearInterval(this.ticker); this.ticker = null }
  private async releaseKeepAwake(): Promise<void> { await this.deps.invoke('setKeepScreenOn', { keepScreenOn: false }).catch(() => undefined) }
  dispose(): void { this.stopTicker(); this.disposers.forEach(dispose => dispose()); this.disposers = [] }
}
export const recorder = new Recorder()
export function useRecorder(): RecorderSnapshot { return useSyncExternalStore(recorder.subscribe, recorder.getSnapshot, () => INITIAL) }
