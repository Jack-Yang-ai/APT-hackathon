import { useState } from 'react'
import { ChevronDown, FolderOpen } from 'lucide-react'

import { ConnectionSection } from '../components/ConnectionSection'
import { usePageTitle } from '../layout/PageTitle'
import aptLogo from '@/assets/apt-logo.png'
import { cn } from '@/shared/lib/cn'
import { invokeNative } from '@/shared/bridge'
import { APP_NAME, APP_VERSION } from '@/shared/config/app'
import { growthStore, useGrowth } from '@/shared/growth/store'
import { getSegmentMinutes, setSegmentMinutes, type SegmentMinutes } from '@/shared/growth/recorder'
import { PROCESSING_LABEL, useGrowthProcessing } from '@/shared/growth/processing'
import { useGrowthConnection } from '@/shared/growth/connection'
import {
  AtomError,
  callAtom,
  ATOM_RECORDER_OPEN_RECORDING,
  CONNECTOR_QUICK_NOTE,
} from '@/shared/growth/atoms'
import { formatBytes } from '@/shared/lib/format'
import { useAsync } from '@/shared/hooks/useAsync'

/**
 * 设置：只放真的会影响记录行为的项，加上一份收起来的诊断信息。
 *
 * 数据落在哪、处理由谁消费这类细节都收在「诊断信息」里，不往用户主流程上堆。
 */
