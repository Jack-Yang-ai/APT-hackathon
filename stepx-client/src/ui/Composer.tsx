import { useLayoutEffect, useRef } from 'react'
import { ArrowUp, X } from 'lucide-react'

import { composerStore, useComposerDraft } from '@/shared/growth/composer'
import { askStore, MAIN_TOPIC_ID, useAsk } from '@/shared/ask/store'

/**
 * 全应用唯一的一个输入框（一级页常驻的那个，与 Agent 页底部的是**同一个组件**）。
 *
 * 发送契约（改动前先读一遍，这里每一条都是有原因的）：
 *  1. 只有 `askStore` 读完本地数据（`ready`）才允许发送；
 *  2. `acquire(key)` 冻结这一次的 text / background / revision，并置上**跨页面共享**的忙锁
 *     —— 切页不会把它解锁，所以同一份草稿不可能被发两次；
 *  3. 全局输入在发起**之前同步**把话题切到主聊天，紧接着调 `send` 固定归属：
 *     归属不能靠路由 state 或 effect 去补，StrictMode 下那样会发两遍；
 *  4. 发送成功才 `clearIfRevision` —— 期间用户又改了字就不会被迟到回调抹掉；
 *  5. 出错**不清草稿**，错误就地显示，可以再点一次。
 *
 * 只由点击或 Enter 触发；中文输入法组词期间的 Enter 不会发送。
 */
export function Composer({
  draftKey,
  placeholder = '从这里接着想',
  forceMain = false,
  onSent,
}: {
  draftKey: string
  placeholder?: string
  /** 一级页常驻的那个输入框：发送固定进主聊天；Agent 页里的则发给当前话题 */
  forceMain?: boolean
  /** 发送后要做的动作（例如进入 Agent 页） */
  onSent?: () => void
}) {
  const draft = useComposerDraft(draftKey)
  const snapshot = useAsk()
  const composing = useRef(false)
  const submitting = useRef(false)
  const input = useRef<HTMLTextAreaElement>(null)
  useLayoutEffect(() => {
    const field = input.current
    if (!field) return
    field.style.height = 'auto'
    const lineHeight = Number.parseFloat(getComputedStyle(field).lineHeight) || 24
    field.style.height = `${Math.min(field.scrollHeight, lineHeight * 4 + 20)}px`
  }, [draft.text])

  function submit() {
    if (composing.current || submitting.current || !snapshot.ready) return
    const captured = composerStore.acquire(draftKey)
    if (!captured) return
    submitting.current = true

    // 一级页那个常驻输入框固定进主聊天：同步切、紧接着发，中间不留任何 await
    if (forceMain) askStore.selectTopic(MAIN_TOPIC_ID)
    const pending = askStore.send(captured.text.trim(), captured.background,captured.eventRef)
    onSent?.()

    void pending
      .then(() => {
        composerStore.clearIfRevision(draftKey, captured.revision)
      })
      .catch((failure: unknown) => {
        // 错误写进草稿本身：外壳那个输入框会随导航卸载，写在组件 state 里就丢了
        composerStore.reportError(
          draftKey,
          failure instanceof Error ? failure.message : '消息未能保存，输入还在，可以再试',
        )
      })
      .finally(() => {
        submitting.current = false
        composerStore.release(draftKey)
      })
  }

  const disabled = !snapshot.ready || !draft.text.trim()

  return (
    <div className="w-full">
      {draft.error && (
        <p role="alert" className="pb-1.5 text-caption text-danger">
          {draft.error}
        </p>
      )}

      {(draft.background !== undefined || draft.eventRef) && (
        <div className="apt-context">
          <span>
            带着背景 · {draft.eventRef ? '已选事件' : '已选内容'}
          </span>
          <button
            type="button"
            aria-label="移除背景"
            onClick={() => composerStore.update(draftKey, { background: undefined,eventRef:undefined })}
            className="-mr-1 flex size-8 shrink-0 items-center justify-center rounded text-muted-foreground active:bg-accent"
          >
            <X className="size-4" aria-hidden />
          </button>
        </div>
      )}

      <div className="apt-composer">
        <textarea
          ref={input}
          rows={1}
          aria-label="向问问提问"
          value={draft.text}
          placeholder={placeholder}
          enterKeyHint="send"
          autoComplete="off"
          disabled={!snapshot.ready}
          onChange={(event) => composerStore.update(draftKey, { text: event.target.value })}
          onCompositionStart={() => {
            composing.current = true
          }}
          onCompositionEnd={() => {
            composing.current = false
          }}
          onKeyDown={(event) => {
            if (event.key !== 'Enter' || event.shiftKey) return
            // 组词中 / 输入法正在合成时不发送
            if (composing.current || event.nativeEvent.isComposing) return
            event.preventDefault()
            submit()
          }}
          className="disabled:opacity-50"
        />
        <button
          type="button"
          onClick={submit}
          disabled={disabled || draft.busy}
          aria-label="发送"
          className="apt-send transition-transform active:scale-95"
        >
          <ArrowUp className="size-5" aria-hidden />
        </button>
      </div>
    </div>
  )
}
