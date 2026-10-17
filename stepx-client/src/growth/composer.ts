import { useSyncExternalStore } from 'react'
import type { EventRef } from './source-scope'

/** One local draft per conversation. Global inputs use the fixed main-chat ID. */
export type ComposerDraft = Readonly<{
  text: string
  background?: string
  eventRef?: EventRef
  revision: number
  error: string
  busy: boolean
}>

type StoragePort = Pick<Storage, 'getItem' | 'setItem'>
const EMPTY: ComposerDraft = Object.freeze({ text: '', revision: 0, error: '', busy: false })
const PREFIX = 'growth.ask.draft.v1:'
function checkedRef(value: EventRef | undefined): EventRef | undefined {
  if(value===undefined)return undefined
  if(!value || typeof value.eventId!=='string' || !value.eventId || value.eventId.length>220
    || typeof value.recordingId!=='string' || !value.recordingId || value.recordingId.length>160
    || !/^[a-f0-9]{64}$/.test(value.fingerprint))throw new Error('事件来源无效，请重新带入')
  return {eventId:value.eventId,recordingId:value.recordingId,fingerprint:value.fingerprint}
}

export class ComposerStore {
  private drafts = new Map<string, ComposerDraft>()
  private listeners = new Set<() => void>()
  constructor(private storage: () => StoragePort = () => window.localStorage) {}
  subscribe = (listener: () => void) => {
    this.listeners.add(listener)
    return () => { this.listeners.delete(listener) }
  }
  get = (key: string): ComposerDraft => {
    const known = this.drafts.get(key)
    if (known) return known
    let draft = EMPTY
    try {
      const raw = this.storage().getItem(PREFIX + encodeURIComponent(key))
      if (raw !== null) {
        const value = JSON.parse(raw)
        if (!value || typeof value.text !== 'string' ||
          (value.background !== undefined && typeof value.background !== 'string')) {
          throw new Error('invalid draft')
        }
        const oldRecording=typeof value.background==='string' && value.background.startsWith('这次录音：')
        draft = Object.freeze({ text: value.text, background:oldRecording?undefined:value.background,eventRef:checkedRef(value.eventRef),revision:0,
          error:oldRecording?'旧录音背景需要从事件详情重新带入，问题仍保留。':'',busy:false })
      }
    } catch {
      draft = Object.freeze({ ...EMPTY, error: '草稿未能恢复，新的输入会暂留在当前页面。' })
    }
    this.drafts.set(key, draft)
    return draft
  }
  private publish(key: string, draft: ComposerDraft) {
    this.drafts.set(key, Object.freeze(draft))
    for (const listener of this.listeners) listener()
  }
  /** Shared across the shell and chat view, so navigation cannot unlock a pending send. */
  acquire(key: string): ComposerDraft | undefined {
    const current = this.get(key)
    if (current.busy || !current.text.trim()) return undefined
    this.publish(key, { ...current, busy: true })
    return current
  }
  release(key: string): void {
    const current = this.get(key)
    if (current.busy) this.publish(key, { ...current, busy: false })
  }
  /** Failed submission remains visible after the originating input unmounts. */
  reportError(key: string, message: string): void {
    this.publish(key, { ...this.get(key), error: message })
  }
  /** Input remains visible even if browser storage is unavailable. */
  attach(key: string, context: { question?: string; background?: string; eventRef?: EventRef }): ComposerDraft {
    const current = this.get(key)
    return this.update(key, { background: context.eventRef ? undefined : context.background, eventRef: context.eventRef,
      text: current.text.trim() ? current.text : context.question ?? current.text })
  }
  update(key: string, change: { text?: string; background?: string; eventRef?: EventRef }): ComposerDraft {
    const current = this.get(key)
    const next = { ...current, ...change, revision: current.revision + 1, error: '' }
    next.eventRef=checkedRef(next.eventRef)
    if(next.eventRef)next.background=undefined
    if (typeof next.text !== 'string' ||
      (next.background !== undefined && typeof next.background !== 'string')) {
      throw new Error('草稿内容无效')
    }
    try {
      this.storage().setItem(PREFIX + encodeURIComponent(key), JSON.stringify({ text:next.text,background:next.background,eventRef:next.eventRef }))
    } catch {
      next.error = '草稿暂未保存，输入还在；关闭 App 后可能无法恢复。'
    }
    this.publish(key, next)
    return this.get(key)
  }
  /** A late submit must never erase text entered or context changed after it started. */
  clearIfRevision(key: string, revision: number): boolean {
    const current = this.get(key)
    if (current.revision !== revision) return false
    try {
      this.storage().setItem(PREFIX + encodeURIComponent(key), JSON.stringify({ text: '' }))
    } catch {
      this.publish(key, { ...current, error: '消息已保存，但草稿未能清空。输入仍保留。' })
      return false
    }
    this.publish(key, { text: '', revision: current.revision + 1, error: '', busy: current.busy })
    return true
  }
}

export const composerStore = new ComposerStore()
export function useComposerDraft(key: string) {
  return useSyncExternalStore(composerStore.subscribe, () => composerStore.get(key), () => EMPTY)
}
