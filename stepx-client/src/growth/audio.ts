/** Canonical 16k mono PCM16 WAV. AAC is decoded, never merely renamed. */
export function encodeWav(samples: Float32Array, sampleRate: number): Uint8Array {
  if (sampleRate !== 16000 || !samples.length || samples.length > 16000 * 601) throw new Error('音频时长或采样率不支持')
  const bytes = new Uint8Array(44 + samples.length * 2), view = new DataView(bytes.buffer)
  const text = (offset: number, value: string) => [...value].forEach((c, i) => { bytes[offset + i] = c.charCodeAt(0) })
  text(0, 'RIFF'); text(8, 'WAVE'); text(12, 'fmt '); text(36, 'data')
  for (const [offset, value] of [[4, bytes.length - 8], [16,16], [24,16000], [28,32000], [40,bytes.length - 44]]) view.setUint32(offset, value, true)
  for (const [offset, value] of [[20,1], [22,1], [32,2], [34,16]]) view.setUint16(offset, value, true)
  samples.forEach((sample, i) => {
    if (!Number.isFinite(sample)) throw new Error('音频解码结果无效')
    const value = Math.max(-1, Math.min(1, sample))
    view.setInt16(44 + i * 2, Math.round(value * (value < 0 ? 32768 : 32767)), true)
  })
  return bytes
}
export async function toWav(blob: Blob): Promise<Uint8Array> {
  if (!blob.size || blob.size > 25 * 1024 * 1024)
    throw new Error('这台设备暂不能转换录音，原音频仍保存在本机')
  const raw = new Uint8Array(await blob.arrayBuffer()), header = new DataView(raw.buffer)
  if (raw.length >= 46 && String.fromCharCode(...raw.slice(0, 4)) === 'RIFF'
    && String.fromCharCode(...raw.slice(8, 16)) === 'WAVEfmt ' && String.fromCharCode(...raw.slice(36, 40)) === 'data'
    && header.getUint32(4, true) === raw.length - 8 && header.getUint32(16, true) === 16
    && header.getUint16(20, true) === 1 && header.getUint16(22, true) === 1 && header.getUint32(24, true) === 16000
    && header.getUint32(28, true) === 32000 && header.getUint16(32, true) === 2 && header.getUint16(34, true) === 16
    && header.getUint32(40, true) === raw.length - 44 && (raw.length - 44) % 2 === 0
    && (raw.length - 44) / 32000 <= 601) return raw
  if (typeof AudioContext === 'undefined' || typeof OfflineAudioContext === 'undefined')
    throw new Error('这台设备暂不能转换录音，原音频仍保存在本机')
  let context: AudioContext
  try { context = new AudioContext({ sampleRate: 16000 }) }
  catch { throw new Error('这台设备暂不能转换录音，原音频仍保存在本机') }
  try {
    const decoded = await context.decodeAudioData(await blob.arrayBuffer())
    if (!Number.isFinite(decoded.duration) || decoded.duration <= 0 || decoded.duration > 601) throw new Error('录音须在10分钟以内，原音频已保留')
    const render = new OfflineAudioContext(1, Math.ceil(decoded.duration * 16000), 16000)
    const source = render.createBufferSource(); source.buffer = decoded; source.connect(render.destination); source.start()
    const output = await render.startRendering()
    return encodeWav(output.getChannelData(0), 16000)
  } catch (error) {
    throw new Error(error instanceof Error && error.message.includes('分钟') ? error.message : '音频转换未完成，原音频仍在本机，可重试')
  } finally { await context.close().catch(() => undefined) }
}
export async function sha256(bytes: Uint8Array): Promise<string> {
  const buffer = bytes.slice().buffer
  return [...new Uint8Array(await crypto.subtle.digest('SHA-256', buffer))].map(b => b.toString(16).padStart(2, '0')).join('')
}
