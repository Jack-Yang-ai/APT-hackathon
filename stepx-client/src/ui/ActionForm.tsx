import { useEffect, useRef, useState } from 'react'

import { Sheet } from './UI'
import { actionsStore, actionStatus, ACTION_LABELS, type ActionStatus } from '@/shared/growth/actions'
import type { ActionSource, GrowthAction } from '@/shared/growth/actions'
import type { PersonalCandidate } from '@/shared/growth/personal-action-data'

/** 毫秒 → `<input type="datetime-local">` 需要的本地时间串 */
function toLocalInput(ms: number | null): string {
  if (ms === null) return ''
  const d = new Date(ms)
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`
}

/**
 * 行动的新增 / 编辑表单（底部弹层，两个入口共用）。
 *
 * 三条不能破的规矩：
 *  1. **先写库成功、再关弹层**——失败保留用户输入并把原因显示出来，绝不提前当成保存好了；
 *  2. **不自动安排时间**：默认没有时间，用户不选就没有；
 *  3. 从录音/事带过来的 `source` 只是**关联**，不会被当成用户已承诺的事项。
 */
export function ActionForm({
  open,
  action,
  candidate,
  source,
  onClose,
  onSaved,
}: {
  open: boolean
  /** 传入表示编辑已有行动 */
  action?: GrowthAction
  candidate?: PersonalCandidate
  /** 从详情页「加到行动」带过来的来源 */
  source?: ActionSource
  onClose: () => void
  onSaved?: () => void
}) {
  const [title, setTitle] = useState('')
  const [due, setDue] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [mine,setMine]=useState(false)
  const [status, setStatus] = useState<ActionStatus>('next')
  const [statusEdited, setStatusEdited] = useState(false)
  const [hasDue, setHasDue] = useState(false)
  const [details,setDetails]=useState({condition:'',deadline:'',collaborators:'',nextStep:''})
  // 同步锁：连点两下也只提交一次（state 更新是异步的，挡不住快速双击）
  const submitting = useRef(false)

  useEffect(() => {
    if (!open) return
    setTitle(action?.title ?? candidate?.title ?? '')
    setMine(false)
    setStatusEdited(false)
    setStatus(action ? actionStatus(action) : candidate?.kind === 'request' ? 'confirm' : candidate?.kind === 'follow_up' ? 'followup' : 'next')
    setHasDue(action?.dueAt !== null && action?.dueAt !== undefined)
    setDetails({condition:action?.condition??candidate?.condition??'',deadline:action?.deadline??candidate?.deadline??'',collaborators:action?.collaborators??candidate?.collaborators??'',nextStep:action?.nextStep??''})
    setDue(toLocalInput(action?.dueAt ?? null))
    setError('')
    setBusy(false)
    submitting.current = false
    // Background source polling must not reset the user's unsaved edits.
  }, [open, action?.id, candidate?.id])

  async function submit() {
    if (submitting.current) return
    const content = title.trim()
    if(candidate&&!mine){setError('请先确认这项行动是自己的');return}
    if (!content) {
      setError('写点什么再保存')
      return
    }
    let dueAt: number | null = null
    if (hasDue && due) {
      const parsed = new Date(due).getTime()
      if (!Number.isFinite(parsed)) {
        setError('时间格式不对，重新选一下')
        return
      }
      dueAt = parsed
    }
    if (hasDue && !due) { setError('请选择具体期限，或关闭设置期限'); return }
    submitting.current = true
    setBusy(true)
    setError('')
    try {
      if (action) await actionsStore.edit(action.id, { title: content, dueAt, ...(statusEdited ? { status } : {}), ...details })
      else if(candidate)await actionsStore.adopt(candidate,mine,{title:content,dueAt,status,...details})
      else await actionsStore.create({ title: content, dueAt, status, ...details, ...(source ? { source } : {}) })
      onSaved?.()
      onClose()
    } catch (failure) {
      // 保存没成功：输入原样留着，原因说清楚
      setError(failure instanceof Error ? failure.message : '没保存成功，请重试')
    } finally {
      submitting.current = false
      setBusy(false)
    }
  }

  return <Sheet open={open} onClose={onClose} title={action ? '编辑行动' : candidate ? '确认个人行动' : '新增行动'}
    busy={busy} canSave={!!title.trim()} onSave={() => void submit()}>
    <div className="apt-stack">
      {candidate && <section><p className="apt-group-title">确认归属</p><label className="apt-form-group apt-form-row"><input type="checkbox" className="apt-check" checked={mine} onChange={event => setMine(event.target.checked)} />这是我的行动</label><p className="apt-form-note">先核对原话，再确认是不是自己的行动。</p></section>}
      <section><p className="apt-group-title">行动</p><div className="apt-form-group">
        <label className="apt-form-row"><textarea aria-label="行动标题" rows={2} value={title} maxLength={240} onChange={event => setTitle(event.target.value)} placeholder="标题" /></label>
        <label className="apt-form-row"><span className="apt-form-label">状态</span><select aria-label="行动状态" value={status} onChange={event => { setStatus(event.target.value as ActionStatus); setStatusEdited(true) }}>{(Object.keys(ACTION_LABELS) as ActionStatus[]).map(value => <option key={value} value={value}>{ACTION_LABELS[value]}</option>)}</select></label>
        <label className="apt-form-row"><textarea aria-label="行动下一步" rows={1} value={details.nextStep} maxLength={2400} placeholder="下一步" onChange={event => setDetails({ ...details, nextStep: event.target.value })} /></label>
        <label className="apt-form-row"><input aria-label="期限说明" value={details.deadline} maxLength={2400} placeholder="期限说明" onChange={event => setDetails({ ...details, deadline: event.target.value })} /></label>
        <label className="apt-form-row justify-between"><span>设置期限</span><input aria-label="设置期限" className="apt-check" type="checkbox" checked={hasDue} onChange={event => setHasDue(event.target.checked)} /></label>
        {hasDue && <label className="apt-form-row flex-wrap"><span>期限</span><input aria-label="期限" type="datetime-local" value={due} onChange={event => setDue(event.target.value)} /></label>}
      </div><p className="apt-form-note">不设置期限就不安排具体时间。</p></section>
      <section><p className="apt-group-title">安排</p><div className="apt-form-group">
        <label className="apt-form-row"><textarea aria-label="条件" rows={1} value={details.condition} maxLength={2400} placeholder="条件" onChange={event => setDetails({ ...details, condition: event.target.value })} /></label>
        <label className="apt-form-row"><textarea aria-label="协作人／依赖" rows={1} value={details.collaborators} maxLength={2400} placeholder="协作人／依赖" onChange={event => setDetails({ ...details, collaborators: event.target.value })} /></label>
      </div></section>
      {source && <p className="apt-form-note">会关联到这条录音，方便以后回看。</p>}
      {error && <p role="alert" className="apt-panel apt-lead">{error}</p>}
    </div>
  </Sheet>
}
