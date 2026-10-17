import { initBridge, invokeNative } from '@/shared/bridge'
import { sha256 } from './audio'

export interface RootSession {
  captureId: string; matterId: string; indexBase: number; chunkSeconds: number; limitSeconds: number
  state: 'starting' | 'recording' | 'stopping' | 'stopped' | 'failed'; frames?: number; startedAt?: number; reason: string | null
  uploadClient?: string
  audioFormat?: 'wav' | 'm4a'
  uploadRevoked?: boolean
}
export interface RootPiece {
  captureId: string; matterId: string; index: number; piece: number; frames: number; frameOffset: number
  capturedAt: number; size: number; sha256: string; file: string; cloudEligible: boolean
  uploadClient?: string
  audioFormat?: 'wav' | 'm4a'
}
export interface RootUpload {
  captureId: string; matterId: string; piece: number; frames: number; sha256: string; key: string; durationSec: number
  state: 'pending' | 'waiting-connection' | 'uploading' | 'uploaded' | 'cancelled'; uploadedAt?: number
}
export interface RootStatus {
  version: 1; runtime: string; epoch: string; updatedAt: number; validation: boolean
  lastCommand: { id?: string; ok?: boolean; error?: string }; sessions: RootSession[]; pieces: RootPiece[]
  uploads?: RootUpload[]
  audioFormats?: ('wav' | 'm4a')[]
  backgroundVersion?:number
}
export const ROOT_COMMAND_KEY = 'growth.root.capture.command.v1'
export const ROOT_JOURNAL_KEY = 'growth.root.capture.journal.v1'
const hosts = ['https://appassets.t-stepos.com', 'https://appassets.stepaos.com']
export const rootUuid = (value: unknown): value is string => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value)
const integer = (value: unknown, min: number, max: number): value is number => typeof value === 'number' && Number.isSafeInteger(value) && value >= min && value <= max
export function parseRootUploadReceipt(value: unknown): RootUpload {
  const row = value as RootUpload
  if (!row || !rootUuid(row.captureId) || !rootUuid(row.matterId) || !integer(row.piece,0,8640)
    || !integer(row.frames,1,9600000) || !/^[0-9a-f]{64}$/.test(row.sha256) || row.durationSec !== row.frames / 16000
    || row.state !== 'uploaded' || !integer(row.uploadedAt,1,Number.MAX_SAFE_INTEGER) || typeof row.key !== 'string'
    || !/^stepx\/[0-9a-f-]{36}\/[0-9a-f-]{36}\/[0-9a-f-]{36}-[0-9a-f]{64}\.(wav|m4a)$/.test(row.key)
    || !new RegExp(`-${row.sha256}\\.(wav|m4a)$`).test(row.key)) throw new Error('后台上传回执无法核验')
  return structuredClone(row)
}
export function parseRootStatus(value: unknown): RootStatus {
  const status = value as RootStatus
  if (!status || status.version !== 1 || !rootUuid(status.epoch) || typeof status.runtime !== 'string'
    || !integer(status.updatedAt, 1, Number.MAX_SAFE_INTEGER) || typeof status.validation !== 'boolean'
    || !status.lastCommand || !Array.isArray(status.sessions) || status.sessions.length > 1000
    || !Array.isArray(status.pieces) || status.pieces.length > 2000) throw new Error('持续录音状态无法核验')
  if (status.audioFormats !== undefined && (!Array.isArray(status.audioFormats) || status.audioFormats.length > 2
    || new Set(status.audioFormats).size !== status.audioFormats.length || status.audioFormats.some(format => !['wav','m4a'].includes(format))))
    throw new Error('持续录音格式能力无法核验')
  const sessions = new Map<string, RootSession>()
  if(status.backgroundVersion!==undefined&&status.backgroundVersion!==1)throw new Error('后台处理协议无法核验')
  for (const session of status.sessions) {
    if (!rootUuid(session.captureId) || !rootUuid(session.matterId) || sessions.has(session.captureId)
      || !integer(session.indexBase, 0, 10000) || !integer(session.chunkSeconds, 5, 600) || !integer(session.limitSeconds, 12, 43200)
      || !['starting', 'recording', 'stopping', 'stopped', 'failed'].includes(session.state)
      || session.frames !== undefined && !integer(session.frames, 0, session.limitSeconds * 16000)
      || session.startedAt !== undefined && !integer(session.startedAt, 1, Number.MAX_SAFE_INTEGER)) throw new Error('持续录音身份无法核验')
    if (session.uploadClient !== undefined && !rootUuid(session.uploadClient)) throw new Error('后台上传身份无法核验')
    if (session.audioFormat !== undefined && !['wav','m4a'].includes(session.audioFormat)) throw new Error('持续录音格式无法核验')
    if (session.uploadRevoked !== undefined && typeof session.uploadRevoked !== 'boolean') throw new Error('后台上传撤销状态无法核验')
    sessions.set(session.captureId, session)
  }
  const seen = new Set<string>()
  for (const piece of status.pieces) {
    const session = sessions.get(piece.captureId), key = `${piece.captureId}:${piece.piece}`
    const format = piece.audioFormat ?? 'wav'
    if (!session || piece.matterId !== session.matterId || !integer(piece.piece, 0, 8640) || seen.has(key)
      || !integer(piece.index, 0, 20000) || piece.index !== session.indexBase + piece.piece
      || !integer(piece.frames, 1, session.chunkSeconds * 16000) || !integer(piece.frameOffset, 0, 43200 * 16000)
      || piece.frameOffset !== piece.piece * session.chunkSeconds * 16000
      || !integer(piece.capturedAt, 1, Number.MAX_SAFE_INTEGER) || !integer(piece.size, 46, 19200044)
      || !['wav','m4a'].includes(format) || (format === 'wav' ? piece.size !== 44 + piece.frames * 2
        : session.audioFormat !== 'm4a' || piece.size > 44 + piece.frames * 2) || !/^[0-9a-f]{64}$/.test(piece.sha256)
      || piece.file !== `apt-root-${piece.captureId}-${String(piece.piece).padStart(4, '0')}.${format}`
      || typeof piece.cloudEligible !== 'boolean' || status.validation && piece.cloudEligible) throw new Error('持续录音分片无法核验')
    if (piece.uploadClient !== undefined && (!rootUuid(piece.uploadClient) || piece.uploadClient !== session.uploadClient || status.validation))
      throw new Error('后台上传分片归属无法核验')
    if (!status.validation && session.uploadClient !== undefined && piece.uploadClient !== session.uploadClient)
      throw new Error('后台上传分片归属缺失，不能改用重复上传路径')
    seen.add(key)
  }
  if (status.uploads !== undefined) {
    if (!Array.isArray(status.uploads) || status.uploads.length > 2000 || status.validation && status.uploads.length) throw new Error('后台上传回执无法核验')
    const uploads = new Set<string>()
    for (const row of status.uploads) {
      const session = sessions.get(row.captureId), id = `${row.captureId}:${row.piece}`
      if (!session?.uploadClient || row.matterId !== session.matterId || !integer(row.piece, 0, 8640) || uploads.has(id)
        || !integer(row.frames, 1, session.chunkSeconds * 16000) || !/^[0-9a-f]{64}$/.test(row.sha256)
        || typeof row.key !== 'string' || !row.key.startsWith(`stepx/${session.uploadClient}/${session.matterId}/`)
        || !new RegExp(`/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-${row.sha256}\\.(wav|m4a)$`).test(row.key)
        || row.durationSec !== row.frames / 16000 || !['pending','waiting-connection','uploading','uploaded','cancelled'].includes(row.state)
        || row.state === 'uploaded' && !integer(row.uploadedAt, 1, Number.MAX_SAFE_INTEGER)) throw new Error('后台上传回执归属无法核验')
      if (row.key.endsWith('.m4a') && session.audioFormat !== 'm4a') throw new Error('后台上传格式归属无法核验')
      uploads.add(id)
    }
  }
  return structuredClone(status)
}
export function validateRootWav(bytes: Uint8Array, frames: number): void {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  const text = (at: number, n: number) => String.fromCharCode(...bytes.slice(at, at + n))
  if (bytes.length !== 44 + frames * 2 || text(0, 4) !== 'RIFF' || text(8, 8) !== 'WAVEfmt '
    || text(36, 4) !== 'data' || view.getUint32(4, true) !== bytes.length - 8 || view.getUint32(16, true) !== 16
    || view.getUint16(20, true) !== 1 || view.getUint16(22, true) !== 1 || view.getUint32(24, true) !== 16000
    || view.getUint32(28, true) !== 32000 || view.getUint16(32, true) !== 2 || view.getUint16(34, true) !== 16
    || view.getUint32(40, true) !== frames * 2) throw new Error('持续录音音频不完整，原件已保留')
}
export class RootRecordingClient {
  private host: string | null = null
  private commands: Promise<unknown> = Promise.resolve()
  async revokeMatter(matterId: string): Promise<void> {
    if (!rootUuid(matterId) || await initBridge() !== 'native') return
    const key = `growth.root.capture.deleted.${matterId}`
    // Block concurrent STARTs/body writes across WebViews before asking root for a durable tombstone.
    await invokeNative('setStorage',{key,data:'deleted'})
    const status = await this.status()
    if (!status || status.uploads === undefined) throw new Error('持续录音服务尚未确认删除，录音已保留，请恢复服务后重试')
    this.fresh(status); await this.command(status,'forget',{matterId})
    // Only root's immutable, fsynced tombstone authorizes source deletion; SDK storage may flush asynchronously.
    try { await invokeNative('removeStorage',{key}) } catch { /* Harmless queue item; retry cleanup when the App reconnects. */ }
  }
  async uploadReceipt(captureId: string, piece: number): Promise<RootUpload | null> {
    if (!rootUuid(captureId) || !integer(piece,0,8640)) throw new Error('后台上传身份无法核验')
    if (await initBridge() !== 'native') return null
    const bytes = await this.fetchFile(`apt-root-upload-${captureId}-${String(piece).padStart(4,'0')}.json`,8192)
    return bytes ? parseRootUploadReceipt(JSON.parse(new TextDecoder().decode(bytes))) : null
  }
  private async fetchFile(name: string, max: number): Promise<Uint8Array | null> {
    for (const host of this.host ? [this.host] : hosts) {
      const abort = new AbortController()
      let timer: ReturnType<typeof setTimeout> | undefined
      try {
        const bytes = await Promise.race([
          (async () => {
            const result = await fetch(`${host}/media/${name}`, { cache: 'no-store', signal: abort.signal, redirect: 'error' })
            if (result.status === 404) return null
            if (!result.ok || Number(result.headers.get('content-length') ?? 0) > max) throw new Error('持续录音文件暂时不可读')
            const bytes = new Uint8Array(await result.arrayBuffer())
            if (bytes.length > max) throw new Error('持续录音文件大小无法核验')
            return bytes
          })(),
          new Promise<never>((_, reject) => { timer = setTimeout(() => { abort.abort(); reject(new Error('持续录音文件读取超时，原件已保留')) }, 5000) }),
        ])
        if (bytes === null) continue
        this.host = host; return bytes
      } finally { clearTimeout(timer) }
    }
    return null
  }
  async status(): Promise<RootStatus | null> {
    if (await initBridge() !== 'native') return null
    const result = await this.fetchFile('apt-root-status-v1.json', 1024 * 1024)
    if (!result) return null
    const text = new TextDecoder().decode(result)
    return parseRootStatus(JSON.parse(text))
  }
  fresh(status: RootStatus): void {
    const age = Date.now() - status.updatedAt
    if (age < -5000 || age > 8000) throw new Error('持续录音服务离线，请恢复手机录音服务；已保存录音仍在')
  }
  command(status: RootStatus, action: 'start' | 'stop' | 'ack' | 'ping' | 'forget', fields: Record<string, unknown> = {}): Promise<RootStatus> {
    const pending = this.commands.then(() => this.send(status, action, fields))
    this.commands = pending.catch(() => undefined); return pending
  }
  private async send(status: RootStatus, action: 'start' | 'stop' | 'ack' | 'ping' | 'forget', fields: Record<string, unknown>): Promise<RootStatus> {
    // Read freshness again after the previous single mailbox command completes.
    const latest = await this.status()
    if (latest && latest.epoch === status.epoch) status = latest
    this.fresh(status)
    const commandId = crypto.randomUUID()
    let timer: ReturnType<typeof setTimeout> | undefined
    try {
      await Promise.race([
        invokeNative('setStorage', { key: ROOT_COMMAND_KEY, data: JSON.stringify({ ...fields, version: 1, epoch: status.epoch, commandId, action, createdAt: Date.now() }) }),
        new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error('录音指令写入未确认，请核当前录音状态')), 5000) }),
      ])
    } finally { clearTimeout(timer) }
    const deadline = Date.now() + 8000
    while (Date.now() < deadline) {
      await new Promise(resolve => setTimeout(resolve, 250))
      const next = await this.status()
      if (!next) throw new Error('持续录音服务暂时不可读，操作尚未确认')
      this.fresh(next)
      if (next.epoch !== status.epoch) throw new Error('持续录音服务已重启，请核当前状态后重试')
      if (next.lastCommand.id === commandId) {
        if (!next.lastCommand.ok) throw new Error('持续录音操作未被接受，请检查麦克风权限并重试')
        return next
      }
    }
    throw new Error('持续录音操作未确认，请保存重试')
  }
  url(piece: RootPiece): string {
    if (!this.host) throw new Error('持续录音媒体未连接')
    return `${this.host}/media/${piece.file}`
  }
  async audio(piece: RootPiece): Promise<Blob> {
    const result = await this.fetchFile(piece.file, piece.size)
    if (!result) throw new Error('持续录音文件尚未读取，原件已保留')
    const bytes = result
    if (piece.audioFormat === 'm4a') {
      if (bytes.length !== piece.size || bytes.length < 46 || String.fromCharCode(...bytes.slice(4,8)) !== 'ftyp')
        throw new Error('持续录音压缩文件不完整，原件已保留')
    } else validateRootWav(bytes, piece.frames)
    if (await sha256(bytes) !== piece.sha256) throw new Error('持续录音校验未通过，原件已保留')
    return new Blob([bytes.slice().buffer], { type: piece.audioFormat === 'm4a' ? 'audio/mp4' : 'audio/wav' })
  }
}
