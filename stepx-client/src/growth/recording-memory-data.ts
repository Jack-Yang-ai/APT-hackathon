import { projectedEvents } from './source-scope'
import type { Sources } from './source-scope'
import type { TranscriptLine } from './processing-data'

export interface RecordingSource {
  id: string; revision: number; created: string; updated: string
  title: string; text: string; partial: boolean; deleted: boolean
}
export interface MemoryRow {
  id: string; recordingId: string; jobId: string; record: RecordingSource; acknowledged: number
  delegated?: boolean
}
export interface DesiredMemory {
  id: string; recordingId: string; jobId: string
  created: string; title: string; text: string; partial: boolean
}
const date = (ms: number) => {
  if (!Number.isFinite(ms) || !Number.isFinite(new Date(ms).getTime())) throw new Error('录音日期无法核验，原材料已保留')
  return new Date(ms).toISOString()
}
const day = (ms: number) => date(ms + 8 * 3600000).slice(0, 10)
const bytes = (text: string) => new TextEncoder().encode(text).length
/** Exact shape and property order of the shared Worker's canonical recording record. */
export function canonicalRecording(record: RecordingSource, namespace: string): object {
  return { device_id: namespace.toLowerCase(), id: record.id.toLowerCase(), revision: record.revision,
    created: date(Date.parse(record.created)), updated: date(Date.parse(record.updated)),
    title: record.deleted ? '已移出记忆' : record.title, text: record.deleted ? '' : record.text,
    partial: record.partial, deleted: record.deleted }
}
function validLine(line: TranscriptLine, start: number, duration: number): boolean {
  return !!line && Number.isSafeInteger(line.line_id) && line.line_id > 0 && typeof line.text === 'string' && !!line.text.trim()
    && Number.isFinite(line.t_sec) && Number.isFinite(line.t_end_sec) && line.t_sec >= start
    && line.t_end_sec >= line.t_sec && line.t_end_sec <= duration + 0.5
}
/** The content library is read only. Transport pieces never manufacture semantic events. */
export function projectRecordingMemory(source: Sources, onUnavailable: () => void = () => {}): DesiredMemory[] {
  const validTime = (value: number) => Number.isFinite(value) && Number.isFinite(new Date(value).getTime())
  const eligibleMatters = source.matters.filter(row => !row.recordingTimeUnverified && validTime(row.startedAt))
  const eligibleSegments = source.segments.filter(row => row.cloudEligible !== false && validTime(row.capturedAt)
    && validTime(row.capturedAt + row.durationSec * 1000) && row.durationSec > 0 && row.durationSec <= 601
    && eligibleMatters.some(matter => matter.id === row.matterId && matter.startedAt <= row.capturedAt))
  const eligibleJobs = source.jobs.filter(job => {
    const segment = eligibleSegments.find(row => row.id === job.id && row.matterId === job.recordingId)
    const matter = eligibleMatters.find(row => row.id === job.recordingId)
    const start = segment && matter ? (segment.capturedAt - matter.startedAt) / 1000 : NaN
    return !!segment && !!matter && Array.isArray(job.lines)
      && job.lines.every(line => validLine(line, start, start + segment.durationSec))
  })
  // A continuation cannot borrow a title or summary from excluded private material.
  const result: DesiredMemory[] = [], events = projectedEvents({
    matters: eligibleMatters, segments: eligibleSegments, jobs: eligibleJobs,
  })
  for (const job of source.jobs.filter(row => !row.id.startsWith('__'))) {
    const matter = source.matters.find(row => row.id === job.recordingId)
    const segment = source.segments.find(row => row.id === job.id && row.matterId === job.recordingId)
    if (!matter || !segment || segment.cloudEligible === false
      || !Array.isArray(job.lines) || !job.lines.length) continue
    if (!eligibleSegments.includes(segment) || !eligibleMatters.includes(matter)) { onUnavailable(); continue }
    const pieces = source.segments.filter(row => row.matterId === matter.id).sort((a, b) => a.index - b.index)
    const partial = matter.endedAt === null || matter.captureComplete === false
      || pieces.some((row, index) => row.index !== index || !eligibleSegments.includes(row)
        || !eligibleJobs.some(work => work.id === row.id && work.recordingId === matter.id)
        || !source.jobs.some(work => work.id === row.id && work.recordingId === matter.id && work.state === 'done' && work.lines !== undefined))
      || job.lines.some(line => line?.redacted || line?.is_gap)
    const start = (segment.capturedAt - matter.startedAt) / 1000, duration = start + segment.durationSec
    const marker = (reason: string): DesiredMemory => ({
      id: matter.id + '/' + job.id + '/unavailable', recordingId: matter.id, jobId: job.id,
      created: date(segment.capturedAt), title: 'StepX 录音 · 原话暂不可用', partial: true,
      text: JSON.stringify({ schema: 'apt.recording-source/1', platform: 'stepx',
        recording_id: matter.id, segment_id: job.id, unavailable: reason,
        note: '原话和录音完整留在手机；本标记不是转写正文，不能据此回答内容事实。' }),
    })
    if (!Number.isFinite(start) || start < 0 || !Number.isFinite(duration) || duration < start || job.lines.length > 2000
      || new Set(job.lines.map(line => line?.line_id)).size !== job.lines.length
      || job.lines.some(line => !validLine(line, start, duration))) {
      result.push(marker('invalid_or_oversized_transcript')); continue
    }
    const lines = job.lines.filter(line => !line.redacted), projected: DesiredMemory[] = []
    const relevant = events.filter(event => event.recordingId === matter.id && event.segmentIds.includes(job.id))
    let cursor = 0, unavailable = false
    while (cursor < lines.length) {
      const firstAt = matter.startedAt + lines[cursor].t_sec * 1000
      let end = Math.min(cursor + 8, lines.length)
      for (let next = cursor + 1; next < end; next++) {
        if (day(firstAt) !== day(matter.startedAt + lines[next].t_sec * 1000)) { end = next; break }
      }
      let row: DesiredMemory
      for (;;) {
        const group = lines.slice(cursor, end), ids = new Set(group.map(line => line.line_id))
        const scoped = relevant.filter(event => event.lineIds.some(id => ids.has(id)))
        const text = JSON.stringify({ schema: 'apt.recording-source/1', platform: 'stepx',
          recording_id: matter.id, segment_id: job.id, transcript_revision: job.lineRevision ?? 0,
          session_started_at: date(matter.startedAt), segment_index: segment.index, fragment: true, partial,
          events: scoped.map(event => ({ semantic_id: event.id, title: event.title, latest_title: event.latestTitle,
            ...(event.lineIds.every(id => ids.has(id)) ? { ai_summary: event.summary } : {}) })),
          lines: group.map(line => ({ line_id: line.line_id, text: line.text,
            start_ms: line.t_sec * 1000, end_ms: line.t_end_sec * 1000,
            is_gap: line.is_gap, cluster_tag: line.cluster_tag, person_id: line.person_id ?? null,
            actor_tag: line.actor_tag ?? null })),
        })
        row = { id: matter.id + '/' + job.id + '/' + group[0].line_id,
          recordingId: matter.id, jobId: job.id, created: date(firstAt),
          title: ('StepX · ' + (scoped[0]?.title ?? '录音原话')).slice(0, 256), text, partial }
        if (text.length <= 15000) break
        if (end === cursor + 1) { unavailable = true; break }
        end--
      }
      if (unavailable) break
      projected.push(row!)
      cursor = end
    }
    if (unavailable || projected.length > 900 || projected.reduce((sum, row) => sum + bytes(row.text), 0) > 6 * 1024 * 1024)
      result.push(marker('transcript_exceeds_read_replica_capacity'))
    else result.push(...projected)
  }
  return result
}
