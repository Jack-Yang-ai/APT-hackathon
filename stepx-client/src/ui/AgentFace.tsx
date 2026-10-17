import { useNavigate } from 'react-router-dom'

import agentFigure from '@/assets/apt-agent.png'
import { cn } from '@/shared/lib/cn'
import { useRecorder } from '@/shared/growth/recording-controller'
import { useComposerDraft } from '@/shared/growth/composer'
import { MAIN_TOPIC_ID } from '@/shared/ask/store'

/**
 * 三个一级页共用的 Agent 入口。
 *
 * 形象是**雾蓝团子**的定稿素材原图（`src/assets/apt-agent.png`，透明底，只有眼睛和嘴）——
 * 直接引用原始像素，不重绘、不换色、不拉伸。它和蓝色的 `a` 标识是**两个独立角色**：
 * 标识进 favicon 与桌面图标，团子只做 Agent 形象，两者不互相顶替。
 *
 * 三句话**只反映真实状态**：
 *  - 默认「随时聊聊」；
 *  - 正在录音 → 「在听」；
 *  - 消息真的在发送中 → 「在回你」。
 * 没有"正在执行""帮你办好了"这类没有依据的话，也不挂任何数字或假任务。
 * 点击永远进主聊天，不跟着上次选的专题漂移。
 *
 * 动效：只有消息**真的在发送中**（`replying`）才轻微缩放 + 摇摆，其余状态是静止的原图；
 * `prefers-reduced-motion` 的全局降级在 globals.css 末尾生效。
 */

export type AgentMood = 'idle' | 'listening' | 'replying'

export const AGENT_STATUS: Record<AgentMood, string> = {
  idle: '随时聊聊',
  listening: '在听',
  replying: '在回你',
}

export function AgentFace({ mood = 'idle', size = 36, className }: { mood?: AgentMood; size?: number; className?: string }) {
  return (
    <img
      src={agentFigure}
      width={size}
      height={size}
      /* 装饰性图像：可读名称留在父按钮的 aria-label 上，这里不重复念一遍 */
      alt=""
      draggable={false}
      className={cn('apt-agent shrink-0 select-none', mood === 'replying' && 'agent-sway', className)}
    />
  )
}

/** 当前该显示哪一副表情 —— 只看真实状态 */
export function useAgentMood(): AgentMood {
  const recording = useRecorder()
  const draft = useComposerDraft(MAIN_TOPIC_ID)
  if (recording.state === 'recording') return 'listening'
  if (draft.busy) return 'replying'
  return 'idle'
}

/** 一级页标题行右侧的那个入口 */
export function AgentEntry() {
  const navigate = useNavigate()
  const mood = useAgentMood()
  return (
    <button
      type="button"
      onClick={() => navigate('/ask', { replace: true })}
      aria-label={`打开 Apt 对话，当前${AGENT_STATUS[mood]}`}
      className="flex size-11 items-center justify-center rounded-full active:bg-accent"
    >
      <AgentFace mood={mood} size={44} />
    </button>
  )
}
