import { useSyncExternalStore } from 'react'
import { initBridge, invokeNative } from '@/shared/bridge'

/**
 * 现有 Growth 云代理。StepX 直连受保护的传输适配层。
 * 模型路由仍在 Growth 后端，这个应用不持有任何模型凭据。
 */
export const GROWTH_BASE_URL = 'https://apt-backend.example/stepx'
const TOKEN_KEY = 'growth.stepx.gate'
interface Health { ok: boolean; chatConfigured: boolean; asrConfigured: boolean; extractionQueueConfigured: boolean; semanticRecipe: string; source: string | null; backgroundConfigured?:boolean; audioFormats?: ('wav' | 'm4a')[] }
export interface ConnectionSnapshot {
  ready: boolean; connecting: boolean; hasCredential: boolean; error: string | null; health: Health | null
}
const EMPTY: ConnectionSnapshot = { ready: false, connecting: false, hasCredential: false, error: null, health: null }

export class CloudFailure extends Error {
  constructor(public readonly code: string, public readonly status: number) {
    super(code === 'unauthorized' ? '门禁令牌不正确，请重新连接'
      : code === 'unknown_result' ? '请求超时，结果尚不确定，重试可能会重新调用服务'
      : code === 'credential_storage_failed' ? '本机凭据存储失败，请重试；未确认保存或清除成功'
      : code === 'asr_submission_unknown' ? '转写提交结果未知，正在核对回执；不会立即重复提交'
      : code === 'asr_submission_expired' ? '转写提交已超过核对时限，原音频已保留；请手动重试，可能重新产生转写费用'
      : code === 'asr_retry_authorization_required' ? '请重新确认重试；旧版应用请先更新，原音频已保留'
      : code === 'offline' ? '当前没有网络，恢复后可重试'
      : code === 'connection_not_configured' ? '云代理尚未配置'
      : '云端处理未完成，可以稍后重试')
  }
}
/**
 * 当前宿主：`native` = 真机壳（有沙箱存储）；`mock` = 浏览器 / 平台预览。
 *
 * 为什么要判它：预览下壳的 mock 桥会把 setStorage 落到 **localStorage**，
 * 令牌就被长期留在浏览器里了——而本文件的承诺只是"网页只保存当前标签页会话"。
 * 所以只有真机才走原生存储，预览一律走 sessionStorage。
 */
let hostMode: Promise<'native' | 'mock'> | null = null
function host(): Promise<'native' | 'mock'> {
  if (!hostMode) hostMode = initBridge().catch(error => { hostMode = null; throw error })
  return hostMode
}

async function readCredential(): Promise<string> {
  try {
    if ((await host()) === 'native') {
      const result = await invokeNative('getStorage', { key: TOKEN_KEY })
      return typeof result?.data === 'string' ? result.data : ''
    }
    return sessionStorage.getItem(TOKEN_KEY) ?? ''
  } catch { throw new CloudFailure('credential_storage_failed', 0) }
}
async function writeCredential(token: string): Promise<void> {
  try {
    if ((await host()) === 'native') await invokeNative('setStorage', { key: TOKEN_KEY, data: token })
    else sessionStorage.setItem(TOKEN_KEY, token)
  } catch { throw new CloudFailure('credential_storage_failed', 0) }
}
async function clearCredential(): Promise<void> {
  try {
    if ((await host()) === 'native') await invokeNative('removeStorage', { key: TOKEN_KEY })
    else sessionStorage.removeItem(TOKEN_KEY)
  } catch { throw new CloudFailure('credential_storage_failed', 0) }
}

