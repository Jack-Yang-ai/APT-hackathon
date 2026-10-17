import type { ActionEvaluation } from './personal-action-data'
export const SEMANTIC_RECIPE = 'v3-semantic-continuity'
export interface TranscriptLine {
  line_id: number; text: string; cluster_tag: string | null; t_sec: number; t_end_sec: number; is_gap: false
  recipe?: string; streaming?: boolean; stream_context?: PreviousContext
  action_protocol?: string; action_only?: boolean; action_request?: string; source_revision?: number
  person_id?: string | null; actor_tag?: string; redacted?: boolean
}
export interface PreviousContext { event_id: number; title: string; latest_title: string; summary: string; tail: string; t_end_sec: number }
export interface UnderstoodEvent { id: string; semanticId: number; recordingId: string; title: string; latestTitle: string; summary: string; lineIds: number[]; startedAt: number; endedAt: number }
export interface ProcessingJob {
  id: string; recordingId: string; index: number
  state: 'pending' | 'uploading' | 'transcribing' | 'extracting' | 'done' | 'failed'
  remoteKey?: string; session?: string; seconds?: number; uploaded?: boolean; taskId?: string; ticket?: string
  lines?: TranscriptLine[]; requestLines?: TranscriptLine[]; events?: UnderstoodEvent[]
  lineRevision?: number; requestRevision?: number; personalEvaluation?: ActionEvaluation
  /** A controlled exclusion starts a new semantic root without renumbering transcript evidence. */
  semanticStart?:number
  nextAt: number; attempts: number; error?: string; retryFailed?: boolean; retryId?: string; failureCode?: string; extractionAttempt?: number; extractPart?: number
}
/** Explicit user retry only. Unknown submissions retain their original provider identity. */
export function retryProcessingJob(current:ProcessingJob):ProcessingJob {
  const job=structuredClone(current)
  if(['asr_failed','asr_cached_result_invalid','asr_submission_expired','asr_retry_authorization_required'].includes(job.failureCode??'')
    ||(job.uploaded&&!job.taskId&&job.lines===undefined)) {
    job.taskId=undefined;job.lines=undefined;job.retryFailed=true;job.retryId=crypto.randomUUID()
  }
  if(job.ticket&&['invalid_extraction_result','invalid_result'].includes(job.failureCode??'')) {
    job.extractionAttempt=(job.extractionAttempt??0)+1;job.extractPart=job.index+job.extractionAttempt*100000
    if(job.extractPart>999999)throw Error('整理重试次数已达上限，请检查服务状态')
    job.ticket=undefined
  }
  job.state=job.ticket||job.lines?'extracting':job.uploaded?'transcribing':'pending';job.error=undefined;job.nextAt=0
  return job
}
const object = (value: unknown): Record<string, unknown> | null => value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null
function milliseconds(value: unknown): number {
  if (typeof value === 'string' && value.trim()) return Number(value)
  if (typeof value === 'number') return Number.isInteger(value) ? value : value < 10000 ? value * 1000 : value
  return NaN
}
/** Same ASR time units and multi-block traversal as the native Growth parser. */
export function parseASR(receipt: unknown, segment: { index: number; capturedAt: number }, recording: { startedAt: number }, audioSeconds: number): TranscriptLine[] {
  const root = object(receipt)
  if (root?.state !== 'done' || !Array.isArray(root.result)) throw new Error('转写报文不完整，可以重试读取')
  if (!Number.isFinite(audioSeconds) || audioSeconds <= 0 || audioSeconds > 601) throw new Error('音频时长无法核验')
  const rows: Record<string, unknown>[] = []
  let recognized = root.result.length === 0
  const walk = (value: unknown, depth = 0) => {
    if (depth > 5) throw new Error('转写报文格式无法识别')
    if (Array.isArray(value)) { for (const item of value) walk(item, depth + 1); return }
    const block = object(value)
    if (!block) throw new Error('转写报文格式无法识别')
    if (block.error || ['FAIL','ERROR','BLOCK'].some(code => String(block.status ?? '').toUpperCase().includes(code))) throw new Error('转写服务返回失败，原音频已保留')
    if (Object.keys(block).length === 0) { recognized = true; return }
    let found = false, nonempty = false
    for (const name of ['utterances', 'sentences', 'segments']) {
      if (!(name in block)) continue
      if (!Array.isArray(block[name])) throw new Error('转写分句容器格式无效')
      found = true; recognized = true
      for (const row of block[name] as unknown[]) {
        const parsed = object(row); if (!parsed || parsed.error || typeof parsed.text !== 'string'
          || ['FAIL','ERROR','BLOCK'].some(code => String(parsed.status ?? '').toUpperCase().includes(code))) throw new Error('转写原话格式无效')
        if (typeof parsed.text === 'string' && parsed.text.trim()) nonempty = true
        if (!rows.some(existing => JSON.stringify(existing) === JSON.stringify(parsed))) rows.push(parsed)
      }
    }
    let nested = false
    for (const name of ['result', 'data', 'transcript', 'transcription']) {
      const value = block[name]
      if (value !== undefined && value !== null && (Array.isArray(value) || object(value))) { nested = true; walk(value, depth + 1) }
    }
    // Text-only formats need an explicit parser, rather than a false empty result.
    const textOnly = ['text','transcript','transcription'].some(name => typeof block[name] === 'string' && (block[name] as string).trim())
    if (textOnly && !nonempty) throw new Error('转写含文字但没有有效分句，原音频已保留')
    if (found || nested) return
    throw new Error('转写报文格式无法识别，原音频已保留')
  }
  walk(root.result)
  if (!recognized || rows.length > 2000) throw new Error('转写报文格式无法识别')
  if (!Number.isSafeInteger(segment.index) || segment.index < 0 || segment.index > 999999) throw new Error('分片编号无效')
  const lines: TranscriptLine[] = []
  for (const row of rows) {
    if (typeof row.text !== 'string') throw new Error('转写原话格式无效')
    const text = row.text.trim(); if (!text) continue
    if (text.length > 16000) throw new Error('转写原话过长')
    let start = milliseconds(row.start_time ?? row.start ?? row.begin_time)
    let end = milliseconds(row.end_time ?? row.end ?? row.finish_time)
    // Real StepFun file results can pad an utterance end beyond the WAV while
    // its complete word alignment remains correct. Recover only from all words,
    // matching the exact sentence, with every word inside the real source.
    if (Number.isFinite(start) && start >= 0 && start <= audioSeconds * 1000
      && (!Number.isFinite(end) || end > audioSeconds * 1000 + 500) && Array.isArray(row.words) && row.words.length) {
      let cursor = start, finalEnd = start, valid = true, alignedText = ''
      for (const rawWord of row.words) {
        const word = object(rawWord)
        if (!word || typeof word.text !== 'string' || !word.text) { valid = false; break }
        const wordStart = word.start_time === undefined ? cursor : milliseconds(word.start_time)
        const wordEnd = milliseconds(word.end_time)
        if (!Number.isFinite(wordStart) || !Number.isFinite(wordEnd) || wordStart < cursor || wordEnd < wordStart
          || wordStart > audioSeconds * 1000 || wordEnd > audioSeconds * 1000 + 500) { valid = false; break }
        alignedText += word.text; cursor = wordEnd; finalEnd = wordEnd
      }
      if (valid && alignedText.replace(/\s+/g, '') === text.replace(/\s+/g, '')) end = finalEnd
    }
    if (!Number.isFinite(start) || !Number.isFinite(end) || start < 0 || end < start || start > audioSeconds * 1000 || end > audioSeconds * 1000 + 500) throw new Error('转写时间范围无效，原音频已保留')
    const speaker = object(row.speaker)?.id ?? row.speaker ?? row.speaker_id
    const tag = typeof speaker === 'string' || typeof speaker === 'number' ? `片${segment.index}:${String(speaker).slice(0, 100)}` : null
    const offset = (segment.capturedAt - recording.startedAt) / 1000
    if (!Number.isFinite(offset) || offset < 0) throw new Error('录音时间范围无效')
    lines.push({ line_id: segment.index * 100000 + lines.length + 1, text, cluster_tag: tag,
      t_sec: offset + start / 1000, t_end_sec: offset + Math.min(end, audioSeconds * 1000) / 1000, is_gap: false })
  }
  return lines
}
export function freezeLines(lines: TranscriptLine[], previous?: PreviousContext): TranscriptLine[] {
  const frozen = structuredClone(lines)
  if (!frozen.length) return frozen
  frozen[0] = { ...frozen[0], recipe: SEMANTIC_RECIPE, streaming: true,
    ...(previous ? { stream_context: structuredClone(previous) } : {}) }
  return frozen
}
/** Only a validated continuation pointer joins events. No local semantic guessing. */
export function parseEvents(payload: unknown, job: ProcessingJob, recordingStartedAt: number): UnderstoodEvent[] {
  const root = object(payload)
  if (root?.pipeline_version !== SEMANTIC_RECIPE || !Array.isArray(root.events) || !job.requestLines?.length) throw new Error('整理结果不完整，可以重试读取')
  const lines = job.requestLines, previous = lines[0].stream_context, events: UnderstoodEvent[] = []
  const used = new Set<number>(); let priorEnd = -1
  for (const raw of root.events) {
    const event = object(raw)
    if (!event || typeof event.title !== 'string' || !event.title.trim() || (typeof event.summary !== 'string' || !event.summary.trim())
      || !Number.isSafeInteger(event.line_from) || !Number.isSafeInteger(event.line_to)) throw new Error('整理结果缺少原话出处')
    const from = lines.findIndex(line => line.line_id === event.line_from), to = lines.findIndex(line => line.line_id === event.line_to)
    if (from < 0 || to < from || from <= priorEnd) throw new Error('整理结果的原话范围无效')
    priorEnd = to
    const cited = lines.slice(from, to + 1)
    if (cited.some(line => used.has(line.line_id))) throw new Error('整理结果的原话范围重复')
    cited.forEach(line => used.add(line.line_id))
    const continuation = event.continuation_id
    if (continuation !== undefined && continuation !== null && (continuation !== previous?.event_id || events.length !== 0)) throw new Error('整理结果的延续关系无效')
    const semanticId = continuation ? previous!.event_id : cited[0].line_id
    const title = continuation ? previous!.title : event.title.trim()
    events.push({ id: `${job.recordingId}:${semanticId}`, semanticId, recordingId: job.recordingId,
      title: title.slice(0,240), latestTitle: event.title.trim().slice(0,240), summary: event.summary.slice(0,2400),
      lineIds: cited.map(line => line.line_id), startedAt: recordingStartedAt + Math.min(...cited.map(line => line.t_sec)) * 1000,
      endedAt: recordingStartedAt + Math.max(...cited.map(line => line.t_end_sec)) * 1000 })
  }
  return events
}
export function combinedEvents(jobs: ProcessingJob[]): UnderstoodEvent[] {
  const roots = new Map<string, UnderstoodEvent>()
  for (const job of [...jobs].sort((a,b)=>a.index-b.index)) for (const event of job.state === 'done' ? job.events ?? [] : []) {
    const prior = roots.get(event.id)
    roots.set(event.id, prior ? { ...event, title: prior.title, startedAt: Math.min(prior.startedAt,event.startedAt), endedAt: Math.max(prior.endedAt,event.endedAt), lineIds: [...new Set([...prior.lineIds, ...event.lineIds])] } : event)
  }
  return [...roots.values()].sort((a,b)=>b.startedAt-a.startedAt)
}
