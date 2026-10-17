import { useSyncExternalStore } from 'react'
import { initBridge } from '@/shared/bridge'
import { recorder as nativeRecorder } from './recorder'
import type { RecorderSnapshot } from './recorder'
import { RootRecordingClient } from './root-recording'
import { RootRecorder } from './root-recorder'

/** Native fallback is selected only when no root deployment status exists. */
class RecordingController {
  private selected: typeof nativeRecorder | RootRecorder | null = null
  private selecting: Promise<void> | null = null
  private listeners = new Set<() => void>()
  private snapshot: RecorderSnapshot = nativeRecorder.getSnapshot()
  subscribe = (fn: () => void) => { this.listeners.add(fn); return () => { this.listeners.delete(fn) } }
  getSnapshot = (): RecorderSnapshot => this.snapshot
  private emit = () => { if (this.selected) this.snapshot = this.selected.getSnapshot(); this.listeners.forEach(fn => fn()) }
  initialize(): Promise<void> {
    if (this.selected) return this.selected.initialize()
    if (this.selecting) return this.selecting
    this.selecting = (async () => {
      const client = new RootRecordingClient()
      try {
        const status = await initBridge() === 'native' ? await client.status() : null
        this.selected = status ? new RootRecorder(client) : nativeRecorder
        if (status && !status.sessions.some(row => ['starting', 'recording', 'stopping'].includes(row.state))) {
          // One-time legacy checkpoint recovery; never stop the live root stream.
          await nativeRecorder.initialize(); nativeRecorder.dispose()
        }
        this.selected.subscribe(this.emit)
        await this.selected.initialize(); this.emit()
      } catch {
        // A corrupt/inaccessible deployment status cannot safely mean "use another mic".
        this.snapshot = { ...this.snapshot, state: 'recovering', phase: null,
          error: '录音服务状态未能读取，请保留 App 并重试' }; this.listeners.forEach(fn => fn())
      }
    })().finally(() => { this.selecting = null })
    return this.selecting
  }
  private async call(action: 'start' | 'resume' | 'pause' | 'finish' | 'retryRecovery'): Promise<void> {
    if (!this.selected) await this.initialize()
    if (this.selected) await this.selected[action]()
  }
  start = () => this.call('start')
  resume = () => this.call('resume')
  pause = () => this.call('pause')
  finish = () => this.call('finish')
  retryRecovery = () => this.call('retryRecovery')
  dismissError = () => this.selected?.dismissError()
}
export const recorder = new RecordingController()
export function useRecorder(): RecorderSnapshot { return useSyncExternalStore(recorder.subscribe, recorder.getSnapshot, recorder.getSnapshot) }
