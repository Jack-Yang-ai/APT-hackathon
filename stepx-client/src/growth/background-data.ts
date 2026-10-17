import type { ProcessingJob } from './processing-data'
import type { Matter, Segment } from './types'
import type { MemoryRow } from './recording-memory-data'
import type { RootSession } from './root-recording'
export const BACKGROUND_PREFIX='__background__:'
export interface BackgroundSnapshot { matter:Matter;segments:Segment[];jobs:ProcessingJob[];memory:MemoryRow[];captures?:RootSession[] }
export interface BackgroundOwner {
  id:string;recordingId:string;namespace:string;generation:string;handoffId:string
  phase:'preparing'|'active'|'revoked';controlVersion:number;epoch:number;dirty:boolean;deleted?:boolean
  snapshot:BackgroundSnapshot;jobStamps:Record<string,string>;matterStamp:string
  retry?:'failed'|'actions'
  removedIds?:string[]
  removedIndices?:Record<string,number>
  blockedEpoch?:number
  control?:{version:number;mutationId:string;epoch:number;snapshot:BackgroundSnapshot;deleted:boolean;retry?:'failed'|'actions';removedIds?:string[];removedIndices?:Record<string,number>}
  error?:string;lastSuccess?:number;remoteDone?:number;remoteTotal?:number;remoteFailed?:number;remoteSources?:number;remotePending?:number
}
export const backgroundOwner=(jobs:unknown[],id:string):BackgroundOwner|undefined=>
  jobs.find(row=>(row as BackgroundOwner).id===BACKGROUND_PREFIX+id) as BackgroundOwner|undefined
export const backgroundMatterStamp=(matter:Matter)=>JSON.stringify([matter.id,matter.startedAt,matter.endedAt,
  matter.captureComplete??null,matter.rootFinalizing??false,matter.personalActionsEnabled??false,matter.recordingTimeUnverified??false,matter.rootDeletionPending??false])
