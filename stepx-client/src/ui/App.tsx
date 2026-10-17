import { useEffect, useLayoutEffect } from 'react'
import { Navigate, Route, Routes } from 'react-router-dom'

import { growthConnection } from '@/shared/growth/connection'
import { growthProcessing } from '@/shared/growth/processing'
import { recordingMemory } from '@/shared/growth/recording-memory'
import { actionsStore } from '@/shared/growth/actions'
import { personalProcessing } from '@/shared/growth/personal-processing'
import { askStore } from '@/shared/ask/store'
import { recorder } from '@/shared/growth/recording-controller'
import { AppShell } from './layout/AppShell'
import { NowPage, DayEventsPage } from './pages/NowPage'
import { ActionsPage } from './pages/ActionsPage'
import { AskPage } from './pages/AskPage'
import { MePage, ImportPage } from './pages/MePage'
import { MatterDetailPage } from './pages/MatterDetailPage'
import { SettingsPage } from './pages/SettingsPage'
import { BackScreenPage } from './pages/BackScreenPage'
import { EventPage, EventTranscriptPage } from './pages/EventPage'
import { ActionDetailPage, RemovedActionsPage } from './components/ActionsSection'
import { RecordingsPage } from './pages/RecordingsPage'
import './ios-theme.css'

/**
 * App UI 路由表。
 * 一级入口是「此刻 / 行动 / 我」三个（底部 Tab + 常驻输入框）；
 * **Agent（/ask）不在 AppShell 里**——它全屏覆盖业务导航，自己带收起按钮。
 */
export function App() {
  useLayoutEffect(() => {
    // 已有真实首屏才收起HTML启动层；不等待本机数据、桥接或云端。
    window.dispatchEvent(new Event('apt:ui-ready'))
  }, [])
  // 启动接线：接上现有的 Apt 云代理 + 启动处理队列 + 读行动。
  // 没存过凭据就什么也不做（init 内部直接返回），不会自动连接、不会去猜令牌。
  useEffect(() => {
    void recorder.initialize()
    void growthConnection.init()
    void growthProcessing.init()
    recordingMemory.init()
    void personalProcessing.init()
    // 行动读不出来时不吞掉：错误留在 store 里，由「行动」页显示并提供重试
    void actionsStore.init().catch(() => undefined)
    // 对话也要在启动时读好：一级页那个常驻输入框靠它判断能不能发送，
    // 只等用户打开 Agent 页才初始化的话，一级页的输入框会一直是禁用的
    void askStore.init().catch(() => undefined)
  }, [])

  return (
    <Routes>
      {/* Agent 全屏页：不吃 AppShell 的 Tab 与常驻输入，自己带收起按钮 */}
      <Route path="ask" element={<AskPage />} />

      <Route element={<AppShell />}>
        <Route index element={<NowPage />} />
        <Route path="actions" element={<ActionsPage />} />
        <Route path="actions/removed" element={<RemovedActionsPage />} />
        <Route path="actions/:id" element={<ActionDetailPage />} />
        <Route path="me" element={<MePage />} />
        <Route path="me/settings" element={<SettingsPage />} />
        <Route path="me/backscreen" element={<BackScreenPage />} />
        <Route path="me/import" element={<ImportPage />} />
        <Route path="days/:day" element={<DayEventsPage />} />
        <Route path="events/:id" element={<EventPage />} />
        <Route path="events/:id/transcript" element={<EventTranscriptPage />} />
        <Route path="recordings" element={<RecordingsPage />} />
        <Route path="recordings/:id" element={<MatterDetailPage />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  )
}
