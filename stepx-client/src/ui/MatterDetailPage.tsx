import { useEffect, useRef, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { ListPlus, Pause, Play } from 'lucide-react'

import { Link } from 'react-router-dom'
import { ActionRecognition } from '../components/ActionRecognition'
import { PersonalCandidates } from '../components/PersonalCandidates'
import { usePageTitle } from '../layout/PageTitle'
import { Button } from '@/shared/ui/Button'
import { EmptyState } from '@/shared/ui/Feedback'
import { cn } from '@/shared/lib/cn'
import { growthStore, useGrowth } from '@/shared/growth/store'
import { useGrowthRuntime } from '@/shared/growth/runtime'
import { growthProcessing, useGrowthProcessing, PROCESSING_LABEL } from '@/shared/growth/processing'
import { retryMatter } from '@/shared/growth/upload'
import { useGrowthConnection } from '@/shared/growth/connection'
import type { ProcessingJob, TranscriptLine } from '@/shared/growth/processing-data'
import { formatClock, formatDuration, formatMinutes, formatRange } from '@/shared/growth/format'
import type { Matter, Segment } from '@/shared/growth/types'
import { readNativeAudio } from '@/shared/growth/recording-audio'

function recordingRange(matter: Matter): string {
  return matter.recordingTimeUnverified ? '录制时间尚未确认' : formatRange(matter.startedAt, matter.endedAt)
}
function recordingOrigin(matter: Matter): string {
  return matter.recoveredFromNative ? '从这台手机恢复 · 仅保存在本机' : matter.origin === 'record' ? '这台手机录制' : '文件导入'
}

/**
 * 一次**录音记录**的详情。
 *
 * 三样东西各归各位，不要混：
 *  - **事**：云端按事整理出来的产物（`processing.events`），只信这个，本地不猜；
 *  - **原话**：转写回来的逐句文字（`job.lines`），带出处时间；说话人只给"未确认分组"，不断言是谁；
 *  - **音频**：本机的原始分段，处理到哪一步都保留，随时可回放。
 */
export function MatterDetailPage() {
  useGrowthRuntime()
  const { id = '' } = useParams()
  const snapshot = useGrowth()
  const processing = useGrowthProcessing()
  const connection = useGrowthConnection()
  const navigate = useNavigate()
  const matter = growthStore.getMatter(id)
  const segments = snapshot.segments.filter((s) => s.matterId === id)
  const jobs = processing.jobs.filter((job) => job.recordingId === id)
  const events = processing.events.filter((event) => event.recordingId === id)

  usePageTitle(matter ? matter.recoveredFromNative ? '恢复的录音' : recordingRange(matter) : '记录')

  if (!snapshot.ready) {
    return (
      <div className="page">
        <p className="text-body text-muted-foreground">正在打开这段录音…</p>
      </div>
    )
  }
  if (!matter) {
    return (
      <div className="page">
        <EmptyState title="这段录音不在了" description="可能已经被删除。" />
      </div>
    )
  }

  const recordedSec = segments.reduce((sum, s) => sum + s.durationSec, 0)
  const hasFailure = jobs.some((job) => job.state === 'failed')
  const lines = collectLines(jobs)
  const localOnly = segments.length > 0 && segments.every(segment => segment.cloudEligible === false)

  return (
    <div className="page apt-stack">
      <section className="space-y-2">
        <h2 className="apt-group-title">事</h2>
        {events.length > 0 ? (
          <ul className="space-y-2">
            {events.map((event) => (
              <li key={event.id} className="apt-panel">
                <Link to={`/events/${encodeURIComponent(event.id)}`} className="text-body font-medium text-primary">{event.title}</Link>
                <p className="mt-1 whitespace-pre-wrap text-body">{event.summary}</p>
                <p className="mt-1 text-caption text-muted-foreground">
                  {formatRange(event.startedAt, event.endedAt)}
                  {event.latestTitle !== event.title && ` · 最新进展：${event.latestTitle}`}
                </p>
                {/* 只是把这条事带过去当来源；要不要做、做什么、什么时候做都由用户自己写 */}
                <button
                  type="button"
                  onClick={() =>
                    navigate('/actions', {
                      state: { actionSource: { recordingId: event.recordingId, eventId: event.id } },
                    })
                  }
                  className="mt-1 flex min-h-tap items-center gap-1 text-caption font-medium text-primary active:opacity-70"
                >
                  <ListPlus className="size-4" aria-hidden />
                  加到行动
                </button>
              </li>
            ))}
          </ul>
        ) : (
          <div className="apt-panel">
            <p className="text-caption text-muted-foreground">{localOnly ? '恢复的原音频仅保存在本机，还没有转写和整理。' : describeNoEvent(jobs, connection.ready)}</p>
            <button
              type="button"
              onClick={() =>
                navigate('/actions', { state: { actionSource: { recordingId: matter.id } } })
              }
              className="mt-1 flex min-h-tap items-center gap-1 text-caption font-medium text-primary active:opacity-70"
            >
              <ListPlus className="size-4" aria-hidden />
              加到行动
            </button>
          </div>
        )}
      </section>

      <section className="apt-settings-group">
        <InfoRow label="时间范围" value={recordingRange(matter)} />
        <InfoRow label="录音时长" value={recordedSec > 0 ? formatMinutes(recordedSec) : '未知'} />
        <InfoRow label="分段" value={`${segments.length} 段`} />
        <InfoRow label="来源" value={recordingOrigin(matter)} />
      </section>

      {processing.error && (
        <div className="apt-panel">
          <p className="text-body text-danger">{processing.error}</p>
          <Button
            variant="outline"
            className="mt-2"
            onClick={() => void growthProcessing.retryStorage().catch(() => undefined)}
          >
            重试
          </Button>
        </div>
      )}

      {hasFailure && <RetryButton matterId={matter.id} />}

      <section className="space-y-2">
        <h2 className="apt-group-title">原话</h2>
        {lines.length === 0 ? (
          <p className="text-body text-muted-foreground">{localOnly ? '原音频可在下面播放，尚未转写。' : describeNoLines(jobs, connection.ready)}</p>
        ) : (
          <ul className="apt-settings-group">
            {lines.map(({ line }) => (
              <li key={line.line_id} className="list-row items-start py-3">
                <span className="w-12 shrink-0 pt-0.5 text-caption text-muted-foreground tabular-nums">
                  {formatClock(matter.startedAt + line.t_sec * 1000)}
                </span>
                <span className="min-w-0 flex-1">
                  <span className="block whitespace-pre-wrap text-body">{line.text}</span>
                  {line.cluster_tag && (
                    <span className="mt-0.5 block text-caption text-muted-foreground">
                      未确认分组 {line.cluster_tag}
                    </span>
                  )}
                </span>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section className="space-y-2">
        <h2 className="apt-group-title">录音分段</h2>
        {segments.length === 0 ? (
          <p className="text-body text-muted-foreground">这次录音没有留下分段。</p>
        ) : (
          <ul className="apt-settings-group">
            {segments.map((segment) => {
              const job = jobs.find((row) => row.id === segment.id)
              return <SegmentRow key={segment.id} segment={segment} job={job} />
            })}
          </ul>
        )}
      </section>

      <ActionRecognition recordingId={matter.id}/>
      <PersonalCandidates recordingId={matter.id}/>
    </div>
  )
}

/** 只收集真的转写回来的句子，按时间排序 */
function collectLines(jobs: ProcessingJob[]): { line: TranscriptLine }[] {
  return jobs
    .flatMap((job) => job.lines ?? [])
    .slice()
    .sort((a, b) => a.t_sec - b.t_sec)
    .map((line) => ({ line }))
}

function describeNoEvent(jobs: ProcessingJob[], connected: boolean): string {
  if (jobs.some((job) => job.state === 'failed')) return '有分段处理未完成，重试之后才会出整理结果。'
  if (jobs.some((job) => job.state !== 'done')) return '还在处理：转写和按事整理完成后，结果会出现在这里。'
  if (jobs.length > 0 && jobs.every((job) => (job.lines ?? []).length === 0)) {
    return '这段录音没有识别到文字，原音频已保留。'
  }
  return connected ? '还没有整理出的事。' : '连上 Apt 云代理后会自动转写、按事整理。'
}

function describeNoLines(jobs: ProcessingJob[], connected: boolean): string {
  if (jobs.some((job) => job.state === 'failed')) return '有分段处理未完成，重试之后才会出逐字稿。'
  if (jobs.some((job) => job.state !== 'done')) return '还在转写，完成后逐字稿会出现在这里。'
  if (jobs.length > 0) return '没有识别到文字，原音频已保留。'
  return connected ? '还没有可展示的逐字稿。' : '连上 Apt 云代理后会自动转写。'
}

/** 失败分片的重试：报错也要说出来，不能点了没反应 */
function RetryButton({ matterId }: { matterId: string }) {
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  return (
    <div>
      <Button
        variant="outline"
        block
        loading={busy}
        onClick={() => {
          if (busy) return
          setBusy(true)
          setError('')
          void retryMatter(matterId)
            .catch((failure: unknown) => {
              setError(failure instanceof Error ? failure.message : '重试未能开始，请稍后再试')
            })
            .finally(() => setBusy(false))
        }}
      >
        重试没处理完的分段
      </Button>
      {error && (
        <p role="alert" className="mt-1 text-caption text-danger">
          {error}
        </p>
      )}
    </div>
  )
}

function InfoRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="list-row min-h-tap py-3">
      <span className="flex-1 text-body text-muted-foreground">{label}</span>
      <span className="text-body">{value}</span>
    </div>
  )
}

function SegmentRow({ segment, job }: { segment: Segment; job?: ProcessingJob }) {
  const failed = job?.state === 'failed'
  const noText = job?.state === 'done' && (job.lines ?? []).length === 0
  const status = segment.cloudEligible === false ? '仅保存在本机' : job ? PROCESSING_LABEL[job.state] : '待上传'
  return (
    <li className="list-row py-3">
      <SegmentAudio segment={segment} />
      <div className="min-w-0 flex-1">
        <p className="text-body">
          第 {segment.index + 1} 段
          <span className="ml-2 text-caption text-muted-foreground">{formatClock(segment.capturedAt)}</span>
        </p>
        {/* 处理状态取回执；失败要能一眼看见，它是需要人处理的 */}
        <p className={cn('mt-0.5 text-caption', failed ? 'text-danger' : 'text-muted-foreground')}>
          {segment.durationSec > 0 ? formatDuration(segment.durationSec) : '时长未知'} · {status}
          {failed && job?.error ? ` · ${job.error}` : ''}
          {noText ? ' · 没有识别到文字，原音频已保留' : ''}
        </p>
      </div>
    </li>
  )
}

/** 分段回放：优先用存在本机的那份（壳给的虚拟 URL 过了会话就取不到了） */
function SegmentAudio({ segment }: { segment: Segment }) {
  const audioRef = useRef<HTMLAudioElement>(null)
  const [src, setSrc] = useState<string | null>(null)
  const [playing, setPlaying] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [attempt, setAttempt] = useState(0)

  useEffect(() => {
    let objectUrl: string | null = null
    let cancelled = false
    setSrc(null); setPlaying(false); setError(null)
    void (async () => {
      let blob = await growthStore.getAudio(segment.id)
      if (!blob?.size) {
        blob = await readNativeAudio({ tempFilePath: segment.localUrl, size: segment.sizeBytes, duration: segment.durationSec })
        if (!cancelled) await growthStore.commitCapturedAudio({ ...segment, cloudEligible: false }, blob)
      }
      if (cancelled) return
      if (blob && blob.size > 0) {
        objectUrl = URL.createObjectURL(blob)
        setSrc(objectUrl)
      } else setError('音频还未读取，点此重试')
    })().catch(() => { if (!cancelled) setError('播放未完成，点此重试') })
    return () => {
      cancelled = true
      if (objectUrl) URL.revokeObjectURL(objectUrl)
    }
  }, [segment.id, segment.localUrl, segment.sizeBytes, segment.durationSec, attempt])

  return (
    <div className="flex w-16 shrink-0 flex-col items-center gap-1">
      <button
        type="button"
        disabled={!src && !error}
        aria-label={error ? '重试播放这一段' : playing ? '暂停播放' : '播放这一段'}
        onClick={() => {
          if (error) { setAttempt(value => value + 1); return }
          const audio = audioRef.current
          if (!audio) return
          if (audio.paused) void audio.play().catch(() => { setPlaying(false); setError('播放未完成，点此重试') })
          else audio.pause()
        }}
        className="flex size-11 shrink-0 items-center justify-center rounded-full bg-primary-soft text-primary transition-transform duration-fast active:scale-95"
      >
        {playing ? <Pause className="size-5" aria-hidden /> : <Play className="size-5" aria-hidden />}
      </button>
      {error && <p role="alert" className="text-caption text-danger">{error}</p>}
      {src && <audio
        ref={audioRef}
        src={src}
        preload="metadata"
        onPlay={() => setPlaying(true)}
        onPause={() => setPlaying(false)}
        onEnded={() => setPlaying(false)}
        onError={() => { setPlaying(false); setError('播放未完成，点此重试') }}
        className="hidden"
      />}
    </div>
  )
}
