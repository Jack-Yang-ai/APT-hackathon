import { useState } from 'react'
import { Button } from '@/shared/ui/Button'
import { growthConnection, useGrowthConnection } from '@/shared/growth/connection'
import { recordingMemory, useRecordingMemory } from '@/shared/growth/recording-memory'
import { backgroundProcessing, useBackgroundProcessing } from '@/shared/growth/background'

export function ConnectionSection() {
  const connection = useGrowthConnection()
  const memory = useRecordingMemory()
  const background = useBackgroundProcessing()
  const [token, setToken] = useState('')
  const [busy, setBusy] = useState(false)
  const [localError, setLocalError] = useState('')

  async function handleConnect() {
    if (busy || !token.trim()) return
    setBusy(true)
    setLocalError('')
    try {
      await growthConnection.connect(token)
      setToken('') // 连上之后清空输入框，不回填已保存的令牌
    } catch (error) {
      setLocalError(error instanceof Error ? error.message : '连接未能完成，请重试')
    } finally {
      setBusy(false)
    }
  }

  async function handleDisconnect() {
    if (busy) return
    setBusy(true)
    setLocalError('')
    try {
      await growthConnection.disconnect()
    } catch (error) {
      // 清除没成功就**不能**显示成断开完成：把原因露出来，让人可以再试
      setLocalError(error instanceof Error ? error.message : '断开未能完成，请重试')
    } finally {
      setBusy(false)
    }
  }

  /**
   * 错误行的「重试」：按当前真实状态挑动作，不做无用功。
   *  - 还认为持有一份凭据 → 说明上次是**清除没做完**，重试清除；
   *  - 否则 → 重试读取（init 失败时会重置标记，能真正再读一次）并尝试重连。
   */
  async function handleRetry() {
    if (busy) return
    setBusy(true)
    setLocalError('')
    try {
      if (growthConnection.getSnapshot().hasCredential) {
        await growthConnection.disconnect()
      } else {
        await growthConnection.init()
        await growthConnection.reconnect()
      }
    } catch (error) {
      setLocalError(error instanceof Error ? error.message : '重试未能完成')
    } finally {
      setBusy(false)
    }
  }

  const message = localError || connection.error

  return (
    <section className="space-y-2">
      <h2 className="apt-group-title">云端连接</h2>
      <div className="apt-panel">
        <p className="apt-section-title">APT 云端</p>

        {connection.ready ? (
          <>
            <p className="mt-2 apt-lead text-primary">已连接</p>
            {connection.health && (
              <p className="mt-0.5 text-caption text-muted-foreground">
                对话{connection.health.chatConfigured ? '已配置' : '未配置'} · 转写
                {connection.health.asrConfigured ? '已配置' : '未配置'}
              </p>
            )}
            <Button variant="outline" block className="mt-3" loading={busy} onClick={() => void handleDisconnect()}>
              断开连接
            </Button>
          </>
        ) : (
          <>
            <input
              type="password"
              value={token}
              onChange={(event) => setToken(event.target.value)}
              placeholder="连接令牌"
              aria-label="云端连接令牌"
              autoComplete="off"
              autoCorrect="off"
              spellCheck={false}
              className="mt-2 min-h-tap w-full rounded-md border border-input bg-background px-3 text-body outline-none focus:border-primary"
            />
            <Button
              block
              className="mt-3"
              loading={busy || connection.connecting}
              disabled={!token.trim()}
              onClick={() => void handleConnect()}
            >
              连接
            </Button>
          </>
        )}

        {message && (
          <p role="alert" className="mt-2 text-caption text-danger">
            {message}
            <button type="button" onClick={() => void handleRetry()} className="ml-2 text-primary">
              重试
            </button>
          </p>
        )}
        <p className="mt-2 text-caption text-muted-foreground">
          连接凭据只保存在这台手机上；电脑预览只保留当前标签页会话。
        </p>
      </div>
      <div className="apt-panel">
        <p className="apt-section-title">Mac 输入法记忆</p>
        <p className="mt-2 text-body">
          {memory.running ? '正在核对录音来源…' : memory.ready
            ? '已同步 ' + (memory.acknowledged+background.sources) + ' 条 · 待同步 ' + (memory.pending+background.pending) + ' 条'
            : '等待读取本机录音来源'}
        </p>
        <p className="mt-2 text-caption text-muted-foreground">
          录音分片在后台上传、转写、整理并同步，熄屏后会继续。Mac 只能查询已同步的内容；手机上的原件保留。
        </p>
        {background.recordings>0&&<p className="mt-2 text-caption text-muted-foreground">
          后台已整理 {background.done} / {background.total} 片{background.preparing>0?' · 正在交接已有录音':''}
          {background.controls>0?' · 有修改等待后台确认':''}
        </p>}
        {background.failed>0&&<p role="alert" className="mt-2 text-caption text-danger">{background.failed} 片处理未完成，可在录音详情重试；原音频已保留。</p>}
        {background.error&&<p role="alert" className="mt-2 text-caption text-danger">{background.error}</p>}
        {!connection.ready && <p className="mt-2 text-caption text-muted-foreground">连接云端后继续同步；Mac 只能查已成功同步的范围。</p>}
        {memory.unavailable > 0 && <p className="mt-2 text-caption text-danger">{memory.unavailable} 份来源的时间或格式待核验，仍保留在手机，尚未供 Mac 查询。</p>}
        {memory.error && <p role="alert" className="mt-2 text-caption text-danger">{memory.error}</p>}
        <Button variant="outline" block className="mt-3" loading={memory.running}
          onClick={() => {void recordingMemory.kick();void backgroundProcessing.kick()}}>重新核对与同步</Button>
      </div>
    </section>
  )
}
