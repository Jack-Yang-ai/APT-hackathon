import { sha256 } from './audio'
import { growthStore } from './store'
import type { Matter, Segment } from './types'
import { nativeFileName, nativeFileStartedAt, parseNativeAudio, type NativeAudioFile } from './recording-journal'
import { readNativeAudio, nativeMediaURL } from './recording-audio'

export function savedNativeFile(file: NativeAudioFile): Segment | undefined {
  const name = nativeFileName(file.tempFilePath)
  return growthStore.getSnapshot().segments.find(segment => {
    if (segment.nativeFileName === name) return true
    try { return nativeFileName(segment.localUrl) === name } catch { return false }
  })
}
/** Only a local forensic manifest is accepted. It never assigns old files to an old session. */
export async function readRecoveryManifest(fileHint?: string): Promise<NativeAudioFile[]> {
  const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 3000)
  try {
    // The actual stop receipt is authoritative. Before the first receipt, the
    // installed test container's verified virtual host handles Studio previews.
    const origin = fileHint ? new URL(nativeMediaURL(fileHint)).origin
      : location.pathname.startsWith('/preview/') ? 'https://appassets.t-stepos.com' : location.origin
    const url = new URL('/media/apt-recording-recovery.json', origin).href
    const response = await fetch(url, { signal: controller.signal })
    if (!response.ok || (response.url && response.url !== url)) return []
    const value = await response.json() as { version?: number; files?: NativeAudioFile[] }
    if (value.version !== 1 || !Array.isArray(value.files) || value.files.length > 20) return []
    return value.files.map(file => parseNativeAudio({ ...file, tempFilePath: new URL('/media/' + nativeFileName(file.tempFilePath), origin).href }))
  } catch { return [] }
  finally { clearTimeout(timer) }
}
export async function recoverNativeFile(file: NativeAudioFile): Promise<void> {
  const existing = savedNativeFile(file)
  if (existing && (await growthStore.getAudio(existing.id))?.size === file.size) return
  const blob = await readNativeAudio(file)
  if (existing) {
    // Repair a missing Blob without overwriting existing processing receipts or ownership.
    await growthStore.commitCapturedAudio({ ...existing, cloudEligible: false }, blob)
    return
  }
  const hash = await sha256(new Uint8Array(await blob.arrayBuffer()))
  // Equal bytes can be two different captures. Preserve each native file identity.
  const id = 'native-recovery-' + nativeFileName(file.tempFilePath).replace(/\W/g, '-') + '-' + hash
  const startedAt = nativeFileStartedAt(file.tempFilePath)
  const matter: Matter = { id, startedAt, endedAt: null, origin: 'import', title: null, progress: null,
    recoveredFromNative: true, recordingTimeUnverified: true }
  const segment: Segment = { id, matterId: id, index: 0, capturedAt: startedAt, durationSec: file.duration,
    sizeBytes: blob.size, localUrl: file.tempFilePath, nativeFileName: nativeFileName(file.tempFilePath),
    stage: 'recorded', attempts: 0, cloudEligible: false }
  await growthStore.commitRecoveredAudio(matter, segment, blob)
}
