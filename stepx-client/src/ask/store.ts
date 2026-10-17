import { useSyncExternalStore } from 'react'
import { STORE_MESSAGES, STORE_TOPICS, idbGetAll, idbPutMany, idbUpdate } from '@/shared/growth/idb'
import { newId } from '@/shared/growth/store'
import { chatService, type ChatResult, type ChatTurn } from './service'
import { sourceTransaction, readSources } from '@/shared/growth/idb'
import { growthStore } from '@/shared/growth/store'
import { growthProcessing } from '@/shared/growth/processing'
import { eventStamp, resolveEvent, eventBackground, projectedEvents, type EventRef } from '@/shared/growth/source-scope'
import { DEFAULT_TOPIC_TITLE, type Message, type Topic } from './types'

export const MAIN_TOPIC_ID = 'main'
const MAIN_TOPIC: Topic = { id: MAIN_TOPIC_ID, title: '主聊天', createdAt: 0, updatedAt: 0 }

export interface AskSnapshot {
  ready: boolean
  storageOk: boolean
  topics: Topic[]
  messages: Message[]
  currentTopicId: string | null
}
const EMPTY: AskSnapshot = {
  ready: false, storageOk: true, topics: [MAIN_TOPIC], messages: [], currentTopicId: MAIN_TOPIC_ID,
}