export class GrowthConnection {
  private token = ''
  private version = 0
  private initialized = false
  private writes: Promise<void> = Promise.resolve()
  private snapshot: ConnectionSnapshot = EMPTY
  private listeners = new Set<() => void>()
  subscribe = (listener: () => void) => { this.listeners.add(listener); return () => { this.listeners.delete(listener) } }
  getSnapshot = (): ConnectionSnapshot => this.snapshot
  private emit(patch: Partial<ConnectionSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch }; this.listeners.forEach(listener => listener())
  }
  async init(): Promise<void> {
    if (this.initialized) return
    this.initialized = true
    const before = this.version
    try {
      const stored = await readCredential()
      if (before !== this.version || !stored) return
      this.token = stored
      this.emit({ hasCredential: true })
      await this.connect(stored)
    } catch (error) {
      this.initialized = false
      if (before === this.version) this.emit({ ready: false, error: error instanceof CloudFailure ? error.message : '读取连接设置失败，请重试' })
    }
  }
  async connect(candidate: string): Promise<void> {
    const token = candidate.trim()
    if (token.length < 12 || token.length > 512 || /[\r\n]/.test(token)) throw new Error('请填写现有 Growth 门禁令牌')
    const version = ++this.version
    this.emit({ ready: false, connecting: true, error: null })
    try {
      const health = await this.fetchJson<Health>('/health', undefined, token)
      if (health.ok !== true || typeof health.chatConfigured !== 'boolean' || typeof health.asrConfigured !== 'boolean'
        || typeof health.extractionQueueConfigured !== 'boolean' || health.semanticRecipe !== 'v3-semantic-continuity' || typeof health.source !== 'string') throw new CloudFailure('bad_health', 502)
      this.writes = this.writes.catch(() => undefined).then(async () => {
        if (version === this.version) await writeCredential(token)
      })
      await this.writes
      if (version !== this.version) return
      this.token = token
      this.emit({ ready: true, connecting: false, hasCredential: true, error: null, health })
    } catch (error) {
      if (version === this.version) this.emit({ connecting: false, ready: false,
        error: error instanceof CloudFailure ? error.message : '连接未能完成，请重试' })
      throw error
    }
  }
  async reconnect(): Promise<void> { if (this.token) await this.connect(this.token) }
  async disconnect(): Promise<void> {
    const version = ++this.version
    const hadCredential = this.snapshot.hasCredential
    this.token = ''; this.emit({ ...EMPTY, hasCredential: hadCredential })
    this.writes = this.writes.catch(() => undefined).then(async () => {
      await clearCredential()
    })
    try {
      await this.writes
      if (version === this.version) this.emit({ hasCredential: false })
    } catch (error) {
      if (version === this.version) this.emit({ hasCredential: true, error: error instanceof CloudFailure ? error.message : '清除连接设置失败，请重试' })
      throw error
    }
  }
  isReady(): boolean { return this.snapshot.ready }
  async request<T>(path: string, body?: unknown, timeoutMs = 90000): Promise<T> {
    if (!this.snapshot.ready || !this.token) throw new CloudFailure('connection_not_configured', 503)
    const version = this.version
    const result = await this.fetchJson<T>(path, body, this.token, timeoutMs)
    if (version !== this.version) throw new CloudFailure('connection_changed', 409)
    return result
  }
  private async fetchJson<T>(path: string, body: unknown, token: string, timeoutMs = 90000): Promise<T> {
    const target = new URL(GROWTH_BASE_URL + path)
    if (!path.startsWith('/') || path.startsWith('//') || target.origin !== 'https://apt-backend.example'
      || !target.pathname.startsWith('/stepx/')) throw new CloudFailure('invalid_path', 400)
    // The Neo WebView can retain a stale offline flag; the bounded fetch determines reachability.
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), timeoutMs)
    try {
      const binary = body instanceof Blob || body instanceof Uint8Array || body instanceof ArrayBuffer
      const response = await fetch(target.href, {
        method: body === undefined ? 'GET' : 'POST', credentials: 'omit', redirect: 'error', signal: controller.signal,
        headers: { 'X-Growth-Token': token, ...(body === undefined ? {} : { 'Content-Type': body instanceof Blob && body.type === 'audio/mp4' ? 'audio/mp4' : binary ? 'audio/wav' : 'application/json' }) },
        ...(body === undefined ? {} : { body: binary ? body as BodyInit : JSON.stringify(body) }),
      })
      let result: unknown
      try { result = await response.json() } catch { throw new CloudFailure(controller.signal.aborted ? 'unknown_result' : 'bad_response', 502) }
      if (!response.ok) {
        const code = result && typeof result === 'object' && 'error' in result && typeof result.error === 'string' ? result.error : 'request_failed'
        const expired = code === 'asr_failed' && result && typeof result === 'object'
          && 'reason' in result && result.reason === 'asr_submission_expired'
        throw new CloudFailure(expired ? 'asr_submission_expired' : code, response.status)
      }
      return result as T
    } catch (error) {
      if (error instanceof CloudFailure) throw error
      throw new CloudFailure(controller.signal.aborted ? 'unknown_result' : 'network_failed', 0)
    } finally { clearTimeout(timer) }
  }
}

export const growthConnection = new GrowthConnection()
export function useGrowthConnection(): ConnectionSnapshot {
  return useSyncExternalStore(growthConnection.subscribe, growthConnection.getSnapshot, () => EMPTY)
}
