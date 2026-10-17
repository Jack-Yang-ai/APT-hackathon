import { isVerbatim, normalizeQuote } from './quote-normalize'
import type { TranscriptLine } from './processing-data'
import { recordingMaterial, fragmentMaterial, lineStamp, type Sources } from './source-scope'

export const ACTION_PROTOCOL = 'personal-actions/v1'
export type ActionKind = 'accepted' | 'request' | 'follow_up'
export interface PersonalCandidate {
  id: string; recordingId: string; evaluationId: string; kind: ActionKind; title: string
  lineId: number; quote: string; evidence: { lineId: number; quote: string }[]
  condition: string; deadline: string; collaborators: string
  provisional: boolean
}
export interface ActionEvaluation {
  id: string; recordingId: string; requestId: string; revision: number; stamp: string; session: string
  lines: TranscriptLine[]; state: 'queued' | 'running' | 'done' | 'failed'; ticket?: string
  candidates?: PersonalCandidate[]; error?: string; nextAt: number; owner?: string; until?: number
  fragmentId?: string
}
const object = (value: unknown): Record<string,unknown> | null => value && typeof value==='object' && !Array.isArray(value) ? value as Record<string,unknown> : null
function text(value: unknown, limit=2400): string {
  if (typeof value!=='string' || value.length>limit) throw new Error('个人行动字段无效，原话已保留')
  return value.trim()
}
export function parsePersonalActions(payload: unknown, evaluation: ActionEvaluation): PersonalCandidate[] {
  const root=object(payload)
  if (root?.terminal === true) throw new Error('个人行动识别失败，请重新识别这场录音')
  if (root?.action_protocol !== ACTION_PROTOCOL || !Array.isArray(root.personal_actions)) throw new Error('尚未完成新版个人行动识别')
  const byId=new Map(evaluation.lines.map(line=>[line.line_id,line])), seen=new Set<string>()
  return root.personal_actions.map((raw,index)=>{
    const item=object(raw)
    if (!item || !['accepted','request','follow_up'].includes(String(item.kind))
      || ['who','owner','person_id'].some(field=>field in item) || !Number.isSafeInteger(item.line_id)
      || !Array.isArray(item.evidence) || !item.evidence.length) throw new Error('个人行动归属或证据无效')
    const lineId=item.line_id as number, line=byId.get(lineId), quote=text(item.quote), title=text(item.title,240)
    if (!line || line.is_gap || line.redacted || line.person_id!=null || !title || !isVerbatim(quote,line.text)) throw new Error('个人行动责任原话或归属无法核验')
    if (item.speaker_hint!==undefined && item.speaker_hint!==null && line.cluster_tag!==null && item.speaker_hint!==line.cluster_tag) throw new Error('责任发言分组不一致')
    const evidence=item.evidence.map(rawEvidence=>{
      const evidence=object(rawEvidence), id=evidence?.line_id
      const source=Number.isSafeInteger(id)?byId.get(id as number):undefined
      const quoted=text(evidence?.quote)
      if (!source || source.is_gap || source.redacted || !isVerbatim(quoted,source.text)) throw new Error('个人行动上下文原话无法核验')
      return { lineId:id as number,quote:quoted }
    })
    if (!evidence.some(row=>row.lineId===lineId)) throw new Error('个人行动缺少责任发言')
    const key=`${lineId}:${normalizeQuote(title)}`
    if (seen.has(key)) throw new Error('个人行动重复'); seen.add(key)
    return { id:`${evaluation.requestId}:${index}`,recordingId:evaluation.recordingId,evaluationId:evaluation.requestId,
      kind:item.kind as ActionKind,title,lineId,quote,evidence,provisional:!!evaluation.fragmentId,condition:text(item.condition_text),
      deadline:text(item.deadline_text),collaborators:text(item.collaborators_text) }
  })
}
export function currentEvaluation(source: Sources, recordingId: string): ActionEvaluation | undefined {
  const row=source.jobs.find(job=>job.id===`__actions__:${recordingId}`) as unknown as ActionEvaluation | undefined
  if (!row || row.state!=='done') return undefined
  try {
    const material=recordingMaterial(source,recordingId)
    if(material.stamp!==row.stamp || lineStamp(row.lines)!==lineStamp(material.lines) || !Array.isArray(row.candidates))return undefined
    const checked=parsePersonalActions({action_protocol:ACTION_PROTOCOL,personal_actions:row.candidates.map(candidate=>({
      kind:candidate.kind,title:candidate.title,line_id:candidate.lineId,quote:candidate.quote,
      evidence:candidate.evidence.map(evidence=>({line_id:evidence.lineId,quote:evidence.quote})),condition_text:candidate.condition,
      deadline_text:candidate.deadline,collaborators_text:candidate.collaborators}))},row)
    return JSON.stringify(checked)===JSON.stringify(row.candidates)?row:undefined
  } catch { return undefined }
}
export function currentEvaluations(source:Sources,recordingId:string):ActionEvaluation[] {
  const whole=currentEvaluation(source,recordingId)
  if(whole)return [whole]
  // Closing changes the required context to the full session. Never resurrect
  // an earlier provisional promise while whole-session calibration is pending.
  if(source.matters.find(row=>row.id===recordingId)?.endedAt!==null)return []
  return source.jobs.filter(job=>job.recordingId===recordingId&&job.state==='done'&&job.personalEvaluation).flatMap(job=>{
    const evaluation=job.personalEvaluation!
    try {
      if(evaluation.fragmentId!==job.id || fragmentMaterial(source,job.id).stamp!==evaluation.stamp
        || lineStamp(evaluation.lines)!==lineStamp(job.lines??[]) || !evaluation.candidates)return []
      const checked=parsePersonalActions({action_protocol:ACTION_PROTOCOL,personal_actions:evaluation.candidates.map(candidate=>({
        kind:candidate.kind,title:candidate.title,line_id:candidate.lineId,quote:candidate.quote,evidence:candidate.evidence.map(row=>({line_id:row.lineId,quote:row.quote})),
        condition_text:candidate.condition,deadline_text:candidate.deadline,collaborators_text:candidate.collaborators}))},evaluation)
      return JSON.stringify(checked)===JSON.stringify(evaluation.candidates)?[evaluation]:[]
    }catch{return []}
  })
}
export function currentCandidate(source: Sources, candidate: PersonalCandidate): PersonalCandidate {
  const evaluation=currentEvaluations(source,candidate.recordingId).find(row=>row.requestId===candidate.evaluationId)
  const current=evaluation?.candidates?.find(row=>row.id===candidate.id && row.evaluationId===candidate.evaluationId)
  if (!current || JSON.stringify(current)!==JSON.stringify(candidate)) throw new Error('行动的来源或评估已变化，请重新打开')
  return current
}
export interface IgnoredAction { id: string; type: 'ignored'; recordingId: string; lineId: number; removedAt: number | null }
export const ignoredId = (recordingId: string, lineId: number) => `__ignored__:${encodeURIComponent(recordingId)}:${lineId}`
export function candidateSuppressed(rows: unknown[], candidate: PersonalCandidate): boolean {
  return rows.some(raw=>{
    const row=raw as { type?:string; recordingId?:string; lineId?:number; removedAt?:number|null; source?:{ recordingId:string; responsibilityLineId?:number;candidateKey?:string } }
    return row.type==='ignored' ? row.recordingId===candidate.recordingId && row.lineId===candidate.lineId && row.removedAt!==null
      : row.source?.recordingId===candidate.recordingId && row.source.responsibilityLineId===candidate.lineId
        && (!!row.removedAt || !row.source.candidateKey || row.source.candidateKey===normalizeQuote(candidate.title))
  })
}