export function SettingsPage() {
  usePageTitle('设置')
  const snapshot = useGrowth()
  const processing = useGrowthProcessing()
  const connection = useGrowthConnection()
  const [minutes, setMinutesState] = useState<SegmentMinutes>(getSegmentMinutes)
  const [openDiagnostics, setOpenDiagnostics] = useState(false)
  const [quickNoteBusy, setQuickNoteBusy] = useState(false)

  const usage = useAsync(() => growthStore.audioUsage(), [snapshot.segments.length])

  const counts = processing.jobs.reduce<Record<string, number>>((acc, job) => {
    acc[job.state] = (acc[job.state] ?? 0) + 1
    return acc
  }, {})
  const failures = processing.jobs.filter((job) => job.state === 'failed')

  function changeMinutes(value: SegmentMinutes) {
    setSegmentMinutes(value)
    setMinutesState(value)
  }

  function notify(title: string) {
    void invokeNative('showToast', { title, duration: 2000 }).catch(() => undefined)
  }

  async function openQuickNote() {
    if (quickNoteBusy) return
    setQuickNoteBusy(true)
    try {
      await callAtom(ATOM_RECORDER_OPEN_RECORDING, {}, CONNECTOR_QUICK_NOTE)
    } catch (error) {
      notify(error instanceof AtomError ? error.userMessage : '没能打开快记')
    } finally {
      setQuickNoteBusy(false)
    }
  }

  return (
    <div className="page apt-stack">
      <ConnectionSection />

      <section className="space-y-2">
        <h2 className="apt-group-title">记录</h2>
        <div className="apt-panel">
          <p className="text-body">一段录多久</p>
          <p className="mt-0.5 text-caption text-muted-foreground">
            这是保存与传输的分段时长；实际录音状态以「此刻」页为准。
          </p>
          <div className="mt-3 flex gap-2">
            {([5, 10] as const).map((value) => (
              <button
                key={value}
                type="button"
                onClick={() => changeMinutes(value)}
                aria-pressed={minutes === value}
                className={cn(
                  'min-h-tap flex-1 rounded-md border text-body transition-colors duration-fast',
                  minutes === value
                    ? 'border-primary bg-primary-soft font-medium text-primary'
                    : 'border-border bg-surface text-foreground active:bg-accent',
                )}
              >
                {value} 分钟
              </button>
            ))}
          </div>
        </div>
      </section>

      <section className="space-y-2">
        <h2 className="apt-group-title">存储</h2>
        <div className="apt-panel">
          <p className="text-body">
            手机里存着 {usage.data?.count ?? 0} 段录音
            {usage.data && usage.data.bytes > 0 && ` · ${formatBytes(usage.data.bytes)}`}
          </p>
          <p className="mt-0.5 text-caption text-muted-foreground">
            原始音频在处理完成前都留在本机；清理应用数据会一并清掉。
          </p>
        </div>
      </section>

      <section className="space-y-2">
        <h2 className="apt-group-title">其它工具</h2>
        <div className="apt-settings-group">
          <button
            type="button"
            disabled={quickNoteBusy}
            onClick={() => void openQuickNote()}
            className="apt-setting-row transition-colors duration-fast active:bg-accent disabled:opacity-50"
          >
            <FolderOpen className="size-5 text-muted-foreground" aria-hidden />
            <span className="min-w-0 flex-1">
              <span className="block apt-lead">用快记录一段</span>
            </span>
          </button>
        </div>
        <p className="text-caption text-muted-foreground">
          在快记里录，材料留在快记，不会进到 Apt。
        </p>
      </section>

      <section className="space-y-2">
        <button
          type="button"
          onClick={() => setOpenDiagnostics((value) => !value)}
          aria-expanded={openDiagnostics}
          className="apt-setting-row apt-settings-group transition-colors duration-fast active:bg-accent"
        >
          <span className="flex-1">
            <span className="block text-body">诊断信息</span>
            <span className="mt-0.5 block text-caption text-muted-foreground">
              {failures.length > 0 ? `有 ${failures.length} 段处理未完成` : '处理、连接与数据位置'}
            </span>
          </span>
          <ChevronDown
            className={cn(
              'size-5 shrink-0 text-muted-foreground transition-transform duration-fast',
              openDiagnostics && 'rotate-180',
            )}
            aria-hidden
          />
        </button>

        {openDiagnostics && (
          <div className="space-y-1 apt-panel">
            <p className="text-caption text-muted-foreground">
              本机 {snapshot.matters.length} 次录音 · {snapshot.segments.length} 段
            </p>
            <p className="text-caption text-muted-foreground">
              处理：
              {processing.jobs.length === 0
                ? '还没有任务'
                : (Object.keys(PROCESSING_LABEL) as Array<keyof typeof PROCESSING_LABEL>)
                    .filter((state) => counts[state])
                    .map((state) => `${PROCESSING_LABEL[state]} ${counts[state]}`)
                    .join(' · ')}
            </p>
            <p className="text-caption text-muted-foreground">
              云代理：
              {connection.connecting ? '连接中' : connection.ready ? '已连接' : '未连接'}
              {connection.health &&
                ` · 对话${connection.health.chatConfigured ? '已配置' : '未配置'} · 转写${
                  connection.health.asrConfigured ? '已配置' : '未配置'
                } · 整理队列${connection.health.extractionQueueConfigured ? '已配置' : '未配置'}`}
            </p>
            {processing.error && <p className="text-caption text-danger">{processing.error}</p>}
            {failures.length > 0 && (
              <ul className="space-y-1 pt-1">
                {failures.slice(0, 5).map((job) => (
                  <li key={job.id} className="text-caption text-danger">
                    第 {job.index + 1} 段 · 已试 {job.attempts} 次 · {job.error ?? '处理未完成'}
                  </li>
                ))}
              </ul>
            )}
            <p className="pt-1 text-caption text-muted-foreground">
              数据位置：原始音频、转写与整理结果在本机存储；上传的音频与处理任务在 Apt 私有云；
              按事整理由 Apt 侧的执行器消费，它停机时这里会等待。
            </p>
            <p className="text-caption text-muted-foreground">
              尚未迁移到 StepX：正式 iPhone 库、声纹、研究记忆（不做跨设备记忆同步）。
            </p>
          </div>
        )}
      </section>

      <section className="space-y-2">
        <h2 className="apt-group-title">关于</h2>
        <div className="flex items-center gap-3 apt-panel">
          {/* 品牌位：用定稿的蓝色 a 标识原图，和桌面图标、favicon 是同一张 */}
          <img src={aptLogo} alt="" width={40} height={40} draggable={false} className="shrink-0 select-none" />
          <div className="min-w-0 flex-1">
            <p className="text-body font-medium text-foreground">{APP_NAME}</p>
            <p className="mt-0.5 text-caption text-muted-foreground">版本 {APP_VERSION}</p>
          </div>
        </div>
      </section>
    </div>
  )
}
