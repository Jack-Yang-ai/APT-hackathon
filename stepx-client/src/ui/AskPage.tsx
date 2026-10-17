import { useEffect, useState } from 'react'
import { useLocation, useNavigate } from 'react-router-dom'
import { Archive, ArrowUpLeft, Check, ChevronLeft, Ellipsis, MessageCircle, Plus, Sparkles } from 'lucide-react'
import { Composer } from '../components/Composer'
import { AgentFace, useAgentMood } from '../components/AgentFace'
import { Sheet } from '../components/UI'
import { AptGlyph } from '../components/AptGlyph'
import { QuoteSheet } from '../components/QuoteSheet'
import { getReturnTo } from '../layout/returnTo'
import { askStore, MAIN_TOPIC_ID, useAsk } from '@/shared/ask/store'
import { composerStore, useComposerDraft } from '@/shared/growth/composer'
import { DEFAULT_TOPIC_TITLE, type Message, type Topic } from '@/shared/ask/types'
import type { EventRef } from '@/shared/growth/source-scope'

export function AskPage() {
  const snapshot = useAsk(), location = useLocation(), navigate = useNavigate(), mood = useAgentMood()
  const [showTopics, setShowTopics] = useState(false), [options, setOptions] = useState<string | null>(null)
  const [nameTarget, setNameTarget] = useState<Topic | 'new' | null>(null), [name, setName] = useState('')
  const [topicBusy, setTopicBusy] = useState(false), [topicError, setTopicError] = useState('')
  const [quote, setQuote] = useState<EventRef | null>(null), [handoffNotice, setHandoffNotice] = useState('')
  useEffect(() => { void askStore.init(); askStore.selectTopic(MAIN_TOPIC_ID) }, [])
  useEffect(() => {
    const handoff = location.state as { background?: string; question?: string; eventRef?: EventRef } | null
    if (!handoff) return
    askStore.selectTopic(MAIN_TOPIC_ID)
    const existing = composerStore.get(MAIN_TOPIC_ID)
    if (existing.text.trim() && handoff.question && existing.text !== handoff.question) setHandoffNotice('原有未发送的问题已保留，可继续编辑后发送。')
    composerStore.attach(MAIN_TOPIC_ID, handoff)
    navigate(location.pathname, { replace: true, state: null })
  }, [location.state, location.pathname, navigate])
  const isExisting = snapshot.topics.some(item => item.id === snapshot.currentTopicId)
  const draftKey = isExisting ? snapshot.currentTopicId! : '__new__', draft = useComposerDraft(draftKey)
  const topic = askStore.currentTopic(), messages = snapshot.currentTopicId ? askStore.messagesOf(snapshot.currentTopicId) : []
  const busy = topicBusy || snapshot.messages.some(message => message.status === 'sending')
  function editName(target: Topic | 'new') { setNameTarget(target); setName(target === 'new' ? '' : target.title); setTopicError('') }
  async function saveName() {
    if (busy || !nameTarget) return
    setTopicBusy(true); setTopicError('')
    try {
      if (nameTarget === 'new') { askStore.startNewTopic(name); setShowTopics(false) }
      else await askStore.renameTopic(nameTarget.id, name)
      setNameTarget(null); setOptions(null)
    } catch (error) { setTopicError(error instanceof Error ? error.message : '话题未能保存') } finally { setTopicBusy(false) }
  }
  function topicRow(item: Topic) {
    const current = item.id === snapshot.currentTopicId, main = item.id === MAIN_TOPIC_ID
    return <div className="apt-panel !p-0" style={{ borderColor: current ? 'rgb(var(--primary) / .5)' : undefined }} key={item.id}>
      <div className="flex items-start"><button className="flex min-w-0 flex-1 items-start gap-3 p-4 text-left" disabled={busy} onClick={() => { askStore.selectTopic(item.id); setShowTopics(false) }}>
        <span className="flex size-9 shrink-0 items-center justify-center rounded-xl bg-primary-soft text-primary">{main ? <Sparkles className="size-4" aria-hidden /> : <MessageCircle className="size-4" aria-hidden />}</span>
        <span className="min-w-0 flex-1"><span className="apt-lead block font-semibold">{item.title}</span><span className="apt-meta mt-1.5 block">{main ? '随时聊，所有已接通的记录都能问' : new Date(item.updatedAt).toLocaleDateString('zh-CN')}</span></span>
        {current && <Check className="mt-1 size-4 shrink-0 text-primary" aria-hidden />}
      </button>{!main && <button disabled={busy} aria-label={`${item.title}的话题选项`} aria-expanded={options === item.id} className="apt-icon-button mt-2 !text-muted-foreground" onClick={() => setOptions(options === item.id ? null : item.id)}><Ellipsis className="size-5" aria-hidden /></button>}</div>
      {options === item.id && <div className="flex gap-4 border-t border-border px-4"><button className="min-h-11 apt-lead text-primary" disabled={busy} onClick={() => editName(item)}>改名</button><button className="min-h-11 apt-lead text-primary" disabled={busy} onClick={() => {
        if (busy) return; setTopicBusy(true); setTopicError('')
        void askStore.archiveTopic(item.id, !item.archived).catch(error => setTopicError(error instanceof Error ? error.message : '话题未能更新')).finally(() => { setTopicBusy(false); setOptions(null) })
      }}>{item.archived ? '取消归档' : '归档'}</button></div>}
    </div>
  }
  return <div className="flex h-screen-dvh flex-col bg-background text-foreground">
    <header className="apt-chat-header"><div className="apt-chat-title mx-auto w-full max-w-[600px]">
      <button aria-label="关闭对话" className="apt-icon-button justify-start !text-foreground" onClick={() => navigate(getReturnTo(), { replace: true })}><ChevronLeft className="size-6" aria-hidden /></button>
      <div className="flex min-w-0 flex-col items-center"><AgentFace mood={mood} size={44} /><h1 className="apt-lead w-full truncate text-center font-semibold">{topic?.title ?? DEFAULT_TOPIC_TITLE}</h1></div>
      <button className="apt-nav-action" disabled={busy} onClick={() => { setShowTopics(true); setTopicError('') }} aria-label="聊天与话题">话题</button>
    </div></header>
    <main className="min-h-0 flex-1 scroll-y"><div className="page apt-detail-stack" style={{ paddingTop: 20 }}>
      {snapshot.currentTopicId === MAIN_TOPIC_ID && handoffNotice && <p role="status" className="apt-meta">{handoffNotice}</p>}
      {!snapshot.storageOk && <div className="apt-panel"><p role="alert" className="apt-lead">聊天暂时未能读取，草稿仍保留。</p><button className="min-h-11 text-primary" onClick={() => void askStore.init()}>重新读取</button></div>}
      {!snapshot.ready ? <p className="apt-meta">正在打开…</p> : messages.length === 0 ? <section className="space-y-5 pt-6">
        <h2 className="apt-page-intro">{draft.eventRef || draft.background ? '带着背景，继续聊。' : snapshot.currentTopicId === MAIN_TOPIC_ID ? '从这里，接着想。' : '这件事，慢慢聊。'}</h2>
        <p className="text-body leading-relaxed text-muted-foreground">{snapshot.currentTopicId === MAIN_TOPIC_ID ? '回想刚才，也聊聊接下来。提到你的记录时，会带上能核对的原话。' : '围绕这个话题接着想，聊天会一直保留在这里。'}</p>
        <div className="space-y-2.5 pt-2">{['最近收到的内容里，定了哪些事？', '这件事还有什么没有说清楚？', '帮我找一下相关的原话'].map(text => <button key={text} className="flex min-h-11 w-full items-center gap-3 rounded-md bg-surface px-4 py-3.5 text-left" onClick={() => composerStore.update(draftKey, { text })}><span className="apt-lead apt-secondary min-w-0 flex-1">{text}</span><ArrowUpLeft className="size-4 shrink-0 text-primary" aria-hidden /></button>)}</div>
      </section> : messages.map(message => <MessageRow key={message.id} message={message} sending={askStore.isSending(message.id)} onRetry={() => void askStore.retry(message.id)} onQuote={setQuote} />)}
    </div></main>
    <footer className="apt-business-footer z-20 shrink-0"><div className="mx-auto w-full max-w-[600px]"><Composer draftKey={draftKey} /></div></footer>
    <Sheet open={showTopics} title="聊天与话题" onClose={() => setShowTopics(false)} busy={topicBusy}>
      <div className="apt-stack">{topicError && !nameTarget && <p role="alert" className="apt-lead">{topicError}</p>}{snapshot.topics.filter(item => !item.archived).map(topicRow)}
        {snapshot.topics.some(item => item.archived) && <details><summary className="flex min-h-11 cursor-pointer items-center gap-2 apt-lead text-muted-foreground"><Archive className="size-4" aria-hidden />已归档 · {snapshot.topics.filter(item => item.archived).length}</summary><div className="apt-stack pt-3">{snapshot.topics.filter(item => item.archived).map(topicRow)}</div></details>}
        <button disabled={busy} className="apt-pill w-full" onClick={() => editName('new')}><Plus className="size-4" aria-hidden />新建话题</button>
      </div>
    </Sheet>
    <Sheet open={nameTarget !== null} title={nameTarget === 'new' ? '新话题' : '改名'} onClose={() => setNameTarget(null)} onSave={() => void saveName()} saveLabel={nameTarget === 'new' ? '开始聊' : '保存'} busy={topicBusy} canSave={nameTarget === 'new' || !!name.trim()}>
      <div className="apt-form-group"><label className="apt-form-row"><input aria-label="话题名称" value={name} onChange={event => setName(event.target.value)} placeholder={nameTarget === 'new' ? '想聊什么？给话题起个名字' : '话题名称'} /></label></div><p className="apt-form-note">{nameTarget === 'new' ? '最多12个字。也可以留空，用第一问命名。' : '最多12个字，聊天内容会保留。'}</p>{topicError && <p role="alert" className="apt-lead mt-3">{topicError}</p>}
    </Sheet>
    <QuoteSheet target={quote} onClose={() => setQuote(null)} />
  </div>
}

