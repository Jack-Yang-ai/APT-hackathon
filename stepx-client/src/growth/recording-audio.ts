import { nativeLog } from '@/shared/bridge'
import { nativeFileName, type NativeAudioFile } from './recording-journal'

export class RecordingAudioFailure extends Error {
  constructor(readonly stage: 'file-read' | 'file-content', readonly status?: number) {
    super(stage === 'file-read' ? '录音文件读取未完成，原件仍在本机，请点保存重试' : '录音文件无法验证，原件仍在本机，请保留 App')
  }
}
export function nativeMediaURL(source: string): string {
  const url = new URL(source)
  nativeFileName(source)
  if (url.origin !== location.origin && !['https://appassets.t-stepos.com', 'https://appassets.stepaos.com'].includes(url.origin))
    throw new RecordingAudioFailure('file-content')
  // ContainerWebViewClient intercepts media on its virtual host. A debug page's
  // Studio origin is different; rewriting to that origin would hit the server.
  return url.href
}
export function localNativeURL(file: NativeAudioFile): string { return nativeMediaURL(file.tempFilePath) }
export async function readNativeAudio(file: NativeAudioFile): Promise<Blob> {
  const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 15000)
  try {
    const url = localNativeURL(file)
    const response = await fetch(url, { signal: controller.signal })
    if (!response.ok) throw new RecordingAudioFailure('file-read', response.status)
    if (response.url && new URL(response.url).href !== url) throw new RecordingAudioFailure('file-content')
    const blob = await response.blob()
    if (blob.size !== file.size || !blob.size) throw new RecordingAudioFailure('file-content')
    const header = new Uint8Array(await blob.slice(0, 16).arrayBuffer())
    const ascii = (from: number, to: number) => String.fromCharCode(...header.slice(from, to))
    if (ascii(4, 8) !== 'ftyp' && ascii(0, 5) !== '#!AMR') throw new RecordingAudioFailure('file-content')
    return blob
  } catch (error) {
    const failure = error instanceof RecordingAudioFailure ? error : new RecordingAudioFailure('file-read')
    nativeLog.w('growth/recorder', 'native audio read failed', { stage: failure.stage, status: failure.status })
    throw failure
  } finally { clearTimeout(timer) }
}
