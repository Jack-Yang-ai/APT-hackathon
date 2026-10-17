import { useEffect, useState } from 'react'
import { useLocation, useNavigate } from 'react-router-dom'
import { Plus } from 'lucide-react'
import { ActionsSection } from '../components/ActionsSection'
import { PersonalCandidates } from '../components/PersonalCandidates'
import { ActionForm } from '../components/ActionForm'
import { Intro } from '../components/UI'
import { ACTION_LABELS, type ActionStatus, type ActionSource } from '@/shared/growth/actions'
import { useGrowthRuntime } from '@/shared/growth/runtime'

let lastFilter: ActionStatus | null = null
export function ActionsPage() {
  useGrowthRuntime()
  const location = useLocation(), navigate = useNavigate()
  const [selected, setSelected] = useState<ActionStatus | null>(lastFilter), [adding, setAdding] = useState(false)
  const [incomingSource, setIncomingSource] = useState<ActionSource>()
  useEffect(() => {
    const handoff = location.state as { actionSource?: ActionSource } | null
    if (!handoff?.actionSource) return
    setIncomingSource(handoff.actionSource); setAdding(true)
    navigate(location.pathname, { replace: true, state: null })
  }, [location.state, location.pathname, navigate])
  return <div className="page apt-stack">
    <Intro title="让下一步清楚一点。" trailing={<button className="apt-icon-button -mt-2" aria-label="新增行动" onClick={() => { setIncomingSource(undefined); setAdding(true) }}><Plus className="size-5" aria-hidden /></button>}>你的行动、需要确认的事，都留在这里。</Intro>
    <div className="apt-filters" role="group" aria-label="行动状态筛选">{([null, ...Object.keys(ACTION_LABELS)] as (ActionStatus | null)[]).map(status => <button key={status ?? 'all'} className="apt-pill" aria-pressed={selected === status} onClick={() => { lastFilter = status; setSelected(status) }}>{status ? ACTION_LABELS[status] : '全部'}</button>)}</div>
    <ActionsSection selected={selected} />
    {(selected === null || selected === 'confirm') && <PersonalCandidates />}
    <ActionForm open={adding} source={incomingSource} onClose={() => setAdding(false)} />
  </div>
}
