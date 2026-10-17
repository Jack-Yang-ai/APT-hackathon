import { useSyncExternalStore } from 'react'
import { growthConnection } from './connection'
import { growthStore } from './store'
import { growthProcessing } from './processing'
import { STORE_RECORDING_MEMORY, sourceTransaction } from './idb'
import { fingerprint } from './source-scope'
import { projectRecordingMemory, canonicalRecording } from './recording-memory-data'
import type { MemoryRow, RecordingSource } from './recording-memory-data'

interface Meta { id: '__identity__'; namespace: string }
interface Lease { id: '__lease__'; owner: string; until: number }
export interface RecordingMemorySnapshot {
  ready: boolean; running: boolean; sources: number; pending: number; acknowledged: number; unavailable: number
  error: string | null; lastSuccess: number | null
}
const EMPTY: RecordingMemorySnapshot = { ready: false, running: false, sources: 0, pending: 0,
  acknowledged: 0, unavailable: 0, error: null, lastSuccess: null }
const UUID = /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/
const defaults = {
  connection: growthConnection,
  transact: <T>(apply: Parameters<typeof sourceTransaction<T>>[1]) =>
    sourceTransaction('readwrite', apply, [STORE_RECORDING_MEMORY]),
}
/** A durable read projection, never a writer to recording or transcript data. */
export class RecordingMemorySync {
  private snapshot: RecordingMemorySnapshot = EMPTY
  private listeners = new Set<() => void>()
  private busy = false
  private owner = crypto.randomUUID()
  private timer: ReturnType<typeof setInterval> | null = null
  private disposers: Array<() => void> = []
  constructor(private readonly deps = defaults) {}
  subscribe = (listener: () => void) => { this.listeners.add(listener); return () => { this.listeners.delete(listener) } }
  getSnapshot = (): RecordingMemorySnapshot => this.snapshot
  private emit(patch: Partial<RecordingMemorySnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch }; this.listeners.forEach(listener => listener())
  }
  init(): void {
    if (this.timer) return
    this.disposers = [this.deps.connection.subscribe(() => { void this.kick() }),
      growthStore.subscribe(() => { void this.kick() }), growthProcessing.subscribe(() => { void this.kick() })]
    this.timer = setInterval(() => { void this.kick() }, 30000)
    void this.kick()
  }
  dispose(): void {
    if (this.timer) clearInterval(this.timer)
    this.timer = null; this.disposers.forEach(dispose => dispose()); this.disposers = []
  }
  private counts(rows: MemoryRow[]): Pick<RecordingMemorySnapshot, 'ready' | 'sources' | 'acknowledged' | 'pending'> {
    rows=rows.filter(row=>!row.delegated)
    return { ready: true, sources: rows.filter(row => !row.record.deleted).length,
      acknowledged: rows.filter(row => !row.record.deleted && row.acknowledged === row.record.revision).length,
      pending: rows.filter(row => row.acknowledged !== row.record.revision).length }
  }
  private async prepare(): Promise<{ namespace: string; records: MemoryRow[] } | null> {
    const result = await this.deps.transact((source, put) => {
      const rows = source.rows[STORE_RECORDING_MEMORY], now = Date.now()
      const lease = rows.find(row => (row as Lease).id === '__lease__') as Lease | undefined
      if (lease && lease.owner !== this.owner && lease.until > now) return null
      put(STORE_RECORDING_MEMORY, { id: '__lease__', owner: this.owner, until: now + 60000 })
      let meta = rows.find(row => (row as Meta).id === '__identity__') as Meta | undefined
      if (!meta) { meta = { id: '__identity__', namespace: crypto.randomUUID().toLowerCase() }; put(STORE_RECORDING_MEMORY, meta) }
      if (!UUID.test(meta.namespace)) throw new Error('本机来源身份无法读取，请保留数据后重试')
      const existing = rows.filter(row => (row as MemoryRow).record) as MemoryRow[]
      const delegated=new Set(source.jobs.filter(row=>row.id.startsWith('__background__:')).map(row=>row.recordingId))
      let unavailable = 0
      const desired = projectRecordingMemory({...source,matters:source.matters.filter(row=>!delegated.has(row.id))}, () => { unavailable++ }), wanted = new Set(desired.map(row => row.id))
      const updated = new Map(existing.map(row => [row.id, row]))
      const revise = (row: MemoryRow, record: Omit<RecordingSource, 'id' | 'revision' | 'updated'>) => {
        if (!Number.isSafeInteger(row.record.revision) || row.record.revision >= Number.MAX_SAFE_INTEGER) throw new Error('来源版本无法递增')
        const next = { ...row, record: { ...record, id: row.record.id, revision: row.record.revision + 1,
          updated: new Date(Math.max(now, Date.parse(record.created))).toISOString() } }
        put(STORE_RECORDING_MEMORY, next); updated.set(row.id, next)
      }
      for (const row of existing) if (!delegated.has(row.recordingId)&&!wanted.has(row.id) && !row.record.deleted) revise(row,
        { ...row.record, title: '已移出记忆', text: '', deleted: true })
      for (const value of desired) {
        const prior = updated.get(value.id)
        if (!prior) {
          const row: MemoryRow = { id: value.id, recordingId: value.recordingId, jobId: value.jobId, acknowledged: 0,
            record: { id: 'apt_recording_' + crypto.randomUUID().toLowerCase(), revision: 1, created: value.created,
              updated: new Date(Math.max(now, Date.parse(value.created))).toISOString(),
              title: value.title, text: value.text, partial: value.partial, deleted: false } }
          put(STORE_RECORDING_MEMORY, row); updated.set(row.id, row)
        } else if (prior.record.deleted || prior.record.created !== value.created || prior.record.title !== value.title
          || prior.record.text !== value.text || prior.record.partial !== value.partial) revise(prior,
            { created: value.created, title: value.title, text: value.text, partial: value.partial, deleted: false })
      }
      const current = [...updated.values()]
      const status = { ...this.counts(current), unavailable }
      const pending = current.filter(row => !delegated.has(row.recordingId)&&row.acknowledged !== row.record.revision)
      if (!pending.length) return { namespace: meta.namespace, records: [], status }
      // Each current transcript is indivisible. Old tombstones can drain in separate bounded pages.
      const first = pending.find(row => row.record.deleted) ?? pending[0]
      let group = pending.filter(row => row.jobId === first.jobId)
      if (group.every(row => row.record.deleted)) {
        const liveJobs = new Set(pending.filter(row => !row.record.deleted).map(row => row.jobId))
        group = pending.filter(row => row.record.deleted && !liveJobs.has(row.jobId))
      }
      const groupBytes = group.reduce((sum, row) => sum + new TextEncoder().encode(JSON.stringify(row.record)).length + 1, 200)
      if (group.length > 2000 || groupBytes > 7 * 1024 * 1024) {
        group = group.filter(row => row.record.deleted).slice(0, 1000)
        if (!group.length) throw new Error('这份转写超出同步容量，原材料仍在本机')
      }
      const records: MemoryRow[] = []
      let size = 200
      for (const row of group) {
        const length = new TextEncoder().encode(JSON.stringify(row.record)).length + 1
        if (size + length > 7 * 1024 * 1024) {
          if (group.some(value => !value.record.deleted)) throw new Error('这份转写超出同步容量，原材料仍在本机')
          break
        }
        size += length; records.push(structuredClone(row))
      }
      if (!records.length || records.length > 2000) throw new Error('来源同步批次超出范围')
      return { namespace: meta.namespace, records, status }
    })
    if (result) this.emit(result.status)
    return result
  }
  async kick(): Promise<void> {
    if (this.busy) return
    this.busy = true; this.emit({ running: true, error: null })
    try {
      for (let batch = 0; batch < 20; batch++) {
        const pending = await this.prepare()
        if (!pending || !pending.records.length || !this.deps.connection.isReady()) break
        const hashes = await Promise.all(pending.records.map(row =>
          fingerprint(JSON.stringify(canonicalRecording(row.record, pending.namespace)))))
        const receipt = await this.deps.connection.request<{ schema: string; accepted: Array<{ id: string; revision: number; fingerprint: string }>; stale: unknown[]; conflicts: unknown[] }>(
          '/recording-memory/sync', { schema: 'apt.recording-memory.batch/1', device_id: pending.namespace,
            records: pending.records.map(row => row.record) }, 15000)
        if (receipt.schema !== 'apt.recording-memory.receipt/1' || !Array.isArray(receipt.accepted)
          || !Array.isArray(receipt.stale) || receipt.stale.length || !Array.isArray(receipt.conflicts) || receipt.conflicts.length
          || receipt.accepted.length !== pending.records.length
          || new Set(receipt.accepted.map(row => row.id)).size !== pending.records.length
          || !pending.records.every((row, index) => receipt.accepted.some(value => value.id === row.record.id
            && value.revision === row.record.revision && value.fingerprint === hashes[index]))) throw new Error('来源回执不一致，尚未确认同步')
        await this.deps.transact((source, put) => {
          const rows = source.rows[STORE_RECORDING_MEMORY], lease = rows.find(row => (row as Lease).id === '__lease__') as Lease | undefined
          if (lease?.owner !== this.owner || lease.until <= Date.now()) throw new Error('同步已由其它窗口接续，请重试')
          for (const sent of pending.records) {
            const current = rows.find(row => (row as MemoryRow).id === sent.id) as MemoryRow | undefined
            if (current && JSON.stringify(current.record) === JSON.stringify(sent.record))
              put(STORE_RECORDING_MEMORY, { ...current, acknowledged: sent.record.revision })
          }
        })
        this.emit({ lastSuccess: Date.now() })
      }
    } catch (error) {
      this.emit({ error: error instanceof Error ? error.message : '录音记忆尚未同步，可重试；原材料仍在本机' })
    } finally {
      const status = await this.deps.transact((source, put) => {
        const row = source.rows[STORE_RECORDING_MEMORY].find(value => (value as Lease).id === '__lease__') as Lease | undefined
        if (row?.owner === this.owner) put(STORE_RECORDING_MEMORY, { ...row, until: 0 })
        return this.counts(source.rows[STORE_RECORDING_MEMORY].filter(value => (value as MemoryRow).record) as MemoryRow[])
      }).catch(() => undefined)
      if (status) this.emit(status)
      this.busy = false; this.emit({ running: false })
    }
  }
}
export const recordingMemory = new RecordingMemorySync()
export const useRecordingMemory = () => useSyncExternalStore(recordingMemory.subscribe, recordingMemory.getSnapshot, () => EMPTY)
