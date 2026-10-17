import { useEffect, useState } from 'react'
import { useGrowth } from '@/shared/growth/store'
import { useGrowthProcessing } from '@/shared/growth/processing'
import { readSources } from '@/shared/growth/idb'
import { projectedEvents, resolveEvent, eventStamp, type EventRef } from '@/shared/growth/source-scope'
import { formatClock } from '@/shared/growth/format'
import { Sheet } from './UI'

/** Opening a citation keeps the current chat/topic mounted and never displays a cached transcript. */
export function QuoteSheet({ target, onClose }: { target: EventRef | null; onClose: () => void }) {
  const source = useGrowth(), processing = useGrowthProcessing()
  const key = target ? JSON.stringify(target) : ''
  const [verified, setVerified] = useState<{ key: string; stamp: string }>(), [error, setError] = useState('')
  useEffect(() => {
    setVerified(undefined); setError('')
    if (!target) return
    let cancelled = false
    void readSources().then(current => resolveEvent(current, target)).then(event => {
      if (!cancelled) setVerified({ key, stamp: eventStamp(event) })
    }).catch(error => { if (!cancelled) setError(error instanceof Error ? error.message : '原话未能读取') })
    return () => { cancelled = true }
  }, [key])
  const event = target ? projectedEvents({ ...source, jobs: processing.jobs }).find(row => row.id === target.eventId && row.recordingId === target.recordingId) : undefined
  const allowed = event && verified?.key === key && verified.stamp === eventStamp(event)
  const matter = event && source.matters.find(row => row.id === event.recordingId)
  return <Sheet open={!!target} title="这件事的原话" onClose={onClose}>
    {allowed && matter ? <><h3 className="apt-section-title">{event.title}</h3><p className="apt-meta mt-2">分组尚未确认身份。</p>
      <ul>{event.lines.map(line => <li className="apt-transcript-row" key={line.line_id}><time>{formatClock(matter.startedAt + line.t_sec * 1000)}</time><p className="min-w-0 flex-1 whitespace-pre-wrap text-body">{line.text}</p></li>)}</ul>
    </> : <p role="status" className="apt-lead">{error || (verified ? '这条出处已变化或移出记忆，不能再展示旧原话。' : '正在核验当前原话…')}</p>}
  </Sheet>
}
