import { useState } from 'react'
import { usePersonalActions } from '@/shared/growth/personal-processing'
import { candidateSuppressed } from '@/shared/growth/personal-action-data'
import type { PersonalCandidate } from '@/shared/growth/personal-action-data'
import { currentEvaluations } from '@/shared/growth/personal-action-data'
import { useGrowth } from '@/shared/growth/store'
import { useGrowthProcessing } from '@/shared/growth/processing'
import type { ProcessingJob } from '@/shared/growth/processing-data'
import { actionsStore, useActions } from '@/shared/growth/actions'
import { ActionForm } from './ActionForm'
const LABEL={accepted:'承诺／决定',request:'尚未接下的请求',follow_up:'依赖跟进建议'}
export function PersonalCandidates({recordingId,lineIds}:{recordingId?:string;lineIds?:number[]}) {
  const personal=usePersonalActions(),actions=useActions(),[selected,setSelected]=useState<PersonalCandidate|undefined>(),[error,setError]=useState(''),[pending,setPending]=useState<string|null>(null)
  const source=useGrowth(),processing=useGrowthProcessing()
  const current={...source,jobs:[...processing.jobs,...personal.evaluations as unknown as ProcessingJob[]]}
  const candidates=source.matters.flatMap(matter=>currentEvaluations(current,matter.id).flatMap(row=>row.candidates??[])).filter(row=>(!recordingId||row.recordingId===recordingId)
    && (!lineIds||lineIds.includes(row.lineId)&&row.evidence.every(evidence=>lineIds.includes(evidence.lineId)))
    && !candidateSuppressed([...actions.actions,...actions.ignored],row))
  if(!candidates.length&&!selected)return null
  return <section className="apt-stack">{candidates.length>0&&<><h2 className="apt-section-title">从记录中确认</h2>
    <p className="text-caption text-muted-foreground">已核对后续动作和上下文；说话人尚未确认，保存前请核对归属。</p>
    {error&&<p role="alert" className="text-caption text-danger">{error}</p>}
    {candidates.map(candidate=><div className="apt-panel space-y-3" key={candidate.id}>
      <p className="text-caption font-semibold text-primary">{LABEL[candidate.kind]}</p><p className="apt-section-title">{candidate.title}</p>
      {candidate.provisional&&<p className="text-caption text-muted-foreground">录音还会继续，结束后会结合整场原话再次核对。</p>}
      {candidate.evidence.map((row,index)=><p key={index} className={index===0?'apt-lead apt-secondary whitespace-pre-wrap':'apt-meta whitespace-pre-wrap'}>“{row.quote}”</p>)}
      {candidate.condition&&<p className="apt-meta">条件 · {candidate.condition}</p>}
      {candidate.deadline&&<p className="apt-meta">期限 · {candidate.deadline}</p>}
      <p className="apt-meta">当前原话 · AI 提取</p>
      <div className="flex flex-wrap gap-3"><button disabled={pending!==null} className="min-h-11 text-caption text-primary" onClick={()=>setSelected(candidate)}>确认并保存</button>
        <button disabled={pending!==null} className="min-h-11 text-caption text-muted-foreground" onClick={()=>{
          if(pending)return;setPending(candidate.id);setError('');void actionsStore.ignore(candidate).catch(error=>setError(error instanceof Error?error.message:'忽略未保存')).finally(()=>setPending(null))
        }}>忽略这项</button></div>
    </div>)}</>}
    <ActionForm open={!!selected&&candidates.some(row=>row.id===selected.id)} candidate={selected} onClose={()=>setSelected(undefined)}/>
  </section>
}
