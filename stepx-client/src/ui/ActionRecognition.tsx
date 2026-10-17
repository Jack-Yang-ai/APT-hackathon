import { useState } from 'react'
import { personalProcessing, usePersonalActions } from '@/shared/growth/personal-processing'
export function ActionRecognition({recordingId}:{recordingId:string}) {
  const snapshot=usePersonalActions(),row=snapshot.evaluations.find(row=>row.recordingId===recordingId),[busy,setBusy]=useState(false),[error,setError]=useState('')
  const running=row&&['queued','running'].includes(row.state)
  return <section className="apt-panel space-y-2"><h2 className="apt-section-title">个人行动识别</h2>
    <p className="text-caption text-muted-foreground">{running?'正在核对整场原话…':row?.state==='failed'?row.error:row?.state==='done'?'已完成整场识别；候选需要确认后才会保存。':'尚未按新版识别。完成整场保存和转写后可以识别。'}</p>
    <button disabled={busy||!!running} className="min-h-11 text-caption text-primary disabled:opacity-40" onClick={()=>{
      if(busy)return;setBusy(true);setError('');void personalProcessing.recognize(recordingId).catch(error=>setError(error instanceof Error?error.message:'识别未开始')).finally(()=>setBusy(false))
    }}>{busy?'正在准备…':row?'重新识别个人行动':'识别个人行动'}</button>
    {(error||snapshot.error)&&<p role="alert" className="text-caption text-danger">{error||snapshot.error}</p>}
  </section>
}
