/** Growth transport replaces the closed platform bucket path; local originals are kept. */
import { nativeLog } from '@/shared/bridge'
import { growthStore } from './store'
import { growthConnection } from './connection'
import { growthProcessing } from './processing'
import { SEMANTIC_RECIPE } from './processing-data'
export function isCloudReady(): boolean {
  const state = growthConnection.getSnapshot()
  return state.ready && state.health?.asrConfigured === true && state.health.extractionQueueConfigured === true
    && state.health.semanticRecipe === SEMANTIC_RECIPE
}
export async function cacheSegmentAudio(segmentId: string, localUrl: string): Promise<void> {
  try {
    const response = await fetch(localUrl)
    if (!response.ok) throw new Error('audio missing')
    const blob = await response.blob()
    if (!blob.size) throw new Error('empty audio')
    await growthStore.saveAudio(segmentId, blob)
  } catch {
    nativeLog.w('growth/upload', 'audio persistence failed')
    throw new Error('录音保存未完成，请保留 App 并重试')
  }
}
export function enqueueUpload(_segmentId: string): void { void growthProcessing.kick() }
export function resumePendingUploads(): void { void growthProcessing.kick() }
export async function retryMatter(matterId: string): Promise<void> { await growthProcessing.retryRecording(matterId) }
