import { useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { ChevronDown } from 'lucide-react'
import { useGrowthRuntime } from '@/shared/growth/runtime'
import { useGrowth } from '@/shared/growth/store'
import { useGrowthProcessing } from '@/shared/growth/processing'
import { startOfDay, endOfDay } from '@/shared/growth/format'
import { CaptureBar } from '../components/CaptureBar'
import { EventRows } from '../components/EventRows'
import { Empty } from '../components/UI'
import { usePageTitle } from '../layout/PageTitle'

export function NowPage() {
  useGrowthRuntime()
  const source = useGrowth(), processing = useGrowthProcessing(), [selected, setSelected] = useState<number | null>(null)
  const today = startOfDay(Date.now()), day = selected ?? today
  const days = [...new Set([today, day, ...processing.events.map(event => startOfDay(event.startedAt)).filter(value => value >= today - 6 * 86400000)])].sort((a, b) => b - a)
  const events = processing.events.filter(event => event.startedAt >= day && event.startedAt < endOfDay(day))
  const pending = processing.jobs.some(job => job.state !== 'done')
  return <div className="page">
    <header className="flex min-h-11 flex-wrap items-center justify-between gap-3">
      <label className="relative inline-flex min-h-11 min-w-0 max-w-full items-center font-semibold text-primary">
        <select aria-label="切换日期" value={day} onChange={event => setSelected(Number(event.target.value))} className="min-h-11 min-w-0 max-w-full appearance-none bg-transparent pr-6 text-body outline-none">
          {days.map(value => <option value={value} key={value}>{new Date(value).getMonth() + 1}月{new Date(value).getDate()}日{value === today ? ' · 今天' : ''}</option>)}
        </select><ChevronDown className="pointer-events-none absolute right-0 size-3.5" aria-hidden />
      </label>
      <span className="apt-meta shrink-0">{events.length} 件事件</span>
    </header>
    <CaptureBar />
    {!source.storageOk && <p role="alert" className="apt-lead py-3">本地存储暂时不可用，请保留 App 并重试。</p>}
    {events.length ? <EventRows events={events} /> : <Empty title="还没有切分好的事件">{pending ? '事件正在整理，完成后会出现在这里。' : '事件整理好后会出现在这里，也可以随时和 Agent 聊聊。'}</Empty>}
    {(pending || processing.error) && <Link to="/recordings" className="flex min-h-11 items-center text-caption text-primary">{processing.error ? '有内容未能整理，查看处理状态' : '查看处理中的录音'}</Link>}
  </div>
}

export function DayEventsPage() {
  useGrowthRuntime()
  const { day: value = '' } = useParams(), day = Number(value), processing = useGrowthProcessing()
  const valid = Number.isFinite(day) && day > 0 && day <= 8640000000000000 && startOfDay(day) === day
  usePageTitle(valid ? `${new Date(day).getMonth() + 1}月${new Date(day).getDate()}日` : '这一天')
  const events = valid ? processing.events.filter(event => startOfDay(event.startedAt) === day) : []
  return <div className="page" style={{ paddingTop: 12 }}>
    {processing.error && <p role="alert" className="apt-lead py-3">{processing.error}</p>}
    {events.length ? <EventRows events={events} /> : <Empty title="这一天还没有切分好的事件。" />}
  </div>
}
