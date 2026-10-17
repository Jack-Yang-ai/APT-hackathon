import { Mic, Pause, Play, Square } from 'lucide-react'

import { cn } from '@/shared/lib/cn'
import { formatMinutes, formatRecordingClock } from '@/shared/growth/format'
import type { RecorderSnapshot } from '@/shared/growth/recorder'

/** 白色录音卡片：显示控制器确认的状态、实际帧时长与可用操作。 */
export function RecordControl({
  snapshot,
  available,
  unavailableReason,
  onStart,
  onPause,
  onResume,
  onFinish,
}: {
  snapshot: RecorderSnapshot
  /** 当前宿主是否具备录音能力（电脑预览里没有） */
  available: boolean
  unavailableReason?: string
  onStart: () => void
  onPause: () => void
  onResume: () => void
  onFinish: () => void
}) {
  const { state, ready, phase, elapsedSec, segmentLimitSec, segmentElapsedSec } = snapshot
  const busy = state === 'busy'
  const recording = state === 'recording'
  const paused = state === 'paused'
  const recovering = state === 'recovering'

  const primaryAction = recording || recovering ? onFinish : paused ? onResume : onStart
  const primaryLabel = recovering ? '保存并结束' : recording ? '结束记录' : paused ? '继续记录' : '开始记录'

  const headline = !available
    ? '录音不可用'
    : state === 'idle'
      ? '随时开始记录'
      : recording
        ? formatRecordingClock(elapsedSec)
        : paused
          ? '已暂停'
          : recovering ? '录音待恢复'
          : phase === 'reading' ? '正在读取音频…' : phase === 'saving' ? '正在保存…' : phase === 'stopping' ? '正在收尾…'
          : phase === 'initializing' ? '正在读取录音…' : '正在启动麦克风…'

  const detail = !available
    ? (unavailableReason ?? '当前环境不能录音')
    : state === 'idle'
      ? snapshot.backgroundSupported ? '点右侧开始，锁屏可持续录音' : '点右侧开始；切后台会保存并暂停'
      : recording
        ? snapshot.backgroundSupported ? `锁屏持续录音 · 每 ${Math.round(segmentLimitSec / 60)} 分钟保存一段`
          : `本段 ${formatRecordingClock(segmentElapsedSec)} / ${Math.round(segmentLimitSec / 60)} 分钟自动接续`
        : paused
          ? `已录 ${formatMinutes(elapsedSec)}，可以接着录`
          : recovering ? '点右侧重试保存并结束，请保留 App'
          : '请稍候，确认保存后再离开'

  return (
    <section className="apt-panel">
      <div className="mb-4 flex items-center justify-between gap-2">
        <h2 className="apt-section-title flex items-center gap-2"><Mic className="size-4 text-primary" aria-hidden />今天的记录</h2>
        <span className="text-caption text-muted-foreground">{snapshot.backgroundSupported ? 'Neo 采集' : '本机采集'}</span>
      </div>
      <div className="flex items-center gap-3">
      <div className="min-w-0 flex-1">
        <p className="flex items-center gap-2">
          {recording && (
            <span className="relative flex size-2 shrink-0" aria-hidden>
              <span className="absolute inline-flex size-full animate-ping rounded-full bg-primary/40" />
              <span className="relative inline-flex size-2 rounded-full bg-primary" />
            </span>
          )}
          <span className="truncate text-hero font-semibold tabular-nums">{headline}</span>
        </p>
        <p className="mt-1 line-clamp-2 text-caption">{detail}</p>
      </div>

      <div className="flex shrink-0 items-center gap-2">
        {(recording || paused) && (
          <button
            type="button"
            onClick={recording ? onPause : onFinish}
            disabled={busy}
            aria-label={recording ? '暂停记录' : '保存并结束'}
            className="flex size-11 items-center justify-center rounded-full bg-primary-soft text-primary active:opacity-80 disabled:opacity-50"
          >
            {recording ? <Pause className="size-5" aria-hidden /> : <Square className="size-5" aria-hidden />}
          </button>
        )}
        <button
          type="button"
          onClick={primaryAction}
          disabled={busy || !available || (!ready && !recovering)}
          aria-label={primaryLabel}
          className={cn(
            'flex size-16 items-center justify-center rounded-full transition-transform duration-fast active:scale-95',
            available
              ? 'bg-primary text-primary-foreground'
              : 'bg-muted text-muted-foreground',
            'disabled:opacity-60',
          )}
        >
          {recording || recovering ? (
            <Square className="size-6" fill="currentColor" aria-hidden />
          ) : paused ? (
            <Play className="size-7" fill="currentColor" aria-hidden />
          ) : (
            <Mic className="size-7" aria-hidden />
          )}
        </button>
      </div>
      </div>
    </section>
  )
}
