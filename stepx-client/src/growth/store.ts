/* =============================================================================
 * 记录仓库：内存状态 + IndexedDB 持久化 + 订阅
 *
 * 页面通过 `useGrowth()` 订阅；写入一律走这里的方法，方法内部先落 IndexedDB 再更新内存，
 * 所以要「杀进程后还能接着传」的分片，必须经由 addSegment / updateSegment 落库。
 * ========================================================================== */

import { useSyncExternalStore } from 'react'

import {
  STORE_BLOBS,
  STORE_MATTERS,
  STORE_SEGMENTS,
  STORE_PROCESSING,
  idbDelete,
  idbGet,
  idbGetAll,
  idbPut,
  idbCommitAudio,
  idbDeleteMatter,
  idbPrepareMatterDeletion,
  idbUpdate,
} from './idb'
import type { Matter, Segment } from './types'
import { RootRecordingClient } from './root-recording'

export interface GrowthSnapshot {
  /** 本地数据是否已载入完成 */
  ready: boolean
  /** 本地存储是否可用（不可用时页面要明确说明，不能假装记录已保存） */
  storageOk: boolean
  /** 记录，按开始时间倒序 */
  matters: Matter[]
  /** 全部分片，按录制时间正序 */
  segments: Segment[]
}

const EMPTY: GrowthSnapshot = { ready: false, storageOk: true, matters: [], segments: [] }

