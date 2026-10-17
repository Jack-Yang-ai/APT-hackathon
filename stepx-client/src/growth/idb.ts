/* =============================================================================
 * 本地真实持久化（IndexedDB）
 *
 * 为什么不用 localStorage：录音分片的音频是二进制、单条就几 MB，
 * localStorage 只存字符串且有 5MB 上限，存不下也放不住。
 *
 * 这里存三类东西：
 *  1. `matters` / `segments` —— 记录与分段的元数据（含阶段、失败原因）；
 *  2. `blobs` —— 分段的音频本体。**这是「断网可恢复」的关键**：
 *     壳给的虚拟 URL 是会话内的，重启后未必还能取到文件；
 *     录完立刻把音频落到 IndexedDB，之后无论断网还是杀进程，都能从这里接着传。
 *  3. `topics` / `messages` —— 「问问」的话题与消息。
 *
 * **升级只新增 store**：每次打开都按名字逐个补建缺失的 store，已有的 store 与其里的
 * 数据一律不动。所以从旧版本升上来时，手机里已经录好的材料不会丢。
 * ========================================================================== */

import type { Sources } from './source-scope'
import type { Matter } from './types'
import type { BackgroundOwner } from './background-data'
const BACKGROUND_PREFIX='__background__:'

const DB_NAME = 'growth'
const DB_VERSION = 5

export const STORE_MATTERS = 'matters'
export const STORE_SEGMENTS = 'segments'
export const STORE_BLOBS = 'blobs'
export const STORE_TOPICS = 'topics'
export const STORE_MESSAGES = 'messages'
export const STORE_PROCESSING = 'processing'
export const STORE_ACTIONS = 'actions'
export const STORE_RECORDING_MEMORY = 'recording_memory'

let dbPromise: Promise<IDBDatabase> | null = null

function openDb(): Promise<IDBDatabase> {
  if (dbPromise) return dbPromise
  dbPromise = new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION)
    request.onupgradeneeded = () => {
      const db = request.result
      if (!db.objectStoreNames.contains(STORE_MATTERS)) {
        db.createObjectStore(STORE_MATTERS, { keyPath: 'id' })
      }
      if (!db.objectStoreNames.contains(STORE_SEGMENTS)) {
        const store = db.createObjectStore(STORE_SEGMENTS, { keyPath: 'id' })
        store.createIndex('matterId', 'matterId', { unique: false })
      }
      if (!db.objectStoreNames.contains(STORE_BLOBS)) {
        db.createObjectStore(STORE_BLOBS, { keyPath: 'id' })
      }
      if (!db.objectStoreNames.contains(STORE_PROCESSING)) db.createObjectStore(STORE_PROCESSING, { keyPath: 'id' })
      if (!db.objectStoreNames.contains(STORE_ACTIONS)) db.createObjectStore(STORE_ACTIONS, { keyPath: 'id' })
      if (!db.objectStoreNames.contains(STORE_RECORDING_MEMORY)) db.createObjectStore(STORE_RECORDING_MEMORY, { keyPath: 'id' })
      if (!db.objectStoreNames.contains(STORE_TOPICS)) {
        db.createObjectStore(STORE_TOPICS, { keyPath: 'id' })
      }
      if (!db.objectStoreNames.contains(STORE_MESSAGES)) {
        const store = db.createObjectStore(STORE_MESSAGES, { keyPath: 'id' })
        store.createIndex('topicId', 'topicId', { unique: false })
      }
    }
    request.onsuccess = () => {
      const db = request.result
      db.onversionchange = () => { db.close(); dbPromise = null }
      resolve(db)
    }
    request.onerror = () => reject(request.error ?? new Error('本地存储打开失败'))
  })
  // 打开失败时不要把失败的 Promise 永久缓存住，允许下次重试
  dbPromise.catch(() => {
    dbPromise = null
  })
  return dbPromise
}

