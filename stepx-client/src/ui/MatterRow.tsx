import { Link } from 'react-router-dom'

import type { Matter, Segment } from '@/shared/growth/types'
import type { ProcessingJob } from '@/shared/growth/processing-data'
import { formatMinutes, formatRange } from '@/shared/growth/format'
import { useRecorder } from '@/shared/growth/recording-controller'

/**
 * 一次**录音记录**在列表里的一行（界面上的「录音记录」，不是语义事）。
 *
 * 状态一律取处理回执（`jobs`）而不是本机那段旧阶段；时长仍用采集到的真实秒数
 * （处理还没跑起来时，秒数是唯一可说的东西）。标题用时间范围——真正的标题由
 * 云端按事整理产出，这里不替它编。
 */
export function MatterRow({
  matter,
  segments,
  jobs,
}: {
  matter: Matter
  segments: Segment[]
  jobs: ProcessingJob[]
}) {
  const recordedSec = segments.reduce((sum, s) => sum + s.durationSec, 0)
  const recording = useRecorder()
  const title = matter.title ?? (matter.recoveredFromNative ? '恢复的录音' : formatRange(matter.startedAt, matter.endedAt))
  const active = recording.matterId === matter.id
  const progress = active && recording.state === 'recording' ? `正在录音 · ${formatMinutes(recording.elapsedSec)}`
    : active && recording.state === 'recovering' ? '保存未完成，回到此刻重试'
    : active && recording.state === 'busy' ? '正在确认录音状态…'
    : active && recording.state === 'paused' ? `已暂停 · ${segments.length} 段已保存`
    : describe(segments.length, jobs, recordedSec, segments.every(segment => segment.cloudEligible === false))

  return (
    <li className="list-row">
      <Link to={`/recordings/${matter.id}`} className="block min-w-0 flex-1 py-3">
        <p className="text-body font-medium">{title}</p>
        <p className="mt-1 line-clamp-2 text-caption text-muted-foreground">{progress}</p>
      </Link>
    </li>
  )
}

/** 一句进展：说清这段材料现在到哪一步，不堆技术词，也不替云端下结论 */
function describe(segmentCount: number, jobs: ProcessingJob[], recordedSec: number, localOnly: boolean): string {
  // 导入的录音壳不解析媒体元数据，时长为 0——这时如实说"未知"
  const clock = recordedSec > 0 ? formatMinutes(recordedSec) : '时长未知'
  const prefix = `${segmentCount} 段录音 · ${clock}`

  if (segmentCount === 0) return '尚未保存音频 · 旧记录已保留'
  if (localOnly) return `${prefix} · 仅保存在本机`
  if (jobs.length === 0) return `${prefix} · 待上传`

  const failed = jobs.filter((job) => job.state === 'failed').length
  if (failed > 0) return `有 ${failed} 段处理未完成，点开可以重试`

  const moving = jobs.filter((job) => job.state === 'pending' || job.state === 'uploading').length
  if (moving > 0) return `${prefix} · ${moving} 段待上传`

  const extracting = jobs.filter((job) => job.state === 'extracting').length
  if (extracting > 0) return `${prefix} · 正在按事整理`

  const transcribing = jobs.filter((job) => job.state === 'transcribing').length
  if (transcribing > 0) return `${prefix} · 等待转写`

  const done = jobs.filter((job) => job.state === 'done')
  if (done.length === jobs.length) {
    const noText = done.filter((job) => (job.lines ?? []).length === 0).length
    return noText === done.length ? `${prefix} · 没有识别到文字，原音频已保留` : `${prefix} · 已整理`
  }
  return prefix
}