function MessageRow({ message, sending, onRetry, onQuote }: { message: Message; sending: boolean; onRetry: () => void; onQuote: (ref: EventRef) => void }) {
  const isUser = message.role === 'user'
  return <div className="flex flex-col gap-2.5">
    {isUser ? <p className="apt-chat-question whitespace-pre-wrap text-body">{message.text}</p> : <div className="apt-chat-answer space-y-2"><p className="apt-meta flex items-center gap-1.5"><AptGlyph kind="ask" size={16} />APT · 回答</p><p className="whitespace-pre-wrap text-body">{message.text}</p>
      {message.sourceRefs?.length ? <div className="flex flex-wrap gap-2">{message.sourceRefs.map((ref, i) => <button key={ref.eventId} onClick={() => onQuote(ref)} className="apt-pill !text-caption">原话 {i + 1}</button>)}</div> : null}</div>}
    {isUser && (message.status === 'failed' || message.status === 'waiting') && <div className="apt-chat-answer"><p role="status" className="apt-meta">{message.failure ?? (message.status === 'failed' ? '发送失败' : '模型服务还没接通')}</p><button onClick={onRetry} disabled={sending} className="min-h-11 text-caption font-medium text-primary disabled:opacity-50">{sending ? '重试中…' : '重试'}</button></div>}
    {isUser && message.status === 'sending' && <p role="status" className="apt-meta">正在翻记录…</p>}
  </div>
}
