import { useState, type ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { ChevronLeft, ChevronRight, FileAudio, Settings, Grid2X2 } from 'lucide-react'
import { useGrowth } from '@/shared/growth/store'
import { projectedEvents } from '@/shared/growth/source-scope'
import { useGrowthProcessing } from '@/shared/growth/processing'
import { useGrowthRuntime } from '@/shared/growth/runtime'
import { startOfDay } from '@/shared/growth/format'
import { usePageTitle } from '../layout/PageTitle'
import { importAudioFile } from '@/shared/growth/import'
import { ContinueAsk } from '../components/ContinueAsk'
import { Intro } from '../components/UI'

export function MePage() {
  useGrowthRuntime()
  const source = useGrowth(), processing = useGrowthProcessing()
  const events = projectedEvents({ ...source, jobs: processing.jobs }), days = new Set(events.map(event => startOfDay(event.startedAt)))
  const latest = [...events].sort((a, b) => b.startedAt - a.startedAt)[0]
  return <div className="page">
    <Intro title="回到那一天。">回看切分好的事件，带着背景继续问。</Intro>
    <div className="mt-5"><RecordingCalendar recorded={days} /></div>
    <p className="apt-form-note">{!source.storageOk ? '本地存储未能读取，请保留 App 并重试。' : '有点的日子有事件，点进去回看。'}</p>
    {latest && <div className="mt-3"><ContinueAsk event={latest} label="问问最近的事件" question="这件事有哪些值得记住的内容？" /></div>}
    <div className="apt-settings-group mt-6">
      <MeRow to="/me/import" icon={<FileAudio />} label="导入录音" />
      <MeRow to="/recordings" icon={<FileAudio />} label="录音与处理" />
      <MeRow to="/me/backscreen" icon={<Grid2X2 />} label="背屏" />
      <MeRow to="/me/settings" icon={<Settings />} label="设置" />
    </div>
    <p className="apt-form-note">录音和声音材料保存在这台 Neo 上。</p>
  </div>
}

export function MeRow({ to, icon, label, detail }: { to: string; icon: ReactNode; label: string; detail?: string }) {
  return <Link to={to} className="apt-setting-row">{icon}<span className="min-w-0 flex-1"><span className="block text-body">{label}</span>{detail && <span className="apt-meta mt-1 block">{detail}</span>}</span><ChevronRight className="apt-row-chevron !size-3" aria-hidden /></Link>
}

function RecordingCalendar({ recorded }: { recorded: Set<number> }) {
  const today = new Date(), thisMonth = new Date(today.getFullYear(), today.getMonth(), 1).getTime()
  const [month, setMonth] = useState(thisMonth), date = new Date(month), year = date.getFullYear(), number = date.getMonth()
  const count = new Date(year, number + 1, 0).getDate(), offset = (date.getDay() + 6) % 7
  return <section className="apt-panel" style={{ padding: '16px 12px' }} aria-label="事件日历">
    <div className="mb-2 flex items-center gap-1"><h2 className="apt-section-title flex-1">{year} 年 {number + 1} 月</h2>
      <button className="apt-icon-button" aria-label="上个月" onClick={() => setMonth(new Date(year, number - 1, 1).getTime())}><ChevronLeft className="size-4" aria-hidden /></button>
      <button className="apt-icon-button" aria-label="下个月" disabled={month >= thisMonth} onClick={() => setMonth(new Date(year, number + 1, 1).getTime())}><ChevronRight className="size-4" aria-hidden /></button>
    </div>
    <div className="grid grid-cols-7 gap-y-1 text-center">
      {['一', '二', '三', '四', '五', '六', '日'].map(day => <span key={day} className="pb-2 text-caption font-medium text-muted-foreground">{day}</span>)}
      {Array.from({ length: offset }, (_, i) => <span key={'empty-' + i} />)}
      {Array.from({ length: count }, (_, i) => {
        const day = new Date(year, number, i + 1).getTime(), has = recorded.has(day), current = day === startOfDay(today.getTime())
        const content = <><span>{i + 1}</span><span aria-hidden className={`size-1 rounded-full ${has ? 'bg-primary' : ''}`} /></>
        const className = `apt-calendar-day flex min-h-11 min-w-0 flex-col items-center justify-center rounded-full apt-lead tabular-nums ${current ? 'bg-primary-soft font-semibold text-primary' : has ? 'text-foreground' : 'text-muted-foreground'}`
        return has ? <Link key={day} to={`/days/${day}`} aria-label={`${number + 1}月${i + 1}日，有事件`} className={className}>{content}</Link>
          : <span key={day} aria-label={`${number + 1}月${i + 1}日，没有事件`} className={className}>{content}</span>
      })}
    </div>
  </section>
}

/** Separate entry avoids invoking a native file picker when merely navigating to Me. */
export function ImportPage() {
  return <ImportContent />
}
function ImportContent() {
  usePageTitle('导入录音')
  const [busy, setBusy] = useState(false), [result, setResult] = useState('')
  return <div className="page apt-stack"><Intro title="把录音带进来。">已有的音频，也能继续整理和追问。</Intro>
    <section className="apt-panel space-y-3"><FileAudio className="size-6 text-primary" aria-hidden /><h2 className="apt-section-title">选择音频文件</h2><p className="apt-lead apt-secondary">导入后先保存在本机，连接云端后继续转写与整理。</p>
      <button disabled={busy} className="apt-pill w-full disabled:opacity-40" onClick={() => {
        if (busy) return; setBusy(true); setResult('')
        void importAudioFile().then(outcome => setResult(outcome.status === 'imported' ? '录音已加进来，可到「录音与处理」查看。' : outcome.status === 'failed' ? outcome.reason : '')).catch(() => setResult('文件未能导入，请重试。')).finally(() => setBusy(false))
      }}>{busy ? '正在导入…' : '选择录音文件'}</button>
    </section>{result && <p role="status" className="apt-lead">{result}</p>}
    <Link to="/recordings" className="apt-pill self-start">查看录音与处理</Link>
  </div>
}