function run<T>(
  store: string,
  mode: IDBTransactionMode,
  fn: (objectStore: IDBObjectStore) => IDBRequest<T>,
): Promise<T> {
  return openDb().then(
    (db) =>
      new Promise<T>((resolve, reject) => {
        const tx = db.transaction(store, mode)
        const request = fn(tx.objectStore(store))
        let result: T
        let requestSucceeded = false
        request.onsuccess = () => { result = request.result; requestSucceeded = true }
        tx.oncomplete = () => {
          if (requestSucceeded) resolve(result)
          else reject(new Error('本地存储请求未完成'))
        }
        request.onerror = () => reject(request.error ?? new Error('本地存储读写失败'))
        tx.onabort = () => reject(tx.error ?? new Error('本地存储事务被中止'))
      }),
  )
}

export function idbGetAll<T>(store: string): Promise<T[]> {
  return run<T[]>(store, 'readonly', (s) => s.getAll() as IDBRequest<T[]>)
}

export function idbGet<T>(store: string, id: string): Promise<T | undefined> {
  return run<T | undefined>(store, 'readonly', (s) => s.get(id) as IDBRequest<T | undefined>)
}

const sourceStores = new Set([STORE_MATTERS, STORE_SEGMENTS, STORE_PROCESSING])
const dirtyInTransaction=new WeakMap<IDBTransaction,Map<string,{deleted:boolean;removed:Map<string,number>;owner?:BackgroundOwner}>>()
/** User control is durable in the same transaction as the formal edit/deletion. */
function dirtyBackground(tx:IDBTransaction,recordingId:string,deleted=false,removedId?:string,removedIndex?:number):void {
  let states=dirtyInTransaction.get(tx);if(!states){states=new Map();dirtyInTransaction.set(tx,states)}
  let state=states.get(recordingId);const prior=!!state
  if(!state){state={deleted:false,removed:new Map()};states.set(recordingId,state)}
  state.deleted||=deleted;if(removedId&&removedIndex!==undefined)state.removed.set(removedId,removedIndex)
  const store=tx.objectStore(STORE_PROCESSING),change=state
  const write=()=>{const owner=change.owner;if(owner)store.put({...owner,epoch:owner.epoch+1,dirty:true,
    removedIds:[...new Set([...(owner.removedIds??[]),...change.removed.keys()])],
    removedIndices:{...owner.removedIndices,...Object.fromEntries(change.removed)},...(change.deleted?{deleted:true}:{})})}
  if(prior){write();return}
  const read=store.get(BACKGROUND_PREFIX+recordingId)
  read.onsuccess=()=>{change.owner=read.result;write()}
}
/** Revoke cached plaintext in the very transaction changing the formal source. */
function revokeMemory(tx: IDBTransaction, recordingId: string): void {
  const memory = tx.objectStore(STORE_RECORDING_MEMORY), read = memory.getAll()
  read.onsuccess = () => {
    for (const row of read.result) if (row.recordingId === recordingId && row.record && !row.record.deleted) {
      if (!Number.isSafeInteger(row.record.revision) || row.record.revision >= Number.MAX_SAFE_INTEGER) { tx.abort(); return }
      memory.put({ ...row, record: { ...row.record, revision: row.record.revision + 1,
        title: '已移出记忆', text: '', deleted: true,
        updated: new Date(Math.max(Date.now(), Date.parse(row.record.created))).toISOString() } })
    }
  }
}
function revokeSource(tx: IDBTransaction, store: string, value: unknown): void {
  if (!sourceStores.has(store) || !value || typeof value !== 'object') return
  const row = value as { id?: string; matterId?: string; recordingId?: string }
  const recordingId = store === STORE_MATTERS ? row.id : store === STORE_SEGMENTS ? row.matterId
    : row.id?.startsWith('__') ? undefined : row.recordingId
  if (recordingId) revokeMemory(tx, recordingId)
  if (row.id && (store === STORE_SEGMENTS || (store === STORE_PROCESSING && !row.id.startsWith('__')))) {
    const prior = tx.objectStore(store).get(row.id)
    prior.onsuccess = () => {
      const oldOwner = store === STORE_SEGMENTS ? prior.result?.matterId : prior.result?.recordingId
      if (oldOwner && oldOwner !== recordingId) {revokeMemory(tx, oldOwner);dirtyBackground(tx,oldOwner,false,row.id,prior.result.index)}
    }
  }
}
export function idbPut(store: string, value: unknown): Promise<IDBValidKey> {
  if (sourceStores.has(store)) return sourceTransaction('readwrite', (_source, put) => {
    put(store, value); return (value as { id: string }).id
  })
  return run<IDBValidKey>(store, 'readwrite', (s) => s.put(value))
}

