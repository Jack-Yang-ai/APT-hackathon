import { useState } from 'react'
import { Mic, Pause, Play, Square, ChevronDown } from 'lucide-react'
import { recorder, useRecorder } from '@/shared/growth/recording-controller'
import { useRecordingAvailability } from '@/shared/growth/runtime'
import { formatDuration } from '@/shared/growth/format'

/** Neo's compact device row retains real pause/stop controls even while folded. */
export function CaptureBar() {
  const status = useRecorder(), available = useRecordingAvailability(), [expanded, setExpanded] = useState(false)
  const busy = ['busy', 'recovering'].includes(status.state), active = status.state === 'recording', paused = status.state === 'paused'
  return <section className="pb-5" aria-label="Neo 录音">
    <div className="flex items-center gap-2">
      <Mic className="size-3.5 shrink-0 text-muted-foreground" aria-hidden />
      <button className="flex min-h-11 min-w-0 flex-1 items-center gap-1 text-left text-caption text-muted-foreground" onClick={() => setExpanded(!expanded)} aria-expanded={expanded}>
        <span className="truncate">{active ? '正在录音' : status.interrupted ? '录音已中断' : paused ? '已暂停' : busy ? '正在保存' : 'Neo 录音'}{status.elapsedSec > 0 ? ` · ${formatDuration(status.elapsedSec)}` : ''}</span><ChevronDown className={`size-3 shrink-0 ${expanded ? 'rotate-180' : ''}`} aria-hidden />
      </button>
      {active ? <button className="apt-icon-button" onClick={() => void recorder.pause()} aria-label="暂停录音"><Pause className="size-4" aria-hidden /></button>
        : <button disabled={busy || available !== true} className="apt-icon-button" aria-label={paused ? '继续录音' : '开始录音'} onClick={() => void (paused ? recorder.resume() : recorder.start())}><Play className="size-4" aria-hidden /></button>}
      {(active || paused || busy) && <button className="apt-icon-button" onClick={() => void recorder.finish()} aria-label="结束并保存"><Square className="size-4" aria-hidden /></button>}
    </div>
    {(expanded || status.error || status.interrupted) && <div className="space-y-2 pb-2 text-caption text-muted-foreground">
      <p>{available === false ? '电脑预览不能录音，请在 Neo 打开。' : status.notice ?? '录音先保存在手机上，整理完成后按事件展示。'}</p>
      {status.error && <><p role="alert" className="text-foreground">{status.error}</p><button className="min-h-11 text-primary" onClick={() => void recorder.retryRecovery()}>保存重试</button></>}
    </div>}
  </section>
}
