import { useSyncExternalStore } from 'react'
import { initBridge, invokeNative } from '@/shared/bridge'
import type { Segment } from './types'
import type { ProcessingJob } from './processing-data'

export type BackGlyph = 'mic'
export interface BackStatus {
  version: 1; runtime: string; epoch: string; updatedAt: number
  hardware: { supported: true; logicalWidth: 17; logicalHeight: 23; state: number; brightness: number; rotation: number; enabled: boolean }
  mode: 'off' | 'recording' | 'test'; overrideActive: boolean; glyph: BackGlyph | 'apt' | 'done'; minutes: number
  lastCommand: { id?: string; ok?: boolean }; error: string | null
}
export interface BackSnapshot { ready: boolean; native: boolean; busy: boolean; canStop: boolean; status: BackStatus | null; error: string | null; notice: string | null }
const INITIAL: BackSnapshot = { ready: false, native: false, busy: false, canStop: false, status: null, error: null, notice: null }
const KEY = 'growth.neo.back.command.v1'
const uuid = (v: unknown): v is string => typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(v)
/** UI preview of the same fixed microphone/minute frame used on Neo. */
export function backScreenPixels(minutes: number): boolean[] {
  if (!Number.isSafeInteger(minutes) || minutes < 0 || minutes > 720) throw new Error('背屏时长无法核验')
  const pixels = Array<boolean>(391).fill(false)
  const microphone = ['0011100', '0111110', '0111110', '0111110', '0111110', '0011100', '1000001', '0100010', '0011100', '0001000', '0011100']
  for (let row = 0; row < microphone.length; row++) for (let col = 0; col < 7; col++)
    if (microphone[row][col] === '1') pixels[(row + 2) * 17 + col + 5] = true
  const numbers = ['111101101101111', '010110010010111', '111001111100111', '111001111001111', '101101111001001',
    '111100111001111', '111100111101111', '111001001001001', '111101111101111', '111101111001111']
  const text = String(minutes), left = Math.floor((17 - (text.length * 4 - 1)) / 2)
  for (let digit = 0; digit < text.length; digit++) for (let row = 0; row < 5; row++) for (let col = 0; col < 3; col++)
    if (numbers[Number(text[digit])][row * 3 + col] === '1') pixels[(17 + row) * 17 + left + digit * 4 + col] = true
  return pixels
}
/** Count persisted upload acknowledgements, never preallocated keys or semantic success. */
export function backScreenUploads(segments: readonly Segment[], jobs: readonly ProcessingJob[]): { saved: number; uploaded: number; pending: number } {
  let uploaded = 0, pending = 0
  const byId = new Map(jobs.map(job => [job.id, job]))
  for (const segment of segments) {
    const job = byId.get(segment.id)
    if (job?.recordingId === segment.matterId && job.index === segment.index && job.uploaded === true && job.remoteKey) uploaded++
    else if (segment.cloudEligible !== false) pending++
  }
  return { saved: segments.length, uploaded, pending }
}
export function parseBackStatus(value: unknown): BackStatus {
  const s = value as BackStatus, h = s?.hardware
  // Old services expose their last logo/check even while off. Read them for STOP;
  // neither the UI preview nor the command channel can display those patterns.
  const legacyGlyph = (s?.runtime === '1.0.0' || s?.runtime === '1.0.1') && ['apt', 'done'].includes(s.glyph)
  if (!s || s.version !== 1 || !uuid(s.epoch) || !Number.isSafeInteger(s.updatedAt) || !h || h.supported !== true
    || h.logicalWidth !== 17 || h.logicalHeight !== 23 || !Number.isInteger(h.state)
    || !Number.isInteger(h.brightness) || h.brightness < 0 || h.brightness > 255 || !Number.isInteger(h.rotation)
    || typeof h.enabled !== 'boolean' || !['off', 'recording', 'test'].includes(s.mode)
    || typeof s.overrideActive !== 'boolean' || s.glyph !== 'mic' && !legacyGlyph
    || !Number.isSafeInteger(s.minutes) || s.minutes < 0 || s.minutes > 720 || !s.lastCommand || typeof s.lastCommand !== 'object'
    || typeof s.runtime !== 'string' || s.runtime.length > 30
    || !(s.lastCommand.id === undefined && s.lastCommand.ok === undefined
      || (uuid(s.lastCommand.id) || s.lastCommand.id === 'invalid') && typeof s.lastCommand.ok === 'boolean')
    || !(s.error === null || typeof s.error === 'string' && s.error.length < 200)) throw new Error('背屏状态无法核验，请重试')
  if (Date.now() - s.updatedAt > 8000 || Date.now() - s.updatedAt < -5000) throw new Error('背屏服务离线，请恢复手机服务后重试')
  return structuredClone(s)
}
export class BackScreenStore {
  private snapshot = { ...INITIAL }
  private listeners = new Set<() => void>()
  private host: string | null = null
  private initializing: Promise<void> | null = null
  private operation = 0
  private issuedAt = 0
  private commandFailure: string | null = null
  private refreshId = 0
  private stopStatus: BackStatus | null = null
  subscribe = (fn: () => void) => { this.listeners.add(fn); return () => { this.listeners.delete(fn) } }
  getSnapshot = (): BackSnapshot => this.snapshot
  private emit(patch: Partial<BackSnapshot>): void {
    if (patch.status) { this.stopStatus = patch.status; patch.canStop = true }
    if (patch.native === false) { this.stopStatus = null; patch.canStop = false }
    this.snapshot = { ...this.snapshot, ...patch }; this.listeners.forEach(fn => fn())
  }
  async refresh(): Promise<void> {
    const request = ++this.refreshId, operation = this.operation
    const current = () => request === this.refreshId && operation === this.operation
    try {
      const native = await initBridge() === 'native'
      if (!current()) return
      this.emit({ native })
      if (!native) { this.emit({ ready: true, status: null, error: null }); return }
      const status = await this.read()
      if (!current()) return
      if (this.snapshot.status?.epoch === status.epoch && this.snapshot.status.updatedAt > status.updatedAt) return
      this.emit({ ready: true, status, error: status.error ?? this.commandFailure })
    } catch (error) { if (current()) this.emit({ ready: true, status: null, error: error instanceof Error ? error.message : '背屏暂时不可用' }) }
  }
  initialize(): Promise<void> {
    if (this.initializing) return this.initializing
    this.initializing = this.refresh().finally(() => { this.initializing = null }); return this.initializing
  }
  private async read(): Promise<BackStatus> {
    for (const host of this.host ? [this.host] : ['https://appassets.t-stepos.com', 'https://appassets.stepaos.com']) {
      const abort = new AbortController(); let timer: ReturnType<typeof setTimeout> | undefined
      try {
        const result = await Promise.race([
          (async () => {
            const response = await fetch(`${host}/media/apt-neo-back-status-v1.json`, { cache: 'no-store', redirect: 'error', signal: abort.signal })
            if (response.status === 404) return null
            if (!response.ok) throw new Error('背屏服务未连接，请重试')
            const text = await response.text()
            if (text.length > 8192) throw new Error('背屏状态无法读取')
            return parseBackStatus(JSON.parse(text))
          })(),
          new Promise<never>((_, reject) => { timer = setTimeout(() => { abort.abort(); reject(new Error('背屏读取超时，请重试')) }, 5000) }),
        ])
        if (!result) continue
        this.host = host; return result
      } finally { clearTimeout(timer) }
    }
    throw new Error('背屏服务未连接，请恢复手机服务后重试')
  }
  async command(action: 'recording' | 'stop'): Promise<void> {
    if (this.snapshot.busy && action !== 'stop') return
    const operation = ++this.operation
    this.commandFailure = null
    this.emit({ busy: true, error: null, notice: null })
    let timer: ReturnType<typeof setTimeout> | undefined
    try {
      if (!['recording', 'stop'].includes(action))
        throw new Error('背屏操作无法识别，请重新选择')
      if (await initBridge() !== 'native') throw new Error('电脑预览不能控制手机背屏，请在 Neo 上打开')
      const status = action === 'stop' && this.stopStatus ? this.stopStatus : await this.read(), id = crypto.randomUUID()
      if (operation !== this.operation) return
      this.stopStatus = status
      this.issuedAt = Math.max(Date.now(), this.issuedAt + 1)
      await Promise.race([
        invokeNative('setStorage', { key: KEY, data: JSON.stringify({ version: 1, epoch: status.epoch, commandId: id, action, createdAt: this.issuedAt }) }),
        new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error('背屏指令写入未确认，请重试')), 5000) }),
      ])
      clearTimeout(timer)
      if (operation !== this.operation) return
      const deadline = Date.now() + 8000
      while (Date.now() < deadline) {
        await new Promise(resolve => setTimeout(resolve, 250))
        const next = await this.read()
        if (operation !== this.operation) return
        if (next.epoch !== status.epoch) throw new Error('背屏服务已重启，请重试')
        if (next.lastCommand.id !== id) continue
        if (!next.lastCommand.ok) throw new Error(next.error ?? '背屏操作未完成，请重试')
        if (action === 'recording' && next.mode !== 'recording' || action === 'stop' && (next.mode !== 'off' || next.overrideActive))
          throw new Error(next.error ?? '背屏操作未完成，请重试')
        this.emit({ status: next, error: next.error, notice: action === 'recording' ? '已开启录音联动；真正收音时显示麦克风和分钟数。' : '已停止背屏联动。' })
        return
      }
      throw new Error('背屏操作未确认，请查看手机后重试')
    } catch (error) {
      if (operation === this.operation) {
        this.commandFailure = error instanceof Error ? error.message : '背屏操作未完成'
        this.emit({ error: this.commandFailure })
      }
    }
    finally { clearTimeout(timer); if (operation === this.operation) this.emit({ busy: false }) }
  }
}
export const backScreen = new BackScreenStore()
export function useBackScreen(): BackSnapshot { return useSyncExternalStore(backScreen.subscribe, backScreen.getSnapshot, () => INITIAL) }
