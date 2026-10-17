import { useEffect, useRef, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { usePageTitle } from '../layout/PageTitle'
import { useGrowthRuntime } from '@/shared/growth/runtime'
import { growthStore, useGrowth } from '@/shared/growth/store'
import { useGrowthProcessing } from '@/shared/growth/processing'
import { projectedEvents, eventStamp } from '@/shared/growth/source-scope'
import { readSources } from '@/shared/growth/idb'
import { formatClock, formatRange } from '@/shared/growth/format'
import { PersonalCandidates } from '../components/PersonalCandidates'
import { ContinueAsk } from '../components/ContinueAsk'
import { Empty } from '../components/UI'

export function EventPage() { return <EventContent transcript={false} /> }
export function EventTranscriptPage() { return <EventContent transcript /> }
function EventContent({ transcript }: { transcript: boolean }) {
  useGrowthRuntime()
  const { id = '' } = useParams(), source = useGrowth(), processing = useGrowthProcessing()
  const [pane, setPane] = useState<'highlights' | 'details'>('highlights')
  const event = projectedEvents({ ...source, jobs: processing.jobs }).find(row => row.id === id)
  usePageTitle(transcript ? '原话' : '这件事')
  if (!event) return <div className="page"><Empty title="这件事的来源已变化或尚未核验。" /><Link to="/recordings" className="apt-pill">查看保留的原录音</Link></div>
  const matter = source.matters.find(row => row.id === event.recordingId)!
  return <div className="page" style={{ paddingTop: 4, paddingBottom: 32 }}>
    {transcript ? <>
      <p className="apt-meta py-3">{event.title} · 分组尚未确认身份。</p>
      <ul>{event.lines.map(line => <li className="apt-transcript-row" key={line.line_id}><time>{formatClock(matter.startedAt + line.t_sec * 1000)}</time><p className="min-w-0 flex-1 whitespace-pre-wrap break-words text-body">{line.text}</p></li>)}</ul>
      <div className="apt-stack py-4">{event.segmentIds.map(segmentId => {
        const segment = source.segments.find(row => row.id === segmentId)!, job = processing.jobs.find(row => row.id === segmentId)!
        const lines = (job.lines ?? []).filter(line => event.lineIds.includes(line.line_id)), offset = (segment.capturedAt - matter.startedAt) / 1000
        return <EventAudio key={`${segmentId}:${eventStamp(event)}`} eventId={event.id} stamp={eventStamp(event)} segmentId={segmentId} start={Math.max(0, Math.min(...lines.map(line => line.t_sec)) - offset)} end={Math.min(segment.durationSec || job.seconds || 0, Math.max(...lines.map(line => line.t_end_sec)) - offset)} />
      })}</div>
    </> : <>
      <header className="apt-event-heading"><h1 className="apt-detail-title">{event.title}</h1><p className="apt-lead mt-1 text-muted-foreground">{formatRange(event.startedAt, event.endedAt)}</p></header>
      <div className="apt-segments mb-2" role="group" aria-label="看哪一栏"><button aria-pressed={pane === 'highlights'} onClick={() => setPane('highlights')}>重点</button><button aria-pressed={pane === 'details'} onClick={() => setPane('details')}>详情</button></div>
      <p className="apt-meta py-2">分组尚未确认身份。</p>
      {pane === 'highlights' ? <section className="space-y-4 pt-4"><p className="whitespace-pre-wrap break-words text-section font-semibold">{event.summary}</p><ContinueAsk event={event} label="问问这件事" /></section>
        : <section className="apt-event-details space-y-3"><p className="apt-meta">{formatRange(event.startedAt, event.endedAt)}</p><h2 className="text-section font-semibold">{event.latestTitle}</h2><p className="whitespace-pre-wrap break-words text-body leading-relaxed">{event.summary}</p><ContinueAsk event={event} /></section>}
      <div className="mt-6"><PersonalCandidates recordingId={event.recordingId} lineIds={event.lineIds} /></div>
    </>}
    <Link to={`/recordings/${encodeURIComponent(event.recordingId)}`} className="mt-4 flex min-h-11 items-center text-caption text-muted-foreground">查看原录音与处理</Link>
  </div>
}
function EventAudio({eventId,stamp,segmentId,start,end}:{eventId:string;stamp:string;segmentId:string;start:number;end:number}) {
  const [audio]=useState(()=>new Audio()),[playing,setPlaying]=useState(false),[error,setError]=useState('')
  const live=useRef(true),busy=useRef(false)
  useEffect(()=>{
    live.current=true
    let deadline:ReturnType<typeof setTimeout>|undefined
    const time=()=>{if(audio.currentTime>=end||audio.currentTime<start-0.05){audio.pause();setPlaying(false)}}
    const started=()=>{clearTimeout(deadline);deadline=setTimeout(()=>{audio.pause();if(live.current)setPlaying(false)},Math.max(0,(end-audio.currentTime)*1000))}
    const paused=()=>clearTimeout(deadline)
    const ended=()=>setPlaying(false);audio.addEventListener('timeupdate',time);audio.addEventListener('ended',ended)
    audio.addEventListener('playing',started);audio.addEventListener('pause',paused)
    return()=>{live.current=false;clearTimeout(deadline);audio.pause();audio.removeEventListener('timeupdate',time);audio.removeEventListener('ended',ended);audio.removeEventListener('playing',started);audio.removeEventListener('pause',paused);if(audio.src.startsWith('blob:'))URL.revokeObjectURL(audio.src);audio.removeAttribute('src')}
  },[audio,start,end])
  return <div><button className="apt-pill !text-caption" onClick={()=>{
    if(playing){audio.pause();setPlaying(false);return}if(busy.current)return;busy.current=true;setError('')
    void (async()=>{
      if(end<=start)throw new Error('音频范围尚未核验，请查看原录音')
      if(!audio.src){const blob=await growthStore.getAudio(segmentId);if(!live.current)return;if(!blob)throw new Error('本机音频未能读取，原件仍保留');audio.src=URL.createObjectURL(blob);await new Promise<void>((resolve,reject)=>{audio.onloadedmetadata=()=>resolve();audio.onerror=()=>reject(new Error('音频无法播放'))})}
      const fresh=projectedEvents(await readSources()).find(row=>row.id===eventId)
      if(!fresh||eventStamp(fresh)!==stamp)throw new Error('音频来源已变化，请重新打开这件事')
      if(!live.current)return;audio.currentTime=start;await audio.play();if(live.current)setPlaying(true);else audio.pause()
    })().catch(error=>{if(live.current)setError(error instanceof Error?error.message:'播放未开始')}).finally(()=>{busy.current=false})
  }}>{playing?'暂停':'播放这件事的音频'}</button>{error&&<p className="text-caption text-danger">{error}</p>}</div>
}