/** Read and change one record inside the same transaction, including across tabs. */
export async function idbUpdate<T>(store: string, id: string, update: (current: T | undefined) => T): Promise<T> {
  const db = await openDb()
  return new Promise<T>((resolve, reject) => {
    const tx = db.transaction(sourceStores.has(store) ? [...new Set([store, STORE_RECORDING_MEMORY,STORE_PROCESSING])] : store, 'readwrite'), objectStore = tx.objectStore(store)
    let result: T
    tx.oncomplete = () => resolve(result)
    tx.onabort = () => reject(tx.error ?? new Error('本地存储事务被中止'))
    tx.onerror = () => reject(tx.error ?? new Error('本地存储读写失败'))
    const read = objectStore.get(id)
    read.onsuccess = () => {
      try {
        result = update(read.result)
        if (sourceStores.has(store) && (result as { id?: string }).id !== id) throw new Error('正式来源身份不可改写')
        revokeSource(tx, store, result); objectStore.put(result)
        if(sourceStores.has(store)) {
          const row=result as {id:string;recordingId?:string;matterId?:string}
          const recordingId=store===STORE_MATTERS?row.id:store===STORE_SEGMENTS?row.matterId:row.id.startsWith('__')?undefined:row.recordingId
          if(recordingId)dirtyBackground(tx,recordingId)
        }
      }
      catch (error) { tx.abort(); reject(error) }
    }
  })
}

export function idbDelete(store: string, id: string): Promise<undefined> {
  if (sourceStores.has(store)) throw new Error('正式来源删除须通过录音删除入口')
  return run<undefined>(store, 'readwrite', (s) => s.delete(id) as IDBRequest<undefined>)
}

export function idbClear(store: string): Promise<undefined> {
  if (sourceStores.has(store)) throw new Error('正式来源清理须通过录音删除入口')
  return run<undefined>(store, 'readwrite', (s) => s.clear() as IDBRequest<undefined>)
}

/** 本地存储是否可用（隐私模式 / 老旧内核下可能被禁用） */
export async function isLocalStoreAvailable(): Promise<boolean> {
  try {
    await openDb()
    return true
  } catch {
    return false
  }
}

/** 多条记录在同一个事务中提交；任何写入失败时整体回滚。 */
export async function idbPutMany(writes: { store: string; value: unknown }[]): Promise<void> {
  if (!writes.length) return
  const db = await openDb()
  return new Promise<void>((resolve, reject) => {
    const tx = db.transaction([...new Set([...writes.map((write) => write.store),
      ...(writes.some(write => sourceStores.has(write.store)) ? [STORE_RECORDING_MEMORY,STORE_PROCESSING] : [])])], 'readwrite')
    tx.oncomplete = () => resolve()
    tx.onabort = () => reject(tx.error ?? new Error('本地存储事务被中止'))
    tx.onerror = () => reject(tx.error ?? new Error('本地存储读写失败'))
    try {
      for (const { store, value } of writes) {
        revokeSource(tx, store, value); tx.objectStore(store).put(value)
        const row=value as {id?:string;recordingId?:string;matterId?:string}
        const recordingId=store===STORE_MATTERS?row.id:store===STORE_SEGMENTS?row.matterId:store===STORE_PROCESSING&&!row.id?.startsWith('__')?row.recordingId:undefined
        if(recordingId)dirtyBackground(tx,recordingId)
      }
    } catch (error) {
      tx.abort()
      reject(error)
    }
  })
}

