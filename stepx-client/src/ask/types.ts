/* =============================================================================
 * 「问问」：话题与消息
 *
 * 规则（都是产品明确要求的，改动前先读一遍）：
 *  - **默认只有一个主聊天**，话题由用户手动新建 / 切换，不做任何自动分类；
 *  - **空话题不入库**：点「新话题」只是在内存里起一个草稿，发出第一条消息时才真正落库；
 *  - 消息按话题归属，**回复必须写回发起它的那个话题**，不能跟着界面当前选中的话题跑；
 *  - 未接上模型服务时**不产生任何助手消息**——不编造回复，也不显示"已回答"。
 * ========================================================================== */

import type { EventRef } from '@/shared/growth/source-scope'

/** 一个话题 */
export interface Topic {
  id: string
  /**
   * 展示用标题。
   * 默认是「新话题」；发出第一条消息后取那条消息的开头做名字——**这只是命名，不是自动分类**，
   * 它不会把消息分派到不同话题去。
   */
  title: string
  createdAt: number
  updatedAt: number
  archived?: boolean
}

/**
 * 用户消息的状态。
 * 助手消息只会在**真的拿到回复**时才被写入，所以它恒为 `sent`。
 */
export type MessageStatus =
  /** 请求已发出，还没回来 */
  | 'sending'
  /** 已经拿到回复 */
  | 'sent'
  /** 调用失败，可重试（重试复用同一条消息，不会重复插入） */
  | 'failed'
  /** 模型服务还没接通——不是错误，是已知状态 */
  | 'waiting'

/** 一条消息 */
export interface Message {
  id: string
  topicId: string
  role: 'user' | 'assistant'
  text: string
  createdAt: number
  status: MessageStatus
  /** 助手消息指向它所回答的那条用户消息 */
  replyTo?: string
  /** 用户显式带入的背景，仅供这条消息及它的重试使用 */
  background?: string
  eventRef?: EventRef
  sourceRefs?: EventRef[]
  requestHistoryIds?: string[]
  /** 发送时冻结的早先已完成往来，重试不混入之后的消息 */
  requestHistory?: { role: 'user' | 'assistant'; text: string }[]
  /** 失败原因（已脱敏，可直接展示） */
  failure?: string
}

/** 默认话题名；第一条消息发出前一直用它 */
export const DEFAULT_TOPIC_TITLE = '新话题'

/** 一条用户消息的展示状态文案 */
export const MESSAGE_STATUS_LABEL: Record<MessageStatus, string> = {
  sending: '发送中…',
  sent: '',
  failed: '发送失败',
  waiting: '模型服务还没接通',
}
