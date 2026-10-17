import { useEffect } from 'react'
import { Link } from 'react-router-dom'
import { ChevronRight, Mic, RefreshCw, Square } from 'lucide-react'
import { Intro } from '../components/UI'
import { usePageTitle } from '../layout/PageTitle'
import { backScreen, backScreenPixels, backScreenUploads, useBackScreen } from '@/shared/growth/backscreen'
import { useRecorder } from '@/shared/growth/recording-controller'
import { useGrowth } from '@/shared/growth/store'
import { useGrowthProcessing } from '@/shared/growth/processing'

function DotPreview({ active, minutes }: { active: boolean; minutes: number }) {
  const pixels = active ? backScreenPixels(minutes) : Array<boolean>(391).fill(false)
  return <div role="img" aria-label={active ? `背屏预览：麦克风，${minutes}分钟` : '背屏预览：当前没有录音显示'}
    className="mx-auto grid w-fit gap-1 rounded-xl bg-foreground p-5" style={{ gridTemplateColumns: 'repeat(17, 4px)' }}>
    {pixels.map((lit, index) => <span key={index} className="size-1 rounded-full"
      style={{ background: lit ? 'rgb(var(--primary-foreground))' : 'rgb(var(--primary-foreground) / .07)' }} />)}
  </div>
}
function duration(seconds: number): string {
  const value = Math.max(0, Math.floor(seconds))
  return `${Math.floor(value / 60)}:${String(value % 60).padStart(2, '0')}`
}
export function BackScreenPage() {
  usePageTitle('背屏')
  const snapshot = useBackScreen(), recording = useRecorder(), source = useGrowth(), processing = useGrowthProcessing()
  useEffect(() => {
    void backScreen.initialize()
    const timer = setInterval(() => { if (document.visibilityState === 'visible' && !backScreen.getSnapshot().busy) void backScreen.refresh() }, 3000)
    return () => clearInterval(timer)
  }, [])
  const status = snapshot.status, available = snapshot.native && status?.hardware.enabled === true
  const linked = status?.mode === 'recording', displaying = available && linked && status.overrideActive && status.glyph === 'mic' && !status.error
  const pieces = source.segments.filter(row => row.matterId === recording.matterId)
  const { uploaded, pending } = backScreenUploads(pieces, processing.jobs)
  const recordingLabel = !recording.ready ? '正在确认录音状态' : recording.state === 'recording' ? '正在录音'
    : recording.interrupted ? '录音意外中断'
    : recording.state === 'paused' ? '已暂停' : recording.state === 'recovering' ? '录音需要恢复'
    : recording.state === 'busy' ? '正在处理录音操作' : '未开始录音'
  const displayLabel = !snapshot.ready ? '正在连接…' : !snapshot.native ? '电脑预览'
    : !status ? '暂时无法读取背屏状态' : !status.hardware.enabled ? '系统背屏已关闭'
    : status.error ? '联动需要重试' : status.overrideActive && status.glyph !== 'mic' ? '旧版图案正在显示，请关闭'
    : displaying ? `录音联动中 · ${status.minutes} 分钟`
    : linked ? '联动已开启 · 等待录音' : '录音联动未开启'
  return <div className="page apt-stack">
    <Intro title="翻过来，看见录音。">背面只显示麦克风和录音时长。</Intro>
    <section className="apt-panel space-y-4">
      <div className="flex items-start justify-between gap-3">
        <div><h2 className="apt-section-title">Neo 背屏</h2><p role="status" className="mt-1 text-caption text-muted-foreground">{displayLabel}</p></div>
        <button disabled={snapshot.busy} onClick={() => void backScreen.refresh()} className="flex size-11 shrink-0 items-center justify-center rounded-full bg-primary-soft text-primary disabled:opacity-40" aria-label="刷新背屏状态"><RefreshCw className="size-4" aria-hidden /></button>
      </div>
      <DotPreview active={Boolean(displaying)} minutes={status?.minutes ?? 0} />
      <p className="text-center text-caption text-muted-foreground">{displaying ? '本次连续收音的完整分钟数，不满一分钟显示 0。' : '开始收音后，麦克风和分钟数会出现在这里。'}</p>
      <p className="text-center text-caption text-muted-foreground">预览根据服务状态更新，实际显示请看手机背面。</p>
    </section>
    <section className="apt-panel space-y-3">
      <div className="flex items-center gap-2"><Mic className="size-4 text-primary" aria-hidden /><h2 className="apt-section-title">跟随录音显示</h2></div>
      <p className="text-caption text-muted-foreground">熄屏后继续显示；暂停、结束或连接中断后收起。每次开启最多联动 12 小时。</p>
      <div className="flex gap-2">
        <button disabled={!available || snapshot.busy || linked && !status?.error} onClick={() => void backScreen.command('recording')} className="apt-pill min-w-0 flex-1 !bg-primary !text-primary-foreground disabled:opacity-40">{snapshot.busy ? '正在设置…' : linked && !status?.error ? '录音联动已开启' : '开启录音联动'}</button>
        <button disabled={!snapshot.native || !snapshot.canStop} onClick={() => void backScreen.command('stop')} className="apt-pill shrink-0 disabled:opacity-40"><Square className="size-4" aria-hidden />关闭显示</button>
      </div>
    </section>
    <section className="apt-panel space-y-3">
      <h2 className="apt-section-title">当前录音与上传</h2>
      <dl className="space-y-2 text-caption">
        <div className="flex justify-between gap-3"><dt className="text-muted-foreground">录音状态</dt><dd>{recordingLabel}</dd></div>
        {recording.matterId && <div className="flex justify-between gap-3"><dt className="text-muted-foreground">本场累计录音</dt><dd className="tabular-nums">{duration(recording.elapsedSec)}</dd></div>}
        {recording.matterId && source.ready && source.storageOk && <>
          <div className="flex justify-between gap-3"><dt className="text-muted-foreground">已存入 App</dt><dd>{pieces.length} 段</dd></div>
          {processing.ready && <div className="flex justify-between gap-3"><dt className="text-muted-foreground">已上传</dt><dd>{uploaded} 段</dd></div>}
          {processing.ready && pending > 0 && <div className="flex justify-between gap-3"><dt className="text-muted-foreground">待上传</dt><dd>{pending} 段</dd></div>}
        </>}
      </dl>
      {source.ready && !source.storageOk && <p role="alert" className="text-caption text-danger">本机录音记录暂时无法读取，请保留 App 并重试。</p>}
      {!processing.ready && <p className="text-caption text-muted-foreground">{processing.error ?? '正在读取上传回执…'}</p>}
      {recording.error && <p role="alert" className="text-caption text-danger">{recording.error}</p>}
      <p className="text-caption text-muted-foreground">分片和上传回执同步到 App 后更新；当前还未切下的一段不计入。上传成功后继续转写与整理。</p>
      <Link to="/recordings" className="flex min-h-11 items-center justify-between gap-3 text-caption text-primary">查看录音与处理<ChevronRight className="size-4" aria-hidden /></Link>
    </section>
    {snapshot.error && <p role="alert" className="rounded-md bg-surface p-4 text-caption text-danger">{snapshot.error}</p>}
    {snapshot.notice && <p role="status" className="text-caption text-muted-foreground">{snapshot.notice}</p>}
    {snapshot.native && status && !status.hardware.enabled && <p className="text-caption text-muted-foreground">请在手机系统设置中开启背屏，再开启录音联动。</p>}
    {!snapshot.native && snapshot.ready && <p className="text-caption text-muted-foreground">请在 Neo 上设置背屏，电脑预览无法连接手机硬件。</p>}
  </div>
}
