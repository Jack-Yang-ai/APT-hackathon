import { initBridge, invokeNative } from '@/shared/bridge'
import type { Segment } from './types'

export interface NativeAudioFile { tempFilePath: string; duration: number; size: number }
export interface Capture {
  id: string; matterId: string; index: number; startedAt: number; acknowledgedAt: number | null; elapsedBefore: number
}
export interface PendingCapture { capture: Capture; file: NativeAudioFile; segment: Segment }
export interface RecordingJournal {
  version: 1; matterId: string | null; elapsedSec: number; nextIndex: number
  capture: Capture | null; pending: PendingCapture | null; orphans: NativeAudioFile[]; unresolved: Capture[]
}
export const emptyJournal = (): RecordingJournal => ({ version: 1, matterId: null, elapsedSec: 0, nextIndex: 0, capture: null, pending: null, orphans: [], unresolved: [] })
const KEY = 'growth.recorder.checkpoint.v1'
const finite = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v) && v >= 0

/** This is a native file identity, not a guess about the owner of a legacy file. */
export function nativeFileName(url: string): string {
  const parsed = new URL(url)
  const name = parsed.pathname.match(/^\/media\/(record_\d{10,16}\.(?:m4a|amr))$/)?.[1]
  if (!name || parsed.username || parsed.password || parsed.search || parsed.hash || parsed.protocol !== 'https:')
    throw new Error('原生录音文件地址无效')
  return name
}
export function nativeFileStartedAt(url: string): number { return Number(nativeFileName(url).match(/\d+/)![0]) }
export function parseNativeAudio(value: unknown): NativeAudioFile {
  const file = value as Partial<NativeAudioFile> | null
  if (!file || typeof file.tempFilePath !== 'string' || !finite(file.duration) || !finite(file.size)
    || file.size === 0 || file.size > 25 * 1024 * 1024 || file.duration > 601) throw new Error('原生录音回执不完整')
  nativeFileName(file.tempFilePath)
  return { tempFilePath: file.tempFilePath, duration: file.duration, size: file.size }
}
function validCapture(value: unknown): value is Capture {
  const c = value as Capture | null
  return Boolean(c && typeof c.id === 'string' && c.id && typeof c.matterId === 'string' && c.matterId
    && Number.isInteger(c.index) && c.index >= 0 && finite(c.startedAt) && finite(c.elapsedBefore)
    && (c.acknowledgedAt === null || finite(c.acknowledgedAt) && c.acknowledgedAt >= c.startedAt))
}
export function parseJournal(value: unknown): RecordingJournal {
  if (value === null || value === undefined || value === '') return emptyJournal()
  const j = (typeof value === 'string' ? JSON.parse(value) : value) as RecordingJournal
  if (!j || j.version !== 1 || !(j.matterId === null || typeof j.matterId === 'string' && j.matterId.length > 0) || !finite(j.elapsedSec)
    || !Number.isInteger(j.nextIndex) || j.nextIndex < 0 || !Array.isArray(j.orphans)
    || !(j.capture === null || validCapture(j.capture))
    || !(j.pending === null || typeof j.pending === 'object' && j.pending)) throw new Error('录音恢复记录无法读取，请保留 App')
  if (j.capture && j.capture.matterId !== j.matterId) throw new Error('录音恢复归属不一致')
  j.orphans.forEach(parseNativeAudio)
  if (!Array.isArray(j.unresolved) || !j.unresolved.every(validCapture)) throw new Error('未确认录音归属无法读取')
  if (j.pending) {
    const p = j.pending
    if (!validCapture(p.capture) || !p.segment || !p.file || p.capture.matterId !== j.matterId || p.segment.id !== p.capture.id
      || p.segment.matterId !== p.capture.matterId || p.segment.index !== p.capture.index
      || !finite(p.segment.durationSec) || p.segment.durationSec !== p.file.duration || p.segment.sizeBytes !== p.file.size
      || p.segment.localUrl !== p.file.tempFilePath || p.segment.stage !== 'recorded'
      || p.capture.id !== j.capture?.id) throw new Error('待保存录音归属不一致')
    parseNativeAudio(p.file)
  }
  return structuredClone(j)
}
/** Metadata survives a WebView reload and an IndexedDB Blob quota failure. */
export async function readRecordingJournal(): Promise<RecordingJournal> {
  if (await initBridge() !== 'native') return emptyJournal()
  const result = await invokeNative('getStorage', { key: KEY })
  return parseJournal(result.data)
}
export async function writeRecordingJournal(journal: RecordingJournal): Promise<void> {
  if (await initBridge() !== 'native') return
  await invokeNative('setStorage', { key: KEY, data: JSON.stringify(journal) })
}
