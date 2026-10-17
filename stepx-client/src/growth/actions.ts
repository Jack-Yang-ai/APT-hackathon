import { useSyncExternalStore } from 'react'
import { idbGetAll, idbUpdate, STORE_ACTIONS } from './idb'
import { newId } from './store'
import { sourceTransaction } from './idb'
import { currentCandidate, currentEvaluations, candidateSuppressed, ignoredId } from './personal-action-data'
import type { PersonalCandidate, IgnoredAction } from './personal-action-data'
import { projectedEvents, type Sources } from './source-scope'
import { normalizeQuote } from './quote-normalize'

export interface ActionSource { recordingId: string; eventId?: string; responsibilityLineId?: number; evaluationId?: string; candidateKey?:string }
export type ActionPhase = 'next' | 'confirm' | 'followup' | 'doing'
export type ActionStatus = ActionPhase | 'done' | 'cancelled'
export const ACTION_LABELS: Record<ActionStatus, string> = { next: '下一步', confirm: '待确认', followup: '待跟进', doing: '进行中', done: '已完成', cancelled: '已取消' }
const PHASES: ActionPhase[] = ['next', 'confirm', 'followup', 'doing']
export function actionPhase(action: GrowthAction): ActionPhase {
  return action.phase ?? (action.kind === 'request' ? 'confirm' : action.kind === 'follow_up' ? 'followup' : 'next')
}
export function actionStatus(action: GrowthAction): ActionStatus {
  return action.cancelled ? 'cancelled' : action.done ? 'done' : actionPhase(action)
}
/** Resolve display evidence through the same validated evaluations used by adoption. */
export function actionOrigin(action: GrowthAction, source: Sources) {
  const ref = action.source
  if (!ref) return { warning: null, event: undefined, quote: undefined, to: undefined }
  const matter = source.matters.find(row => row.id === ref.recordingId)
  const event = projectedEvents(source).find(row => row.id === ref.eventId && (ref.responsibilityLineId === undefined || row.lineIds.includes(ref.responsibilityLineId)))
  const evaluation = ref.evaluationId ? currentEvaluations(source, ref.recordingId).find(row => row.requestId === ref.evaluationId) : undefined
  const candidate = evaluation?.candidates?.find(row => row.lineId === ref.responsibilityLineId && normalizeQuote(row.title) === ref.candidateKey)
  const warning = !matter ? '来源已不在本机，行动和修改仍保留。' : (ref.evaluationId && !candidate) || (ref.eventId && !event) ? '出处已变化，请重新核验；行动和状态仍保留。' : null
  return { warning, event: warning ? undefined : event, quote: warning ? undefined : candidate?.evidence.map(row => row.quote).join('\n'),
    to: matter ? event ? `/events/${encodeURIComponent(event.id)}` : `/recordings/${encodeURIComponent(matter.id)}` : undefined }
}
export interface GrowthAction {
  id: string; title: string; dueAt: number | null; done: boolean
  createdAt: number; updatedAt: number; source?: ActionSource
  removedAt?: number | null; cancelled?: boolean; kind?: 'accepted' | 'request' | 'follow_up'
  condition?: string; deadline?: string; collaborators?: string; nextStep?: string
  phase?: ActionPhase
}
export interface ActionDraft { title: string; dueAt?: number | null; source?: ActionSource; condition?: string; deadline?: string; collaborators?: string; nextStep?: string; status?: ActionStatus }
export interface ActionsSnapshot { ready: boolean; actions: GrowthAction[]; ignored: IgnoredAction[]; error: string | null }
const EMPTY: ActionsSnapshot = { ready: false, actions: [], ignored: [], error: null }
const timestamp = (value: unknown): value is number => typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 8640000000000000
function draft(input: ActionDraft): Omit<ActionDraft, 'status'> & { dueAt: number | null; phase?: ActionPhase; done?: boolean; cancelled?: boolean } {
  if (typeof input.title !== 'string' || !input.title.trim() || input.title.trim().length > 240) throw new Error('行动内容需要 1–240 个字')
  const dueAt = input.dueAt ?? null
  if (dueAt !== null && !timestamp(dueAt)) throw new Error('行动时间无效，请重新选择')
  const source = input.source
  if (input.status !== undefined && !Object.prototype.hasOwnProperty.call(ACTION_LABELS, input.status)) throw new Error('行动状态无效')
  if (source !== undefined && (!source || typeof source !== 'object' || Array.isArray(source) || typeof source.recordingId !== 'string' || !source.recordingId || source.recordingId.length > 160
    || (source.eventId !== undefined && (typeof source.eventId !== 'string' || !source.eventId || source.eventId.length > 200)))) throw new Error('行动来源无效')
  if (source?.responsibilityLineId !== undefined && (!Number.isSafeInteger(source.responsibilityLineId) || source.responsibilityLineId<=0)) throw new Error('行动责任行无效')
  const details: Partial<ActionDraft> = {}
  for (const field of ['condition','deadline','collaborators','nextStep'] as const) if (input[field]!==undefined) {
    if (typeof input[field]!=='string' || input[field]!.length>2400) throw new Error('行动补充内容过长')
    details[field]=input[field]!.trim()
  }
  const state = input.status === undefined ? {} : {
    ...(PHASES.includes(input.status as ActionPhase) ? { phase: input.status as ActionPhase } : {}),
    done: input.status === 'done', cancelled: input.status === 'cancelled',
  }
  return { title: input.title.trim(), dueAt, ...details, ...state, ...(source ? { source: { ...source } } : {}) }
}
function valid(row: GrowthAction): GrowthAction {
  if (!row || typeof row.id !== 'string' || !row.id || typeof row.done !== 'boolean' || !timestamp(row.createdAt) || !timestamp(row.updatedAt)) throw new Error('行动数据无法读取，请保留 App 并重试')
  if ((row.removedAt!==undefined && row.removedAt!==null && !timestamp(row.removedAt)) || (row.cancelled!==undefined && typeof row.cancelled!=='boolean')) throw new Error('行动状态无法读取')
  if (row.phase !== undefined && !PHASES.includes(row.phase)) throw new Error('行动状态无法读取')
  return { ...row, ...draft(row) }
}
export function orderedActions(rows: GrowthAction[]): GrowthAction[] {
  return [...rows].sort((a, b) => Number(a.done) - Number(b.done)
    || (a.dueAt ?? Infinity) - (b.dueAt ?? Infinity) || a.createdAt - b.createdAt || a.id.localeCompare(b.id))
}
interface ActionDependencies {
  read(): Promise<(GrowthAction | IgnoredAction)[]>
  mutate(id: string, update: (current: GrowthAction | undefined) => GrowthAction): Promise<GrowthAction>
  id(): string
}
const DEFAULT: ActionDependencies = { read: () => idbGetAll<GrowthAction>(STORE_ACTIONS), mutate: (id, update) => idbUpdate(STORE_ACTIONS, id, update), id: newId }
export class ActionsStore {
  private snapshot: ActionsSnapshot = EMPTY
  private listeners = new Set<() => void>()
  private operations: Promise<void> = Promise.resolve()
  constructor(private deps: ActionDependencies = DEFAULT) {}
  subscribe = (listener: () => void): (() => void) => { this.listeners.add(listener); return () => { this.listeners.delete(listener) } }
  getSnapshot = (): ActionsSnapshot => this.snapshot
  private emit(patch: Partial<ActionsSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch }; this.listeners.forEach(listener => listener())
  }
  private run<T>(operation: () => Promise<T>): Promise<T> {
    const pending = this.operations.then(operation).catch(error => {
      this.emit({ error: error instanceof Error ? error.message : '行动未保存，请重试' }); throw error
    })
    this.operations = pending.then(() => undefined, () => undefined)
    return pending
  }
  private async load(force=false): Promise<void> {
    if (this.snapshot.ready && !force) return
    const stored=await this.deps.read(), rows:GrowthAction[]=[],ignored:IgnoredAction[]=[]
    for (const row of stored) {
      if ('type' in row && row.type==='ignored') {
        if (row.id!==ignoredId(row.recordingId,row.lineId) || !Number.isSafeInteger(row.lineId) || row.lineId<=0 || (row.removedAt!==null && !timestamp(row.removedAt))) throw new Error('忽略记录无法读取')
        ignored.push(row)
      } else rows.push(valid(row as GrowthAction))
    }
    this.emit({ ready: true, actions: orderedActions(rows), ignored, error: null })
  }
  init(): Promise<void> { return this.run(() => this.load()) }
  refresh(): Promise<void> { return this.run(() => this.load(true)) }
  private publish(row: GrowthAction): void {
    this.emit({ actions: orderedActions([...this.snapshot.actions.filter(action => action.id !== row.id), valid(row)]), error: null })
  }
  create(input: ActionDraft): Promise<GrowthAction> {
    // Freeze the user's explicit input before waiting for an earlier transaction.
    const frozen = structuredClone(input)
    return this.run(async () => {
      await this.load(); const fields = draft(frozen), id = this.deps.id(), now = Date.now()
      const row = await this.deps.mutate(id, current => {
        if (current) throw new Error('行动编号已存在，请重试')
        return { id, ...fields, done: fields.done ?? false, cancelled: fields.cancelled ?? false, createdAt: now, updatedAt: now }
      })
      this.publish(row); return row
    })
  }
  edit(id: string, input: ActionDraft): Promise<void> {
    const frozen = structuredClone(input)
    return this.run(async () => {
      await this.load(); const fields = draft(frozen)
      const row = await this.deps.mutate(id, current => {
        if (!current || current.removedAt) throw new Error('这条行动已移除，请先恢复')
        return { ...valid(current), ...fields, source:current.source, updatedAt: Date.now() }
      })
      this.publish(row)
    })
  }
  setDone(id: string, done: boolean): Promise<void> {
    return this.run(async () => {
      await this.load()
      if (typeof done !== 'boolean') throw new Error('行动状态无效')
      const row = await this.deps.mutate(id, current => {
        if (!current || current.removedAt) throw new Error('这条行动已移除，请先恢复')
        return { ...valid(current), done, updatedAt: Date.now() }
      })
      this.publish(row)
    })
  }
  setStatus(id: string, status: ActionStatus): Promise<void> {
    return this.run(async () => {
      await this.load()
      if (!Object.prototype.hasOwnProperty.call(ACTION_LABELS, status)) throw new Error('行动状态无效')
      const row = await this.deps.mutate(id, current => {
        if (!current || current.removedAt) throw new Error('这条行动已移除，请先恢复')
        return { ...valid(current), phase: PHASES.includes(status as ActionPhase) ? status as ActionPhase : actionPhase(current),
          done: status === 'done', cancelled: status === 'cancelled', updatedAt: Date.now() }
      })
      this.publish(row)
    })
  }
  private changeState(id:string, change:Partial<Pick<GrowthAction,'removedAt'|'cancelled'>>): Promise<void> {
    return this.run(async()=>{
      await this.load()
      const row=await this.deps.mutate(id,current=>{
        if (!current) throw new Error('这条行动已经不存在，请重新打开')
        if (current.removedAt && change.removedAt!==null) throw new Error('这条行动已移除，请先恢复')
        return { ...valid(current),...change,updatedAt:Date.now() }
      }); this.publish(row)
    })
  }
  remove(id:string):Promise<void> { return this.changeState(id,{removedAt:Date.now()}) }
  restore(id:string):Promise<void> { return this.changeState(id,{removedAt:null}) }
  setCancelled(id:string,cancelled:boolean):Promise<void> { return this.changeState(id,{cancelled}) }
  /** The caller must explicitly confirm ownership; a cluster label never grants it. */
  adopt(candidate:PersonalCandidate, confirmedMine:boolean, input:ActionDraft):Promise<GrowthAction> {
    const frozen=structuredClone(candidate), fields=draft(structuredClone(input)),id=this.deps.id()
    return this.run(async()=>{
      if (confirmedMine!==true) throw new Error('请先确认这项行动是自己的')
      const row=await sourceTransaction('readwrite',(source,put)=>{
        const current=currentCandidate(source,frozen)
        if (candidateSuppressed(source.actionRows,current)) throw new Error('这项行动已保存、移除或忽略，请到相应列表查看')
        const event=projectedEvents(source).find(row=>row.recordingId===current.recordingId&&row.lineIds.includes(current.lineId))
        const row:GrowthAction={id,...fields,source:{recordingId:current.recordingId,responsibilityLineId:current.lineId,evaluationId:current.evaluationId,candidateKey:normalizeQuote(current.title),...(event?{eventId:event.id}:{})},
          kind:current.kind,done:fields.done??false,cancelled:fields.cancelled??false,removedAt:null,createdAt:Date.now(),updatedAt:Date.now()}
        put(STORE_ACTIONS,row); return row
      }); await this.load(true); return row
    })
  }
  ignore(candidate:PersonalCandidate):Promise<void> {
    const frozen=structuredClone(candidate)
    return this.run(async()=>{
      await sourceTransaction('readwrite',(source,put)=>{
        const current=currentCandidate(source,frozen)
        if (candidateSuppressed(source.actionRows,current)) throw new Error('这项行动已经处理，请重新打开')
        put(STORE_ACTIONS,{id:ignoredId(current.recordingId,current.lineId),type:'ignored',recordingId:current.recordingId,lineId:current.lineId,removedAt:Date.now()})
      }); await this.load(true)
    })
  }
  restoreIgnored(id:string):Promise<void> {
    return this.run(async()=>{
      await sourceTransaction('readwrite',(source,put)=>{
        const row=source.actionRows.find(raw=>(raw as IgnoredAction).id===id) as IgnoredAction | undefined
        if (!row || row.type!=='ignored') throw new Error('忽略记录已变化，请重新打开')
        put(STORE_ACTIONS,{...row,removedAt:null})
      }); await this.load(true)
    })
  }
}
export const actionsStore = new ActionsStore()
export function useActions(): ActionsSnapshot { return useSyncExternalStore(actionsStore.subscribe, actionsStore.getSnapshot, () => EMPTY) }