/** Audio, owner, deletion tombstone and root delivery receipt share one transaction. */
export async function idbCommitAudio(
  segment: { id: string; matterId: string }, blob: Blob,
  receipt?: { id: string; sha256: string }, recoveredMatter?: unknown,
): Promise<'saved' | 'duplicate' | 'deleted' | 'missing'> {
  const db = await openDb()
  return new Promise((resolve, reject) => {
    const tx = db.transaction([STORE_MATTERS, STORE_SEGMENTS, STORE_BLOBS, STORE_PROCESSING, STORE_RECORDING_MEMORY], 'readwrite')
    const owners = tx.objectStore(STORE_MATTERS), meta = tx.objectStore(STORE_PROCESSING)
    let result: 'saved' | 'duplicate' | 'deleted' | 'missing' = 'missing'
    tx.oncomplete = () => resolve(result)
    tx.onabort = () => reject(tx.error ?? new Error('录音事务未完成'))
    tx.onerror = () => reject(tx.error ?? new Error('录音事务未完成'))
    const deleted = meta.get('__deleted_matter__:' + segment.matterId)
    deleted.onsuccess = () => {
      if (deleted.result) { result = 'deleted'; return }
      const owner = owners.get(segment.matterId)
      owner.onsuccess = () => {
        if (!owner.result && !recoveredMatter) return
        const commit = () => {
          revokeSource(tx, STORE_SEGMENTS, segment)
          if (recoveredMatter && !owner.result) owners.put(recoveredMatter)
          tx.objectStore(STORE_BLOBS).put({ id: segment.id, blob })
          tx.objectStore(STORE_SEGMENTS).put(segment)
          dirtyBackground(tx,segment.matterId)
          if (receipt) meta.put(receipt)
          result = 'saved'
        }
        if (!receipt) { commit(); return }
        const prior = meta.get(receipt.id)
        prior.onsuccess = () => {
          if (!prior.result) { commit(); return }
          if (prior.result.sha256 !== receipt.sha256) { tx.abort(); return }
          const audio = tx.objectStore(STORE_BLOBS).get(segment.id)
          audio.onsuccess = () => {
            // Recover a missing local Blob from the still retained root original.
            if (!audio.result?.blob || audio.result.blob.size !== blob.size) commit()
            else result = 'duplicate'
          }
        }
      }
    }
  })
}

/** Source checks and derived writes share a single transaction with source deletion. */
export async function sourceTransaction<T>(mode: IDBTransactionMode,
  apply: (source: Sources & { actionRows: unknown[]; rows: Record<string, unknown[]> }, put: (store: string, row: unknown) => void) => T,
  extraStores: string[] = [], backgroundWrite=false): Promise<T> {
  const db = await openDb()
  return new Promise((resolve,reject) => {
    const stores = [...new Set([STORE_MATTERS,STORE_SEGMENTS,STORE_PROCESSING,STORE_ACTIONS,
      ...(mode === 'readwrite' ? [STORE_RECORDING_MEMORY] : []),...extraStores])]
    const tx = db.transaction(stores,mode)
    const values: Record<string, unknown[]> = {}; let result: T, failure: unknown, remaining = stores.length
    tx.oncomplete = () => resolve(result)
    tx.onabort = () => reject(failure ?? tx.error ?? new Error('来源校验或保存未完成，请重试'))
    tx.onerror = () => reject(failure ?? tx.error ?? new Error('来源校验或保存未完成，请重试'))
    for (const store of stores) {
      const read = tx.objectStore(store).getAll()
      read.onsuccess = () => {
        values[store] = read.result
        if (--remaining) return
        try { result = apply({ matters:values[STORE_MATTERS],segments:values[STORE_SEGMENTS],
          jobs:values[STORE_PROCESSING],actionRows:values[STORE_ACTIONS],rows:values } as Sources & { actionRows:unknown[]; rows:Record<string, unknown[]> },
          (target,row) => {
            revokeSource(tx,target,row);tx.objectStore(target).put(row)
            if(!backgroundWrite) {
              const value=row as {id?:string;recordingId?:string;matterId?:string}
              const recordingId=target===STORE_MATTERS?value.id:target===STORE_SEGMENTS?value.matterId
                :target===STORE_PROCESSING&&!value.id?.startsWith('__')?value.recordingId:undefined
              if(recordingId)dirtyBackground(tx,recordingId)
            }
          }) }
        catch (error) { failure=error; tx.abort() }
      }
    }
  })
}
export const readSources = (): Promise<Sources> => sourceTransaction('readonly',source => source)

