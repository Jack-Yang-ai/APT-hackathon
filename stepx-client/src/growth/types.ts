/**
 * StepX 的采集场次（Matter）与传输分片（Segment）沿用现有持久化字段。
 * 语义上的事、逐字稿与云端回执由 processing-data 定义；分片边界不代表一件事。
 * 旧枚举与库字段保留兼容。界面只展示已有材料和真实处理回执。
 */

/** 分片的处理阶段。四态必须能分别显示：待上传 / 上传中 / 等待理解 / 已理解，失败单独标红。 */
export type SegmentStage =
  /** 已录到本机（音频已缓存），等待上传 */
  | 'recorded'
  /** 上传中 */
  | 'uploading'
  /** 已上传，等待云端理解 */
  | 'uploaded'
  /** 旧的云端理解完成状态（保留持久化兼容） */
  | 'understood'
  /** 上传失败（可重试） */
  | 'failed'

/** 一段音频分片 */
export interface Segment {
  id: string
  matterId: string
  /** 这次录音里的第几段，从 0 开始 */
  index: number
  /** 分片开始时间（毫秒时间戳；沿用 capturedAt 字段） */
  capturedAt: number
  /** 时长（秒） */
  durationSec: number
  /** 字节数；取不到时为 0 */
  sizeBytes: number
  /** 壳给出的虚拟 URL（https://<页面主机>/media/xxx.m4a），本机会话内可用于播放 */
  localUrl: string
  stage: SegmentStage
  /** 云端对象路径（上传成功后写入） */
  remotePath?: string
  /** 旧的逐字稿字段；当前逐句原话取 processing 回执 */
  transcript?: string | null
  /** 最近一次失败的脱敏原因（只说人话，不落原始堆栈） */
  failure?: string
  /** 已尝试上传次数 */
  attempts: number
  /** Recovered private files stay local until their ownership and timing are checked. */
  cloudEligible?: boolean
  /** Native uploader owns this exact PCM; the App consumes its server receipt. */
  rootUpload?: { captureId: string; piece: number; sha256: string; client: string }
  rootAudioFormat?: 'm4a'
  nativeFileName?: string
}

/** 一次采集场次；它的边界不是语义上的一件事。 */
export interface Matter {
  id: string
  /** 开始时间（毫秒时间戳） */
  startedAt: number
  /** 用户确认的结束时间；null 不能证明原生麦克风仍在录制 */
  endedAt: number | null
  /** 来源：本机录制 / 从文件导入 */
  origin: 'record' | 'import'
  /** 旧的标题字段；当前语义结果读 processing.events */
  title: string | null
  /** 旧的进展字段，保留兼容 */
  progress: string | null
  recoveredFromNative?: boolean
  recordingTimeUnverified?: boolean
  /** New recordings opt into independent whole-record action recognition after closing. */
  personalActionsEnabled?: boolean
  captureComplete?: boolean
  /** Microphone is stopped; closed native pieces are still being prepared/received. */
  rootFinalizing?: boolean
  /** Marks root START intent before dispatch, so deletion revokes even a delayed START. */
  rootUploadClient?: string
  /** Durable deletion intent denies a concurrent START; retained for retry if root is unavailable. */
  rootDeletionPending?: boolean
}

/** 上传 / 理解的整体状态，用于页面上的状态条 */
export type SyncPhase =
  | 'idle'
  /** 有分片待上传（含离线积压） */
  | 'pending'
  /** 正在上传 */
  | 'uploading'
  /** 全部已上传，等云端理解 */
  | 'waiting'
  /** 有分片上传失败 */
  | 'failed'

/** 分片阶段的展示文案（一句话说清"现在到哪一步了"） */
export const SEGMENT_STAGE_LABEL: Record<SegmentStage, string> = {
  recorded: '待上传',
  uploading: '上传中',
  uploaded: '已上传 · 等待理解',
  understood: '已理解',
  failed: '上传失败',
}

/** 「此刻」页状态条的主文案。空数据不套用。 */
export const SYNC_PHASE_LABEL: Record<SyncPhase, string> = {
  idle: '随时可以开始',
  pending: '有分片待上传',
  uploading: '正在上传',
  waiting: '已上传 · 等待理解',
  failed: '有分片上传失败',
}

/** 从这次录音的分段推导整体状态 */
export function deriveSyncPhase(segments: Segment[]): SyncPhase {
  if (segments.length === 0) return 'idle'
  if (segments.some((s) => s.stage === 'failed')) return 'failed'
  if (segments.some((s) => s.stage === 'uploading')) return 'uploading'
  if (segments.some((s) => s.stage === 'recorded')) return 'pending'
  if (segments.some((s) => s.stage === 'uploaded')) return 'waiting'
  return 'idle'
}
