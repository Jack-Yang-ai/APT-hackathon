import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { projectedEvents, eventStamp, eventRef, type ScopedEvent } from '@/shared/growth/source-scope'
import { readSources } from '@/shared/growth/idb'
import { AptGlyph } from './AptGlyph'

export function ContinueAsk({ event, label = '继续问', question = '这件事目前定了什么，还有哪些没定？' }: { event: ScopedEvent; label?: string; question?: string }) {
  const navigate = useNavigate(), [busy, setBusy] = useState(false), [error, setError] = useState('')
  return <div><button className="apt-pill !text-caption" disabled={busy} onClick={() => {
    if (busy) return
    setBusy(true); setError('')
    void (async () => {
      const fresh = projectedEvents(await readSources()).find(row => row.id === event.id)
      if (!fresh || eventStamp(fresh) !== eventStamp(event)) throw new Error('来源已变化，请重新打开这件事')
      navigate('/ask', { replace: true, state: { eventRef: await eventRef(fresh), question } })
    })().catch(error => setError(error instanceof Error ? error.message : '背景未能带入')).finally(() => setBusy(false))
  }}><AptGlyph kind="ask" size={18} />{label}</button>{error && <p role="alert" className="apt-meta mt-2">{error}</p>}</div>
}
