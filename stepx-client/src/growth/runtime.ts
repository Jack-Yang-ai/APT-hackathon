/* =============================================================================
 * 运行期接线：应用启动时只做三件事
 *  1. 把本地记录载入内存；
 *  2. 网络恢复 / 回到前台时，把积压的"待上传"重新排进队列（断网可恢复）；
 *  3. 探测当前宿主有没有录音能力（电脑预览没有，页面要如实说明）。
 * ========================================================================== */

import { useEffect, useState } from 'react'

import { initBridge, isNativeApiAvailable, onNativeEvent } from '@/shared/bridge'

import { growthStore } from './store'
import { recorder } from './recording-controller'
import { resumePendingUploads } from './upload'
import { recordingMemory } from './recording-memory'
import { backgroundProcessing } from './background'

/** 应用启动接线。在 App 顶层调用一次。 */
export function useGrowthRuntime(): void {
  useEffect(() => {
    void growthStore.init()
    void recorder.initialize()
    backgroundProcessing.init()

    // 分片还在 IndexedDB 里，回到前台 / 网络恢复就能接着传
    const disposers: Array<() => void> = []
    void onNativeEvent('networkStatusChange', (payload) => {
      if (payload?.isConnected) { resumePendingUploads(); void recordingMemory.kick() }
    }).then((dispose) => disposers.push(dispose))

    // 网络事件之外再兜一层：有些环境不推 networkStatusChange，回到前台时也试一次
    const onVisible = () => {
      if (document.visibilityState === 'visible') { resumePendingUploads(); void recordingMemory.kick() }
    }
    document.addEventListener('visibilitychange', onVisible)

    return () => {
      disposers.forEach((dispose) => dispose())
      document.removeEventListener('visibilitychange', onVisible)
      backgroundProcessing.dispose()
    }
  }, [])
}

/**
 * 当前宿主能不能录音。`undefined` 表示还在探测。
 *
 * 电脑 / 平台预览里没有 App 壳，录音接口不存在——这时页面要给**准确的提示**，
 * 而不是静默失败、更不是去录电脑的麦克风。
 */
export function useRecordingAvailability(): boolean | undefined {
  const [available, setAvailable] = useState<boolean | undefined>(undefined)
  useEffect(() => {
    let cancelled = false
    void (async () => {
      // 注意：mock 宿主下 `isNativeApiAvailable` **恒为 true**（它的用途是"别把入口藏起来"），
      // 所以这里必须先用 initBridge 判宿主，再用 canIUse 确认壳真的注册了录音。
      const mode = await initBridge()
      const ok = mode === 'native' ? await isNativeApiAvailable('recordAudio') : false
      if (!cancelled) setAvailable(ok)
    })()
    return () => {
      cancelled = true
    }
  }, [])
  return available
}
