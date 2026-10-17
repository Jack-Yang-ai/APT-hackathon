import { useEffect, useState } from 'react'
import { Link, useLocation, useNavigate, useParams } from 'react-router-dom'
import { ActionForm } from './ActionForm'
import { ContinueAsk } from './ContinueAsk'
import { Empty, Info } from './UI'
import { actionsStore, useActions, actionStatus, actionPhase, actionOrigin, ACTION_LABELS, type ActionStatus, type GrowthAction } from '@/shared/growth/actions'
import { useGrowth } from '@/shared/growth/store'
import { useGrowthProcessing } from '@/shared/growth/processing'
import { usePersonalActions } from '@/shared/growth/personal-processing'
import type { ProcessingJob } from '@/shared/growth/processing-data'
import { useGrowthRuntime } from '@/shared/growth/runtime'
import { usePageTitle } from '../layout/PageTitle'

function dueLabel(ms: number) { return new Date(ms).toLocaleString('zh-CN', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' }) }
function useActionOrigins() {
  const source = useGrowth(), processing = useGrowthProcessing(), personal = usePersonalActions()
  const current = { ...source, jobs: [...processing.jobs, ...personal.evaluations as unknown as ProcessingJob[]] }
  return (action: GrowthAction) => {
    if (!source.ready || (action.source?.evaluationId && !personal.ready)) return { warning: '正在核验出处…', event: undefined, quote: undefined, to: undefined }
    return actionOrigin(action, current)
  }
}

export function ActionsSection({ selected }: { selected: ActionStatus | null }) {
  const snapshot = useActions(), origin = useActionOrigins()
  const shown = snapshot.actions.filter(action => !action.removedAt && (selected === null || actionStatus(action) === selected))
  if (!snapshot.ready) return <p className="apt-meta py-3">正在读取行动…</p>
  return <section className="apt-stack">
    {snapshot.error && <div className="apt-panel"><p role="alert" className="apt-lead">{snapshot.error}</p><button className="min-h-11 text-primary" onClick={() => void actionsStore.refresh().catch(() => undefined)}>重新读取</button></div>}
    {shown.map(action => <Link key={action.id} to={`/actions/${encodeURIComponent(action.id)}`} className="apt-panel block space-y-2.5">
      <p className="text-caption font-semibold text-primary">{ACTION_LABELS[actionStatus(action)]}</p><h2 className="apt-section-title">{action.title}</h2>
      {action.nextStep && <p className="apt-lead apt-secondary">下一步 · {action.nextStep}</p>}
      {(action.deadline || action.dueAt !== null) && <p className="apt-meta">期限 · {action.deadline || dueLabel(action.dueAt!)}</p>}
      {origin(action).warning && <p className="apt-meta">{origin(action).warning}</p>}
    </Link>)}
    {!shown.length && !snapshot.error && <div className="apt-panel"><Empty title={selected === null ? '从一件想做的事开始。' : `这里暂时没有${ACTION_LABELS[selected]}的行动。`}>点右上角新增，也可以从录音提取结果里确认。</Empty></div>}
  </section>
}

export function ActionDetailPage() {
  useGrowthRuntime(); usePageTitle('行动详情')
  const { id = '' } = useParams(), snapshot = useActions(), originFor = useActionOrigins(), navigate = useNavigate(), location = useLocation()
  const action = snapshot.actions.find(row => row.id === id && !row.removedAt)
  const [editing, setEditing] = useState(false), [busy, setBusy] = useState(false), [error, setError] = useState('')
  useEffect(() => {
    if (!(location.state as { editAction?: boolean } | null)?.editAction || !action) return
    setEditing(true); navigate(location.pathname, { replace: true, state: null })
  }, [location.state, location.pathname, action?.id, navigate])
  const run = async (operation: () => Promise<void>) => {
    if (busy) return; setBusy(true); setError('')
    try { await operation() } catch (error) { setError(error instanceof Error ? error.message : '行动未能更新') } finally { setBusy(false) }
  }
  if (!action) return <div className="page"><Empty title={snapshot.ready ? '这条行动已移除或无法读取。' : '正在读取行动…'} /><Link to="/actions/removed" className="apt-pill">查看已移除</Link></div>
  const origin = originFor(action), status = actionStatus(action)
  const question = `一起讨论这件行动：${action.title}\n下一步：${action.nextStep ?? ''}\n期限：${action.deadline || (action.dueAt !== null ? dueLabel(action.dueAt) : '未设置')}\n条件：${action.condition ?? ''}\n协作人／依赖：${action.collaborators ?? ''}`
  return <div className="page apt-detail-stack" style={{ paddingTop: 20 }}>
    <p className="apt-lead font-semibold text-primary">{ACTION_LABELS[status]}</p><h1 className="apt-page-intro">{action.title}</h1>
    <Info label="下一步">{action.nextStep || '还没填写'}</Info><Info label="期限">{action.dueAt !== null ? dueLabel(action.dueAt) : '尚未设置具体时间'}</Info>
    {action.deadline && <Info label="期限说明">{action.deadline}</Info>}<Info label="条件">{action.condition || '尚未填写'}</Info><Info label="协作人／依赖">{action.collaborators || '尚未填写'}</Info>
    {origin.warning && <p className="apt-lead">{origin.warning}</p>}
    {action.source ? <section className="apt-panel space-y-2.5"><h2 className="apt-section-title">当前出处</h2>{origin.quote && <p className="whitespace-pre-wrap text-body">{origin.quote}</p>}
      {origin.to ? <Link to={origin.to} className="flex min-h-11 items-center text-primary apt-lead">查看录音详情与原话</Link> : <p className="apt-meta">原来源未能读取。</p>}</section> : <Info label="来源">你手动创建的行动</Info>}
    {origin.event ? <ContinueAsk event={origin.event} label="继续讨论这件行动" question={question} /> : <button className="apt-pill" onClick={() => navigate('/ask', { replace: true, state: { question } })}>继续讨论这件行动</button>}
    <div className="apt-settings-group">
      {status === 'done' || status === 'cancelled' ? <button className="apt-setting-row text-primary" disabled={busy} onClick={() => void run(() => actionsStore.setStatus(id, actionPhase(action)))}>恢复行动</button> : <>
        <button className="apt-setting-row text-primary" disabled={busy} onClick={() => void run(() => actionsStore.setStatus(id, 'done'))}>标记已完成</button>
        <button className="apt-setting-row text-primary" disabled={busy} onClick={() => void run(() => actionsStore.setStatus(id, 'cancelled'))}>取消行动</button></>}
      <button className="apt-setting-row text-primary" disabled={busy} onClick={() => void run(async () => { await actionsStore.remove(id); navigate('/actions', { replace: true }) })}>移除行动</button>
    </div><p className="apt-meta">移除后可在行动页的“已移除”里恢复。</p>
    {error && <p role="alert" className="apt-lead">{error}</p>}
    <ActionForm open={editing} action={action} onClose={() => setEditing(false)} />
  </div>
}

export function RemovedActionsPage() {
  usePageTitle('已移除')
  const snapshot = useActions(), [busy, setBusy] = useState<string | null>(null), [error, setError] = useState('')
  const removed = snapshot.actions.filter(row => row.removedAt), ignored = snapshot.ignored.filter(row => row.removedAt !== null)
  async function restore(id: string, operation: () => Promise<void>) {
    if (busy) return; setBusy(id); setError('')
    try { await operation() } catch (error) { setError(error instanceof Error ? error.message : '恢复未保存') } finally { setBusy(null) }
  }
  return <div className="page apt-stack" style={{ paddingTop: 20 }}>
    {error && <p role="alert" className="apt-lead">{error}</p>}
    {!removed.length && !ignored.length && <Empty title="没有已移除的行动或候选。" />}
    {removed.map(action => <section className="apt-panel space-y-2" key={action.id}><h2 className="apt-section-title">{action.title}</h2><p className="apt-meta">移除前 · {ACTION_LABELS[actionStatus(action)]}</p><button disabled={busy !== null} className="min-h-11 apt-lead text-primary" onClick={() => void restore(action.id, () => actionsStore.restore(action.id))}>恢复行动</button></section>)}
    {ignored.map(row => <section className="apt-panel space-y-2" key={row.id}><h2 className="apt-section-title">已忽略的候选</h2><p className="apt-meta">恢复后会按当前来源重新核验。</p><button disabled={busy !== null} className="min-h-11 apt-lead text-primary" onClick={() => void restore(row.id, () => actionsStore.restoreIgnored(row.id))}>恢复候选</button></section>)}
  </div>
}