export class AskStore {
  private validRefs=new Set<string>()
  private visibilityRevision=0
  private watching=false
  private pendingBindings=new Map<string,Map<string,string>>()
  private pendingRefs=new Map<string,EventRef[]>()
  private topics = new Map<string, Topic>()
  private messages = new Map<string, Message>()
  private draft: Topic | null = null
  private currentTopicId: string = MAIN_TOPIC_ID
  private snapshot: AskSnapshot = EMPTY
  private listeners = new Set<() => void>()
  private initPromise: Promise<void> | null = null
  private inFlight = new Set<string>()
  private busyTopics = new Set<string>()
  private topicMutation = false
  // 写回失败时保留真实结果；重试先重新落盘，不重复请求模型。
  private pendingResults = new Map<string, ChatResult>()
  // 仅展示本次落盘错误，不把未提交的状态冒充成已保存数据。
  private storageFailures = new Map<string, string>()

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener)
    return () => { this.listeners.delete(listener) }
  }
  getSnapshot = (): AskSnapshot => this.snapshot

  private unsafeLegacy(message:Message,visited=new Set<string>()):boolean {
    if(visited.has(message.id))return true
    const seen=new Set(visited);seen.add(message.id)
    if(message.background?.startsWith('这次录音：'))return true
    const parent=message.replyTo?this.messages.get(message.replyTo):undefined
    if(parent&&(this.unsafeLegacy(parent,seen)||!this.references(parent).every(ref=>this.validRefs.has(this.refKey(ref)))))return true
    for(const id of message.requestHistoryIds??[]) {
      const source=this.messages.get(id)
      if(!source||this.unsafeLegacy(source,seen)||!this.references(source).every(ref=>this.validRefs.has(this.refKey(ref))))return true
    }
    for(const turn of message.requestHistory??[]) {
      const matches=[...this.messages.values()].filter(row=>row.id!==message.id&&row.role===turn.role&&row.text===turn.text&&row.createdAt<=message.createdAt)
      if(!matches.length || matches.some(row=>this.unsafeLegacy(row,seen)||!this.references(row).every(ref=>this.validRefs.has(this.refKey(ref)))))return true
    }
    return false
  }
  private refKey(ref:EventRef):string {return `${ref.recordingId}:${ref.eventId}:${ref.fingerprint}`}
  private references(message:Message):EventRef[] {return [...(message.eventRef?[message.eventRef]:[]),...(message.sourceRefs??[])]}
  private safeMessage(message:Message):boolean {return !this.unsafeLegacy(message)&&this.references(message).every(ref=>this.validRefs.has(this.refKey(ref)))}
  private async refreshVisibility():Promise<void> {
    const revision=++this.visibilityRevision
    this.validRefs.clear();this.emit()
    try {
      const source=await readSources(),valid=new Set<string>()
      for(const message of this.messages.values())for(const ref of this.references(message)) {
        try{await resolveEvent(source,ref);valid.add(this.refKey(ref))}catch{/* Stale answers remain stored but are withheld. */}
      }
      if(revision===this.visibilityRevision){this.validRefs=valid;this.emit()}
    }catch{/* Keep derived answers hidden when current sources cannot be read. */}
  }
  private emit(): void {
    const main = this.topics.get(MAIN_TOPIC_ID) ?? MAIN_TOPIC
    this.snapshot = {
      ready: this.snapshot.ready,
      storageOk: this.snapshot.storageOk,
      topics: [main, ...[...this.topics.values()]
        .filter((topic) => topic.id !== MAIN_TOPIC_ID)
        .sort((a, b) => b.updatedAt - a.updatedAt)],
      messages: [...this.messages.values()].sort((a, b) => a.createdAt - b.createdAt)
        .map(message=>message.role==='assistant'&&!this.safeMessage(message)?{...message,text:'这条回答的来源已变化或无法核验，请从事件详情重新提问。'}:message)
        .map((message) => this.storageFailures.has(message.id)
          ? { ...message, status: 'failed', failure: this.storageFailures.get(message.id) }
          : message),
      currentTopicId: this.currentTopicId,
    }
    this.listeners.forEach((listener) => listener())
  }

  init(): Promise<void> {
    if (this.initPromise && (this.snapshot.storageOk || !this.snapshot.ready || this.inFlight.size)) return this.initPromise
    this.snapshot = { ...this.snapshot, ready: false }
    this.emit()
    const task = (async () => {
      const [topics, messages] = await Promise.all([
        idbGetAll<Topic>(STORE_TOPICS), idbGetAll<Message>(STORE_MESSAGES),
      ])
      const recovered = messages.map((message): Message => {
        if (message.role !== 'user' || message.status !== 'sending') return message
        const answered = messages.some((reply) => reply.role === 'assistant' && reply.replyTo === message.id
          && reply.topicId === message.topicId && reply.status === 'sent')
        return { ...message, status: answered ? 'sent' : 'failed',
          failure: answered ? undefined : '上次发送没有完成，可以重试' }
      })
      const changed = recovered.filter((message, index) => message !== messages[index])
      if (changed.length) await idbPutMany(changed.map((value) => ({ store: STORE_MESSAGES, value })))
      this.topics = new Map(topics.map((topic) => [topic.id, topic.id === MAIN_TOPIC_ID
        ? { ...topic, title: MAIN_TOPIC.title } : topic]))
      this.messages = new Map(recovered.map((message) => [message.id, message]))
      this.snapshot = { ...EMPTY, ready: true }
      if(!this.watching){this.watching=true;growthStore.subscribe(()=>void this.refreshVisibility());growthProcessing.subscribe(()=>void this.refreshVisibility())}
      await this.refreshVisibility()
    })()
    this.initPromise = task.catch(() => {
      this.initPromise = null
      this.snapshot = { ...this.snapshot, ready: true, storageOk: false }
      this.emit()
    })
    return this.initPromise
  }

  getTopic(id: string): Topic | undefined {
    return this.topics.get(id) ?? (id === MAIN_TOPIC_ID ? MAIN_TOPIC
      : this.draft?.id === id ? this.draft : undefined)
  }
  currentTopic(): Topic | undefined { return this.getTopic(this.currentTopicId) }
  messagesOf(topicId: string): Message[] {
    return this.snapshot.messages.filter((message) => message.topicId === topicId)
  }
  isSending(messageId: string): boolean { return this.inFlight.has(messageId) }

  startNewTopic(title?: string): void {
    if (this.topicMutation) throw new Error('话题正在保存，请稍后新建')
    const name = title?.trim() || DEFAULT_TOPIC_TITLE
    if (title?.trim() && Array.from(name).length > 12) throw new Error('话题名称最多12个字')
    const now = Date.now()
    this.draft = { id: newId(), title: name, createdAt: now, updatedAt: now }
    this.currentTopicId = this.draft.id
    this.emit()
  }
  selectTopic(id: string): void {
    if (id !== MAIN_TOPIC_ID && !this.topics.has(id)) return
    this.draft = null
    this.currentTopicId = id
    this.emit()
  }

  private async changeTopic(id: string, change: (current: Topic) => Topic): Promise<void> {
    if (id === MAIN_TOPIC_ID) throw new Error('主聊天不能改名或归档')
    if (this.topicMutation || this.inFlight.size) throw new Error('请等当前操作完成后再修改话题')
    this.topicMutation = true
    try {
      await this.init()
      if (!this.snapshot.storageOk) throw new Error('话题未能读取，请重试')
      const saved = await idbUpdate<Topic>(STORE_TOPICS, id, current => {
        if (!current || current.id !== id) throw new Error('这个话题尚未保存或已经变化')
        return change(current)
      })
      this.topics.set(id, saved)
      if (saved.archived && this.currentTopicId === id) this.currentTopicId = MAIN_TOPIC_ID
      this.emit()
    } finally { this.topicMutation = false }
  }
  renameTopic(id: string, title: string): Promise<void> {
    const name = title.trim()
    if (!name || Array.from(name).length > 12) return Promise.reject(new Error('话题名称需要1–12个字'))
    return this.changeTopic(id, current => ({ ...current, title: name, updatedAt: Date.now() }))
  }
  archiveTopic(id: string, archived: boolean): Promise<void> {
    if (typeof archived !== 'boolean') return Promise.reject(new Error('话题状态无效'))
    return this.changeTopic(id, current => ({ ...current, archived, updatedAt: Date.now() }))
  }

  private historyIds(topicId:string,messageId?:string,ref?:EventRef):string[] {
    const ordered=[...this.messages.values()].filter(item=>item.topicId===topicId).sort((a,b)=>a.createdAt-b.createdAt)
    const stop=messageId?ordered.findIndex(item=>item.id===messageId):ordered.length
    return ordered.slice(0,stop<0?0:stop).filter(item=>item.status==='sent'&&this.safeMessage(item)
      && (!ref || this.references(item).some(source=>this.refKey(source)===this.refKey(ref))))
      .slice(-16).map(item=>item.id)
  }

  async send(text:string,background?:string,eventRef?:EventRef): Promise<void> {
    const content = text.trim()
    if (!content) return
    if (this.topicMutation) throw new Error('话题正在保存，问题仍保留，请稍后再发')
    if (!this.snapshot.ready || !this.initPromise) throw new Error('本地存储尚未打开，请稍后重试')
    // 发送归属、草稿和请求上下文都在第一次 await 前捕获。
    const source = this.currentTopic() ?? MAIN_TOPIC
    const topicId = source.id
    if (this.busyTopics.has(topicId)) throw new Error('这个话题正在发送，请稍后重试')
    this.busyTopics.add(topicId)
    const message: Message = {
      id: newId(), topicId, role: 'user', text: content, createdAt: Date.now(), status: 'sending',
      background:eventRef?undefined:background,eventRef:eventRef?{...eventRef}:undefined,requestHistoryIds:this.historyIds(topicId,undefined,eventRef),
    }
    this.inFlight.add(message.id)
    try {
      const event=eventRef?await resolveEvent(await readSources(),eventRef):undefined
      if(background?.startsWith('这次录音：'))throw new Error('请从事件详情重新带入背景；问题仍保留')
      const topic=await sourceTransaction('readwrite',(fresh,put)=>{
        if(event&&!projectedEvents(fresh).some(row=>row.id===event.id&&eventStamp(row)===eventStamp(event)))throw new Error('来源已变化，问题仍保留，请重新带入背景')
        // Another page may have renamed/archived this topic since our snapshot was read.
        const saved=(fresh.rows[STORE_TOPICS] as Topic[]).find(row=>row.id===topicId)
        const latest=saved??source
        const next:Topic={...latest,updatedAt:Math.max(latest.updatedAt,message.createdAt),
          title:topicId===MAIN_TOPIC_ID?MAIN_TOPIC.title:saved?latest.title
            :source.title===DEFAULT_TOPIC_TITLE?`${content.slice(0,14)}${content.length>14?'…':''}`:source.title}
        put(STORE_TOPICS,next);put(STORE_MESSAGES,message)
        return next
      },[STORE_MESSAGES,STORE_TOPICS])
      this.topics.set(topicId, topic)
      this.messages.set(message.id, message)
      // 用户已经切到 B 或起草 C 时，不覆盖当前选择或消费 C。
      if (this.draft?.id === topicId) this.draft = null
      this.snapshot = { ...this.snapshot, storageOk: true }
      this.emit()
      await this.dispatch(message)
    } catch (error) {
      this.snapshot = { ...this.snapshot, storageOk: false }
      throw error
    } finally {
      this.inFlight.delete(message.id)
      this.busyTopics.delete(topicId)
      this.emit()
    }
  }

  async retry(messageId: string): Promise<void> {
    if (this.topicMutation) throw new Error('话题正在保存，请稍后重试')
    const message = this.messages.get(messageId)
    if (!message || message.role !== 'user' || message.status === 'sent') return
    if (this.inFlight.has(messageId) || this.busyTopics.has(message.topicId)) return
    this.inFlight.add(messageId)
    this.busyTopics.add(message.topicId)
    this.emit()
    try {
      const next: Message = { ...message, status: 'sending', failure: undefined,
        requestHistory:undefined,requestHistoryIds:message.requestHistoryIds??this.historyIds(message.topicId,message.id,message.eventRef) }
      await idbPutMany([{ store: STORE_MESSAGES, value: next }])
      this.messages.set(messageId, next)
      this.storageFailures.delete(messageId)
      this.emit()
      await this.dispatch(next)
    } catch {
      this.storageFailures.set(messageId, '本机保存失败，可以重试')
      this.snapshot = { ...this.snapshot, storageOk: false }
    } finally {
      this.inFlight.delete(messageId)
      this.busyTopics.delete(message.topicId)
      this.emit()
    }
  }

  private async dispatch(message: Message): Promise<void> {
    let result=this.pendingResults.get(message.id)
    let bindings=this.pendingBindings.get(message.id)??new Map<string,string>()
    let refs:EventRef[]=this.pendingRefs.get(message.id)??[]
    try {
      if(this.unsafeLegacy(message))throw new Error('旧背景尚未绑定有效来源，请从事件详情重新带入')
      const source=await readSources()
      if(result) {
        const current=new Map(projectedEvents(source).map(event=>[event.id,eventStamp(event)]))
        if([...bindings].some(([id,stamp])=>current.get(id)!==stamp))throw new Error('回答的来源已变化，请重新带入背景')
      } else {
        const history:ChatTurn[]=[]
        const include=async(ref:EventRef)=>{
          const event=await resolveEvent(source,ref);bindings.set(event.id,eventStamp(event))
          if(!refs.some(row=>this.refKey(row)===this.refKey(ref)))refs.push(ref)
          return event
        }
        const event=message.eventRef?await include(message.eventRef):undefined
        for(const id of message.requestHistoryIds??this.historyIds(message.topicId,message.id,message.eventRef)) {
          const turn=this.messages.get(id)
          if(!turn||turn.topicId!==message.topicId||turn.status!=='sent'||this.unsafeLegacy(turn))continue
          if(message.eventRef&&!this.references(turn).some(ref=>this.refKey(ref)===this.refKey(message.eventRef!)))continue
          const beforeRefs=[...refs],beforeBindings=new Map(bindings)
          try {for(const ref of this.references(turn))await include(ref)}catch{refs=beforeRefs;bindings=beforeBindings;continue}
          history.push({role:turn.role,text:turn.text})
        }
        const background=event?eventBackground(event):message.background
        // Check after asynchronous fingerprint work, immediately before the request.
        await sourceTransaction('readonly',fresh=>{
          const current=new Map(projectedEvents(fresh).map(event=>[event.id,eventStamp(event)]))
          if([...bindings].some(([id,stamp])=>current.get(id)!==stamp))throw new Error('来源已变化，请重新带入背景')
        })
        result=await chatService.reply({question:message.text,history,background})
        if(result.status==='ok'&&!result.text.trim())result={status:'failed',reason:'回复为空，可以重试'}
        this.pendingResults.set(message.id,result);this.pendingBindings.set(message.id,bindings);this.pendingRefs.set(message.id,refs)
      }
    }catch(error){result={status:'failed',reason:error instanceof Error?error.message:'没能核对当前来源，请重试'};this.pendingResults.set(message.id,result);bindings=new Map();this.pendingBindings.set(message.id,bindings)}
    const next:Message={...message,status:result.status==='ok'?'sent':result.status==='not-configured'?'waiting':'failed',failure:result.status==='ok'?undefined:result.reason}
    const sourceRefs=refs.length?refs:[...this.references(message)]
    const reply:Message|undefined=result.status==='ok'?{id:`${message.id}:reply`,topicId:message.topicId,role:'assistant',text:result.text,createdAt:Date.now(),status:'sent',replyTo:message.id,sourceRefs}:undefined
    try {
      const topic=await sourceTransaction('readwrite',(fresh,put)=>{
        const current=new Map(projectedEvents(fresh).map(event=>[event.id,eventStamp(event)]))
        if(reply&&[...bindings].some(([id,stamp])=>current.get(id)!==stamp))throw new Error('来源在回答期间已变化，请重新带入背景')
        const saved=(fresh.rows[STORE_TOPICS] as Topic[]).find(row=>row.id===message.topicId)
        if(!saved)throw new Error('话题未能读取，问题仍保留，请重试')
        const latest:Topic={...saved,updatedAt:Math.max(saved.updatedAt,Date.now()),
          title:saved.id===MAIN_TOPIC_ID?MAIN_TOPIC.title:saved.title}
        put(STORE_MESSAGES,next);put(STORE_TOPICS,latest);if(reply)put(STORE_MESSAGES,reply)
        return latest
      },[STORE_MESSAGES,STORE_TOPICS])
      this.messages.set(next.id,next);if(reply)this.messages.set(reply.id,reply);this.topics.set(topic.id,topic)
      this.pendingResults.delete(message.id);this.pendingBindings.delete(message.id);this.pendingRefs.delete(message.id);this.storageFailures.delete(message.id)
      this.snapshot={...this.snapshot,storageOk:true}
      await this.refreshVisibility()
    }catch(error){
      this.storageFailures.set(message.id,error instanceof Error?error.message:'本机保存失败，可以重试')
      this.snapshot={...this.snapshot,storageOk:false}
    }
  }
}

export const askStore = new AskStore()
export function useAsk(): AskSnapshot {
  return useSyncExternalStore(askStore.subscribe, askStore.getSnapshot, () => EMPTY)
}