/** 生成 id；老内核没有 randomUUID 时退回时间戳 + 随机串 */
export function newId(): string {
  const uuid = globalThis.crypto?.randomUUID?.()
  if (uuid) return uuid
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`
}

class GrowthStore {
  private matterOperations = new Map<string, Promise<unknown>>()
  private mutateMatter<T>(id: string, action: () => Promise<T>): Promise<T> {
    const prior = this.matterOperations.get(id) ?? Promise.resolve()
    const next = prior.catch(() => undefined).then(action)
    this.matterOperations.set(id,next)
    return next.finally(() => { if (this.matterOperations.get(id) === next) this.matterOperations.delete(id) })
  }
  private matters = new Map<string, Matter>()
  private segments = new Map<string, Segment>()
  private snapshot: GrowthSnapshot = EMPTY
  private listeners = new Set<() => void>()
  private initPromise: Promise<void> | null = null

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener)
    return () => {
      this.listeners.delete(listener)
    }
  }

  getSnapshot = (): GrowthSnapshot => this.snapshot

  private emit(): void {
    this.snapshot = {
      ready: this.snapshot.ready,
      storageOk: this.snapshot.storageOk,
      matters: [...this.matters.values()].sort((a, b) => b.startedAt - a.startedAt),
      segments: [...this.segments.values()].sort((a, b) => a.capturedAt - b.capturedAt),
    }
    this.listeners.forEach((listener) => listener())
  }

  /** 载入本地数据。应用启动时调用一次，重复调用共用同一个 Promise。 */
  init(): Promise<void> {
    if (this.initPromise) return this.initPromise
    this.initPromise = (async () => {
      try {
        const [matters, segments] = await Promise.all([
          idbGetAll<Matter>(STORE_MATTERS),
          idbGetAll<Segment>(STORE_SEGMENTS),
        ])
        this.matters = new Map(matters.map((m) => [m.id, m]))
        this.segments = new Map(segments.map((s) => [s.id, s]))
        // 上次没传完的分片把 uploading 归位成 recorded，否则会永远卡在"上传中"
        for (const segment of this.segments.values()) {
          if (segment.stage === 'uploading') {
            segment.stage = 'recorded'
            await idbPut(STORE_SEGMENTS, segment)
          }
        }
        // An open record does not prove capture is active or stopped. The recorder
        // reconciles its durable checkpoint with the native recorder before closing it.
        this.snapshot = { ready: true, storageOk: true, matters: [], segments: [] }
        this.emit()
      } catch {
        this.snapshot = { ready: true, storageOk: false, matters: [], segments: [] }
        this.emit()
        this.initPromise = null
      }
    })()
    return this.initPromise
  }

  /* ------------------------------- 读取 ------------------------------- */

  getMatter(id: string): Matter | undefined {
    return this.matters.get(id)
  }

  segmentsOf(matterId: string): Segment[] {
    return this.snapshot.segments.filter((s) => s.matterId === matterId)
  }

  /** 最近一件还没结束的事（用于"接着录"） */
  activeMatter(): Matter | undefined {
    return [...this.matters.values()]
      .filter((m) => m.endedAt === null)
      .sort((a, b) => b.startedAt - a.startedAt)[0]
  }

  /** 今天（本地时区）开始的事 */
  mattersOn(dayStart: number, dayEnd: number): Matter[] {
    return this.snapshot.matters.filter((m) => m.startedAt >= dayStart && m.startedAt < dayEnd)
  }

  segmentsFor(matterId: string): Segment[] {
    return this.snapshot.segments.filter((s) => s.matterId === matterId)
  }

  /* ------------------------------- 写入 ------------------------------- */

  private async requireReady(): Promise<void> {
    await this.init()
    if (!this.snapshot.ready || !this.snapshot.storageOk) throw new Error('本机记录尚未读取，请重试')
  }

  /**
   * 新建一次采集。
   *
   * **先落库、成功了再进内存，而且不吞错误**：调用方要靠它区分"记下来了"和"没记住"。
   * 反过来的写法（先更内存、把写库错误吞掉）会让界面上出现一条重启后就消失的采集，
   * 后面的分段也就失去了归属。
   */
  async createMatter(origin: Matter['origin'] = 'record'): Promise<Matter> {
    await this.requireReady()
    const matter: Matter = {
      id: newId(),
      startedAt: Date.now(),
      endedAt: null,
      origin,
      title: null,
      progress: null,
      personalActionsEnabled: true,
      ...(origin==='record'?{captureComplete:false}:{}),
    }
    await idbPut(STORE_MATTERS, matter)
    this.matters.set(matter.id, matter)
    this.emit()
    return matter
  }

  /**
   * 记录一次采集的收口时间。
   *
   * 先提交持久化，再更新内存；失败必须交给录音控制器显示并保留重试。
   */
  async updateMatter(id: string, patch: Partial<Matter>): Promise<void> {
    await this.requireReady()
    await this.mutateMatter(id,() => this.updateMatterNow(id,patch))
  }
  private async updateMatterNow(id: string, patch: Partial<Matter>, starting = false): Promise<void> {
    const next = await idbUpdate<Matter>(STORE_MATTERS, id, existing => {
      if (!existing) throw new Error('录音已删除')
      if ((starting || patch.rootUploadClient) && existing.rootDeletionPending) throw new Error('录音正在删除，请先完成删除后再开始新录音')
      return { ...existing, ...patch }
    })
    this.matters.set(id, next)
    this.emit()
  }

  async authorizeRootStart<T>(id: string, client: string | undefined, start: () => Promise<T>): Promise<T> {
    await this.requireReady()
    return this.mutateMatter(id,async () => {
      await this.updateMatterNow(id,client ? {rootUploadClient:client} : {},true)
      return start()
    })
  }

  /**
   * 落下一段采集到的音频元数据。
   *
   * 同样是**先落库、成功了再进内存，且不吞错误**——采集与导入都要靠它判断这段材料到底存住没有。
   * 同一 id 重复写入由 IndexedDB 的 put 去重（keyPath = id），不会插出两行。
   */
  async addSegment(segment: Segment): Promise<void> {
    await this.requireReady()
    await idbPut(STORE_SEGMENTS, segment)
    this.segments.set(segment.id, segment)
    this.emit()
  }

  /** Audio and metadata become visible together; native checkpoint clears afterward. */
  async commitCapturedAudio(segment: Segment, blob: Blob): Promise<void> {
    await this.requireReady()
    const result = await idbCommitAudio(segment, blob)
    if (result === 'deleted' || result === 'missing') throw new Error('录音归属尚未读取或已删除')
    this.segments.set(segment.id, segment)
    this.emit()
  }

  /** A recovered file is kept separately; its old recording owner is never guessed. */
  async commitRecoveredAudio(matter: Matter, segment: Segment, blob: Blob): Promise<void> {
    await this.requireReady()
    if (await idbCommitAudio(segment, blob, undefined, matter) === 'deleted') return
    this.matters.set(matter.id, matter)
    this.segments.set(segment.id, segment)
    this.emit()
  }

  /** 更新一段的状态；以持久化成功为准，失败交给调用方恢复。 */
  async updateSegment(id: string, patch: Partial<Segment>): Promise<void> {
    await this.requireReady()
    const current = this.segments.get(id)
    if (!current) return
    const next = { ...current, ...patch }
    await idbPut(STORE_SEGMENTS, next)
    this.segments.set(id, next)
    this.emit()
  }

  async deleteMatter(id: string): Promise<void> {
    await this.requireReady()
    await this.mutateMatter(id,async () => {
      const durable = await idbPrepareMatterDeletion(id)
      if (durable?.rootUploadClient || this.segmentsOf(id).some(row => row.rootUpload))
        await new RootRecordingClient().revokeMatter(id)
      await idbDeleteMatter(id)
      const segments = this.segmentsOf(id)
      for (const segment of segments) this.segments.delete(segment.id)
      this.matters.delete(id)
      this.emit()
    })
  }

  async wasMatterDeleted(id: string): Promise<boolean> {
    await this.requireReady()
    return !!await idbGet(STORE_PROCESSING, '__deleted_matter__:' + id)
  }

  async commitRootAudio(segment: Segment, blob: Blob, sha256: string): Promise<'saved' | 'duplicate' | 'deleted' | 'missing'> {
    await this.requireReady()
    return this.mutateMatter(segment.matterId,async () => {
      const result = await idbCommitAudio(segment, blob, { id: '__root_receipt__:' + segment.id, sha256 })
      if (result === 'saved') { this.segments.set(segment.id, segment); this.emit() }
      return result
    })
  }

  /* ----------------------------- 音频本体 ----------------------------- */

  async saveAudio(id: string, blob: Blob): Promise<void> {
    await this.requireReady()
    await idbPut(STORE_BLOBS, { id, blob })
  }

  async getAudio(id: string): Promise<Blob | undefined> {
    const row = await idbGet<{ id: string; blob: Blob }>(STORE_BLOBS, id).catch(() => undefined)
    return row?.blob
  }

  async dropAudio(id: string): Promise<void> {
    await idbDelete(STORE_BLOBS, id).catch(() => undefined)
  }

  /**
   * 本机材料占用（设置页展示用）。
   *
   * 这里**不提供清理入口**：云端还没接好之前，手机上的这份就是唯一的材料，
   * 清掉等于直接把录音丢了——要腾空间得等材料真正安全存到云端之后再说。
   */
  async audioUsage(): Promise<{ count: number; bytes: number }> {
    const rows = await idbGetAll<{ id: string; blob: Blob }>(STORE_BLOBS).catch(() => [])
    return {
      count: rows.length,
      bytes: rows.reduce((sum, row) => sum + (row.blob?.size ?? 0), 0),
    }
  }
}

export const growthStore = new GrowthStore()

/** 订阅仓库快照。首次调用会触发本地数据载入。 */
export function useGrowth(): GrowthSnapshot {
  const snapshot = useSyncExternalStore(growthStore.subscribe, growthStore.getSnapshot, () => EMPTY)
  return snapshot
}