/** Serialize deletion intent with START authorization across separate WebViews. */
export async function idbPrepareMatterDeletion(id: string): Promise<Matter | undefined> {
  const db = await openDb()
  return new Promise((resolve,reject) => {
    const tx = db.transaction([STORE_MATTERS,STORE_PROCESSING],'readwrite'), store = tx.objectStore(STORE_MATTERS)
    let result: Matter | undefined
    tx.oncomplete = () => resolve(result)
    tx.onabort = () => reject(tx.error ?? new Error('删除准备未完成，请重试'))
    tx.onerror = () => reject(tx.error ?? new Error('删除准备未完成，请重试'))
    const read = store.get(id)
    read.onsuccess = () => {
      if (!read.result) return
      result = { ...read.result, rootDeletionPending:true }
      store.put(result)
      dirtyBackground(tx,id,true)
    }
  })
}

export async function idbDeleteMatter(id: string): Promise<void> {
  const db = await openDb()
  return new Promise((resolve, reject) => {
    const tx = db.transaction([STORE_MATTERS, STORE_SEGMENTS, STORE_BLOBS, STORE_PROCESSING, STORE_RECORDING_MEMORY], 'readwrite')
    tx.oncomplete = () => resolve()
    tx.onabort = () => reject(tx.error ?? new Error('删除未完成，请重试'))
    tx.onerror = () => reject(tx.error ?? new Error('删除未完成，请重试'))
    revokeMemory(tx, id)
    dirtyBackground(tx,id,true)
    tx.objectStore(STORE_PROCESSING).put({ id: '__deleted_matter__:' + id, deletedAt: Date.now() })
    tx.objectStore(STORE_MATTERS).delete(id)
    const derived = tx.objectStore(STORE_PROCESSING).getAll()
    derived.onsuccess = () => {
      for (const row of derived.result) if (row.recordingId === id&&!row.id.startsWith(BACKGROUND_PREFIX)) tx.objectStore(STORE_PROCESSING).delete(row.id)
    }
    const read = tx.objectStore(STORE_SEGMENTS).getAll()
    read.onsuccess = () => {
      for (const row of read.result) if (row.matterId === id) {
        tx.objectStore(STORE_SEGMENTS).delete(row.id)
        tx.objectStore(STORE_BLOBS).delete(row.id)
        tx.objectStore(STORE_PROCESSING).delete(row.id)
      }
    }
  })
}

/** Atomic lease + receipt commits. A callback from an expired runner cannot write. */
export async function processingLease(owner: string, action: 'claim' | 'renew' | 'put' | 'release', job?: unknown): Promise<boolean> {
  const db = await openDb()
  return new Promise<boolean>((resolve, reject) => {
    const tx = db.transaction([STORE_PROCESSING, STORE_MATTERS, STORE_SEGMENTS, STORE_RECORDING_MEMORY], 'readwrite'), store = tx.objectStore(STORE_PROCESSING)
    let accepted = false
    tx.oncomplete = () => resolve(accepted)
    tx.onabort = () => reject(tx.error ?? new Error('处理回执未保存，请重试'))
    tx.onerror = () => reject(tx.error ?? new Error('处理回执未保存，请重试'))
    const read = store.get('__runner__')
    read.onsuccess = () => {
      const lease = read.result as { owner: string; until: number } | undefined
      const now = Date.now()
      if (action === 'release') {
        if (lease?.owner === owner) { store.delete('__runner__'); accepted = true }
        return
      }
      if (action === 'claim') {
        if (lease && lease.owner !== owner && lease.until > now) return
      } else if (!lease || lease.owner !== owner || lease.until <= now) return
      if (action === 'put') {
        const candidate = job as { id: string; recordingId: string }
        const source = tx.objectStore(STORE_SEGMENTS).get(candidate.id)
        source.onsuccess = () => {
          if (!source.result || source.result.matterId !== candidate.recordingId) return
          const recording = tx.objectStore(STORE_MATTERS).get(candidate.recordingId)
          recording.onsuccess = () => {
            if (!recording.result || lease!.until <= Date.now()) return
            const delegated=store.get(BACKGROUND_PREFIX+candidate.recordingId)
            delegated.onsuccess=()=>{
              if(delegated.result)return
              store.put({ id: '__runner__', owner, until: Date.now() + 90000 })
              revokeSource(tx, STORE_PROCESSING, job)
              store.put(job); accepted = true
            }
          }
        }
      } else { store.put({ id: '__runner__', owner, until: now + 90000 }); accepted = true }
    }
  })
}
