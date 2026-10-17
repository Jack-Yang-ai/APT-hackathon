import type { Matter, Segment } from './types'
import type { ProcessingJob, TranscriptLine, UnderstoodEvent, PreviousContext } from './processing-data'

export interface Sources { matters: Matter[]; segments: Segment[]; jobs: ProcessingJob[] }
export interface ScopedEvent extends UnderstoodEvent { lines: TranscriptLine[]; segmentIds: string[]; revisions:number[] }
export interface EventRef { eventId: string; recordingId: string; fingerprint: string }
const lineValue = (line: TranscriptLine) => [line.line_id,line.text,line.cluster_tag,line.t_sec,line.t_end_sec,line.is_gap,line.person_id??null,line.actor_tag??null,line.redacted??false]
export const lineStamp = (lines: TranscriptLine[]) => JSON.stringify(lines.map(lineValue))

/** Validate all inputs, including the previous semantic root used by the model. */
export function projectedEvents(source: Sources): ScopedEvent[] {
  const roots = new Map<string, ScopedEvent>()
  const invalid = new Set<string>()
  for (const job of [...source.jobs].filter(row => !row.id.startsWith('__')).sort((a,b) => a.index-b.index)) {
    const matter = source.matters.find(row => row.id === job.recordingId)
    const segment = source.segments.find(row => row.id === job.id && row.matterId === job.recordingId)
    const frozen = job.requestLines, lines = job.lines
    let valid = !!matter && !!segment && job.state === 'done' && !!lines && !!frozen
      && lineStamp(lines) === lineStamp(frozen) && new Set(lines.map(row => row.line_id)).size === lines.length
      && (job.requestRevision===undefined || job.requestRevision===(job.lineRevision??0))
    const context = frozen?.[0]?.stream_context
    if (context) {
      const prior = roots.get(`${job.recordingId}:${context.event_id}`)
      const canonical=prior&&matter?previousContext(prior,matter.startedAt):undefined
      // Older frozen requests used IDB UUID order for tail text. Prove that exact
      // legacy ordering from still-valid sources; never accept arbitrary old text.
      const earlier=source.jobs.filter(row=>row.recordingId===job.recordingId&&row.index<job.index&&row.state==='done'&&prior?.segmentIds.includes(row.id))
      const legacyTail=(ordered:ProcessingJob[])=>ordered.flatMap(row=>row.lines??[]).filter(line=>prior?.lineIds.includes(line.line_id)).slice(-12).map(line=>line.text).join('\n').slice(-1600)
      const tails=[canonical?.tail,legacyTail(earlier),legacyTail([...earlier].sort((a,b)=>a.id<b.id?-1:a.id>b.id?1:0))]
      const rootIndex=prior?Math.min(...prior.segmentIds.map(id=>source.jobs.find(row=>row.id===id)!.index)):job.index
      const span=source.segments.filter(row=>row.matterId===job.recordingId&&row.index>=rootIndex&&row.index<=job.index)
      const complete=Number.isSafeInteger(job.index)&&span.length===job.index-rootIndex+1
        && new Set(span.map(row=>row.index)).size===span.length
        && span.every(row=>source.jobs.some(work=>work.id===row.id&&work.recordingId===job.recordingId&&work.state==='done'))
      valid = valid && !!prior && !invalid.has(prior.id)
        && complete && !!canonical && tails.includes(context.tail)
        && (['event_id','title','latest_title','summary','t_end_sec'] as const).every(field=>context[field]===canonical[field])
    }
    for (const event of job.events ?? []) {
      const prior = roots.get(event.id)
      const cited = (lines ?? []).filter(row => event.lineIds?.includes(row.line_id))
      const continued = context?.event_id === event.semanticId
      if (!valid || invalid.has(event.id) || event.recordingId !== job.recordingId
        || event.id !== `${job.recordingId}:${event.semanticId}` || !event.lineIds?.length
        || cited.length !== event.lineIds.length || cited.some(row => row.is_gap || row.redacted)
        || JSON.stringify(cited.map(row=>row.line_id))!==JSON.stringify(event.lineIds)
        || (continued ? !prior : cited[0]?.line_id !== event.semanticId)
        || (!continued && prior) || (continued && event.title !== prior!.title)
        || event.startedAt !== matter!.startedAt + Math.min(...cited.map(row => row.t_sec))*1000
        || event.endedAt !== matter!.startedAt + Math.max(...cited.map(row => row.t_end_sec))*1000) {
        invalid.add(event.id); roots.delete(event.id); continue
      }
      roots.set(event.id, { ...event, title: prior?.title ?? event.title,
        startedAt: prior?.startedAt ?? event.startedAt, endedAt: Math.max(prior?.endedAt ?? 0,event.endedAt),
        lineIds: [...(prior?.lineIds ?? []), ...event.lineIds], lines: [...(prior?.lines ?? []), ...cited],
        segmentIds: [...(prior?.segmentIds ?? []), job.id],revisions:[...(prior?.revisions??[]),job.lineRevision??0] })
    }
  }
  return [...roots.values()].filter(event => !invalid.has(event.id)).sort((a,b)=>b.startedAt-a.startedAt)
}
export function previousContext(event: ScopedEvent, startedAt: number): PreviousContext {
  return { event_id: event.semanticId, title: event.title, latest_title: event.latestTitle,
    summary: event.summary, tail: event.lines.slice(-12).map(line=>line.text).join('\n').slice(-1600),
    t_end_sec: (event.endedAt-startedAt)/1000 }
}
/** Whole-record actions require a closed recording, every piece, and completed ASR. No truncation. */
export function recordingMaterial(source: Sources, recordingId: string): { stamp: string; lines: TranscriptLine[]; session: string } {
  const matter = source.matters.find(row=>row.id===recordingId)
  const segments = source.segments.filter(row=>row.matterId===recordingId).sort((a,b)=>a.index-b.index)
  if (!matter || matter.endedAt === null || matter.captureComplete===false || !segments.length || segments.some(row=>row.cloudEligible===false)
    || segments.some((row,index)=>row.index!==index)) throw new Error('整场录音尚未保存完整；等待尾段和转写完成后再识别')
  const jobs = segments.map(segment=>source.jobs.find(job=>job.id===segment.id && job.recordingId===recordingId))
  if (jobs.some(job=>!job || job.state!=='done' || !job.lines || !job.session)) throw new Error('等待整场转写和整理完成后再识别')
  const lines = jobs.flatMap(job=>job!.lines!)
  if (lines.length>2000 || new Set(lines.map(line=>line.line_id)).size!==lines.length) throw new Error('整场原话超出当前识别范围，材料已保留')
  const stamp = JSON.stringify([matter.id,matter.startedAt,matter.endedAt,matter.captureComplete??null,
    segments.map(segment=>[segment.id,segment.index,segment.capturedAt,segment.durationSec,segment.sizeBytes,segment.cloudEligible]),
    jobs.map(job=>[job!.id,job!.lineRevision??0,lineStamp(job!.lines!)])])
  return { stamp, lines: structuredClone(lines), session: jobs[0]!.session! }
}
export function fragmentMaterial(source:Sources, jobId:string):{stamp:string;revision:number} {
  const job=source.jobs.find(row=>row.id===jobId),matter=source.matters.find(row=>row.id===job?.recordingId)
  if(!job||!matter||!job.lines)throw new Error('分片来源已变化')
  const start=job.semanticStart??0
  if(!Number.isSafeInteger(start)||start<0||start>job.index)throw new Error('分片语义起点无法核验')
  if(start>0&&source.segments.some(piece=>piece.matterId===job.recordingId&&piece.index===start-1&&piece.cloudEligible!==false
    &&source.jobs.some(prior=>prior.id===piece.id&&prior.state==='done')))throw new Error('语义断点前的来源已变化')
  const pieces=source.segments.filter(row=>row.matterId===job.recordingId&&row.index>=start&&row.index<=job.index).sort((a,b)=>a.index-b.index)
  if(pieces.length!==job.index-start+1 || pieces.some((row,index)=>row.index!==start+index||row.cloudEligible===false))throw new Error('分片来源不完整')
  const work=pieces.map(piece=>source.jobs.find(row=>row.id===piece.id&&row.recordingId===job.recordingId))
  if(work.some(row=>!row?.lines || (row.id!==job.id&&row.state!=='done')))throw new Error('前序原话尚未就绪')
  return {stamp:JSON.stringify([matter.id,matter.startedAt,pieces.map(row=>[row.id,row.index,row.capturedAt,row.durationSec,row.sizeBytes]),
    work.map(row=>[row!.id,row!.lineRevision??0,lineStamp(row!.lines!),row!.id===job.id?null:[row!.requestLines??null,row!.events??null]])]),
    revision:work.reduce((sum,row)=>sum+(row!.lineRevision??0),0)}
}
export const eventStamp = (event: ScopedEvent) => JSON.stringify([event.id,event.recordingId,event.title,event.latestTitle,event.summary,event.startedAt,event.endedAt,event.segmentIds,event.revisions,lineStamp(event.lines)])
export async function fingerprint(stamp: string): Promise<string> {
  return [...new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(stamp)))].map(byte=>byte.toString(16).padStart(2,'0')).join('')
}
export async function eventRef(event: ScopedEvent): Promise<EventRef> {
  return { eventId:event.id,recordingId:event.recordingId,fingerprint:await fingerprint(eventStamp(event)) }
}
export async function resolveEvent(source: Sources, ref: EventRef): Promise<ScopedEvent> {
  const event = projectedEvents(source).find(row=>row.id===ref.eventId && row.recordingId===ref.recordingId)
  if (!event || await fingerprint(eventStamp(event))!==ref.fingerprint) throw new Error('这件事的来源已变化，请回到详情重新带入；问题仍保留')
  return event
}
export function eventBackground(event: ScopedEvent): string {
  const text = `【这件事】\n${event.title}\n${event.summary}\n【仅这件事的原话】\n${event.lines.map(line=>`${line.line_id} | ${line.text}`).join('\n')}`
  if (text.length>24000) throw new Error('这件事的原话超出对话范围，请先缩小问题范围')
  return text
}
